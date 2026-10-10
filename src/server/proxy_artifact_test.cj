// 代理回源 · 制品层测试（proxy_artifact.cj）
//
// 用本地 stub 上游（支持 / 不支持 Range 两种）覆盖：
// fetchArtifact / fetchArtifactStream 的本地命中与回源、fetchArtifactToBlob 的分块落盘、
// Content-Range 解析、失败清理临时文件。
package ystyle::cjreg.server

import tang.*
import bstorm.*
import ystyle::cjreg.config.*
import ystyle::cjreg.store.*
import ystyle::cjreg.index.*
import stdx.net.http.*
import std.collection.*
import std.convert.*
import std.fs.{Directory, File, Path, exists, removeIfExists}
import std.unittest.*
import std.unittest.testmacro.*

// 造一个代理夹具（可选磁盘 blob 目录 = 走流式路径）
func makeProxy(tmpDir!: String = ""): (ProxyService, PackageStore, BlobStore, UpstreamService, Storm) {
    beginTestStores()
    let storm = testStorm()
    let pkgStore = PackageStore(storm)
    let blob: BlobStore = if (tmpDir.isEmpty()) { MemoryBlobStore() } else { DiskBlobStore(tmpDir) }
    let upStore = BstormUpstreamStore(storm)
    let ups = UpstreamService(upStore)
    let proxy = ProxyService(pkgStore, blob, ups, tmpDir: tmpDir)
    (proxy, pkgStore, blob, ups, storm)
}

// 本地 stub 上游：/pkg/<name>/<version>[?organization=] 返回指定制品；
// supportsRange=false 时忽略 Range 直接回 200 整包（覆盖"上游不支持 Range"的退化分支）
func startArtifactUpstream(payload: Array<Byte>, supportsRange!: Bool = true): (String, Server) {
    let app = Tang()
    app.get("/pkg/:name/:version", { ctx =>
        let range = ctx.getHeader("Range") ?? ""
        if (supportsRange && range.startsWith("bytes=")) {
            let spec = range[6..range.size]
            let dash = spec.indexOf("-") ?? 0
            let from = Int64.parse(spec[0..dash])
            var to = Int64.parse(spec[(dash + 1)..spec.size])
            if (to > payload.size - 1) {
                to = payload.size - 1
            }
            let end = to + 1
            let slice = payload[from..end]
            ctx.responseBuilder
                .status(206u16)
                .header("Content-Range", "bytes ${from}-${to}/${payload.size}")
                .body(slice)
        } else {
            ctx.responseBuilder.status(200u16).body(payload)
        }
    })
    let (base, server, client) = startInProcServer(app)
    client.close()
    (base, server)
}

// 造一个指向 stub 上游的本地包记录（localSha 为空 → 只有 indexJson 里的 sha）
func seedRemotePkg(pkgStore: PackageStore, org: String, name: String, version: String,
                   sha: String): Unit {
    let d = PackageDoc()
    d.organization = org
    d.name = name
    d.version = version
    d.cjcVersion = "1.1.3"
    d.artifactType = "src"
    d.pkgUpstreamMark(sha)
    pkgStore.save(d)
}

// PackageDoc 没有便捷 setter，这里直接写 indexJson（回源落库的真实形态：只带索引条目）
extend PackageDoc {
    func pkgUpstreamMark(sha: String): Unit {
        let idx = PackageIndex()
        idx.organization = this.organization
        idx.name = this.name
        idx.version = this.version
        idx.cjcVersion = this.cjcVersion
        idx.sha256sum = sha
        this.indexJson = generateNDJSON(ArrayList<PackageIndex>([idx]))
        this.sha256 = ""
    }
}

@Test
class ProxyArtifactTest {
    // fetchArtifact：本地 blob 命中（sha 取索引里的值）
    @TestCase
    func testFetchArtifactLocalHit(): Unit {
        let (proxy, pkgStore, blob, _, _) = makeProxy()
        let payload = "local-artifact".toArray()
        let sha = sha256Hex(payload)
        blob.put(sha, payload)
        seedRemotePkg(pkgStore, "acme", "local", "1.0.0", sha)

        let (outcome, body, gotSha) = proxy.fetchArtifact("acme", "local", "1.0.0")
        @Expect(outcome == ProxyOutcome.HitLocal, true)
        @Expect(body.isSome(), true)
        @Expect(String.fromUtf8(body.getOrThrow()), "local-artifact")
        @Expect(gotSha, sha)
    }

    // fetchArtifact：本地无 → 回源取回并落 blob
    @TestCase
    func testFetchArtifactFetchesFromUpstream(): Unit {
        let payload = "from-upstream-artifact".toArray()
        let (base, server) = startArtifactUpstream(payload)
        try {
            let (proxy, _, blob, ups, _) = makeProxy()
            ups.add("mirror", base, 0, "", 0)
            let (outcome, body, sha) = proxy.fetchArtifact("acme", "remote", "1.0.0")
            @Expect(outcome == ProxyOutcome.FetchedFromUpstream, true)
            @Expect(body.isSome(), true)
            @Expect(sha, sha256Hex(payload))
            // 落进本地 blob（下次可命中）
            @Expect(blob.get(sha).isSome(), true)
        } finally {
            server.closeGracefully()
        }
    }

    // fetchArtifact：本地无、上游也没有 → NotFound
    @TestCase
    func testFetchArtifactNotFound(): Unit {
        let (proxy, _, _, ups, _) = makeProxy()
        ups.add("dead", "http://127.0.0.1:9/registry", 0, "", 0)
        let (outcome, body, sha) = proxy.fetchArtifact("acme", "ghost", "1.0.0")
        @Expect(outcome == ProxyOutcome.NotFound, true)
        @Expect(body.isNone(), true)
        @Expect(sha, "")
    }

    // fetchArtifactStream：本地命中 → 流可读
    @TestCase
    func testFetchArtifactStreamLocalHit(): Unit {
        let (proxy, pkgStore, blob, _, _) = makeProxy()
        let payload = "stream-local".toArray()
        let sha = sha256Hex(payload)
        blob.put(sha, payload)
        seedRemotePkg(pkgStore, "acme", "sl", "1.0.0", sha)

        let (outcome, stream, gotSha) = proxy.fetchArtifactStream("acme", "sl", "1.0.0")
        @Expect(outcome == ProxyOutcome.HitLocal, true)
        @Expect(gotSha, sha)
        match (stream) {
            case Some(st) => @Expect(String.fromUtf8(readStreamToBytes(st)), "stream-local")
            case None => @Fail("local hit should yield a stream")
        }
    }

    // fetchArtifactStream：软删的版本不算命中（deletedAt != 0 跳过）→ 无上游则 NotFound
    @TestCase
    func testFetchArtifactStreamSkipsDeleted(): Unit {
        let (proxy, pkgStore, blob, _, _) = makeProxy()
        let payload = "deleted-artifact".toArray()
        let sha = sha256Hex(payload)
        blob.put(sha, payload)
        let d = PackageDoc()
        d.organization = "acme"
        d.name = "del"
        d.version = "1.0.0"
        d.sha256 = sha
        d.deletedAt = 99
        pkgStore.save(d)

        let (outcome, _, _) = proxy.fetchArtifactStream("acme", "del", "1.0.0")
        @Expect(outcome == ProxyOutcome.NotFound, true)
    }

    // fetchArtifactStream 走磁盘：tmpDir 非空 → 分块回源落盘后以流返回
    @TestCase
    func testFetchArtifactStreamViaDiskAndRange(): Unit {
        // 用 20 MiB 触发 >1 个 8 MiB 分块（验证分块循环）
        let payload = Array<Byte>(20 * 1024 * 1024, repeat: 7)
        let (base, server) = startArtifactUpstream(payload)
        try {
            let dir = covScratch("artifact-range")
            let (proxy, _, blob, ups, _) = makeProxy(tmpDir: dir)
            ups.add("mirror", base, 0, "", 0)

            let (outcome, stream, sha) = proxy.fetchArtifactStream("acme", "big", "1.0.0")
            @Expect(outcome == ProxyOutcome.FetchedFromUpstream, true)
            @Expect(sha, sha256Hex(payload))
            match (stream) {
                case Some(st) =>
                    let got = readStreamToBytes(st)
                    @Expect(got.size, payload.size)
                    @Expect(sha256Hex(got), sha)
                case None => @Fail("disk-backed fetch should yield a stream")
            }
            // 制品的字节已落到 blob（按内容寻址）
            @Expect(blob.get(sha).isSome(), true)
        } finally {
            server.closeGracefully()
        }
    }

    // 上游不支持 Range（回 200 整包）：退化分支必须也能落盘成功
    @TestCase
    func testFetchArtifactToBlobUpstreamIgnoresRange(): Unit {
        let payload = "no-range-upstream-payload".toArray()
        let (base, server) = startArtifactUpstream(payload, supportsRange: false)
        try {
            let dir = covScratch("artifact-norange")
            let (proxy, _, _, ups, _) = makeProxy(tmpDir: dir)
            ups.add("mirror", base, 0, "", 0)

            let url = base + "/pkg/nr/1.0.0"
            match (proxy.fetchArtifactToBlob(url, "")) {
                case Some((sha, size)) =>
                    @Expect(sha, sha256Hex(payload))
                    @Expect(size, payload.size)
                case None => @Fail("whole-body fallback should still succeed")
            }
        } finally {
            server.closeGracefully()
        }
    }

    // fetchArtifactToBlob：不可达上游 → None，且临时文件被清掉（不留半成品）
    @TestCase
    func testFetchArtifactToBlobFailureCleansTemp(): Unit {
        let dir = covScratch("artifact-fail")
        let (proxy, _, _, _, _) = makeProxy(tmpDir: dir)
        let r = proxy.fetchArtifactToBlob("http://127.0.0.1:9/pkg/x/1.0.0", "")
        @Expect(r.isNone(), true)
        // 该目录下不应残留 .tmp-fetch-* 文件
        var leftovers = 0
        for (f in Directory.readFrom(Path(dir))) {
            if (f.name.startsWith(".tmp-fetch-")) {
                leftovers++
            }
        }
        @Expect(leftovers, 0)
    }

    // Content-Range 解析纯函数
    @TestCase
    func testTotalFromContentRange(): Unit {
        @Expect(totalFromContentRange("bytes 0-8388607/20971520"), 20971520)
        @Expect(totalFromContentRange("bytes 0-99/100"), 100)
        // 非法/缺失 → -1（"未知总长"，调用方按"读到没有进展为止"处理）
        @Expect(totalFromContentRange(""), -1)
        @Expect(totalFromContentRange("bytes 0-99"), -1)
    }

    // 带 Range 的 GET：206 + Content-Range；重定向透传 Range；不可达 → None
    @TestCase
    func testHttpGetRangeWithStatus(): Unit {
        let payload = Array<Byte>(1024, repeat: 3)
        let (base, server) = startArtifactUpstream(payload)
        try {
            match (httpGetRangeWithStatus(base + "/pkg/r/1.0.0", "", 0, 511)) {
                case Some((code, cr, st)) =>
                    @Expect(code, 206)
                    @Expect(cr.contains("/1024"), true)
                    @Expect(readStreamToBytes(st).size, 512)
                case None => @Fail("range request should succeed")
            }
            @Expect(httpGetRangeWithStatus("http://127.0.0.1:9/pkg/x/1", "", 0, 10).isNone(), true)
        } finally {
            server.closeGracefully()
        }
    }

    // 构建带 Range 的请求：token 非空时带 Authorization；Range 头格式正确
    @TestCase
    func testBuildGetRangeRequest(): Unit {
        let noToken = buildGetRangeRequest("http://x/y", "", 0, 99)
        @Expect(noToken.headers.getFirst("range").getOrThrow(), "bytes=0-99")

        let withToken = buildGetRangeRequest("http://x/y", "tk", 100, 199)
        @Expect(withToken.headers.getFirst("authorization").getOrThrow(), "tk")
        @Expect(withToken.headers.getFirst("range").getOrThrow(), "bytes=100-199")
    }
}
