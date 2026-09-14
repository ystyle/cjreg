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
import std.fs.*

func printUsage(): Unit {
    println("cjreg - 仓颉私有中心仓与多仓工具")
    println()
    println("用法: cjreg <command> [options]")
    println()
    println("命令:")
    println("  serve   启动私有中心仓 HTTP 服务（发布/下载/索引 + 管理 API）")
    println("  init    初始化数据目录（空数据目录创建首个管理员 + 默认官方上游）")
    println("  admin   管理命令（reset-password 应急重置口令 / sync-metadata 回捞展示字段与 README）")
    println()
    println("选项:")
    println("  -d, --data <dir>     数据目录（默认 ./data）")
    println("  -p, --port <n>       serve 端口（默认 8060；优先于配置文件）")
    println("  -c, --config <file>  配置文件（默认 <数据目录>/cjreg.toml）")
    println("  -h, --help           帮助")
    println()
    println("配置文件（可选，TOML）：")
    println("  [server] public_url / port / permission_mode / require_auth / max_request_bytes")
    println("  发布大包（>30MB）需同时提高仓颉 GC 堆：export cjHeapSize=2GB")
    println("  init 会在数据目录生成一份带注释的 cjreg.toml 模板")
}

main(args: Array<String>): Int64 {
    let specs = [
        Full("data", r'd', RequiredValue),
        Full("port", r'p', RequiredValue),
        Full("config", r'c', RequiredValue),
        Long("username", RequiredValue),
        Long("password", RequiredValue),
        Long("all", NoValue),
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
    // 端口：命令行显式传入才记录（否则让配置文件/默认值决定）
    var cliPort: ?UInt16 = None
    match (result.options.get("port")) {
        case Some(v) =>
            match (UInt16.tryParse(v)) {
                case Some(p) => cliPort = Some(p)
                case None => ()
            }
        case None => ()
    }
    // 配置来源：-c/--config 指定，或数据目录下的 cjreg.toml（单一来源，无环境变量配置）
    var configPath = dataDir + "/cjreg.toml"
    match (result.options.get("config")) {
        case Some(v) => if (!v.isEmpty()) {
            configPath = v
        }
        case None => ()
    }
    let cfg = resolveConfig(configPath, cliPort)
    let port = cfg.port

    match (command) {
        case "serve" =>
            return cmdServe(dataDir, cfg)
        case "init" =>
            return cmdInit(dataDir, username, password, cfg.port)
        case "admin" =>
            var sub = ""
            if (result.nonOptions.size >= 2) {
                sub = result.nonOptions[1]
            }
            return cmdAdmin(dataDir, sub, username, password, result.options.contains("all"))
        case "admin-ui" =>
            return cmdAdminUI(dataDir, cfg)
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
func cmdServe(dataDir: String, cfg: CjregConfig): Int64 {
    setSiteName(cfg.siteName)   // 品牌文字（公开端导航 / 后台侧栏 / 登录页）
    let port = cfg.port
    let stores = openStores(dataDir)
    if (stores.isNone()) {
        return 1
    }
    let (pkgStore, userStore, upStore) = stores.getOrThrow()
    let authSvc = AuthService(userStore, 86400)
    let upSvc = UpstreamService(upStore)
    let blobStore: BlobStore = DiskBlobStore(dataDir + "/blobs")
    let proxySvc = ProxyService(pkgStore, blobStore, upSvc)
    // 权限/审计数据单实例：UI（CjregState）与 HTTP handler 必须共用，否则 id 计数器各自递增会撞车
    let adminData = AdminDataStore(userStore.storm)
    let admin = AdminService(authSvc, upSvc, userStore, upStore,
        ResolveService(upSvc), Some(proxySvc), PublishPlanService(pkgStore),
        PublishExecutor(pkgStore, blobStore), adminData: Some(adminData),
        pkgStore: Some(pkgStore), blobStore: Some(blobStore))

    // 同一 Tang 实例：协议路由 + cjxt 管理/公开页面（单进程共享 store）
    let app = buildServer(pkgStore, Some(admin), Some(upSvc), blobStore, config: cfg,
        adminData: Some(adminData))
    // 重启恢复：执行线程随进程退出 → 把「执行中」的计划转为 paused（可续跑），
    // 进度按**条目状态**重算而不是清零：单条状态是即时落盘的，重启后正是靠它决定
    // 哪些不用再发（清零会让用户以为全都没发过，重复推送只会换回 409）。
    //
    // 顺带把所有计划的进度分母重算一遍（"需要发布的项数"）：老计划的 totalCount 是
    // 「条目总数」，把目标仓已有的项也算进去了（实测「0/6」里其实只有 2 项要发）。
    for (planDoc in adminData.listPlans()) {
        var completed: Int64 = 0
        var required: Int64 = 0
        for (item in adminData.listPlanItems(planDoc.id)) {
            if (item.status == "running") {
                let _ = adminData.updatePlanItem(item.id, "pending", "", nowMs())
            } else if (item.status == "completed") {
                completed++
            }
            if (item.category != "already_exists") {
                required++
            }
        }
        let _ = adminData.setPlanTotal(planDoc.id, required)
        // 索引等待语义变更的兼容迁移：老语义是「每 pollInterval 秒探一次、到 pollTimeout 就
        // 放弃等待」，出厂默认 60s/600s；新语义是固定阶梯 + 默认不超时（0 = 一直等）。
        // 只把**从没改过配置**的老计划迁到新默认，用户自己填过的值不动。
        if (legacyPollDefaults(planDoc.pollInterval, planDoc.pollTimeout)) {
            let _ = adminData.setPlanPollTimeout(planDoc.id, 0)
            println("cjreg: 计划 ${planDoc.id}（${planDoc.name}）索引等待上限迁移为 0（一直等）")
        }
        if (planDoc.status == "running") {
            let _ = adminData.updatePlanStatus(planDoc.id, "paused", completed, nowMs())
            let _ = adminData.setPlanError(planDoc.id,
                "服务重启：计划已自动暂停，点「继续执行」会跳过已完成项接着发", nowMs())
        } else if (planDoc.completedCount != completed) {
            // 非 running 的计划也可能对不上（比如上次是进程被杀在收口前）
            let _ = adminData.updatePlanStatus(planDoc.id, planDoc.status, completed, nowMs())
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
        .configure(AppConfig(title: cfg.siteName, cssBundle: "/css/bundle.css?v=5"))
        .serveStatic("/css", "public/css")
        .UseComponent()
        .state<CjregState>({ =>
            let st = CjregState(pkgStore, userStore, upStore, adminData, authSvc, app: Some(cjxtApp), config: cfg)
            st.blobStore = Some(blobStore)
            st.proxySvc = Some(proxySvc)
            st
        })
        .auth({ t => restoreAdminSession(authSvc, t) })
        .port(port)
        .setTang(app)
        // 请求体上限（cjreg.toml 的 max_request_bytes）：stdx 默认 2MB，大包发布会 413
        .serverBuilder({ sb => sb.maxRequestBodySize(cfg.maxRequestBytes) })
    // 优雅关闭（docker stop / Ctrl+C = SIGINT/SIGTERM）：
    // 钩子在数据库 close 之前执行 → 先停 HTTP 服务（停止接收新请求、断开会话），
    // 再 flush memtable 落盘成 SSTable，最后进程退出（exitAfterClose 默认 true）。
    // 注意：普通 close()（如 init 结束）不触发钩子，仅信号关闭路径触发。
    registerGracefulShutdown(pkgStore.storm, cjxtApp)
    cjxtApp.serve()
    return 0
}

// 注册优雅关闭：SIGINT/SIGTERM → 停服 → 关闭数据库（flush 落盘）→ 退出
// 容器/裸机通用（docker stop、systemctl stop、Ctrl+C）；非 Linux 平台由 bstorm/badger 侧 no-op，
// 此时仍依赖 withSyncWrites 的逐写 fsync 保证不丢数据。
func registerGracefulShutdown(storm: Storm, cjxtApp: App): Unit {
    storm.registerShutdownHook({ =>
        println("cjreg: 收到退出信号，正在优雅关闭（停止服务 → 落盘 → 退出）...")
        // 停 HTTP/WS 时 cjxt 会抛 SocketException（会话正被关掉是常态）。
        // 这里必须自己吞掉：钩子的异常一旦逃出去，库那侧就可能完不成落盘
        // （badger-cj ≥ 本轮修复会隔离钩子异常，但我们不能依赖别人兜底）。
        try {
            cjxtApp.stop()
            println("cjreg: HTTP 服务已停止，等待落盘…")
        } catch (e: Exception) {
            // 关服务的失败不影响落盘：数据库才是关键
            println("cjreg: 停止 HTTP 服务时出错（忽略，继续落盘）: " + e.toString())
        }
    })
    storm.registerSignalShutdown()
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
func cmdInit(dataDir: String, username: String, password: String, port: UInt16): Int64 {
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

    // 生成配置文件模板（已存在则不覆盖，避免抹掉用户配置）
    let cfgPath = dataDir + "/cjreg.toml"
    if (!exists(cfgPath)) {
        try {
            let f = File(cfgPath, Write)
            f.write(configTemplate(port).toArray())
            f.close()
            println("cjreg: 已生成配置文件 ${cfgPath}（按需修改 public_url / permission_mode 等）")
        } catch (e: Exception) {
            println("cjreg: 配置文件生成失败（可忽略，默认值即可运行）: ${e.message}")
        }
    }

    println("cjreg: 初始化完成")
    println("  数据目录: ${dataDir}")
    println("  配置文件: ${cfgPath}")
    println("  官方上游: official (https://pkg.cangjie-lang.cn/registry)")
    storm.close()  // 必须 close 才落盘（badger flush）
    return 0
}

// admin：应急管理 + 存量数据回捞
//   reset-password：管理端锁死（管理员被禁用/降级）后的兜底通道
//     语义：重置口令 + 强制 isAdmin=true + isActive=true；信任凭证 = 本地数据目录持有者
//   sync-metadata：把索引聚合包缺的展示字段/README 从制品（.cjp）里回捞补齐
func cmdAdmin(dataDir: String, sub: String, username: String, password: String, all: Bool): Int64 {
    let usage = "用法: cjreg admin reset-password --username <用户名> --password <新口令> [-d <数据目录>]\n" +
        "      cjreg admin sync-metadata [-d <数据目录>] [--all]"
    if (sub.isEmpty() || sub == "help") {
        println(usage)
        return 2
    }
    if (sub == "sync-metadata") {
        return cmdSyncMetadata(dataDir, all)
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

// admin sync-metadata：存量包展示字段/README 回捞
//
// 为什么需要：索引协议（NDJSON）只带 name/version/deps/sha256sum，回源聚合落库的包
// 描述/协议/作者/README 全空（列表页一片空白）；老版本的发布路径也没提取 README。
// 这些信息只在制品（.cjp = gzip+tar）内部，所以命令做的是：取制品 → 解压 → 补空字段。
//   默认只管每个包的最新版本（列表页展示它）；--all 处理所有版本。
func cmdSyncMetadata(dataDir: String, all: Bool): Int64 {
    let stores = openStores(dataDir)
    if (stores.isNone()) {
        return 1
    }
    let (pkgStore, _, upStore) = stores.getOrThrow()
    let blobStore: BlobStore = DiskBlobStore(dataDir + "/blobs")
    let upSvc = UpstreamService(upStore)
    let proxy = ProxyService(pkgStore, blobStore, upSvc)
    println("cjreg: 开始回捞展示字段/README（范围：${if (all) { "所有版本" } else { "每个包的最新版本" }}）")
    let report = syncPackageMetadata(pkgStore, blobStore, proxy, all)
    pkgStore.storm.close()  // 必须 close 才落盘（badger flush）
    println("cjreg: 补收录时间 ${report.stamped} 个版本文档（回源落库早于该字段）")
    println("cjreg: 回捞完成 —— 包 ${report.packages} 个，待补版本 ${report.candidates} 个，" +
        "补齐 ${report.enriched} 个，制品无新增可补内容 ${report.unchanged} 个，制品取不到 ${report.unresolved} 个")
    println("cjreg: 补完后仍缺 —— README ${report.missingReadme} 个，" +
        "描述 ${report.missingDesc} 个，协议 ${report.missingLicense} 个，" +
        "任一展示字段为空 ${report.stillIncomplete} 个（分类/标签等制作者没写就是没有）")
    return if (report.unresolved > 0) { 1 } else { 0 }
}

// admin-ui：启动 cjxt 管理界面（直接访问同进程 store/service）
func cmdAdminUI(dataDir: String, cfg: CjregConfig): Int64 {
    setSiteName(cfg.siteName)
    let port = cfg.port
    let stores = openStores(dataDir)
    if (stores.isNone()) {
        return 1
    }
    let (pkgStore, userStore, upStore) = stores.getOrThrow()
    let adminData = AdminDataStore(userStore.storm)
    let authSvc = AuthService(userStore, 86400)
    // 制品库（包硬删除清理 blob）：与 serve 相同的磁盘布局
    let blobStore: BlobStore = DiskBlobStore(dataDir + "/blobs")
    // 回源代理（管理端「重拉」用）：与 serve 同构
    let proxySvc = ProxyService(pkgStore, blobStore, UpstreamService(upStore))
    let cjxtApp = App()
    cjxtApp
        .configure(AppConfig(title: cfg.siteName, cssBundle: "/css/bundle.css?v=5"))
        .serveStatic("/css", "public/css")
        .UseComponent()
        .state<CjregState>({ =>
            let st = CjregState(pkgStore, userStore, upStore, adminData, authSvc, app: Some(cjxtApp), config: cfg)
            st.blobStore = Some(blobStore)
            st.proxySvc = Some(proxySvc)
            st
        })
        .auth({ t => restoreAdminSession(authSvc, t) })
        .host("0.0.0.0").port(port)
        .serverBuilder({ sb => sb.maxRequestBodySize(cfg.maxRequestBytes) })
    registerGracefulShutdown(pkgStore.storm, cjxtApp)
    cjxtApp.serve()
    return 0
}
