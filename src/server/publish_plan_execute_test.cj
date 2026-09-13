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

// 索引迟迟不出现 → 这一项记「等索引」、计划转 paused（可续跑），
// 但**不中止整个计划**：与它无关的项照发（新版语义；旧的"一超时就全停"已废弃）
@Test
func executeReport_indexTimeout_pausesAndStops() {
    let (store, blobs) = execFixture()
    let items = ArrayList<PlanItem>()
    items.add(execItem(execDoc(store, blobs, "a", "1.0.0"), "a", "1.0.0", 1))
    items.add(execItem(execDoc(store, blobs, "b", "1.0.0"), "b", "1.0.0", 2))
    let calls = Box<Int64>(0)
    let probe: (String, String) -> ?String = { _, _ =>
        // 目标仓索引里始终只有 a 的旧版本：a 等不到，b 与 a 无关、索引里正常可见
        Some("{\"name\":\"a\",\"version\":\"0.9.0\"}\n")
    }
    let ex = PublishExecutor(store, blobs)
    let r = ex.execute(items, "http://127.0.0.1:1", "tok",
        poster: stubPoster(codesOf([200]), calls), indexProbe: probe,
        pollIntervalSec: 1, pollTimeoutSec: 1)
    // 探头永远只报 a 的旧版本 → a、b 两项都等不到自己的版本（两项都已推成功）
    @Expect(r.waitingIndex, 2)
    @Expect(r.aborted, false)               // 不再中止整个计划
    @Expect(r.success, 0)
    @Expect(r.failed, 0)
    // 超时的那一项保持「等待索引」而不是「未推送」：它其实已经推成功了，
    // 续跑时必须能据此知道**不要再推**（重推只会换回 409）
    @Expect(items[0].status == PlanItemStatus.WaitingIndex, true)
    @Expect(items[1].status == PlanItemStatus.WaitingIndex, true)
    @Expect(calls.value, 2)                 // 两项都推过（各一次，没有重推）
    store.storm.close()
}

// 续跑：上次「等待索引」的项**不再重推**，只继续等索引；等到了就完成
@Test
func executeReport_resumeWaitingIndex_doesNotRepush() {
    let (store, blobs) = execFixture()
    let items = ArrayList<PlanItem>()
    let it = execItem(execDoc(store, blobs, "a", "1.0.0"), "a", "1.0.0", 1)
    it.status = PlanItemStatus.WaitingIndex   // 上次已推成功、在等索引
    items.add(it)
    let calls = Box<Int64>(0)
    let probe: (String, String) -> ?String = { _, _ =>
        Some("{\"name\":\"a\",\"version\":\"1.0.0\"}\n")
    }
    let ex = PublishExecutor(store, blobs)
    let r = ex.execute(items, "http://127.0.0.1:1", "tok",
        poster: stubPoster(codesOf([200]), calls), indexProbe: probe,
        pollIntervalSec: 1, pollTimeoutSec: 10)
    @Expect(calls.value, 0)                   // 关键：没有再推一次
    @Expect(r.success, 1)
    @Expect(r.failed, 0)
    @Expect(r.aborted, false)
    @Expect(items[0].status == PlanItemStatus.Completed, true)
    store.storm.close()
}

// 未勾选的「目标仓已有同版本」项：跳过原因必须说清楚
// （只说"未勾选"会让人以为是自己漏点了，然后去手工勾上重复推同一个版本）
@Test
func executeReport_unselectedAlreadyExistsExplainsItself() {
    let (store, blobs) = execFixture()
    let items = ArrayList<PlanItem>()
    let it = execItem(execDoc(store, blobs, "a", "1.0.0"), "a", "1.0.0", 1)
    it.selected = false
    it.category = PlanCategory.AlreadyExists
    items.add(it)
    let calls = Box<Int64>(0)
    let ex = PublishExecutor(store, blobs)
    let r = ex.execute(items, "http://127.0.0.1:1", "tok", poster: stubPoster(codesOf([200]), calls))
    @Expect(calls.value, 0)
    @Expect(r.skipped, 1)
    @Expect(items[0].error.contains("目标仓已有同版本"), true)
    store.storm.close()
}

// 未勾选的「冲突」项：目标仓不允许覆盖（官方中心仓）时必须明说"只能升版" ——
// 说成"未勾选"或"可强制覆盖"都会把人引到注定 409 的操作上
@Test
func executeReport_unselectedConflictOnOfficialSaysUpgrade() {
    let (store, blobs) = execFixture()
    let items = ArrayList<PlanItem>()
    let it = execItem(execDoc(store, blobs, "a", "1.0.0"), "a", "1.0.0", 1)
    it.selected = false
    it.category = PlanCategory.Conflict
    it.overwriteAllowed = false
    items.add(it)
    let calls = Box<Int64>(0)
    let ex = PublishExecutor(store, blobs)
    let r = ex.execute(items, "http://127.0.0.1:1", "tok", poster: stubPoster(codesOf([200]), calls))
    @Expect(r.skipped, 1)
    @Expect(items[0].error.contains("升版"), true)
    store.storm.close()
}

// 自建仓（允许覆盖）时，冲突项的说明则是"勾选可强制覆盖"
@Test
func executeReport_unselectedConflictOnOwnRepoMentionsOverwrite() {
    let (store, blobs) = execFixture()
    let items = ArrayList<PlanItem>()
    let it = execItem(execDoc(store, blobs, "a", "1.0.0"), "a", "1.0.0", 1)
    it.selected = false
    it.category = PlanCategory.Conflict
    it.overwriteAllowed = true
    items.add(it)
    let calls = Box<Int64>(0)
    let ex = PublishExecutor(store, blobs)
    let r = ex.execute(items, "http://127.0.0.1:1", "tok", poster: stubPoster(codesOf([200]), calls))
    @Expect(r.skipped, 1)
    @Expect(items[0].error.contains("覆盖"), true)
    store.storm.close()
}

// ===== 依赖感知：某个包没就绪时，只卡住依赖它的项 =====
//
// 出过的事故（实测）：tsdb 推上去后中心仓审核没过，索引里一直不出现 0.3.3 →
// 上一版代码在索引超时时 `aborted = true` **中止整个计划**，把根本不依赖 tsdb 的
// bstorm 一起卡死了。同一条链上的另一个根（彼此无依赖）本来就该照发。

// 造一个带依赖声明的包（依赖同计划里的 iface）
func execDocWithDep(store: PackageStore, blobs: MemoryBlobStore, name: String, version: String,
                    depName: String, depRequire: String): Int64 {
    let sha = "sha-${name}-${version}"
    let d = PackageDoc()
    d.name = name
    d.version = version
    let entry = PackageIndex()
    entry.name = name
    entry.version = version
    entry.sha256sum = sha
    entry.dependencies.add(DependencyEntry(depName, depRequire, "", "", ""))
    d.indexJson = generateNDJSON(ArrayList<PackageIndex>([entry]))
    store.save(d)
    blobs.put(sha, Array<Byte>(16, repeat: 7))
    d.id
}

// 索引超时不再中止整个计划：无关项照发，只有依赖它的项被跳过
@Test
func executeReport_indexTimeout_onlyBlocksDependents() {
    let (store, blobs) = execFixture()
    let items = ArrayList<PlanItem>()
    // base（被 top 依赖，索引一直不出现）+ top（依赖 base）+ other（与两者无关）
    let baseId = execDoc(store, blobs, "base", "1.0.0")
    let topId = execDocWithDep(store, blobs, "top", "1.0.0", "base", "1.0.0")
    let otherId = execDoc(store, blobs, "other", "1.0.0")
    items.add(execItem(baseId, "base", "1.0.0", 1))
    items.add(execItem(topId, "top", "1.0.0", 2))
    items.add(execItem(otherId, "other", "1.0.0", 3))
    let calls = Box<Int64>(0)
    // 目标仓索引里永远没有 base 1.0.0（审核没过）；其它包正常可见
    let probe: (String, String) -> ?String = { _, name =>
        if (name == "base") {
            Some("{\"name\":\"base\",\"version\":\"0.9.0\"}\n")
        } else {
            Some("{\"name\":\"${name}\",\"version\":\"1.0.0\"}\n")
        }
    }
    let ex = PublishExecutor(store, blobs)
    let r = ex.execute(items, "http://127.0.0.1:1", "tok",
        poster: stubPoster(codesOf([200, 200, 200]), calls), indexProbe: probe,
        pollIntervalSec: 1, pollTimeoutSec: 1)
    @Expect(r.waitingIndex, 1)                       // base 在等索引
    @Expect(r.aborted, false)                        // 不再中止整个计划
    @Expect(r.success, 1)                            // other 照发成功
    @Expect(r.skipped, 1)                            // top 被依赖阻塞
    @Expect(items[0].status == PlanItemStatus.WaitingIndex, true)
    @Expect(items[1].status == PlanItemStatus.Skipped, true)
    @Expect(items[1].error.contains("依赖"), true)
    @Expect(items[1].error.contains("base"), true)
    @Expect(items[2].status == PlanItemStatus.Completed, true)
    @Expect(calls.value, 2)                          // base + other 各推一次，top 没推
    store.storm.close()
}

// 推送失败的项同样阻塞它的依赖方（缺依赖的包发上去也是白搭）
@Test
func executeReport_failedDep_blocksDependentsContinuesOthers() {
    let (store, blobs) = execFixture()
    let items = ArrayList<PlanItem>()
    let baseId = execDoc(store, blobs, "base", "1.0.0")
    let topId = execDocWithDep(store, blobs, "top", "1.0.0", "base", "1.0.0")
    let otherId = execDoc(store, blobs, "other", "1.0.0")
    items.add(execItem(baseId, "base", "1.0.0", 1))
    items.add(execItem(topId, "top", "1.0.0", 2))
    items.add(execItem(otherId, "other", "1.0.0", 3))
    let calls = Box<Int64>(0)
    // base 400（不重试）→ top 必须被跳过；other 200
    let ex = PublishExecutor(store, blobs)
    let r = ex.execute(items, "http://127.0.0.1:1", "tok", poster: stubPoster(codesOf([400, 200]), calls))
    @Expect(r.failed, 1)
    @Expect(r.success, 1)
    @Expect(items[1].error.contains("依赖 base@1.0.0 未在目标仓就绪"), true)
    @Expect(calls.value, 2)                          // top 没有被推
    store.storm.close()
}

// 依赖链传递性：a ← b ← c，a 没就绪 → b、c 都不发
@Test
func executeReport_blockingIsTransitive() {
    let (store, blobs) = execFixture()
    let items = ArrayList<PlanItem>()
    let aId = execDoc(store, blobs, "a", "1.0.0")
    let bId = execDocWithDep(store, blobs, "b", "1.0.0", "a", "1.0.0")
    let cId = execDocWithDep(store, blobs, "c", "1.0.0", "b", "1.0.0")
    items.add(execItem(aId, "a", "1.0.0", 1))
    items.add(execItem(bId, "b", "1.0.0", 2))
    items.add(execItem(cId, "c", "1.0.0", 3))
    let calls = Box<Int64>(0)
    let ex = PublishExecutor(store, blobs)
    // a 400 失败 → b、c 都被阻塞，只有 a 被推一次
    let r = ex.execute(items, "http://127.0.0.1:1", "tok", poster: stubPoster(codesOf([400]), calls))
    @Expect(r.failed, 1)
    @Expect(r.skipped, 2)
    @Expect(calls.value, 1)
    @Expect(items[2].status == PlanItemStatus.Skipped, true)
    store.storm.close()
}
