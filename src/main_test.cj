// 根包（src/main.cj）单元测试：CLI 子命令与数据目录装配
//
// ⚠️ 覆盖边界（重要）：仓颉把 `main` 列为**关键字**，且官方文档明确「当一个包被导入时，
// 包中定义的 main 不会被导入」—— 同包的测试代码也无法引用它：
//   `main([...])` / `let f = main` / `` `main`([...]) `` / `PackageName.main(...)`
//   全部编译不过（实测分别报 "found keyword 'main'" / "undeclared identifier 'main'"）；
//   反射 `PackageInfo.get("ystyle::cjreg").functions` 也拿不到它（恒为空）。
// 因此这里覆盖的是 main() **调用到的**那些顶层函数：printUsage / openStores /
// seedDemoPackages / cmdInit / cmdAdmin / cmdSyncMetadata，以及 cmdServe / cmdAdminUI
// 的**早退分支**（数据目录不可用时返回 1，不会进入阻塞的 serve()）。
// main() 自身的参数解析与命令分派（46–130 行）在语言层面无法被单测触达，只能靠
// tests/e2e.sh 与手工冒烟覆盖 —— 这是仓颉语言约束，非本仓设计取舍。
//
// 临时目录一律用 worktree 内的 .smoke/main-cov/<case>：每个用例独立子目录
// （Badger 对同一目录独占，复用会打开失败），用完即关。
package ystyle::cjreg

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.*
import std.io.*
import bstorm.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.util.*
import ystyle::cjreg.auth.model.*
import ystyle::cjreg.config.*
import ystyle::cjreg.index.*
import ystyle::cjreg.ui.{SITE_NAME, setSiteName}

// ===== 目录与夹具 =====

let MAIN_TEST_ROOT = ".smoke/main-cov"

// 每个用例一个干净目录；返回目录路径
func freshDir(name: String): String {
    let d = "${MAIN_TEST_ROOT}/${name}"
    if (exists(d)) {
        removeIfExists(d, recursive: true)
    }
    Directory.create(d, recursive: true)
    PasswordHash.ITERATIONS = 1000   // 测试提速：PBKDF2 默认 90 万轮太慢
    d
}

// 用一个**文件**占住本应是数据目录的路径：Badger 无法在其下建 cjreg.db，
// openStores 因此返回 None —— 用来触发各命令的"数据目录不可用"分支。
func blockedDir(name: String): String {
    let p = "${MAIN_TEST_ROOT}/${name}-blocked"
    if (exists(p)) {
        removeIfExists(p, recursive: true)
    }
    let f = File(p, Write)
    f.write("not a directory".toArray())
    f.close()
    p
}

func cfgOf(port!: UInt16 = 8060): CjregConfig {
    let c = CjregConfig()
    c.port = port
    return c
}

@Test
public class MainUsageAndStoresTest {
    // printUsage 全量打印（含每个命令与选项），只要不抛异常并走到末尾即可
    @TestCase
    public func testPrintUsageRuns(): Unit {
        printUsage()
        // 再来一次：纯打印，无状态，可重复
        printUsage()
    }

    // openStores：已有目录 → Some（三个 store 都可用）
    @TestCase
    public func testOpenStoresOnExistingDir(): Unit {
        let d = freshDir("open-existing")
        let r = openStores(d)
        @Expect(r.isSome(), true)
        match (r) {
            case Some((pkgStore, userStore, upStore)) =>
                // 三个 store 都能读写（空库）
                @Expect(pkgStore.storm.all<PackageDoc>().size, 0)
                @Expect(userStore.listAllUsers().size, 0)
                @Expect(upStore.listAll().size, 0)
                // 写一条能读回，证明 storm 真的可用
                let doc = PackageDoc()
                doc.organization = "org"
                doc.name = "n"
                doc.version = "1.0.0"
                pkgStore.save(doc)
                @Expect(pkgStore.storm.all<PackageDoc>().size, 1)
                pkgStore.storm.close()
            case None => @Fail("已有目录应能打开")
        }
    }

    // openStores：目录不存在时 Badger 会自建 → 仍返回 Some（新数据目录是正常路径）
    @TestCase
    public func testOpenStoresCreatesMissingDir(): Unit {
        let d = "${MAIN_TEST_ROOT}/open-missing/nested"
        if (exists("${MAIN_TEST_ROOT}/open-missing")) {
            removeIfExists("${MAIN_TEST_ROOT}/open-missing", recursive: true)
        }
        let r = openStores(d)
        @Expect(r.isSome(), true)
        match (r) {
            case Some((pkgStore, _, _)) => pkgStore.storm.close()
            case None => ()
        }
    }

    // openStores：路径被文件占住 → 打日志并返回 None（调用方据此返回 1）
    @TestCase
    public func testOpenStoresFailsWhenPathIsAFile(): Unit {
        let p = blockedDir("open-file")
        let r = openStores(p)
        @Expect(r.isNone(), true)
    }

    // 关闭后重开同一数据目录：写入的数据必须还在（init → serve 的跨进程复用路径）
    @TestCase
    public func testReopenSeesPersistedPackage(): Unit {
        let d = freshDir("open-reopen")
        let first = openStores(d)
        @Expect(first.isSome(), true)
        match (first) {
            case Some((pkgStore, _, _)) =>
                let doc = PackageDoc()
                doc.organization = "org"
                doc.name = "persisted"
                doc.version = "1.0.0"
                pkgStore.save(doc)
                @Expect(pkgStore.listVersions("org", "persisted").size, 1)
                pkgStore.storm.close()
            case None => @Fail("首次打开应成功")
        }
        // 重开：close 会 flush，数据应可读回
        let second = openStores(d)
        @Expect(second.isSome(), true)
        match (second) {
            case Some((pkgStore, _, _)) =>
                @Expect(pkgStore.listVersions("org", "persisted").size, 1)
                @Expect(pkgStore.listVersions("org", "persisted")[0].version, "1.0.0")
                pkgStore.storm.close()
            case None => @Fail("重开应成功")
        }
    }
}

@Test
public class MainSeedDemoTest {
    // 演示数据注入：三个包落库且字段完整（含索引 NDJSON 原文）
    @TestCase
    public func testSeedDemoPackagesInjectsThreePackages(): Unit {
        let storm = Storm.inMemory()
        let pkgStore = PackageStore(storm)
        seedDemoPackages(pkgStore)

        @Expect(pkgStore.listVersions("demo", "demo-app").size, 1)
        @Expect(pkgStore.listVersions("demo", "demo-lib").size, 1)
        @Expect(pkgStore.listVersions("demo", "demo-util").size, 1)
        @Expect(storm.all<PackageDoc>().size, 3)

        let d = pkgStore.listVersions("demo", "demo-lib")[0]
        @Expect(d.version, "2.1.0")
        @Expect(d.cjcVersion, "1.1.0")
        @Expect(d.artifactType, "src")
        @Expect(d.executable, true)
        @Expect(d.description.contains("演示包"), true)
        @Expect(d.repository.contains("demo-lib"), true)
        @Expect(d.license.size, 1)
        @Expect(d.tag.size, 2)
        @Expect(d.category.size, 1)
        @Expect(d.tarballSize, 1024)
        @Expect(d.sha256.size, 64)
        // indexJson 走协议自己的序列化器，能被解析回一条索引
        @Expect(d.indexJson.contains("demo-lib"), true)
        @Expect(parseNDJSON(d.indexJson).size, 1)
        storm.close()
    }

    // 幂等：已存在的包不再注入（重复调用不产生第二份版本）
    @TestCase
    public func testSeedDemoPackagesIsIdempotent(): Unit {
        let storm = Storm.inMemory()
        let pkgStore = PackageStore(storm)
        seedDemoPackages(pkgStore)
        seedDemoPackages(pkgStore)      // 第二次应全部跳过
        @Expect(storm.all<PackageDoc>().size, 3)
        @Expect(pkgStore.listVersions("demo", "demo-app").size, 1)
        storm.close()
    }

    // 部分已存在时只补缺的那些（listVersions 非空即跳过）
    @TestCase
    public func testSeedDemoPackagesFillsOnlyMissing(): Unit {
        let storm = Storm.inMemory()
        let pkgStore = PackageStore(storm)
        let pre = PackageDoc()
        pre.organization = "demo"
        pre.name = "demo-app"
        pre.version = "9.9.9"          // 已存在（版本不同也算"这个包已注入过"）
        pkgStore.save(pre)

        seedDemoPackages(pkgStore)
        // demo-app 保持原本那一条，另两个被补上
        @Expect(pkgStore.listVersions("demo", "demo-app").size, 1)
        @Expect(pkgStore.listVersions("demo", "demo-app")[0].version, "9.9.9")
        @Expect(pkgStore.listVersions("demo", "demo-lib").size, 1)
        @Expect(pkgStore.listVersions("demo", "demo-util").size, 1)
        @Expect(storm.all<PackageDoc>().size, 3)
        storm.close()
    }
}

@Test
public class CmdInitTest {
    // 正常 init：建管理员 + 默认官方上游 + 生成 cjreg.toml 配置模板
    @TestCase
    public func testInitCreatesAdminUpstreamAndConfig(): Unit {
        let d = freshDir("init-ok")
        @Expect(cmdInit(d, "admin", "Passw0rd1", 8060), 0)

        // 数据目录与配置文件都生成了
        @Expect(exists(d + "/cjreg.db"), true)
        @Expect(exists(d + "/cjreg.toml"), true)

        // 配置模板：端口写进去、含 [server] 段
        let f = File(d + "/cjreg.toml", Read)
        let content = String.fromUtf8(readToEnd(f))
        f.close()
        @Expect(content.contains("[server]"), true)
        @Expect(content.contains("8060"), true)

        // 管理员可登录，且是启用的管理员
        let stores = openStores(d)
        @Expect(stores.isSome(), true)
        match (stores) {
            case Some((_, userStore, upStore)) =>
                @Expect(userStore.listAllUsers().size, 1)
                let u = userStore.getUserByUsername("admin").getOrThrow()
                @Expect(u.isAdmin, true)
                @Expect(u.isActive, true)
                @Expect(u.publishToken.isEmpty(), false)
                let auth = AuthService(userStore, 3600)
                @Expect(auth.login("admin", "Passw0rd1").isSome(), true)
                @Expect(auth.login("admin", "wrong").isNone(), true)
                // 默认官方上游
                let ups = upStore.listAll()
                @Expect(ups.size, 1)
                @Expect(ups[0].name, "official")
                @Expect(ups[0].url, "https://pkg.cangjie-lang.cn/registry")
                userStore.storm.close()
            case None => @Fail("init 后应能打开数据目录")
        }
    }

    // 已初始化（存在用户）→ 拒绝重复 init，返回 1；原管理员不受影响
    @TestCase
    public func testInitRefusesSecondRun(): Unit {
        let d = freshDir("init-twice")
        @Expect(cmdInit(d, "admin", "Passw0rd1", 8060), 0)
        @Expect(cmdInit(d, "admin2", "Other1pass", 8060), 1)

        let stores = openStores(d)
        match (stores) {
            case Some((_, userStore, _)) =>
                @Expect(userStore.listAllUsers().size, 1)                    // 没多出用户
                @Expect(userStore.getUserByUsername("admin2").isNone(), true)
                @Expect(userStore.getUserByUsername("admin").isSome(), true)
                userStore.storm.close()
            case None => @Fail("数据目录应可打开")
        }
    }

    // 缺 --username / --password → 返回 1，且不建用户、不生成配置文件
    @TestCase
    public func testInitRequiresCredentials(): Unit {
        let d1 = freshDir("init-nouser")
        @Expect(cmdInit(d1, "", "Passw0rd1", 8060), 1)
        @Expect(exists(d1 + "/cjreg.toml"), false)
        let s1 = openStores(d1)
        match (s1) {
            case Some((_, userStore, _)) =>
                @Expect(userStore.listAllUsers().size, 0)
                userStore.storm.close()
            case None => ()
        }

        let d2 = freshDir("init-nopass")
        @Expect(cmdInit(d2, "admin", "", 8060), 1)
        @Expect(exists(d2 + "/cjreg.toml"), false)

        let d3 = freshDir("init-both-empty")
        @Expect(cmdInit(d3, "", "", 8060), 1)
    }

    // 已存在的 cjreg.toml 不被覆盖（避免抹掉用户配置）
    @TestCase
    public func testInitDoesNotOverwriteExistingConfig(): Unit {
        let d = freshDir("init-keep-config")
        let f = File(d + "/cjreg.toml", Write)
        f.write("# 用户自己的配置\n[server]\nport = 9999\n".toArray())
        f.close()

        @Expect(cmdInit(d, "admin", "Passw0rd1", 8060), 0)
        let rf = File(d + "/cjreg.toml", Read)
        let content = String.fromUtf8(readToEnd(rf))
        rf.close()
        @Expect(content.contains("用户自己的配置"), true)
        @Expect(content.contains("9999"), true)
    }

    // 数据目录不可用（路径被文件占住）→ 返回 1，不抛异常
    @TestCase
    public func testInitFailsOnUnusableDir(): Unit {
        let p = blockedDir("init-blocked")
        @Expect(cmdInit(p, "admin", "Passw0rd1", 8060), 1)
    }

    // 端口写进配置模板（-p 生效链路的一环）
    @TestCase
    public func testInitWritesGivenPort(): Unit {
        let d = freshDir("init-port")
        @Expect(cmdInit(d, "admin", "Passw0rd1", 18099), 0)
        let f = File(d + "/cjreg.toml", Read)
        let content = String.fromUtf8(readToEnd(f))
        f.close()
        @Expect(content.contains("18099"), true)
    }
}

@Test
public class CmdAdminTest {
    // 空子命令与 help → 用法提示 + 返回 2
    @TestCase
    public func testAdminUsageForEmptyAndHelp(): Unit {
        let d = freshDir("admin-usage")
        @Expect(cmdAdmin(d, "", "", "", false), 2)
        @Expect(cmdAdmin(d, "help", "", "", false), 2)
    }

    // 未知子命令 → 返回 2（并打印用法）
    @TestCase
    public func testAdminUnknownSubcommand(): Unit {
        let d = freshDir("admin-unknown")
        @Expect(cmdAdmin(d, "no-such-sub", "", "", false), 2)
        // 大小写敏感：Reset-Password 不是合法子命令
        @Expect(cmdAdmin(d, "Reset-Password", "admin", "NewPass1", false), 2)
    }

    // reset-password 缺参数 → 返回 2（usage 级错误，不是运行失败）
    @TestCase
    public func testAdminResetPasswordRequiresCredentials(): Unit {
        let d = freshDir("admin-rp-nocreds")
        @Expect(cmdInit(d, "admin", "Passw0rd1", 8060), 0)
        @Expect(cmdAdmin(d, "reset-password", "", "NewPass1", false), 2)
        @Expect(cmdAdmin(d, "reset-password", "admin", "", false), 2)
        @Expect(cmdAdmin(d, "reset-password", "", "", false), 2)
    }

    // 重置已存在用户的口令 → 0；新口令可登录、用户被强制为启用管理员
    @TestCase
    public func testAdminResetPasswordExistingUser(): Unit {
        let d = freshDir("admin-rp-ok")
        @Expect(cmdInit(d, "admin", "Passw0rd1", 8060), 0)
        @Expect(cmdAdmin(d, "reset-password", "admin", "NewPass1", false), 0)

        let stores = openStores(d)
        match (stores) {
            case Some((_, userStore, _)) =>
                let auth = AuthService(userStore, 3600)
                @Expect(auth.login("admin", "NewPass1").isSome(), true)     // 新口令生效
                @Expect(auth.login("admin", "Passw0rd1").isNone(), true)   // 旧口令失效
                let u = userStore.getUserByUsername("admin").getOrThrow()
                @Expect(u.isAdmin, true)
                @Expect(u.isActive, true)
                userStore.storm.close()
            case None => @Fail("数据目录应可打开")
        }
    }

    // reset-password 对不存在的用户 → 1（应急恢复**不**创建新用户）
    @TestCase
    public func testAdminResetPasswordUnknownUser(): Unit {
        let d = freshDir("admin-rp-missing")
        @Expect(cmdInit(d, "admin", "Passw0rd1", 8060), 0)
        @Expect(cmdAdmin(d, "reset-password", "ghost", "NewPass1", false), 1)

        let stores = openStores(d)
        match (stores) {
            case Some((_, userStore, _)) =>
                @Expect(userStore.listAllUsers().size, 1)                  // 没多出用户
                @Expect(userStore.getUserByUsername("ghost").isNone(), true)
                userStore.storm.close()
            case None => @Fail("数据目录应可打开")
        }
    }

    // 重置时把被禁用/降级的账号一并拉回可用管理员（应急通道的语义）
    @TestCase
    public func testAdminResetPasswordRestoresDisabledNonAdmin(): Unit {
        let d = freshDir("admin-rp-restore")
        @Expect(cmdInit(d, "admin", "Passw0rd1", 8060), 0)
        // 先把 admin 弄成"被禁用且非管理员"
        let stores = openStores(d)
        match (stores) {
            case Some((_, userStore, _)) =>
                let u = userStore.getUserByUsername("admin").getOrThrow()
                u.isAdmin = false
                u.isActive = false
                userStore.saveUser(u)
                userStore.storm.close()
            case None => @Fail("数据目录应可打开")
        }
        // 此时登录不了
        let before = openStores(d)
        match (before) {
            case Some((_, userStore, _)) =>
                @Expect(AuthService(userStore, 3600).login("admin", "Passw0rd1").isNone(), true)
                userStore.storm.close()
            case None => ()
        }
        // 应急重置 → 恢复为启用管理员
        @Expect(cmdAdmin(d, "reset-password", "admin", "NewPass1", false), 0)
        let after = openStores(d)
        match (after) {
            case Some((_, userStore, _)) =>
                let u = userStore.getUserByUsername("admin").getOrThrow()
                @Expect(u.isAdmin, true)
                @Expect(u.isActive, true)
                @Expect(AuthService(userStore, 3600).login("admin", "NewPass1").isSome(), true)
                userStore.storm.close()
            case None => @Fail("数据目录应可打开")
        }
    }

    // reset-password 在数据目录不可用时 → 1
    @TestCase
    public func testAdminResetPasswordFailsOnUnusableDir(): Unit {
        let p = blockedDir("admin-rp-blocked")
        @Expect(cmdAdmin(p, "reset-password", "admin", "NewPass1", false), 1)
    }

    // sync-metadata 子命令被正确分派（空库 → 没有待回捞项 → 0）
    @TestCase
    public func testAdminDispatchesSyncMetadata(): Unit {
        let d = freshDir("admin-sync")
        @Expect(cmdInit(d, "admin", "Passw0rd1", 8060), 0)
        @Expect(cmdAdmin(d, "sync-metadata", "", "", false), 0)
        // --all 也接受（all=true 分支）
        @Expect(cmdAdmin(d, "sync-metadata", "", "", true), 0)
    }
}

@Test
public class CmdSyncMetadataTest {
    // 空库：没有候选版本，报表全 0，返回 0
    @TestCase
    public func testSyncMetadataOnEmptyStore(): Unit {
        let d = freshDir("sync-empty")
        @Expect(cmdInit(d, "admin", "Passw0rd1", 8060), 0)
        @Expect(cmdSyncMetadata(d, false), 0)
        @Expect(cmdSyncMetadata(d, true), 0)
    }

    // 数据目录不可用 → 1
    @TestCase
    public func testSyncMetadataFailsOnUnusableDir(): Unit {
        let p = blockedDir("sync-blocked")
        @Expect(cmdSyncMetadata(p, false), 1)
    }

    // 本地版本只缺「收录时间」：sync 会补 createdAt 并返回 0（制品取不到不影响返回值）
    @TestCase
    public func testSyncMetadataStampsCollectedAt(): Unit {
        let d = freshDir("sync-stamp")
        @Expect(cmdInit(d, "admin", "Passw0rd1", 8060), 0)
        // 造一个 createdAt=0 的版本（模拟早于该字段的回源落库）
        let stores = openStores(d)
        match (stores) {
            case Some((pkgStore, _, _)) =>
                let doc = PackageDoc()
                doc.organization = "ystyle"
                doc.name = "legacy"
                doc.version = "1.0.0"
                doc.createdAt = 0
                doc.updatedAt = 0
                pkgStore.save(doc)
                pkgStore.storm.close()
            case None => @Fail("数据目录应可打开")
        }
        // sync 补收录时间；制品本地没有也不会抛异常
        let rc = cmdSyncMetadata(d, false)
        @Expect(rc == 0 || rc == 1, true)

        let after = openStores(d)
        match (after) {
            case Some((pkgStore, _, _)) =>
                let docs = pkgStore.listVersions("ystyle", "legacy")
                @Expect(docs.size, 1)
                @Expect(docs[0].createdAt > 0, true)   // 补上了收录时间
                pkgStore.storm.close()
            case None => @Fail("数据目录应可打开")
        }
    }

    // --all 会处理所有版本（多版本库同样能跑完且不抛异常）
    @TestCase
    public func testSyncMetadataAllVersionsRuns(): Unit {
        let d = freshDir("sync-all")
        @Expect(cmdInit(d, "admin", "Passw0rd1", 8060), 0)
        let stores = openStores(d)
        match (stores) {
            case Some((pkgStore, _, _)) =>
                for (v in ["1.0.0", "1.0.1", "2.0.0"]) {
                    let doc = PackageDoc()
                    doc.organization = "ystyle"
                    doc.name = "multi"
                    doc.version = v
                    doc.createdAt = 0
                    pkgStore.save(doc)
                }
                pkgStore.storm.close()
            case None => @Fail("数据目录应可打开")
        }
        let rc = cmdSyncMetadata(d, true)
        @Expect(rc == 0 || rc == 1, true)

        let after = openStores(d)
        match (after) {
            case Some((pkgStore, _, _)) =>
                @Expect(pkgStore.listVersions("ystyle", "multi").size, 3)
                for (doc in pkgStore.listVersions("ystyle", "multi")) {
                    @Expect(doc.createdAt > 0, true)
                }
                pkgStore.storm.close()
            case None => @Fail("数据目录应可打开")
        }
    }
}

@Test
public class BlockingCommandEarlyExitTest {
    // serve：数据目录不可用时返回 1，**不会**进入阻塞的 cjxtApp.serve()
    @TestCase
    public func testServeReturnsEarlyOnUnusableDir(): Unit {
        let p = blockedDir("serve-blocked")
        @Expect(cmdServe(p, cfgOf()), 1)
    }

    // admin-ui：同样在打不开数据目录时返回 1，不阻塞
    @TestCase
    public func testAdminUIReturnsEarlyOnUnusableDir(): Unit {
        let p = blockedDir("adminui-blocked")
        @Expect(cmdAdminUI(p, cfgOf()), 1)
    }

    // 两个命令都会先把 cfg.siteName 写进品牌文字（这条在早退前就已执行）
    @TestCase
    public func testServeSetsSiteNameBeforeEarlyExit(): Unit {
        let p = blockedDir("serve-sitename")
        let cfg = cfgOf()
        cfg.siteName = "brand-check"
        @Expect(cmdServe(p, cfg), 1)
        @Expect(SITE_NAME, "brand-check")
        setSiteName(DEFAULT_SITE_NAME)   // 还原，避免影响同进程其它用例
    }
}
