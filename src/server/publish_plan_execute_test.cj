// 发布计划执行器的状态码语义回归（对齐官方仓返回码规格）。
//
// 关键点：
//   409 是「这次发不上去」→ 该项跳过、继续下一项（不是失败）
//   429/401/403 是「继续下去每一项都会同样失败」→ **立刻中止**，后面的项不再发
//   >=500 是服务器故障 → 退避重试，重试次数用完才判失败
//   已完成的项在续跑时不再重复推送（重复推同一版本只会换回 409）

package ystyle::cjreg.server

import ystyle::cjreg.store.*
import ystyle::cjreg.index.*
import bstorm.*
import std.collection.*

func execFixture(): (PackageStore, MemoryBlobStore) {
    let store = PackageStore(Storm.inMemory())
    (store, MemoryBlobStore())
}

// 造一个可发布的包（有 sha + 有制品），返回 docId
func execDoc(store: PackageStore, blobs: MemoryBlobStore, name: String, version: String): Int64 {
    let sha = "sha-${name}-${version}"
    let d = PackageDoc()
    d.name = name
    d.version = version
    d.sha256 = sha
    let entry = PackageIndex()
    entry.name = name
    entry.version = version
    entry.sha256sum = sha
    d.indexJson = generateNDJSON(ArrayList<PackageIndex>([entry]))
    store.save(d)
    blobs.put(sha, Array<Byte>(16, repeat: 7))
    d.id
}

func execItem(docId: Int64, name: String, version: String, order: Int64): PlanItem {
    PlanItem(docId, name, "", version, PlanCategory.NeedPublish, order)
}

// 按脚本依次返回状态码的桩（用完后重复最后一个）
func stubPoster(codes: ArrayList<Int64>, calls: Box<Int64>): (String, Array<Byte>, String) -> (Bool, Int64, String) {
    { _, _, _ =>
        var idx = calls.value
        if (idx >= Int64(codes.size)) {
            idx = Int64(codes.size) - 1
        }
        calls.value++
        let c = codes[idx]
        let body = if (c == 429) { "{\"error\":\"每日请求频率超限\"}" } else { "" }
        (c >= 200 && c < 300, c, body)
    }
}

func codesOf(values: Array<Int64>): ArrayList<Int64> {
    let l = ArrayList<Int64>()
    for (v in values) {
        l.add(v)
    }
    l
}

@Test
func executeReport_200_completes() {
    let (store, blobs) = execFixture()
    let items = ArrayList<PlanItem>()
    items.add(execItem(execDoc(store, blobs, "a", "1.0.0"), "a", "1.0.0", 1))
    let calls = Box<Int64>(0)
    let ex = PublishExecutor(store, blobs)
    let r = ex.execute(items, "http://127.0.0.1:1", "tok", poster: stubPoster(codesOf([200]), calls))
    @Expect(r.success, 1)
    @Expect(r.failed, 0)
    @Expect(r.aborted, false)
    @Expect(items[0].status == PlanItemStatus.Completed, true)
    store.storm.close()
}

// 409：目标仓已有同版本不同制品 → 跳过并继续（不是失败）
@Test
func executeReport_409_skipsAndContinues() {
    let (store, blobs) = execFixture()
    let items = ArrayList<PlanItem>()
    items.add(execItem(execDoc(store, blobs, "a", "1.0.0"), "a", "1.0.0", 1))
    items.add(execItem(execDoc(store, blobs, "b", "1.0.0"), "b", "1.0.0", 2))
    let calls = Box<Int64>(0)
    let ex = PublishExecutor(store, blobs)
    let r = ex.execute(items, "http://127.0.0.1:1", "tok", poster: stubPoster(codesOf([409, 200]), calls))
    @Expect(calls.value, 2)                     // 409 之后仍然推了第二项
    @Expect(r.success, 1)
    @Expect(r.skipped, 1)
    @Expect(r.failed, 0)
    @Expect(items[0].status == PlanItemStatus.Skipped, true)
    @Expect(items[0].error.contains("409"), true)
    @Expect(items[1].status == PlanItemStatus.Completed, true)
    store.storm.close()
}

// 429：每日频率超限 → 立刻中止，后面的项**不再发**（省配额），且不当作失败
@Test
func executeReport_429_pausesAndStops() {
    let (store, blobs) = execFixture()
    let items = ArrayList<PlanItem>()
    items.add(execItem(execDoc(store, blobs, "a", "1.0.0"), "a", "1.0.0", 1))
    items.add(execItem(execDoc(store, blobs, "b", "1.0.0"), "b", "1.0.0", 2))
    items.add(execItem(execDoc(store, blobs, "c", "1.0.0"), "c", "1.0.0", 3))
    let calls = Box<Int64>(0)
    let ex = PublishExecutor(store, blobs)
    let r = ex.execute(items, "http://127.0.0.1:1", "tok", poster: stubPoster(codesOf([200, 429, 200]), calls))
    @Expect(calls.value, 2)                     // 第三项没有被推
    @Expect(r.aborted, true)
    @Expect(r.abortReason.contains("429"), true)
    @Expect(r.success, 1)
    @Expect(r.failed, 0)
    @Expect(items[2].status == PlanItemStatus.Skipped, true)
    @Expect(items[2].error.contains("中止"), true)
    store.storm.close()
}

// 401：认证失败 → 中止（后续必然同样 401）
@Test
func executeReport_401_aborts() {
    let (store, blobs) = execFixture()
    let items = ArrayList<PlanItem>()
    items.add(execItem(execDoc(store, blobs, "a", "1.0.0"), "a", "1.0.0", 1))
    items.add(execItem(execDoc(store, blobs, "b", "1.0.0"), "b", "1.0.0", 2))
    let calls = Box<Int64>(0)
    let ex = PublishExecutor(store, blobs)
    let r = ex.execute(items, "http://127.0.0.1:1", "tok", poster: stubPoster(codesOf([401, 200]), calls))
    @Expect(calls.value, 1)
    @Expect(r.aborted, true)
    @Expect(r.abortReason.contains("401"), true)
    @Expect(items[1].status == PlanItemStatus.Skipped, true)
    store.storm.close()
}

// >=500：退避重试，用满重试次数仍失败才判该项失败
@Test
func executeReport_500_retriesThenFails() {
    let (store, blobs) = execFixture()
    let items = ArrayList<PlanItem>()
    items.add(execItem(execDoc(store, blobs, "a", "1.0.0"), "a", "1.0.0", 1))
    let calls = Box<Int64>(0)
    let ex = PublishExecutor(store, blobs)
    let r = ex.execute(items, "http://127.0.0.1:1", "tok", poster: stubPoster(codesOf([500, 500, 500]), calls))
    @Expect(calls.value, 3)                     // 重试 3 次
    @Expect(r.failed, 1)
    @Expect(r.aborted, false)
    @Expect(items[0].status == PlanItemStatus.Failed, true)
    store.storm.close()
}

// 500 之后成功：重试有效
@Test
func executeReport_500_thenSuccess() {
    let (store, blobs) = execFixture()
    let items = ArrayList<PlanItem>()
    items.add(execItem(execDoc(store, blobs, "a", "1.0.0"), "a", "1.0.0", 1))
    let calls = Box<Int64>(0)
    let ex = PublishExecutor(store, blobs)
    let r = ex.execute(items, "http://127.0.0.1:1", "tok", poster: stubPoster(codesOf([500, 200]), calls))
    @Expect(calls.value, 2)
    @Expect(r.success, 1)
    @Expect(r.failed, 0)
    store.storm.close()
}

// 400：参数/元数据错误 → 该项失败，不重试（重试也还是 400）
@Test
func executeReport_400_failsWithoutRetry() {
    let (store, blobs) = execFixture()
    let items = ArrayList<PlanItem>()
    items.add(execItem(execDoc(store, blobs, "a", "1.0.0"), "a", "1.0.0", 1))
    let calls = Box<Int64>(0)
    let ex = PublishExecutor(store, blobs)
    let r = ex.execute(items, "http://127.0.0.1:1", "tok", poster: stubPoster(codesOf([400, 400]), calls))
    @Expect(calls.value, 1)
    @Expect(r.failed, 1)
    @Expect(items[0].error.contains("400"), true)
    store.storm.close()
}

// 续跑：已完成的项不再重复推送（重复推同版本只会换回 409）
@Test
func executeReport_skipsAlreadyCompleted() {
    let (store, blobs) = execFixture()
    let items = ArrayList<PlanItem>()
    let done = execItem(execDoc(store, blobs, "a", "1.0.0"), "a", "1.0.0", 1)
    done.status = PlanItemStatus.Completed
    items.add(done)
    items.add(execItem(execDoc(store, blobs, "b", "1.0.0"), "b", "1.0.0", 2))
    let calls = Box<Int64>(0)
    let ex = PublishExecutor(store, blobs)
    let r = ex.execute(items, "http://127.0.0.1:1", "tok", poster: stubPoster(codesOf([200]), calls))
    @Expect(calls.value, 1)                     // 只推了第二项
    @Expect(r.success, 1)
    @Expect(r.skipped, 1)
    store.storm.close()
}

// 未勾选的项不推送
@Test
func executeReport_skipsUnselected() {
    let (store, blobs) = execFixture()
    let items = ArrayList<PlanItem>()
    let off = execItem(execDoc(store, blobs, "a", "1.0.0"), "a", "1.0.0", 1)
    off.selected = false
    items.add(off)
    let calls = Box<Int64>(0)
    let ex = PublishExecutor(store, blobs)
    let r = ex.execute(items, "http://127.0.0.1:1", "tok", poster: stubPoster(codesOf([200]), calls))
    @Expect(calls.value, 0)
    @Expect(r.skipped, 1)
    @Expect(r.success, 0)
    store.storm.close()
}

// 索引就绪等待：推上去还不算完成，必须等目标仓索引里出现该版本
// （拓扑序里下一条依赖它；中心仓的索引同步偶尔很慢）
@Test
func executeReport_waitsForIndexReady() {
    let (store, blobs) = execFixture()
    let items = ArrayList<PlanItem>()
    items.add(execItem(execDoc(store, blobs, "a", "1.0.0"), "a", "1.0.0", 1))
    let calls = Box<Int64>(0)
    let probes = Box<Int64>(0)
    // 第一次查索引还没有该版本，第二次才有
    let probe: (String, String) -> ?String = { _, _ =>
        probes.value++
        if (probes.value < 2) {
            Some("{\"name\":\"a\",\"version\":\"0.9.0\"}\n")
        } else {
            Some("{\"name\":\"a\",\"version\":\"1.0.0\"}\n")
        }
    }
    let ex = PublishExecutor(store, blobs)
    let r = ex.execute(items, "http://127.0.0.1:1", "tok",
        poster: stubPoster(codesOf([200]), calls), indexProbe: probe,
        pollIntervalSec: 1, pollTimeoutSec: 10)
    @Expect(r.success, 1)
    @Expect(r.aborted, false)
    @Expect(probes.value >= 2, true)
    @Expect(items[0].status == PlanItemStatus.Completed, true)
    store.storm.close()
}

// 索引迟迟不出现 → 暂停（不是失败：内容已经推上去了）+ 后面的项不再推
@Test
func executeReport_indexTimeout_pausesAndStops() {
    let (store, blobs) = execFixture()
    let items = ArrayList<PlanItem>()
    items.add(execItem(execDoc(store, blobs, "a", "1.0.0"), "a", "1.0.0", 1))
    items.add(execItem(execDoc(store, blobs, "b", "1.0.0"), "b", "1.0.0", 2))
    let calls = Box<Int64>(0)
    let probes = Box<Int64>(0)
    let probe: (String, String) -> ?String = { _, _ =>
        probes.value++
        Some("{\"name\":\"a\",\"version\":\"0.9.0\"}\n")
    }
    let ex = PublishExecutor(store, blobs)
    let r = ex.execute(items, "http://127.0.0.1:1", "tok",
        poster: stubPoster(codesOf([200]), calls), indexProbe: probe,
        pollIntervalSec: 1, pollTimeoutSec: 1)
    @Expect(calls.value, 1)                 // 第二项没有被推
    @Expect(r.aborted, true)
    @Expect(r.abortReason.contains("索引"), true)
    @Expect(r.success, 0)
    @Expect(r.failed, 0)
    @Expect(items[0].status == PlanItemStatus.Skipped, true)
    @Expect(items[1].status == PlanItemStatus.Skipped, true)
    store.storm.close()
}
