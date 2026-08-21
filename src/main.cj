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

func printUsage(): Unit {
    println("cjreg - 仓颉私有中心仓与多仓工具")
    println()
    println("用法: cjreg <command> [options]")
    println()
    println("命令:")
    println("  serve   启动私有中心仓 HTTP 服务（发布/下载/索引 + 管理 API）")
    println("  init    初始化数据目录（空数据目录创建首个管理员 + 默认官方上游）")
    println("  admin   应急管理（reset-password）")
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
            return cmdAdmin(dataDir)
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

    let app = buildServer(pkgStore, Some(admin), Some(upSvc), blobStore, port)
    println("cjreg: serving on port ${port} (data=${dataDir})")
    app.listen(port)
    return 0
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

// admin：应急管理（reset-password）——当前占位
func cmdAdmin(dataDir: String): Int64 {
    println("cjreg: admin reset-password 尚未实现（需命令行参数用户名/密码）")
    return 1
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
    App()
        .UseComponent()
        .state<CjregState>({ => CjregState(pkgStore, userStore, upStore, adminData, authSvc) })
        .host("127.0.0.1").port(port)
        .serve()
    return 0
}
