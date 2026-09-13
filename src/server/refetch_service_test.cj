// 上游重拉（refetch）+ 共享 blob 保护 单元测试
//
// 重拉的出网口是 ProxyService.fetchBytes，测试注入 stub（全程离线、不碰真上游）。
package ystyle::cjreg.server

import ystyle::cjreg.store.*
import ystyle::cjreg.config.*
import ystyle::cjreg.index.*
import std.unittest.testmacro.*
import std.collection.*

// 上游 stub：按 URL 形状分别返回索引 / 制品
class StubUpstream {
    var artifact: Array<Byte> = Array<Byte>()
    var indexSha: String = ""        // 空 = 用 artifact 的真实 sha256
    var indexHasVersion: Bool = true
    var indexBroken: Bool = false    // 索引取不到
    var artifactBroken: Bool = false // 制品取不到
    var indexCalls: Int64 = 0
    var artifactCalls: Int64 = 0

    func fetch(url: String, token: String): ?Array<Byte> {
        if (url.contains("/index/")) {
            this.indexCalls++
            if (this.indexBroken) {
                return None
            }
            if (!this.indexHasVersion) {
                let other = PackageIndex()
                other.organization = "acme"
                other.name = "demo"
                other.version = "9.9.9"
                other.cjcVersion = "1.1.0"
                other.sha256sum = "ffff"
                return Some(generateNDJSON(ArrayList<PackageIndex>([other])).toArray())
            }
            let e = PackageIndex()
            e.organization = "acme"
            e.name = "demo"
            e.version = "1.0.0"
            e.cjcVersion = "1.1.0"
            e.sha256sum = if (this.indexSha.isEmpty()) { sha256Hex(this.artifact) } else { this.indexSha }
            return Some(generateNDJSON(ArrayList<PackageIndex>([e])).toArray())
        }
        this.artifactCalls++
        if (this.artifactBroken) {
            return None
        }
        return Some(this.artifact)
    }
}

// 夹具：内存 store + 内存 blob + 一个上游（URL 是假的，全部走 stub）
func makeRefetchFixture(): (ProxyService, PackageStore, MemoryBlobStore, StubUpstream) {
    let pkgStore = makeStore()
    let blob = MemoryBlobStore()
    let ups = UpstreamService(MemoryUpstreamStore())
    let _ = ups.add("official", "https://upstream.test/registry", 0, "", 0)
    let proxy = ProxyService(pkgStore, blob, ups)
    let stub = StubUpstream()
    proxy.httpFetch = { u, t => stub.fetch(u, t) }
    (proxy, pkgStore, blob, stub)
}

// 落一个「回源镜像」形态的版本：只有索引字段（upstreamId != 0）+ 旧制品
func addMirrorVersion(store: PackageStore, blob: MemoryBlobStore, tarball: Array<Byte>,
                      version!: String = "1.0.0"): PackageDoc {
    let doc = PackageDoc()
    doc.organization = "acme"
    doc.name = "demo"
    doc.version = version
    doc.cjcVersion = "1.1.0"
    doc.sha256 = sha256Hex(tarball)
    doc.upstreamId = 1
    doc.upstreamName = "official"
    store.save(doc)
    blob.put(doc.sha256, tarball)
    return doc
}

// 1. 重拉：上游内容与本地一致 → Ok、changed=false、制品大小/README 补齐
@Test
func testRefetchKeepsSameContent() {
    let (proxy, store, blob, stub) = makeRefetchFixture()
    let art = cjpWithReadme("demo-1.0.0", "# 重拉 README\n")
    stub.artifact = art
    let doc = addMirrorVersion(store, blob, art)
    let r = refetchVersion(proxy, doc, false)
    @Expect(r.outcome == RefetchOutcome.Ok, true)
    @Expect(r.changed, false)
    @Expect(r.size, art.size)
    @Expect(store.getById(doc.id).getOrThrow().tarballSize, art.size)
    @Expect(store.getById(doc.id).getOrThrow().readme, "# 重拉 README\n")
}

// 2. 上游同版本 sha 变了：默认拒绝（409 语义），带出 old/new sha
@Test
func testRefetchShaChangedNeedsForce() {
    let (proxy, store, blob, stub) = makeRefetchFixture()
    let oldArt = cjpWithReadme("demo-1.0.0", "old")
    let newArt = cjpWithReadme("demo-1.0.0", "new")
    stub.artifact = newArt
    let doc = addMirrorVersion(store, blob, oldArt)
    let before = sha256Hex(oldArt)
    let r = refetchVersion(proxy, doc, false)
    @Expect(r.outcome == RefetchOutcome.ShaChanged, true)
    @Expect(r.oldSha, before)
    @Expect(r.newSha, sha256Hex(newArt))
    // 未被改动
    @Expect(store.getById(doc.id).getOrThrow().sha256, before)
}

// 3. force=true：接受上游新内容，覆盖 sha/size/README，旧 blob 清掉
@Test
func testRefetchForceOverwritesContent() {
    let (proxy, store, blob, stub) = makeRefetchFixture()
    let oldArt = cjpWithReadme("demo-1.0.0", "old")
    let newArt = cjpWithReadme("demo-1.0.0", "new content")
    stub.artifact = newArt
    let doc = addMirrorVersion(store, blob, oldArt)
    let oldSha = sha256Hex(oldArt)
    let newSha = sha256Hex(newArt)
    let r = refetchVersion(proxy, doc, true)
    @Expect(r.outcome == RefetchOutcome.Ok, true)
    @Expect(r.changed, true)
    @Expect(r.newSha, newSha)
    @Expect(store.getById(doc.id).getOrThrow().sha256, newSha)
    @Expect(store.getById(doc.id).getOrThrow().readme, "new content")
    @Expect(blob.get(newSha).isSome(), true)
    @Expect(blob.get(oldSha).isNone(), true)  // 旧制品无引用 → 清理
}

// 4. 本地发布的版本（upstreamId == 0）拒绝重拉：本地才是权威
@Test
func testRefetchRejectsLocalOwnedVersion() {
    let (proxy, store, blob, stub) = makeRefetchFixture()
    let art = cjpWithReadme("demo-1.0.0", "# local\n")
    stub.artifact = art
    let doc = PackageDoc()
    doc.organization = "acme"
    doc.name = "demo"
    doc.version = "1.0.0"
    doc.sha256 = sha256Hex(art)
    doc.upstreamId = 0
    store.save(doc)
    let r = refetchVersion(proxy, doc, true)
    @Expect(r.outcome == RefetchOutcome.LocalOwned, true)
    @Expect(stub.indexCalls, 0)  // 连上游都不该问
}

// 5. 下载内容与上游索引 sha 不符（半截包/内容被换）→ Invalid，本地不动
@Test
func testRefetchRejectsShaMismatch() {
    let (proxy, store, blob, stub) = makeRefetchFixture()
    let art = cjpWithReadme("demo-1.0.0", "# real\n")
    stub.artifact = art
    stub.indexSha = "deadbeefdeadbeef"  // 索引说的 sha 与内容不符
    let doc = addMirrorVersion(store, blob, art)
    let beforeSha = doc.sha256
    let r = refetchVersion(proxy, doc, true)
    @Expect(r.outcome == RefetchOutcome.Invalid, true)
    @Expect(store.getById(doc.id).getOrThrow().sha256, beforeSha)
}

// 6. 上游不可达（索引或制品取不到）→ Unreachable，不误报成功
@Test
func testRefetchUnreachable() {
    let (proxy, store, blob, stub) = makeRefetchFixture()
    let art = cjpWithReadme("demo-1.0.0", "# x\n")
    stub.artifact = art
    stub.indexBroken = true
    let doc = addMirrorVersion(store, blob, art)
    let r = refetchVersion(proxy, doc, false)
    @Expect(r.outcome == RefetchOutcome.Unreachable, true)
    @Expect(r.message.contains("不可达"), true)

    // 索引正常但制品取不到
    let (proxy2, store2, blob2, stub2) = makeRefetchFixture()
    stub2.artifact = art
    stub2.artifactBroken = true
    let doc2 = addMirrorVersion(store2, blob2, art)
    @Expect(refetchVersion(proxy2, doc2, false).outcome == RefetchOutcome.Unreachable, true)
}

// 7. 上游索引里已无该版本 → UpstreamMissing
@Test
func testRefetchUpstreamMissingVersion() {
    let (proxy, store, blob, stub) = makeRefetchFixture()
    let art = cjpWithReadme("demo-1.0.0", "# x\n")
    stub.artifact = art
    stub.indexHasVersion = false
    let doc = addMirrorVersion(store, blob, art)
    let r = refetchVersion(proxy, doc, false)
    @Expect(r.outcome == RefetchOutcome.UpstreamMissing, true)
}

// 8. 硬删除：制品仍被其它版本引用时不删 blob（内容寻址可能共享）
@Test
func testHardDeleteKeepsSharedBlob() {
    let store = makeStore()
    let blob = MemoryBlobStore()
    let art = cjpWithReadme("demo-1.0.0", "# shared\n")
    let sha = sha256Hex(art)
    blob.put(sha, art)
    let a = PackageDoc()
    a.organization = "acme"
    a.name = "demo-a"
    a.version = "1.0.0"
    a.sha256 = sha
    a.deletedAt = 1  // 已软删，可硬删
    store.save(a)
    let b = PackageDoc()
    b.organization = "acme"
    b.name = "demo-b"
    b.version = "1.0.0"
    b.sha256 = sha
    store.save(b)

    @Expect(shaReferencedByOthers(store, sha, a.id), 1)
    let r = hardDeleteVersion(store, blob, None, a, 2)
    @Expect(r.outcome == LifecycleOutcome.Ok, true)
    @Expect(r.blobRemoved, false)
    @Expect(blob.get(sha).isSome(), true)          // 另一个版本还能下载
    @Expect(r.message.contains("仍被 1 个其它版本引用"), true)
    @Expect(store.getById(a.id).isNone(), true)     // 记录已删
}

// 9. 硬删除：无人共享时才删制品（原有行为不回归）
@Test
func testHardDeleteRemovesUnsharedBlob() {
    let store = makeStore()
    let blob = MemoryBlobStore()
    let art = cjpWithReadme("demo-1.0.0", "# solo\n")
    let sha = sha256Hex(art)
    blob.put(sha, art)
    let a = PackageDoc()
    a.organization = "acme"
    a.name = "demo-a"
    a.version = "1.0.0"
    a.sha256 = sha
    a.deletedAt = 1
    store.save(a)
    let r = hardDeleteVersion(store, blob, None, a, 2)
    @Expect(r.blobRemoved, true)
    @Expect(blob.get(sha).isNone(), true)
}

// 10. overwrite 模式：按上游新制品整体刷新展示字段（对比默认只填空）
@Test
func testEnrichOverwriteRefreshesFields() {
    let doc = PackageDoc()
    doc.organization = "acme"
    doc.name = "demo"
    doc.version = "1.0.0"
    doc.description = "旧描述"
    doc.readme = "旧 README"
    doc.tarballSize = 0
    let sb = StringBuilder()
    sb.append("[package]\n")
    sb.append("  name = \"demo\"\n")
    sb.append("  description = \"新描述\"\n")
    sb.append("  license = [\"MIT\"]\n")
    let art = cjpWithReadmeAndToml("demo-1.0.0", "新 README", sb.toString())
    // 默认：只填空 → 已有值不覆盖
    let _ = enrichDocFromArtifact(doc, art)
    @Expect(doc.description, "旧描述")
    @Expect(doc.readme, "旧 README")
    // overwrite：整体刷新
    let _ = enrichDocFromArtifact(doc, art, overwrite: true)
    @Expect(doc.description, "新描述")
    @Expect(doc.readme, "新 README")
    @Expect(doc.license.size, 1)
    @Expect(doc.tarballSize, art.size)
}
