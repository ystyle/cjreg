// 展示字段/README 补齐（回源镜像包 + 存量回捞）单元测试
package ystyle::cjreg.server

import ystyle::cjreg.store.*
import ystyle::cjreg.config.*
import std.unittest.testmacro.*
import std.collection.*

// 夹具：共享同一 store 的 proxy/blob（MemoryUpstreamStore 无上游 ⇒ 全程离线）
func makeSyncFixture(): (ProxyService, PackageStore, MemoryBlobStore) {
    let pkgStore = makeStore()  // 复用车夹具（含内存态 storm 的生命周期管理）
    let blob = MemoryBlobStore()
    let proxy = ProxyService(pkgStore, blob, UpstreamService(MemoryUpstreamStore()))
    (proxy, pkgStore, blob)
}

// 落一个「回源聚合」形态的文档：只有索引字段 + 制品 blob
func addMirrorDoc(store: PackageStore, blob: MemoryBlobStore, org: String, name: String,
                  version: String, tarball: Array<Byte>): PackageDoc {
    let doc = PackageDoc()
    doc.organization = org
    doc.name = name
    doc.version = version
    doc.cjcVersion = "1.1.0"
    doc.sha256 = sha256Hex(tarball)
    doc.upstreamId = 1
    doc.upstreamName = "official"
    store.save(doc)
    blob.put(doc.sha256, tarball)
    return doc
}

// 1. 只填空字段，绝不覆盖已有值
@Test
func testEnrichFillsEmptyFieldsOnly() {
    let d = PackageDoc()
    d.organization = "acme"
    d.name = "demo"
    d.version = "1.0.0"
    d.description = "已有描述"
    let sb = StringBuilder()
    sb.append("[package]\n")
    sb.append("  name = \"demo\"\n")
    sb.append("  description = \"制品里的描述\"\n")
    sb.append("  license = [\"MIT\"]\n")
    sb.append("  authors = [\"ystyle\"]\n")
    sb.append("  repository = \"https://x\"\n")
    sb.append("  tag = [\"json\"]\n")
    sb.append("  output-type = \"executable\"\n")
    let tar = cjpWithReadmeAndToml("demo-1.0.0", "# README\n", sb.toString())
    let changed = enrichDocFromArtifact(d, tar)
    @Expect(changed, true)
    @Expect(d.readme, "# README\n")
    @Expect(d.description, "已有描述")  // 不覆盖
    @Expect(d.license.size, 1)
    @Expect(d.license[0], "MIT")
    @Expect(d.authors[0], "ystyle")
    @Expect(d.repository, "https://x")
    @Expect(d.tag[0], "json")
    @Expect(d.executable, true)
}

// 2. 字段齐全（含制品大小）→ 不需要补齐（调用方据此跳过解压）
@Test
func testNeedsArtifactEnrichFalseWhenComplete() {
    let d = PackageDoc()
    d.readme = "r"
    d.description = "d"
    d.license = ArrayList<String>(["MIT"])
    d.authors = ArrayList<String>(["a"])
    d.repository = "r"
    d.tag = ArrayList<String>(["t"])
    d.category = ArrayList<String>(["c"])
    d.tarballSize = 1234
    @Expect(needsArtifactEnrich(d), false)
    d.readme = ""
    @Expect(needsArtifactEnrich(d), true)
    d.readme = "r"
    d.tarballSize = 0   // 只缺制品大小也要补（列表/详情要显示体积）
    @Expect(needsArtifactEnrich(d), true)
}

// 3. 制品损坏：不抛异常、不误改文档（硬失败可见）
@Test
func testEnrichBrokenArtifactKeepsDoc() {
    let d = PackageDoc()
    d.organization = "acme"
    d.name = "demo"
    d.version = "1.0.0"
    let changed = enrichDocFromArtifact(d, [UInt8(9), UInt8(9), UInt8(9)])
    @Expect(changed, false)
    @Expect(d.readme, "")
    @Expect(d.description, "")
}

// 4. 默认只补每个包的最新版本（列表页展示口径）
@Test
func testSyncMetadataLatestOnly() {
    let (proxy, store, blob) = makeSyncFixture()
    let a1 = addMirrorDoc(store, blob, "acme", "pkg-a", "1.0.0", cjpWithReadme("pkg-a-1.0.0", "readme 1"))
    let a2 = addMirrorDoc(store, blob, "acme", "pkg-a", "2.0.0", cjpWithReadme("pkg-a-2.0.0", "readme 2"))
    let b = addMirrorDoc(store, blob, "acme", "pkg-b", "1.0.0", cjpWithReadme("pkg-b-1.0.0", "readme b"))
    // b 已是完整文档（本地发布形态）→ 不该被碰
    b.readme = "已有 README"
    b.description = "已有描述"
    b.license = ArrayList<String>(["MIT"])
    b.authors = ArrayList<String>(["ystyle"])
    b.repository = "https://x"
    b.tag = ArrayList<String>(["t"])
    b.category = ArrayList<String>(["Network"])
    b.tarballSize = 1024   // 制品大小也算展示字段：齐全才跳过解压
    store.save(b)

    let report = syncPackageMetadata(store, blob, proxy, false)
    @Expect(report.packages, 2)
    @Expect(report.candidates, 1)   // 只有 pkg-a@2.0.0 需要补
    @Expect(report.enriched, 1)
    @Expect(store.getById(a2.id).getOrThrow().readme, "readme 2")
    @Expect(store.getById(a1.id).getOrThrow().readme, "")  // 非最新版本：本轮不动
    @Expect(store.getById(b.id).getOrThrow().readme, "已有 README")
}

// 5. --all：所有版本都补
@Test
func testSyncMetadataAllVersions() {
    let (proxy, store, blob) = makeSyncFixture()
    let a1 = addMirrorDoc(store, blob, "acme", "pkg-a", "1.0.0", cjpWithReadme("pkg-a-1.0.0", "readme 1"))
    let a2 = addMirrorDoc(store, blob, "acme", "pkg-a", "2.0.0", cjpWithReadme("pkg-a-2.0.0", "readme 2"))
    let report = syncPackageMetadata(store, blob, proxy, true)
    @Expect(report.candidates, 2)
    @Expect(report.enriched, 2)
    @Expect(store.getById(a1.id).getOrThrow().readme, "readme 1")
    @Expect(store.getById(a2.id).getOrThrow().readme, "readme 2")
}

// 6. 制品取不到（本地无 blob 且无上游）：记 unresolved，不静默当成功
@Test
func testSyncMetadataUnresolvedArtifact() {
    let (proxy, store, blob) = makeSyncFixture()
    let d = PackageDoc()
    d.organization = "acme"
    d.name = "pkg-x"
    d.version = "1.0.0"
    d.sha256 = "deadbeef"
    store.save(d)
    let report = syncPackageMetadata(store, blob, proxy, false)
    @Expect(report.packages, 1)
    @Expect(report.candidates, 1)
    @Expect(report.enriched, 0)
    @Expect(report.unresolved, 1)
}

// 7. 制品流经本地（下载命中本地 blob）时补齐：enrichDocByVersion
@Test
func testEnrichDocByVersionOnLocalBlob() {
    let (proxy, store, blob) = makeSyncFixture()
    let d = addMirrorDoc(store, blob, "acme", "pkg-a", "2.0.0", cjpWithReadme("pkg-a-2.0.0", "# 下载时补齐"))
    @Expect(d.readme, "")
    // fetchArtifact 只取字节（不产生副作用）
    let (outcome, bytes, _) = proxy.fetchArtifact("acme", "pkg-a", "2.0.0")
    @Expect(outcome == ProxyOutcome.HitLocal, true)
    @Expect(bytes.isSome(), true)
    @Expect(store.getById(d.id).getOrThrow().readme, "")
    // 下载路由用它补齐
    @Expect(enrichDocByVersion(store, "acme", "pkg-a", "2.0.0", bytes.getOrThrow()), true)
    @Expect(store.getById(d.id).getOrThrow().readme, "# 下载时补齐")
    // 已补齐 → 再下不再解压（返回 false）
    @Expect(enrichDocByVersion(store, "acme", "pkg-a", "2.0.0", bytes.getOrThrow()), false)
}

// 8. 回源聚合文档只有 indexJson（无 sha256 列）时，仍能从本地 blob 命中
@Test
func testFetchArtifactFallsBackToIndexJsonSha() {
    let (proxy, store, blob) = makeSyncFixture()
    let tar = cjpWithReadme("pkg-a-1.0.0", "# r")
    let sha = sha256Hex(tar)
    blob.put(sha, tar)
    let d = PackageDoc()
    d.organization = "acme"
    d.name = "pkg-a"
    d.version = "1.0.0"
    d.indexJson = "{\"organization\":\"acme\",\"name\":\"pkg-a\",\"version\":\"1.0.0\",\"sha256sum\":\"${sha}\"}"
    store.save(d)
    let (outcome, bytes, got) = proxy.fetchArtifact("acme", "pkg-a", "1.0.0")
    @Expect(outcome == ProxyOutcome.HitLocal, true)
    @Expect(got, sha)
    @Expect(bytes.isSome(), true)
}
