// cjreg 入口：serve / init / admin
package ystyle::cjreg

import std.argopt.*
import std.convert.*
import std.env.*
import std.io.*
import bstorm.*
import ystyle::cjreg.server.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*
import ystyle::cjreg.config.*
import ystyle::cjreg.ui.*
import cjxt.*
import cjxt.components.*
import std.collection.*

func printUsage(): Unit {
    println("cjreg - 仓颉私有中心仓与多仓工具")
    println()
    println("用法: cjreg <command> [options]")
    println()
    println("命令:")
    println("  serve   启动私有中心仓 HTTP 服务（发布/下载/索引 + 管理 API）")
    println("  init    初始化数据目录（空数据目录创建首个管理员 + 默认官方上游）")
    println("  admin   应急管理（reset-password --username <u> --password <p>）")
    println()
    println("选项:")
    println("  -d, --data <dir>   数据目录（默认 ./data）")
    println("  -p, --port <n>     serve 端口（默认 8060）")
    println("  -h, --help         帮助")
}

main(args: Array<String>): Int64 {
    let specs = [
        Full("data", r'd', RequiredValue),
        Full("port", r'p', RequiredValue),
        Long("username", RequiredValue),
        Long("password", RequiredValue),
        Full("help", r'h', NoValue)
    ]
    var result: ParsedArguments
    try {
        result = parseArguments(args, specs)
    } catch (e: ArgumentParseException) {
        printUsage()
        return 2
    }

    if (result.options.contains("help")) {
        printUsage()
        return 0
    }

    var command = "serve"
    if (result.nonOptions.size >= 1) {
        command = result.nonOptions[0]
    }

    var dataDir = "./data"
    match (result.options.get("data")) {
        case Some(v) => if (!v.isEmpty()) {
            dataDir = v
        }
        case None => ()
    }
    var username = ""
    match (result.options.get("username")) {
        case Some(v) => username = v
        case None => ()
    }
    var password = ""
    match (result.options.get("password")) {
        case Some(v) => password = v
        case None => ()
    }
    var port: UInt16 = 8060
    match (result.options.get("port")) {
        case Some(v) =>
            let n = UInt16.tryParse(v)
            match (n) {
                case Some(p) => port = p
                case None => ()
            }
        case None => ()
    }

    match (command) {
        case "serve" =>
            return cmdServe(dataDir, port)
        case "init" =>
            return cmdInit(dataDir, username, password)
        case "admin" =>
            var sub = ""
            if (result.nonOptions.size >= 2) {
                sub = result.nonOptions[1]
            }
            return cmdAdmin(dataDir, sub, username, password)
        case "admin-ui" =>
            return cmdAdminUI(dataDir, port)
        case _ =>
            println("cjreg: 未知命令 ${command}")
            printUsage()
            return 2
    }
}

// 打开共享存储（PackageStore + BstormUserStore + 上游 store）
func openStores(dataDir: String): ?(PackageStore, BstormUserStore, BstormUpstreamStore) {
    var storm: Storm
    try {
        storm = Storm.open(dataDir + "/cjreg.db", syncWrites: true)
    } catch (e: Exception) {
        println("cjreg: 无法打开数据目录 ${dataDir}: ${e.message}")
        return None
    }
    return Some((PackageStore(storm), BstormUserStore(storm), BstormUpstreamStore(storm)))
}

// serve：启动 HTTP 服务（含管理 API）
func cmdServe(dataDir: String, port: UInt16): Int64 {
    let stores = openStores(dataDir)
    if (stores.isNone()) {
        return 1
    }
    let (pkgStore, userStore, upStore) = stores.getOrThrow()
    let authSvc = AuthService(userStore, 86400)
    let upSvc = UpstreamService(upStore)
    let blobStore: BlobStore = DiskBlobStore(dataDir + "/blobs")
    let proxySvc = ProxyService(pkgStore, blobStore, upSvc)
    let admin = AdminService(authSvc, upSvc, userStore, upStore,
        ResolveService(upSvc), Some(proxySvc), PublishPlanService(pkgStore),
        PublishExecutor(pkgStore, blobStore))

    // 同一 Tang 实例：协议路由 + cjxt 管理/公开页面（单进程共享 store）
    let app = buildServer(pkgStore, Some(admin), Some(upSvc), blobStore)
    let adminData = AdminDataStore(userStore.storm)
    // 重启恢复：执行中的计划复位为待执行（执行线程随进程退出）
    for (planDoc in adminData.listPlans()) {
        if (planDoc.status == "running" || planDoc.status == "paused") {
            let _ = adminData.updatePlanStatus(planDoc.id, "pending", 0, nowMs())
            for (item in adminData.listPlanItems(planDoc.id)) {
                if (item.status == "running") {
                    let _ = adminData.updatePlanItem(item.id, "pending", "", nowMs())
                }
            }
        }
    }
    // 演示/冒烟数据开关：CJREG_SEED_DEMO=1 注入几个本地包（便于验证发布计划等完整流程）
    match (getVariable("CJREG_SEED_DEMO")) {
        case Some(v) => if (v == "1") {
            seedDemoPackages(pkgStore)
        }
        case None => ()
    }
    let cjxtApp = App()
    cjxtApp
        .configure(AppConfig(cssBundle: "/css/bundle.css?v=3"))
        .serveStatic("/css", "public/css")
        .UseComponent()
        .state<CjregState>({ => CjregState(pkgStore, userStore, upStore, adminData, authSvc, app: Some(cjxtApp), permissionMode: permissionModeFromEnv()) })
        .auth({ t => restoreAdminSession(authSvc, t) })
        .port(port)
        .setTang(app)
        .serve()
    return 0
}

// 演示数据注入（CJREG_SEED_DEMO=1）：造几个本地包，便于验证发布计划/包管理等完整流程
func seedDemoPackages(pkgStore: PackageStore): Unit {
    let demos = [
        ("demo", "demo-app", "1.0.0"),
        ("demo", "demo-lib", "2.1.0"),
        ("demo", "demo-util", "0.9.0"),
    ]
    var injected: Int64 = 0
    for ((org, name, version) in demos) {
        if (pkgStore.listVersions(org, name).size > 0) {
            continue
        }
        let d = PackageDoc()
        d.organization = org
        d.name = name
        d.version = version
        d.cjcVersion = "1.1.0"
        d.description = "演示包 ${name}（CJREG_SEED_DEMO 注入）"
        d.artifactType = "src"
        d.executable = true
        d.authors = ArrayList<String>(["ystyle"])
        d.repository = "https://atomgit.com/ystyle/${name}"
        d.homepage = "https://ystyle.top/${name}"
        d.documentation = "https://ystyle.top/${name}/docs"
        d.tag = ArrayList<String>(["demo", "cangjie"])
        d.category = ArrayList<String>(["Utility"])
        d.license = ArrayList<String>(["MIT"])
        d.metaVersion = 1
        d.sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        d.tarballSize = 1024
        d.indexJson = "{\"name\":\"${name}\",\"organization\":\"${org}\",\"version\":\"${version}\",\"sha256sum\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}"
        pkgStore.save(d)
        injected++
    }
    if (injected > 0) {
        println("cjreg: 已注入 ${injected} 个演示包")
    }
}

// init：空数据目录创建首个管理员 + 默认官方上游
func cmdInit(dataDir: String, username: String, password: String): Int64 {
    var storm: Storm
    try {
        storm = Storm.open(dataDir + "/cjreg.db", syncWrites: true)
    } catch (e: Exception) {
        println("cjreg: 无法打开数据目录 ${dataDir}: ${e.message}")
        return 1
    }
    let userStore = BstormUserStore(storm)
    let upStore = BstormUpstreamStore(storm)
    let authSvc = AuthService(userStore, 86400)

    if (!userStore.isEmpty()) {
        println("cjreg: 数据目录已初始化（存在用户），拒绝重复 init")
        storm.close()
        return 1
    }
    // 首个管理员（需 --username/--password）
    if (username.isEmpty() || password.isEmpty()) {
        println("cjreg: init 需要 --username 和 --password 创建首个管理员")
        storm.close()
        return 1
    }
    match (authSvc.initAdmin(username, password)) {
        case Some(u) =>
            println("cjreg: 已创建管理员 ${u.username}（id=${u.id}）")
        case None =>
            println("cjreg: 创建管理员失败")
            storm.close()
            return 1
    }
    // 默认官方上游
    let upSvc = UpstreamService(upStore)
    upSvc.add("official", "https://pkg.cangjie-lang.cn/registry", 0, "", 0)

    println("cjreg: 初始化完成")
    println("  数据目录: ${dataDir}")
    println("  官方上游: official (https://pkg.cangjie-lang.cn/registry)")
    storm.close()  // 必须 close 才落盘（badger flush）
    return 0
}

// admin：应急管理（reset-password）——管理端锁死（管理员被禁用/降级）后的兜底通道
// 语义：重置口令 + 强制 isAdmin=true + isActive=true；信任凭证 = 本地数据目录持有者
func cmdAdmin(dataDir: String, sub: String, username: String, password: String): Int64 {
    let usage = "用法: cjreg admin reset-password --username <用户名> --password <新口令> [-d <数据目录>]"
    if (sub.isEmpty() || sub == "help") {
        println(usage)
        return 2
    }
    if (sub != "reset-password") {
        println("cjreg: 未知的 admin 子命令 ${sub}")
        println(usage)
        return 2
    }
    if (username.isEmpty() || password.isEmpty()) {
        println("cjreg: reset-password 需要 --username 和 --password")
        return 2
    }
    let stores = openStores(dataDir)
    if (stores.isNone()) {
        return 1
    }
    let (_, userStore, _) = stores.getOrThrow()
    let authSvc = AuthService(userStore, 86400)
    let recovered = authSvc.recoverAdmin(username, password)
    userStore.storm.close()  // 必须 close 才落盘（badger flush）
    match (recovered) {
        case Some(u) =>
            println("cjreg: 已重置 ${u.username} 的口令，并确保其为启用状态的管理员（id=${u.id}）")
            return 0
        case None =>
            println("cjreg: 用户 ${username} 不存在（应急恢复不创建新用户）")
            return 1
    }
}

// admin-ui：启动 cjxt 管理界面（直接访问同进程 store/service）
func cmdAdminUI(dataDir: String, port: UInt16): Int64 {
    let stores = openStores(dataDir)
    if (stores.isNone()) {
        return 1
    }
    let (pkgStore, userStore, upStore) = stores.getOrThrow()
    let adminData = AdminDataStore(userStore.storm)
    let authSvc = AuthService(userStore, 86400)
    let cjxtApp = App()
    cjxtApp
        .configure(AppConfig(cssBundle: "/css/bundle.css?v=3"))
        .serveStatic("/css", "public/css")
        .UseComponent()
        .state<CjregState>({ => CjregState(pkgStore, userStore, upStore, adminData, authSvc, app: Some(cjxtApp), permissionMode: permissionModeFromEnv()) })
        .auth({ t => restoreAdminSession(authSvc, t) })
        .host("0.0.0.0").port(port)
        .serve()
    return 0
}
