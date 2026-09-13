// 发布计划执行器的接线回归：制品库必须用注入的那个。
//
// 出过的故障（生产实测）：`runExecution` 自己 new 了 `DiskBlobStore("./data/blobs")`
// （`getDataDir()` 是写死 "./data" 的桩），而不是用启动时按 `-d/--data-dir` 注入的制品库。
// 宿主仓库里工作目录就是仓库根、`./data` 恰好对，本地看着没问题；**容器里工作目录是 /app、
// 真实数据目录是 /data** → 执行器去 `/app/data/blobs`（空目录）找制品，于是**每一项都报
// 「制品缺失（sha=…）」**，而 `/pkg/:name/:version` 下载一切正常，看起来像包坏了。
//
// 这里用「注入的 MemoryBlobStore 里**有**制品」来钉住这条接线：如果哪天又有人自己搭库，
// 断言会立刻变成「制品缺失」而红。

package ystyle::cjreg.ui

import ystyle::cjreg.store.*
import ystyle::cjreg.index.*
import ystyle::cjreg.server.*
import ystyle::cjreg.protocol.*
import bstorm.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

// 造一个「包文档 + 对应制品」齐备的仓：文档里的 sha 就是制品的 sha
func planExecFixture(): (PackageStore, MemoryBlobStore, Int64) {
    let storm = Storm.inMemory()
    let pkgStore = PackageStore(storm)
    let blobs = MemoryBlobStore()
    let tar: Array<Byte> = [UInt8(31), UInt8(139), UInt8(8), UInt8(0), UInt8(1)]
    let sha = sha256Hex(tar)
    blobs.put(sha, tar)
    let entry = PackageIndex()
    entry.name = "demo"
    entry.version = "1.0.0"
    entry.sha256sum = sha
    let doc = PackageDoc()
    doc.name = "demo"
    doc.version = "1.0.0"
    doc.indexJson = generateNDJSON(ArrayList<PackageIndex>([entry]))
    pkgStore.save(doc)
    (pkgStore, blobs, doc.id)
}

// 注入的制品库里**有**该 sha → 执行器不能再报「制品缺失」
// （把它推给一个不存在的目标：这里的断言只关心"制品找没找到"）
@Test
func planExecutor_usesInjectedBlobStore() {
    let (pkgStore, blobs, pkgId) = planExecFixture()
    let items = ArrayList<PlanItem>()
    items.add(PlanItem(pkgId, "demo", "", "1.0.0", PlanCategory.NeedPublish, 1))
    let ex = buildPlanExecutor(pkgStore, Some(blobs))
    @Expect(ex.isSome(), true)
    let report = ex.getOrThrow().execute(items, "http://127.0.0.1:1", "")
    // 目标不存在 → 该项失败（网络），但**绝不能**是制品缺失：制品的 sha 就在注入的库里
    @Expect(items[0].error.contains("制品缺失"), false)
    @Expect(items[0].error.contains("网络"), true)
    @Expect(report.failed, 1)
}

// 没注入制品库 → 明确返回 None（调用方报「制品库未注入」），而不是拿一个错路径硬跑
@Test
func planExecutor_returnsNoneWithoutBlobStore() {
    let (pkgStore, _, _) = planExecFixture()
    @Expect(buildPlanExecutor(pkgStore, None).isNone(), true)
}

// 反向对照：注入一个**空**的制品库时才会报制品缺失 —— 证明上面那条断言不是恒真
@Test
func planExecutor_reportsMissingArtifactWhenStoreEmpty() {
    let (pkgStore, _, pkgId) = planExecFixture()
    let items = ArrayList<PlanItem>()
    items.add(PlanItem(pkgId, "demo", "", "1.0.0", PlanCategory.NeedPublish, 1))
    let empty = MemoryBlobStore()
    let ex = buildPlanExecutor(pkgStore, Some(empty))
    let report = ex.getOrThrow().execute(items, "http://127.0.0.1:1", "")
    @Expect(items[0].error.contains("制品缺失"), true)
    @Expect(report.failed, 1)
}
