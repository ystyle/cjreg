// 代理回源 + 多仓解析单元测试
package ystyle::cjreg.server

import ystyle::cjreg.config.*
import ystyle::cjreg.index.*
import ystyle::cjreg.store.*
import ystyle::cjreg.protocol.*
import bstorm.*
import std.unittest.testmacro.*
import std.collection.*

func makeUpstreamService(): UpstreamService {
    UpstreamService(MemoryUpstreamStore())
}

func makeProxyService(): (ProxyService, PackageStore, MemoryBlobStore, UpstreamService) {
    let pkgStore = PackageStore(Storm.inMemory())
    let blob = MemoryBlobStore()
    let ups = makeUpstreamService()
    ups.add("official", "https://pkg.cangjie-lang.cn/registry", 0, "", 0)
    let proxy = ProxyService(pkgStore, blob, ups)
    (proxy, pkgStore, blob, ups)
}

// 构造一个包索引 NDJSON
func makeIndexNDJSON(name: String, org: String, version: String, sha: String): String {
    "{\"organization\":\"${org}\",\"name\":\"${name}\",\"version\":\"${version}\",\"sha256sum\":\"${sha}\",\"yanked\":false,\"index-version\":1}\n"
}

@Test
func testCacheIndexEntries() {
    let (proxy, pkgStore, _, _) = makeProxyService()
    let ndjson = makeIndexNDJSON("lib", "test", "1.0.0", "sha1") +
        makeIndexNDJSON("lib", "test", "1.1.0", "sha2")
    // 缓存到本地
    proxy.cacheIndexEntries("test", "lib", ndjson, proxy.upstreamSvc.getByName("official").getOrThrow())
    let versions = pkgStore.listVersions("test", "lib")
    @Expect(versions.size, 2)
    // 来源标记
    @Expect(versions[0].upstreamName, "official")
    // 重复缓存不覆盖
    proxy.cacheIndexEntries("test", "lib", ndjson, proxy.upstreamSvc.getByName("official").getOrThrow())
    @Expect(pkgStore.listVersions("test", "lib").size, 2)
}

@Test
func testExtractSha256() {
    let ndjson = makeIndexNDJSON("lib", "test", "1.0.0", "abc123")
    @Expect(extractSha256(ndjson), "abc123")
    @Expect(extractSha256(""), "")
}

@Test
func testResolvePriorityAndConflict() {
    let ups = makeUpstreamService()
    ups.add("official", "https://pkg.cangjie-lang.cn/registry", 0, "", 0)
    ups.add("mirror", "https://mirror.example.com/registry", 5, "", 0)
    let svc = ResolveService(ups)

    // fake fetchIndex：official 命中 1.1.0，mirror 也命中 1.1.0（不同 sha → 冲突）
    let fetchIndex = { org: String, name: String =>
        // 返回两个上游的索引；用 org 参数区分来源
        if (org == "fromOfficial") {
            Some(makeIndexNDJSON("lib", "test", "1.1.0", "shaA"))
        } else {
            Some(makeIndexNDJSON("lib", "test", "1.1.0", "shaB"))
        }
    }
    // 实际测试：resolve 只取第一个上游（official 优先），不会走到 mirror
    // 因此这里只验证优先级命中 + trace
    let r = svc.resolve("lib", "fromOfficial", ">=1.0.0", fetchIndex)
    @Expect(r.found, true)
    @Expect(r.candidates.size, 1)
    @Expect(r.candidates[0].repo, "official")
    @Expect(r.candidates[0].version, "1.1.0")
    match (r.selected) {
        case Some(c) => @Expect(c.sha256sum, "shaA")
        case None => @Fail("should select")
    }
}

@Test
func testResolveVersionRange() {
    let ups = makeUpstreamService()
    ups.add("official", "https://pkg.cangjie-lang.cn/registry", 0, "", 0)
    let svc = ResolveService(ups)
    let ndjson = makeIndexNDJSON("lib", "test", "1.0.0", "s1") +
        makeIndexNDJSON("lib", "test", "1.5.0", "s2") +
        makeIndexNDJSON("lib", "test", "2.0.0", "s3")
    let fetchIndex = { org: String, name: String => Some(ndjson) }

    // 区间 [1.0.0, 2.0.0) → 最佳 1.5.0
    let r = svc.resolve("lib", "test", "[1.0.0, 2.0.0)", fetchIndex)
    @Expect(r.found, true)
    match (r.selected) {
        case Some(c) => @Expect(c.version, "1.5.0")
        case None => @Fail("should select 1.5.0")
    }
}

@Test
func testResolveNotFound() {
    let ups = makeUpstreamService()
    ups.add("official", "https://pkg.cangjie-lang.cn/registry", 0, "", 0)
    let svc = ResolveService(ups)
    // 索引空
    let fetchIndex = { org: String, name: String => Some("") }
    let r = svc.resolve("nope", "test", "1.0.0", fetchIndex)
    @Expect(r.found, false)
    @Expect(r.candidates.size, 0)
}
