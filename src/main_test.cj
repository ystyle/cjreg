// CLI 入口（runCli）测试：参数解析与命令分派的返回码语义
//
// 为什么能测：`main` 是仓颉关键字、包被导入时也不导出，同包测试引用不到它，
// 所以入口函数体放在普通函数 runCli 里（main 只转发）。这里覆盖的正是原先
// 无法触达的 46–130 行：help / 未知命令 / init / admin 各子命令 / 参数缺失。
//
// 临时目录一律用工作区内 .smoke/（已 gitignore），每个用例独立子目录
// （Badger 对同一目录独占，复用会打开失败）；绝不触碰 ~/docker 下的生产数据。
package ystyle::cjreg

import std.unittest.*
import std.unittest.testmacro.*
import std.fs.*
import std.io.*
import ystyle::cjreg.auth.util.*

let RUNCLI_ROOT = ".smoke/runcli"

// 每个用例一个干净目录
func cliDir(name: String): String {
    let d = "${RUNCLI_ROOT}/${name}"
    if (exists(d)) {
        removeIfExists(d, recursive: true)
    }
    Directory.create(d, recursive: true)
    // 测试提速：PBKDF2 默认 90 万轮，init / reset-password 会慢到秒级
    PasswordHash.ITERATIONS = 1000
    d
}

@Test
class RunCliTest {
    // --help / -h：打印用法并返回 0（不进入任何子命令）
    @TestCase
    func testHelpReturnsZero(): Unit {
        @Expect(runCli(["--help"]), 0)
        @Expect(runCli(["-h"]), 0)
    }

    // 未知命令 → 2
    @TestCase
    func testUnknownCommandReturnsTwo(): Unit {
        @Expect(runCli(["definitely-not-a-command"]), 2)
    }

    // 参数解析失败（-d 缺值）→ 2
    @TestCase
    func testBadArgumentsReturnsTwo(): Unit {
        @Expect(runCli(["serve", "-d"]), 2)
    }

    // init：缺 --username / --password → 1（拒绝）
    @TestCase
    func testInitWithoutCredentialsReturnsOne(): Unit {
        let dir = cliDir("init-nocred")
        @Expect(runCli(["init", "-d", dir]), 1)
    }

    // init：正常创建管理员 + 生成配置文件 → 0
    @TestCase
    func testInitCreatesDataDir(): Unit {
        let dir = cliDir("init-ok")
        @Expect(runCli(["init", "-d", dir, "--username", "admin", "--password", "Passw0rd1"]), 0)
        @Expect(exists(dir + "/cjreg.db"), true)
        @Expect(exists(dir + "/cjreg.toml"), true)
    }

    // init：同一目录重复初始化 → 1（存在用户则拒绝）
    @TestCase
    func testInitTwiceRejected(): Unit {
        let dir = cliDir("init-twice")
        @Expect(runCli(["init", "-d", dir, "--username", "admin", "--password", "Passw0rd1"]), 0)
        @Expect(runCli(["init", "-d", dir, "--username", "admin", "--password", "Passw0rd1"]), 1)
    }

    // init：数据目录不可用（被一个文件占住）→ 1
    @TestCase
    func testInitBlockedDataDirReturnsOne(): Unit {
        let base = cliDir("init-blocked")
        let blocked = base + "/occupied"
        let f = File(blocked, Write)
        f.write("not-a-directory".toArray())
        f.close()
        @Expect(runCli(["init", "-d", blocked, "--username", "admin", "--password", "Passw0rd1"]), 1)
    }

    // admin：无子命令 / help → 2
    @TestCase
    func testAdminUsageReturnsTwo(): Unit {
        @Expect(runCli(["admin"]), 2)
        @Expect(runCli(["admin", "help"]), 2)
    }

    // admin：未知子命令 → 2
    @TestCase
    func testAdminUnknownSubcommandReturnsTwo(): Unit {
        @Expect(runCli(["admin", "no-such-sub"]), 2)
    }

    // admin reset-password：缺口令 → 2
    @TestCase
    func testAdminResetPasswordNeedsCredentials(): Unit {
        let dir = cliDir("reset-nocred")
        @Expect(runCli(["admin", "reset-password", "-d", dir]), 2)
    }

    // admin reset-password：用户存在 → 0；用户不存在 → 1
    @TestCase
    func testAdminResetPasswordBranches(): Unit {
        let dir = cliDir("reset-ok")
        @Expect(runCli(["init", "-d", dir, "--username", "admin", "--password", "Passw0rd1"]), 0)
        @Expect(runCli(["admin", "reset-password", "-d", dir,
            "--username", "admin", "--password", "NewPassw0rd"]), 0)
        // 应急恢复不创建新用户
        @Expect(runCli(["admin", "reset-password", "-d", dir,
            "--username", "ghost", "--password", "NewPassw0rd"]), 1)
    }

    // admin sync-metadata：在没有制品的库上跑完（余额统计为 0，返回 0）
    @TestCase
    func testAdminSyncMetadataRuns(): Unit {
        let dir = cliDir("sync")
        @Expect(runCli(["init", "-d", dir, "--username", "admin", "--password", "Passw0rd1"]), 0)
        let code = runCli(["admin", "sync-metadata", "-d", dir])
        @Expect(code, 0)
    }
}
