// 协议端点 handler 级测试：健康检查 / 发布 / 下载 / 索引
//
// 走真实 HTTP（http_env_test.cj 的夹具），覆盖 server.cj 里三个官方端点与健康检查的
// 状态码分支：权限模式、格式非法、版本冲突、鉴权失败、分片校验、软删语义。
package ystyle::cjreg.server

import ystyle::cjreg.store.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

// 拼一个最小合法发布体：段头 + meta 段 + 段头 + 制品段（官方协议二进制格式）
// 段格式：[1 字节类型][4 字节小端长度][内容]
func publishBody(org: String, name: String, version: String, artifact: Array<Byte>,
                 sha256!: String = ""): Array<Byte> {
    let meta = "{\"organization\":\"" + org + "\",\"name\":\"" + name + "\",\"version\":\"" + version +
        "\",\"cjc-version\":\"1.1.3\",\"description\":\"handler test\",\"artifact-type\":\"src\"," +
        "\"index\":{\"sha256sum\":\"" + sha256 + "\",\"index-version\":1}}"
    let mb = meta.toArray()
    let out = ArrayList<UInt8>()
    out.add(1)
    // 小端 4 字节长度
    out.add(UInt8(mb.size & 0xFF))
    out.add(UInt8((mb.size >> 8) & 0xFF))
    out.add(UInt8((mb.size >> 16) & 0xFF))
    out.add(UInt8((mb.size >> 24) & 0xFF))
    for (b in mb) {
        out.add(b)
    }
    out.add(1)
    out.add(UInt8(artifact.size & 0xFF))
    out.add(UInt8((artifact.size >> 8) & 0xFF))
    out.add(UInt8((artifact.size >> 16) & 0xFF))
    out.add(UInt8((artifact.size >> 24) & 0xFF))
    for (b in artifact) {
        out.add(b)
    }
    out.toArray()
}

@Test
class ProtocolEndpointTest {
    // 健康检查：无论是否配置管理服务都应可达
    @TestCase
    func testHealthAlwaysOk(): Unit {
        let env = newHttpEnv()
        try {
            @Expect(httpGet(env, "/api/health").status, 200u16)
        } finally {
            env.close()
        }
    }

    // open 模式：有效发布 token 即可发布，返回包 id
    @TestCase
    func testPublishInOpenMode(): Unit {
        let env = newHttpEnv(mode: "open")
        try {
            let token = seedAdminToken(env)
            let pub = publishTokenOf(env, token)
            @Expect(pub.isEmpty(), false)
            let artifact = "hello-artifact".toArray()
            let resp = httpPostRaw(env, "/pkg/demo?organization=acme",
                publishBody("acme", "demo", "1.0.0", artifact), token: pub)
            @Expect(resp.status, 200u16)
            @Expect(extractJsonInt(bodyText(resp), "id") >= 0, true)
            // 落库可查
            @Expect(env.pkgStore.listVersions("acme", "demo").size, 1)
        } finally {
            env.close()
        }
    }

    // 无 token：发布被拒（401）
    @TestCase
    func testPublishWithoutTokenRejected(): Unit {
        let env = newHttpEnv(mode: "open")
        try {
            let _ = seedAdminToken(env)
            let resp = httpPostRaw(env, "/pkg/demo",
                publishBody("acme", "demo", "1.0.0", "x".toArray()))
            @Expect(resp.status, 401u16)
        } finally {
            env.close()
        }
    }

    // 体格式非法：400，且库内不留记录
    @TestCase
    func testPublishInvalidFormatRejected(): Unit {
        let env = newHttpEnv(mode: "open")
        try {
            let token = seedAdminToken(env)
            let pub = publishTokenOf(env, token)
            // 段类型不是 1 / 长度越界 → 解析失败
            let bad: Array<Byte> = [9, 255, 255, 255, 127, 1, 2, 3]
            let resp = httpPostRaw(env, "/pkg/broken", bad, token: pub)
            @Expect(resp.status, 400u16)
            @Expect(env.pkgStore.listVersions("", "broken").size, 0)
        } finally {
            env.close()
        }
    }

    // 同版本重复发布（open 模式）：409 冲突，不覆盖
    @TestCase
    func testPublishDuplicateConflictInOpenMode(): Unit {
        let env = newHttpEnv(mode: "open")
        try {
            let token = seedAdminToken(env)
            let pub = publishTokenOf(env, token)
            let art1 = "aaa".toArray()
            let body1 = publishBody("acme", "dup", "1.0.0", art1, sha256: sha256Hex(art1))
            @Expect(httpPostRaw(env, "/pkg/dup?organization=acme", body1, token: pub).status, 200u16)
            // 同版本不同制品 → 409（open 模式不可覆盖）
            let art2 = "bbb".toArray()
            let body2 = publishBody("acme", "dup", "1.0.0", art2, sha256: sha256Hex(art2))
            let conflict = httpPostRaw(env, "/pkg/dup?organization=acme", body2, token: pub)
            @Expect(conflict.status, 409u16)
        } finally {
            env.close()
        }
    }

    // team 模式：管理员直通 overwrite，同版本可反复发（预演必需）
    @TestCase
    func testPublishOverwriteAllowedForAdminInTeamMode(): Unit {
        let env = newHttpEnv(mode: "team")
        try {
            let token = seedAdminToken(env)
            let pub = publishTokenOf(env, token)
            let a1 = "one".toArray()
            let b1 = publishBody("acme", "re", "1.0.0", a1, sha256: sha256Hex(a1))
            @Expect(httpPostRaw(env, "/pkg/re?organization=acme", b1, token: pub).status, 200u16)
            let a2 = "two".toArray()
            let b2 = publishBody("acme", "re", "1.0.0", a2, sha256: sha256Hex(a2))
            @Expect(httpPostRaw(env, "/pkg/re?organization=acme", b2, token: pub).status, 200u16)
        } finally {
            env.close()
        }
    }

    // 索引端点：本地有该包 → NDJSON（content-type 与分片校验）
    @TestCase
    func testIndexServesLocalNdjson(): Unit {
        let env = newHttpEnv()
        try {
            let _ = seedPackage(env, "acme", "crc", "1.0.0")
            let resp = httpGet(env, "/index/cr/c/crc?organization=acme")
            @Expect(resp.status, 200u16)
            @Expect(headerOf(resp, "content-type").contains("ndjson"), true)
            @Expect(bodyText(resp).contains("\"crc\""), true)
        } finally {
            env.close()
        }
    }

    // 索引端点：包名过短（<3）→ 400
    @TestCase
    func testIndexShortNameRejected(): Unit {
        let env = newHttpEnv()
        try {
            @Expect(httpGet(env, "/index/ab/c/ab").status, 400u16)
        } finally {
            env.close()
        }
    }

    // 索引端点：本地没有且无上游可回源 → 404
    @TestCase
    func testIndexMissingLocalReturns404(): Unit {
        let env = newHttpEnv()
        try {
            // 名字 >=3 才越过「包名过短」守卫；本地无、无可用上游 → 404
            let resp = httpGet(env, "/index/gh/os/ghost?organization=nobody")
            @Expect(resp.status, 404u16)
        } finally {
            env.close()
        }
    }

    // 下载端点：本地无制品 → 404（有代理服务但 blob 缺失）
    @TestCase
    func testDownloadMissingReturns404(): Unit {
        let env = newHttpEnv()
        try {
            let resp = httpGet(env, "/pkg/ghost/1.0.0?organization=acme")
            @Expect(resp.status, 404u16)
        } finally {
            env.close()
        }
    }

    // 下载端点：blob 命中 → 200 + 附件头 + 字节一致
    @TestCase
    func testDownloadServesBytesFromBlob(): Unit {
        let env = newHttpEnv(tmpDir: covScratch("dl-bytes"))
        try {
            let payload = "artifact-contents-0123456789".toArray()
            let sum = sha256Hex(payload)
            env.blobStore.put(sum, payload)
            let d = PackageDoc()
            d.organization = "acme"
            d.name = "blobbed"
            d.version = "1.0.0"
            d.sha256 = sum
            d.artifactType = "src"
            d.deletedAt = 0
            d.createdAt = 1
            d.updatedAt = 1
            env.pkgStore.save(d)

            let resp = httpGet(env, "/pkg/blobbed/1.0.0?organization=acme")
            @Expect(resp.status, 200u16)
            @Expect(headerOf(resp, "content-disposition").contains("blobbed-1.0.0.cjp"), true)
            let got = bodyBytes(resp)
            @Expect(got.size, payload.size)
            @Expect(sha256Hex(got), sum)
        } finally {
            env.close()
        }
    }

    // 下载计数：命中一次本地版本，downloads 递增
    @TestCase
    func testDownloadIncrementsCounter(): Unit {
        let env = newHttpEnv(tmpDir: covScratch("dl-count"))
        try {
            let payload = "count-me".toArray()
            let sum = sha256Hex(payload)
            env.blobStore.put(sum, payload)
            let d = PackageDoc()
            d.organization = "acme"
            d.name = "counted"
            d.version = "1.0.0"
            d.sha256 = sum
            d.artifactType = "src"
            d.deletedAt = 0
            d.createdAt = 1
            d.updatedAt = 1
            env.pkgStore.save(d)
            let before = env.pkgStore.getById(d.id).getOrThrow().downloadCount
            let _ = httpGet(env, "/pkg/counted/1.0.0?organization=acme")
            let after = env.pkgStore.getById(d.id).getOrThrow().downloadCount
            @Expect(after > before, true)
        } finally {
            env.close()
        }
    }

    // require_auth=true：下载/索引无 token → 401
    @TestCase
    func testReadAuthRequiredRejectsAnonymous(): Unit {
        let env = newHttpEnv(requireAuth: true)
        try {
            @Expect(httpGet(env, "/pkg/whatever/1.0.0").status, 401u16)
            @Expect(httpGet(env, "/index/wh/at/whatever").status, 401u16)
        } finally {
            env.close()
        }
    }

    // require_auth=true：无效 token → 401
    @TestCase
    func testReadAuthInvalidTokenRejected(): Unit {
        let env = newHttpEnv(requireAuth: true)
        try {
            @Expect(httpGet(env, "/pkg/whatever/1.0.0", token: "garbage").status, 401u16)
        } finally {
            env.close()
        }
    }

    // require_auth=true：管理员 token 直通读（超集）
    @TestCase
    func testReadAuthAdminPasses(): Unit {
        let env = newHttpEnv(requireAuth: true)
        try {
            let token = seedAdminToken(env)
            let d = seedPackage(env, "acme", "readable", "1.0.0")
            let _ = d
            let resp = httpGet(env, "/index/re/ad/readable?organization=acme", token: token)
            @Expect(resp.status, 200u16)
        } finally {
            env.close()
        }
    }

    // 发布体走内存路径（tmpDir 为空）也能成功 —— 覆盖 server.cj 的整包读入分支
    @TestCase
    func testPublishViaMemoryPathWhenNoTmpDir(): Unit {
        let env = newHttpEnv(mode: "open")
        try {
            let token = seedAdminToken(env)
            let pub = publishTokenOf(env, token)
            let art = "mem".toArray()
            // URL 的 organization 必须与 meta 段一致，否则发布裁决判 MetaMismatch
            let resp = httpPostRaw(env, "/pkg/mempath?organization=acme",
                publishBody("acme", "mempath", "1.0.0", art, sha256: sha256Hex(art)), token: pub)
            @Expect(resp.status, 200u16)
        } finally {
            env.close()
        }
    }
}
