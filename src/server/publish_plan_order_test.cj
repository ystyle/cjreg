// 发布计划拓扑序回归：**无组织模块**的依赖边必须解析出来，且相互无依赖的包保持调用方顺序。
//
// 出过的故障（生产实测，2026-09-15）：`ystyle::holt@1.0.10` 依赖**无组织**的 `badgercj`。
// analyze 的依赖解析写成「不带前缀 → 跟随依赖方的 org」，于是去 `ystyle::` 里找
// `ystyle::badgercj` → 找不到 → **这条依赖边直接消失** → 拓扑序把 holt 排到 badgercj
// **前面**，计划先推 holt（一个声明了 `badgercj 1.6.20` 的版本）→ 目标仓先出现悬空依赖
// （违反 publish-scope §四「依赖只能声明目标仓已有版本」）。
//
// 判据对齐 cjpm / cjdep：**依赖名即全名**，不带前缀 = 无组织模块；带前缀才是那个组织。
// 另：显式栈是 LIFO，修复前根包正序压入 → 弹出倒序，相互无依赖的包在计划里先后与选择顺序相反。

package ystyle::cjreg.server

import ystyle::cjreg.store.*
import ystyle::cjreg.index.*
import ystyle::cjreg.config.*
import bstorm.*
import std.collection.*

// 造一个带依赖声明的包文档（依赖写成完整名，如 "badgercj" / "ystyle::crc"）
func orderDoc(org: String, name: String, version: String, deps: ArrayList<(String, String)>): PackageDoc {
    let d = PackageDoc()
    d.organization = org
    d.name = name
    d.version = version
    d.sha256 = "sha-" + org + "-" + name + "-" + version
    d.createdAt = 1000
    d.updatedAt = 1000
    let entry = PackageIndex()
    entry.organization = org
    entry.name = name
    entry.version = version
    entry.sha256sum = d.sha256
    for ((dep, require) in deps) {
        entry.dependencies.add(DependencyEntry(dep, require, "", "", ""))
    }
    d.indexJson = generateNDJSON(ArrayList<PackageIndex>([entry]))
    d
}

func orderStore(): PackageStore {
    PackageStore(Storm.inMemory())
}

// 有组织包 → 无组织依赖：依赖必须先于依赖方（修复前 holt 排在最前）
@Test
func analyzePlan_unprefixedDepOfOrgedPackageComesFirst() {
    let store = orderStore()
    store.save(orderDoc("ystyle", "holt", "1.0.10", ArrayList<(String, String)>([("badgercj", "1.6.20")])))
    store.save(orderDoc("", "badgercj", "1.6.20", ArrayList<(String, String)>([("snappy", "1.0.1")])))
    store.save(orderDoc("", "snappy", "1.0.1", ArrayList<(String, String)>()))
    let svc = PublishPlanService(store)
    let roots = ArrayList<(String, String, String)>()
    roots.add(("ystyle", "holt", "1.0.10"))
    let a = svc.analyze(roots)
    @Expect(a.hasCycle, false)
    @Expect(a.items.size, 3)
    @Expect(a.items[0].name, "snappy")     // 最底层依赖先发
    @Expect(a.items[1].name, "badgercj")
    @Expect(a.items[2].name, "holt")       // 修复前会得到 [holt, ...]
    store.storm.close()
}

// 带组织前缀的依赖（ystyle::crc）仍按前缀解析，且与无组织依赖混用时顺序正确
@Test
func analyzePlan_orgPrefixedAndPlainDepsBothResolve() {
    let store = orderStore()
    store.save(orderDoc("", "badgercj", "1.6.20",
        ArrayList<(String, String)>([("snappy", "1.0.1"), ("ystyle::crc", "1.0.0")])))
    store.save(orderDoc("ystyle", "crc", "1.0.0", ArrayList<(String, String)>()))
    store.save(orderDoc("", "snappy", "1.0.1", ArrayList<(String, String)>()))
    let svc = PublishPlanService(store)
    let roots = ArrayList<(String, String, String)>()
    roots.add(("", "badgercj", "1.6.20"))
    let a = svc.analyze(roots)
    @Expect(a.hasCycle, false)
    @Expect(a.items.size, 3)
    @Expect(a.items[2].name, "badgercj")   // 依赖（snappy / crc）都在它前面
    var snappyBefore = false
    var crcBefore = false
    for (i in 0..2) {
        if (a.items[i].name == "snappy") { snappyBefore = true }
        if (a.items[i].name == "crc") { crcBefore = true }
    }
    @Expect(snappyBefore, true)
    @Expect(crcBefore, true)
    store.storm.close()
}

// 执行器侧的「依赖未就绪就别发」也必须看到无组织依赖边：
// 边缺失 = 依赖方不会被拦（holt 会在 badgercj 尚未就绪时被推出去 → 悬空依赖）。
@Test
func planDependencyEdges_resolvesUnprefixedDepOfOrgedPackage() {
    let store = orderStore()
    let badger = orderDoc("", "badgercj", "1.6.20", ArrayList<(String, String)>())
    let holt = orderDoc("ystyle", "holt", "1.0.10",
        ArrayList<(String, String)>([("badgercj", "1.6.20")]))
    store.save(badger)
    store.save(holt)
    let items = ArrayList<PlanItem>()
    items.add(PlanItem(badger.id, "badgercj", "", "1.6.20", PlanCategory.NeedPublish, 1))
    items.add(PlanItem(holt.id, "holt", "ystyle", "1.0.10", PlanCategory.NeedPublish, 2))
    let edges = planDependencyEdges(items, store)
    let holtDeps = edges.get(holt.id).getOrThrow()
    @Expect(holtDeps.contains(badger.id), true)   // 修复前为空 → 依赖门失效
    store.storm.close()
}

// 相互无依赖的根包：顺序必须**确定可复现**（graph-cj 的同层兜底是完整名字典序，
// 与 cjdep 口径一致）。修复前的显式栈是 LIFO，根包会被倒序处理。
@Test
func analyzePlan_independentRootsUseDeterministicOrder() {
    let store = orderStore()
    store.save(orderDoc("", "alpha", "1.0.0", ArrayList<(String, String)>()))
    store.save(orderDoc("", "beta", "1.0.0", ArrayList<(String, String)>()))
    store.save(orderDoc("", "gamma", "1.0.0", ArrayList<(String, String)>()))
    let svc = PublishPlanService(store)
    let roots = ArrayList<(String, String, String)>()
    roots.add(("", "alpha", "1.0.0"))
    roots.add(("", "beta", "1.0.0"))
    roots.add(("", "gamma", "1.0.0"))
    let a = svc.analyze(roots)
    @Expect(a.items.size, 3)
    @Expect(a.items[0].name, "alpha")
    @Expect(a.items[1].name, "beta")
    @Expect(a.items[2].name, "gamma")
    store.storm.close()
}

// 执行顺序必须**现算**：计划条目里冻结的 order 不可信。
// 这里故意把依赖方（holt）的 order 排在最前（模拟旧版本建的计划），执行顺序仍须
// 把 badgercj 排在 holt 之前 —— 否则目标仓会先出现声明了不存在依赖的版本。
@Test
func planExecutionOrder_recomputesInsteadOfTrustingStoredOrder() {
    let store = orderStore()
    let badger = orderDoc("", "badgercj", "1.6.20", ArrayList<(String, String)>([("snappy", "1.0.1")]))
    let snappy = orderDoc("", "snappy", "1.0.1", ArrayList<(String, String)>())
    let holt = orderDoc("ystyle", "holt", "1.0.10",
        ArrayList<(String, String)>([("badgercj", "1.6.20")]))
    store.save(badger)
    store.save(snappy)
    store.save(holt)
    let items = ArrayList<PlanItem>()
    // 冻结的 order：holt 1、badgercj 2、snappy 3（错误顺序）
    items.add(PlanItem(holt.id, "holt", "ystyle", "1.0.10", PlanCategory.NeedPublish, 1))
    items.add(PlanItem(badger.id, "badgercj", "", "1.6.20", PlanCategory.NeedPublish, 2))
    items.add(PlanItem(snappy.id, "snappy", "", "1.0.1", PlanCategory.NeedPublish, 3))
    let ordered = planExecutionOrder(items, store)
    @Expect(ordered[0].name, "snappy")
    @Expect(ordered[1].name, "badgercj")
    @Expect(ordered[2].name, "holt")
    store.storm.close()
}

// 「重新分析」必须整体写回：顺序刷新 + 依赖补齐（否则顺序永远停在建计划那一刻，
// 按钮等于废的）。这里计划里只有 holt（缺 badgercj/snappy），分析结果补进两条。
@Test
func applyAnalysisToPlan_refreshesOrderAndAddsMissingDeps() {
    let store = orderStore()
    store.save(orderDoc("ystyle", "holt", "1.0.10",
        ArrayList<(String, String)>([("badgercj", "1.6.20")])))
    store.save(orderDoc("", "badgercj", "1.6.20", ArrayList<(String, String)>()))
    let admin = AdminDataStore(Storm.inMemory())
    let planId = admin.createPlan("t", 1, 60, 0, 1000)
    // 建计划时只落了 holt（order 1）——模拟"当时依赖边丢了"的旧计划
    admin.addPlanItem(planId, 900, "ystyle", "holt", "1.0.10", 1, "need_publish", true)
    @Expect(admin.listPlanItems(planId).size, 1)

    let svc = PublishPlanService(store)
    let roots = ArrayList<(String, String, String)>()
    roots.add(("ystyle", "holt", "1.0.10"))
    let analysis = svc.analyze(roots)
    let refreshed = applyAnalysisToPlan(admin, planId, analysis)
    @Expect(refreshed.added, 1)          // badgercj 被补进来
    let docs = admin.listPlanItems(planId)
    @Expect(docs.size, 2)
    // 顺序：badgercj 先于 holt
    var badgerOrder: Int64 = -1
    var holtOrder: Int64 = -1
    for (d in docs) {
        if (d.packageName == "badgercj") { badgerOrder = d.order }
        if (d.packageName == "holt") { holtOrder = d.order }
    }
    @Expect(badgerOrder > 0, true)
    @Expect(badgerOrder < holtOrder, true)
    admin.storm.close()
    store.storm.close()
}
