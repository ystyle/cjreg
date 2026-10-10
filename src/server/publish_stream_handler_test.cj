// 流式发布路径测试（publishStream + server.cj 的 tmpDir 分支）
//
// 大包发布是决赛的核心能力（内存与包体无关），它的实现是 publishStream：
// 制品由 intakePublishBody 边读边落临时文件并算 sha，再 claimFile 原子进位。
// 这里通过真实 HTTP + 磁盘 blob 夹具覆盖它的全部分支：
// 认证、meta 校验、sha 比对、同 sha 幂等、覆盖裁决、流式落盘后字节一致、失败时清理临时文件。
package ystyle::cjreg.server

import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

// 统计目录下残留的发布临时文件（.tmp- 前缀；失败路径必须清干净）
func tmpPublishLeftovers(dir: String): Int64 {
    var n: Int64 = 0
    for (f in Directory.readFrom(Path(dir))) {
        if (f.name.startsWith(".tmp-")) {
            n++
        }
    }
    n
}

@Test
class PublishStreamPathTest {
    // 流式发布成功：制品落盘、sha 与字节一致、临时文件不残留
    @TestCase
    func testStreamPublishSucceeds(): Unit {
        let dir = covScratch("stream-ok")
        let env = newHttpEnv(mode: "open", tmpDir: dir)
        try {
            let token = seedAdminToken(env)
            let pub = publishTokenOf(env, token)
            let art = "streamed-artifact-payload".toArray()
            let resp = httpPostRaw(env, "/pkg/sp?organization=acme",
                publishBody("acme", "sp", "1.0.0", art, sha256: sha256Hex(art)), token: pub)
            @Expect(resp.status, 200u16)

            // 落库且 sha/大小正确
            let versions = env.pkgStore.listVersions("acme", "sp")
            @Expect(versions.size, 1)
            @Expect(versions[0].sha256, sha256Hex(art))
            @Expect(versions[0].tarballSize, art.size)
            // 制品可下载且字节一致（走 blob）
            @Expect(env.blobStore.get(versions[0].sha256).isSome(), true)
            // 无残留临时文件
            @Expect(tmpPublishLeftovers(dir), 0)
        } finally {
            env.close()
        }
    }

    // 流式发布：无 token → 401 且临时文件被清掉
    @TestCase
    func testStreamPublishMissingTokenCleansTemp(): Unit {
        let dir = covScratch("stream-notoken")
        let env = newHttpEnv(mode: "open", tmpDir: dir)
        try {
            let _ = seedAdminToken(env)
            let art = "x".toArray()
            let resp = httpPostRaw(env, "/pkg/nt?organization=acme",
                publishBody("acme", "nt", "1.0.0", art, sha256: sha256Hex(art)))
            @Expect(resp.status, 401u16)
            @Expect(tmpPublishLeftovers(dir), 0)
        } finally {
            env.close()
        }
    }

    // 流式发布：无效 token → 401
    @TestCase
    func testStreamPublishInvalidToken(): Unit {
        let dir = covScratch("stream-badtoken")
        let env = newHttpEnv(mode: "open", tmpDir: dir)
        try {
            let _ = seedAdminToken(env)
            let art = "x".toArray()
            let resp = httpPostRaw(env, "/pkg/bt?organization=acme",
                publishBody("acme", "bt", "1.0.0", art, sha256: sha256Hex(art)), token: "not-a-token")
            @Expect(resp.status, 401u16)
            @Expect(tmpPublishLeftovers(dir), 0)
        } finally {
            env.close()
        }
    }

    // 流式发布：meta 与 URL 不一致 → 400 MetaMismatch
    @TestCase
    func testStreamPublishMetaMismatch(): Unit {
        let dir = covScratch("stream-meta")
        let env = newHttpEnv(mode: "open", tmpDir: dir)
        try {
            let token = seedAdminToken(env)
            let pub = publishTokenOf(env, token)
            let art = "y".toArray()
            // URL 是 other，meta 里是 acme
            let resp = httpPostRaw(env, "/pkg/mm?organization=other",
                publishBody("acme", "mm", "1.0.0", art, sha256: sha256Hex(art)), token: pub)
            @Expect(resp.status, 400u16)
            @Expect(tmpPublishLeftovers(dir), 0)
        } finally {
            env.close()
        }
    }

    // 流式发布：meta 里的 sha 与实际不符 → 400 ShaMismatch
    @TestCase
    func testStreamPublishShaMismatch(): Unit {
        let dir = covScratch("stream-sha")
        let env = newHttpEnv(mode: "open", tmpDir: dir)
        try {
            let token = seedAdminToken(env)
            let pub = publishTokenOf(env, token)
            let art = "z".toArray()
            let wrong = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
            let resp = httpPostRaw(env, "/pkg/sm?organization=acme",
                publishBody("acme", "sm", "1.0.0", art, sha256: wrong), token: pub)
            @Expect(resp.status, 400u16)
            @Expect(tmpPublishLeftovers(dir), 0)
        } finally {
            env.close()
        }
    }

    // 流式发布：同版本同 sha 重复发 → 幂等成功（200），不产生第二条记录
    @TestCase
    func testStreamPublishSameShaIsIdempotent(): Unit {
        let dir = covScratch("stream-idem")
        let env = newHttpEnv(mode: "open", tmpDir: dir)
        try {
            let token = seedAdminToken(env)
            let pub = publishTokenOf(env, token)
            let art = "idempotent".toArray()
            let body = publishBody("acme", "idem", "1.0.0", art, sha256: sha256Hex(art))
            @Expect(httpPostRaw(env, "/pkg/idem?organization=acme", body, token: pub).status, 200u16)
            @Expect(httpPostRaw(env, "/pkg/idem?organization=acme", body, token: pub).status, 200u16)
            @Expect(env.pkgStore.listVersions("acme", "idem").size, 1)
            @Expect(tmpPublishLeftovers(dir), 0)
        } finally {
            env.close()
        }
    }

    // 流式发布：同版本不同 sha（open 模式无覆盖权）→ 409，且原记录不被改
    @TestCase
    func testStreamPublishConflictKeepsOriginal(): Unit {
        let dir = covScratch("stream-conflict")
        let env = newHttpEnv(mode: "open", tmpDir: dir)
        try {
            let token = seedAdminToken(env)
            let pub = publishTokenOf(env, token)
            let first = "first-content".toArray()
            @Expect(httpPostRaw(env, "/pkg/cf?organization=acme",
                publishBody("acme", "cf", "1.0.0", first, sha256: sha256Hex(first)), token: pub).status, 200u16)

            let second = "second-content".toArray()
            let conflict = httpPostRaw(env, "/pkg/cf?organization=acme",
                publishBody("acme", "cf", "1.0.0", second, sha256: sha256Hex(second)), token: pub)
            @Expect(conflict.status, 409u16)

            // 原 sha 未被覆盖
            @Expect(env.pkgStore.listVersions("acme", "cf")[0].sha256, sha256Hex(first))
            @Expect(tmpPublishLeftovers(dir), 0)
        } finally {
            env.close()
        }
    }

    // 流式发布：team 模式管理员同版本不同 sha → 允许覆盖（预演必需）
    @TestCase
    func testStreamPublishAdminOverwriteInTeamMode(): Unit {
        let dir = covScratch("stream-overwrite")
        let env = newHttpEnv(mode: "team", tmpDir: dir)
        try {
            let token = seedAdminToken(env)
            let pub = publishTokenOf(env, token)
            let first = "v1".toArray()
            @Expect(httpPostRaw(env, "/pkg/ow?organization=acme",
                publishBody("acme", "ow", "1.0.0", first, sha256: sha256Hex(first)), token: pub).status, 200u16)

            let second = "v2-changed".toArray()
            @Expect(httpPostRaw(env, "/pkg/ow?organization=acme",
                publishBody("acme", "ow", "1.0.0", second, sha256: sha256Hex(second)), token: pub).status, 200u16)
            @Expect(env.pkgStore.listVersions("acme", "ow")[0].sha256, sha256Hex(second))
        } finally {
            env.close()
        }
    }

    // 流式发布：体格式非法（段头坏）→ 400，且不留临时文件
    @TestCase
    func testStreamPublishInvalidFormatCleansTemp(): Unit {
        let dir = covScratch("stream-badfmt")
        let env = newHttpEnv(mode: "open", tmpDir: dir)
        try {
            let token = seedAdminToken(env)
            let pub = publishTokenOf(env, token)
            let bad: Array<Byte> = [9, 255, 255, 255, 127]
            @Expect(httpPostRaw(env, "/pkg/bf", bad, token: pub).status, 400u16)
            @Expect(tmpPublishLeftovers(dir), 0)
        } finally {
            env.close()
        }
    }

    // 流式发布：meta 段缺失（只有制品段）→ 400
    @TestCase
    func testStreamPublishMissingMeta(): Unit {
        let dir = covScratch("stream-nometa")
        let env = newHttpEnv(mode: "open", tmpDir: dir)
        try {
            let token = seedAdminToken(env)
            let pub = publishTokenOf(env, token)
            // 一个段：类型 1 + 长度 3 + "abc"，没有 meta → 解析不出 meta
            let bad: Array<Byte> = [1, 3, 0, 0, 0, 97, 98, 99]
            @Expect(httpPostRaw(env, "/pkg/nm?organization=acme", bad, token: pub).status, 400u16)
            @Expect(tmpPublishLeftovers(dir), 0)
        } finally {
            env.close()
        }
    }

    // 空包名：URL 为 /pkg/ 无法路由到带参端点，这里直接调服务层覆盖 name 为空的守卫
    @TestCase
    func testPublishStreamEmptyNameRejected(): Unit {
        let dir = covScratch("stream-noname")
        let env = newHttpEnv(mode: "open", tmpDir: dir)
        try {
            let result = env.admin.pkgStore.getOrThrow()
            let _ = result
            let store = env.pkgStore
            let blob: BlobStore = env.blobStore
            let svc = PublishService(store, blob, auth: Some(env.authSvc), adminData: Some(env.adminData),
                permissionMode: "open")
            // 造一个临时文件，验证被清掉
            let tmp = dir + "/.tmp-manual"
            let f = File(tmp, Write)
            f.write("junk".toArray())
            f.close()
            let r = svc.publishStream("acme", "", "{}".toArray(), "sha", 4, tmp, "")
            @Expect(r.outcome == PublishOutcome.BadRequest, true)
            @Expect(exists(tmp), false)
        } finally {
            env.close()
        }
    }
}
