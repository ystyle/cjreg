package ystyle::cjreg.server

import ystyle::cjreg.config.*
import ystyle::cjreg.store.*
import ystyle::cjreg.index.*
import bstorm.*
import std.unittest.testmacro.*
import std.collection.*
import std.fs.*

@Test
func testResolveWithMultilineCache() {
    let pkgStore = PackageStore(Storm.inMemory())
    let blob = MemoryBlobStore()
    let upStore = MemoryUpstreamStore()
    let ups = UpstreamService(upStore)
    ups.add("official", "https://pkg.cangjie-lang.cn/registry", 0, "", 0)
    let proxy = ProxyService(pkgStore, blob, ups)

    // 真实缓存：cacheIndexEntries 存完整多行 NDJSON（2 个版本）
    let ndjson = "{\"organization\":\"\",\"name\":\"jsonvalue\",\"version\":\"1.0.1\",\"sha256sum\":\"shaA\",\"yanked\":false,\"index-version\":1}\n" +
        "{\"organization\":\"\",\"name\":\"jsonvalue\",\"version\":\"1.1.0\",\"sha256sum\":\"shaB\",\"yanked\":false,\"index-version\":1}\n"
    proxy.cacheIndexEntries("", "jsonvalue", ndjson, ups.getByName("official").getOrThrow())

    // 本地应缓存 2 个 doc
    @Expect(pkgStore.listVersions("", "jsonvalue").size, 2)

    // fetchIndex 应 HitLocal 且返回可解析 NDJSON
    let (outcome, local) = proxy.fetchIndex("", "jsonvalue")
    let out = File("/tmp/resdebug.txt", Write)
    out.write("hit=${outcome == ProxyOutcome.HitLocal} len=${local.size}\n".toArray())
    let entries = parseNDJSON(local)
    out.write("entries=${entries.size}\n".toArray())
    var head = "(empty)"
    if (local.size > 0) {
        head = local[0..20]
    }
    out.write("localhead=${head}\n".toArray())

    let svc = ResolveService(ups)
    let fetchIndex: (String, String) -> ?String = { o: String, n: String =>
        let (_, idx) = proxy.fetchIndex(o, n)
        if (idx.isEmpty()) { None } else { Some(idx) }
    }
    let r = svc.resolve("jsonvalue", "", "1.1.0", fetchIndex)
    out.write("found=${r.found} candidates=${r.candidates.size}\n".toArray())
    out.close()
    @Expect(r.found, true)
    @Expect(local.size > 0, true)
}
