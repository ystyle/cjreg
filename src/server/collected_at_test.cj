// 回源落库的「本仓收录时间」+ 公开页时间文案 单元测试
//
// 背景：索引协议不含任何时间字段（上游发布时间拿不到）。公开页原先读 updatedAt，
// 回源文档全为 0 → 整个版本历史显示「未知」。现在：回源落库写收录时间，
// 公开页对镜像版本显示「收录于 …」、对本地发布显示「发布于 …」。
package ystyle::cjreg.server

import ystyle::cjreg.store.*
import ystyle::cjreg.config.*
import std.unittest.testmacro.*
import std.collection.*

// 1. 回源落库的文档必须带「本仓收录时间」（否则公开页全「未知」）
@Test
func testCacheIndexEntriesStampsCollectedAt() {
    let (proxy, store, _, ups) = makeProxyService()
    let up = ups.enabledSorted()[0]
    let ndjson = makeIndexNDJSON("demo", "acme", "1.0.0", "abc123")
    proxy.cacheIndexEntries("acme", "demo", ndjson, up)
    let docs = store.listVersions("acme", "demo")
    @Expect(docs.size, 1)
    @Expect(docs[0].createdAt > 0, true)
    @Expect(docs[0].updatedAt > 0, true)
    @Expect(docs[0].upstreamId, up.id)
}

// 2. 已存在的版本不被回源覆盖（含时间）
@Test
func testCacheIndexEntriesSkipsExisting() {
    let (proxy, store, _, ups) = makeProxyService()
    let up = ups.enabledSorted()[0]
    let existing = PackageDoc()
    existing.organization = "acme"
    existing.name = "demo"
    existing.version = "1.0.0"
    existing.sha256 = "user-sha"
    existing.deletedAt = 0
    store.save(existing)
    proxy.cacheIndexEntries("acme", "demo", makeIndexNDJSON("demo", "acme", "1.0.0", "upstream-sha"), up)
    let docs = store.listVersions("acme", "demo")
    @Expect(docs.size, 1)
    @Expect(docs[0].sha256, "user-sha")   // 本地内容不被回源顶掉
    @Expect(docs[0].createdAt, 0)
}

// 3. sync-metadata 给存量（createdAt=0）文档补收录时间，且不动 updatedAt（排序不受影响）
@Test
func testSyncMetadataStampsLegacyDocsOnly() {
    let (proxy, store, blob) = makeSyncFixture()
    let legacyA = PackageDoc()
    legacyA.organization = "acme"
    legacyA.name = "old-a"
    legacyA.version = "1.0.0"
    legacyA.upstreamId = 1
    store.save(legacyA)
    let legacyB = PackageDoc()
    legacyB.organization = "acme"
    legacyB.name = "old-b"
    legacyB.version = "1.0.0"
    legacyB.upstreamId = 1
    legacyB.createdAt = 111
    legacyB.updatedAt = 222
    store.save(legacyB)
    // 完整字段的文档不该被再补（这里只关心时间戳，字段齐全会跳过制品环节）
    let report = syncPackageMetadata(store, blob, proxy, false)
    @Expect(report.stamped, 1)
    @Expect(store.getById(legacyA.id).getOrThrow().createdAt > 0, true)
    @Expect(store.getById(legacyA.id).getOrThrow().updatedAt, 0)   // 不动 updatedAt
    @Expect(store.getById(legacyB.id).getOrThrow().createdAt, 111)
    @Expect(store.getById(legacyB.id).getOrThrow().updatedAt, 222)
}
