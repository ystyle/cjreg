// 包三级删除闭环单元测试：软删/恢复（制品校验）/硬删（记录+制品+计划项联动）
package ystyle::cjreg.server

import ystyle::cjreg.store.*
import bstorm.*
import std.unittest.testmacro.*
import std.collection.*

func makeLifecycleFixture(): (PackageStore, AdminDataStore, MemoryBlobStore) {
    let storm = Storm.inMemory()
    let store = PackageStore(storm)
    let adminData = AdminDataStore(storm)
    let blobs = MemoryBlobStore()
    (store, adminData, blobs)
}

func makeVersionDoc(org: String, name: String, version: String, sha: String, upstreamId: Int64): PackageDoc {
    let d = PackageDoc()
    d.organization = org
    d.name = name
    d.version = version
    d.sha256 = sha
    d.upstreamId = upstreamId
    d.tarballSize = 128
    d.createdAt = 1000
    d.updatedAt = 1000
    d
}

@Test
func testSoftDeleteHidesAndIsIdempotent() {
    let (store, adminData, blobs) = makeLifecycleFixture()
    blobs.put("sha-1", Array<Byte>(3, repeat: 1))
    let doc = makeVersionDoc("test", "demo", "1.0.0", "sha-1", 0)
    store.save(doc)

    let r = softDeleteVersion(store, Some(adminData), doc, 5000)
    @Expect(r.outcome == LifecycleOutcome.Ok, true)
    @Expect(store.getById(doc.id).getOrThrow().deletedAt, 5000)
    // 索引/公开 API 不再可见
    @Expect(publicVersions(store, "test", "demo", { _ => "alice" }).size, 0)
    // 制品保留（可恢复）
    @Expect(blobs.has("sha-1"), true)
    // 幂等
    let again = softDeleteVersion(store, Some(adminData), store.getById(doc.id).getOrThrow(), 6000)
    @Expect(again.outcome == LifecycleOutcome.AlreadyDeleted, true)
    @Expect(store.getById(doc.id).getOrThrow().deletedAt, 5000)
}

@Test
func testRestoreRequiresArtifact() {
    let (store, adminData, blobs) = makeLifecycleFixture()
    blobs.put("sha-1", Array<Byte>(3, repeat: 1))
    let local = makeVersionDoc("test", "demo", "1.0.0", "sha-1", 0)
    store.save(local)
    let _ = softDeleteVersion(store, Some(adminData), local, 5000)

    // 制品在 → 恢复成功
    let ok = restoreVersion(store, blobs, store.getById(local.id).getOrThrow())
    @Expect(ok.outcome == LifecycleOutcome.Ok, true)
    @Expect(ok.artifactPresent, true)
    @Expect(store.getById(local.id).getOrThrow().deletedAt, 0)
    @Expect(publicVersions(store, "test", "demo", { _ => "alice" }).size, 1)

    // 未删除的版本恢复 → 无副作用
    let noop = restoreVersion(store, blobs, store.getById(local.id).getOrThrow())
    @Expect(noop.outcome == LifecycleOutcome.Ok, true)
    @Expect(noop.message.contains("未被删除"), true)

    // 制品丢失（本地发布 + blob 丢失）→ 拒绝恢复
    let lost = makeVersionDoc("test", "lost", "2.0.0", "sha-missing", 0)
    store.save(lost)
    let _ = softDeleteVersion(store, Some(adminData), lost, 5000)
    let bad = restoreVersion(store, blobs, store.getById(lost.id).getOrThrow())
    @Expect(bad.outcome == LifecycleOutcome.ArtifactMissing, true)
    @Expect(bad.artifactPresent, false)
    @Expect(store.getById(lost.id).getOrThrow().deletedAt, 5000)   // 仍保持删除态

    // 上游回源版本（blob 不在本地但可重新拉取）→ 允许恢复
    let cached = makeVersionDoc("test", "cached", "3.0.0", "sha-upstream", 7)
    store.save(cached)
    let _ = softDeleteVersion(store, Some(adminData), cached, 5000)
    let viaUp = restoreVersion(store, blobs, store.getById(cached.id).getOrThrow())
    @Expect(viaUp.outcome == LifecycleOutcome.Ok, true)
    @Expect(store.getById(cached.id).getOrThrow().deletedAt, 0)
}

@Test
func testHardDeleteRequiresSoftDeleteFirst() {
    let (store, adminData, blobs) = makeLifecycleFixture()
    blobs.put("sha-1", Array<Byte>(3, repeat: 1))
    let doc = makeVersionDoc("test", "demo", "1.0.0", "sha-1", 0)
    store.save(doc)

    // 未软删 → 拒绝
    let refused = hardDeleteVersion(store, blobs, Some(adminData), doc, 5000)
    @Expect(refused.outcome == LifecycleOutcome.NotDeleted, true)
    @Expect(store.getById(doc.id).isSome(), true)
    @Expect(blobs.has("sha-1"), true)

    // 软删后 → 记录与制品一并删除
    let _ = softDeleteVersion(store, Some(adminData), doc, 5000)
    let done = hardDeleteVersion(store, blobs, Some(adminData), store.getById(doc.id).getOrThrow(), 6000)
    @Expect(done.outcome == LifecycleOutcome.Ok, true)
    @Expect(done.blobRemoved, true)
    @Expect(store.getById(doc.id).isNone(), true)
    @Expect(blobs.has("sha-1"), false)
    @Expect(store.listVersions("test", "demo").size, 0)

    // 无 sha / 无 blob 的版本（回源缓存）硬删不报错
    let cached = makeVersionDoc("test", "cached", "1.0.0", "", 5)
    store.save(cached)
    let _ = softDeleteVersion(store, Some(adminData), cached, 5000)
    let r2 = hardDeleteVersion(store, blobs, Some(adminData), store.getById(cached.id).getOrThrow(), 6000)
    @Expect(r2.outcome == LifecycleOutcome.Ok, true)
    @Expect(r2.blobRemoved, false)
    @Expect(store.getById(cached.id).isNone(), true)
}

@Test
func testPlanItemsMarkedSkippedOnDelete() {
    let (store, adminData, blobs) = makeLifecycleFixture()
    blobs.put("sha-1", Array<Byte>(1, repeat: 1))
    let doc = makeVersionDoc("test", "demo", "1.0.0", "sha-1", 0)
    store.save(doc)
    // 计划：引用目标版本（pending）+ 另一个版本（pending）+ 已完成项（不应被动）
    let planId = adminData.createPlan("plan", 3, 60, 600, 1000)
    let target = adminData.addPlanItem(planId, doc.id, "test", "demo", "1.0.0", 1, "app", true)
    let other = adminData.addPlanItem(planId, 0, "test", "other", "1.0.0", 2, "deps", true)
    let finished = adminData.addPlanItem(planId, 0, "test", "demo", "1.0.0", 3, "deps", true)
    let _ = adminData.updatePlanItem(finished, "completed", "", 1500)

    let r = softDeleteVersion(store, Some(adminData), doc, 5000)
    @Expect(r.outcome == LifecycleOutcome.Ok, true)
    @Expect(r.skippedPlanItems, 1)
    @Expect(adminData.getPlanItem(target).getOrThrow().status, "skipped")
    @Expect(adminData.getPlanItem(target).getOrThrow().error.contains("已删除"), true)
    @Expect(adminData.getPlanItem(other).getOrThrow().status, "pending")
    @Expect(adminData.getPlanItem(finished).getOrThrow().status, "completed")

    // 再次软删（恢复后再删）不会重复计数；恢复不影响已跳过项
    let _ = restoreVersion(store, blobs, store.getById(doc.id).getOrThrow())
    let r2 = softDeleteVersion(store, Some(adminData), store.getById(doc.id).getOrThrow(), 7000)
    @Expect(r2.skippedPlanItems, 0)   // 已是 skipped，不重复标记
    // 硬删同样联动（新计划项）
    let plan2 = adminData.createPlan("plan2", 3, 60, 600, 8000)
    let target2 = adminData.addPlanItem(plan2, doc.id, "test", "demo", "1.0.0", 1, "app", true)
    let r3 = hardDeleteVersion(store, blobs, Some(adminData), store.getById(doc.id).getOrThrow(), 9000)
    @Expect(r3.skippedPlanItems, 1)
    @Expect(adminData.getPlanItem(target2).getOrThrow().status, "skipped")
}

@Test
func testLifecycleJsonShape() {
    let ok = LifecycleResult(LifecycleOutcome.Ok, "已软删除（可恢复）", 2, false, true)
    let json = lifecycleJson(ok)
    @Expect(json.contains("\"status\":\"ok\""), true)
    @Expect(json.contains("\"skippedPlanItems\":2"), true)
    @Expect(json.contains("\"blobRemoved\":false"), true)
    @Expect(json.contains("\"artifactPresent\":true"), true)
    let missing = LifecycleResult(LifecycleOutcome.ArtifactMissing, "制品\"丢失\"", 0, false, false)
    @Expect(lifecycleJson(missing).contains("\"status\":\"artifact_missing\""), true)
    @Expect(lifecycleJson(missing).contains("制品\\\"丢失\\\""), true)
    @Expect(lifecycleJson(LifecycleResult(LifecycleOutcome.NotDeleted, "x", 0, false, true))
        .contains("\"status\":\"not_deleted\""), true)
    @Expect(lifecycleJson(LifecycleResult(LifecycleOutcome.AlreadyDeleted, "x", 0, false, true))
        .contains("\"status\":\"already_deleted\""), true)
    @Expect(lifecycleJson(LifecycleResult(LifecycleOutcome.NotFound, "x", 0, false, true))
        .contains("\"status\":\"not_found\""), true)
    @Expect(lifecycleJson(LifecycleResult(LifecycleOutcome.Failed, "x", 0, false, true))
        .contains("\"status\":\"failed\""), true)
}
