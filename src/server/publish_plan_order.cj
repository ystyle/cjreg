// 发布计划 · 顺序域：依赖节点键与依赖边解析、现算拓扑执行顺序、排序兜底、传递依赖闭包，
// 以及「重新分析」把 analyze 结果整体写回计划的逻辑
package ystyle::cjreg.server

import ystyle::cjreg.index.*
import ystyle::cjreg.store.*
import graph.*
import ystyle::cjreg.config.*
import ystyle::cjreg.semver_range.*
import stdx.encoding.json.stream.*
import std.io.*
import std.collection.*

// 依赖图节点键 = 包的完整名（与 cjpm / cjdep 口径一致：有组织才带 `org::` 前缀）。
// 拓扑排序的同层顺序按它做字典序，保证计划顺序稳定可复现。
public func dependencyNodeKey(d: PackageDoc): String {
    if (d.organization == "") {
        return d.name
    }
    d.organization + "::" + d.name
}

// 从 indexJson 解析依赖 (org, 名字, 版本要求)。
// 依赖名可能带 `org::` 前缀（如 `ystyle::crc`）——**前缀必须保留**：跨组织依赖
// （snappy/badgercj → ystyle::crc）一旦丢掉前缀，就会去"依赖方自己的 org"里找，
// 找不到 → 这条依赖边直接消失 → 拓扑序被打乱（实测 snappy 被排到了 crc 前面，
// 等于先发依赖方）。org 为空表示"与依赖方同组织"。
//
// 自由函数（不是成员）：analyze 的拓扑排序与执行器的"依赖未就绪就别发"两处都要用。
public func parseDependencyRefs(indexJson: String): ArrayList<(String, String, String)> {
    let result = ArrayList<(String, String, String)>()
    let entries = parseNDJSON(indexJson)
    if (entries.size == 0) {
        return result
    }
    for (d in entries[0].dependencies) {
        let depName = d.name
        let idx = depName.indexOf("::")
        if (idx.isSome()) {
            let i = idx.getOrThrow()
            result.add((depName[..i], depName[i + 2..], d.require))
        } else {
            result.add(("", depName, d.require))
        }
    }
    return result
}

// 计划内的依赖关系：item.pkgId → 它（直接）依赖的、**也在本计划里**的 pkgId 列表。
//
// 用途：某个包发失败/索引一直没就绪时，**只有依赖它的项**该被卡住；
// 计划里与它无关的项（例如同一条链上的另一个根）照发不误。
// 早先是一超时就中止整个计划 —— 实测踩过：tsdb 的索引因中心仓审核没过一直不出现，
// 把根本不依赖 tsdb 的 bstorm 一起卡死了。
func planDependencyEdges(items: ArrayList<PlanItem>, pkgStore: PackageStore): HashMap<Int64, ArrayList<Int64>> {
    let key2id = HashMap<String, Int64>()
    for (it in items) {
        key2id[it.org + "::" + it.name] = it.pkgId
    }
    let edges = HashMap<Int64, ArrayList<Int64>>()
    for (it in items) {
        let deps = ArrayList<Int64>()
        match (pkgStore.getById(it.pkgId)) {
            case Some(doc) =>
                for ((depOrg, depName, _) in parseDependencyRefs(doc.indexJson)) {
                    // 依赖名即全名（与 analyze 的拓扑排序同一判据）：不带前缀 = 无组织模块；
                    // 找不到再按「同组织不写前缀」的历史写法兜底一次。
                    //
                    // 少了这一段，`ystyle::holt → badgercj` 被解析成 `ystyle::badgercj`，
                    // 计划内查不到 → 这条边不存在 → **「依赖未就绪就别发」的门对它失效**：
                    // 依赖方会在依赖尚未出现在目标仓时被推出去（悬空依赖）。
                    var hit = key2id.get(depOrg + "::" + depName)
                    if (hit.isNone() && depOrg == "" && doc.organization != "") {
                        hit = key2id.get(doc.organization + "::" + depName)
                    }
                    match (hit) {
                        case Some(id) => if (id != it.pkgId && !deps.contains(id)) {
                            deps.add(id)
                        }
                        case None => ()
                    }
                }
            case None => ()
        }
        edges[it.pkgId] = deps
    }
    edges
}

// 「重新分析」的写回结果
public struct PlanRefreshResult {
    public var updated: Int64   // 命中并刷新（顺序 + 分类）的条目
    public var added: Int64     // 依赖补齐带来的新条目
    public var skipped: Int64   // 同包已有其它版本条目 → 不重复加
    public init() {
        this.updated = 0
        this.added = 0
        this.skipped = 0
    }
}

// 把一次 analyze 的结果**整体写回**计划：顺序、分类、依赖补齐一起刷新。
//
// 为什么不能只刷分类（旧实现的毛病）：`order` 是建计划时的分析快照，冻结在条目上。
// 一旦那次分析的依赖边有缺（或依赖声明后来改了），顺序就永远错下去，而界面上的
// 「重新分析」只更新分类 —— 用户点了也修不好顺序，等于这个按钮废了。
//
// 语义：
//   - 命中的条目（org/name/version 完全一致）：刷新 order + 分类 + 目标仓对照；
//     已完成/已推送的条目不回退勾选（那是执行记录）
//   - 分析里有、计划里没有的（依赖补齐）：新增条目
//   - 同包已有其它版本条目：不重复加（一个包在一个计划里只出一条），计入 skipped
//   - 计划里有、本次分析没有的：保留（可能带执行记录），顺序排到拓扑序之后
public func applyAnalysisToPlan(adminData: AdminDataStore, planId: Int64,
                                analysis: PlanAnalysis): PlanRefreshResult {
    var res = PlanRefreshResult()   // struct 是值类型：要改字段必须用 var
    let docs = adminData.listPlanItems(planId)
    let exact = HashMap<String, Int64>()     // org::name@version → docId
    let pkgSeen = HashMap<String, Bool>()    // org::name → 已有条目
    for (d in docs) {
        exact[d.packageOrg + "::" + d.packageName + "@" + d.packageVersion] = d.id
        pkgSeen[d.packageOrg + "::" + d.packageName] = true
    }
    let matched = HashMap<Int64, Bool>()     // 本次分析覆盖到的 docId
    var maxOrder: Int64 = 0
    for (it in analysis.items) {
        if (it.order > maxOrder) {
            maxOrder = it.order
        }
        let key = it.org + "::" + it.name + "@" + it.version
        match (exact.get(key)) {
            case Some(id) =>
                matched[id] = true
                let prev = adminData.getPlanItem(id)
                let sel = match (prev) {
                    case Some(x) => if (x.status == "completed" || x.status == "waiting_index") {
                        x.selected
                    } else {
                        it.selected
                    }
                    case None => it.selected
                }
                let _ = adminData.setPlanItemOrder(id, it.order)
                let _ = adminData.setPlanItemCategory(id, planCategoryName(it.category), sel,
                    targetVersion: it.targetVersion, targetCompared: it.targetCompared)
                res.updated++
            case None =>
                let pkgKey = it.org + "::" + it.name
                if (pkgSeen.contains(pkgKey)) {
                    res.skipped++
                } else {
                    pkgSeen[pkgKey] = true
                    let _ = adminData.addPlanItem(planId, it.pkgId, it.org, it.name, it.version, it.order,
                        planCategoryName(it.category), it.selected,
                        targetVersion: it.targetVersion, targetCompared: it.targetCompared)
                    res.added++
                }
        }
    }
    // 计划里多出来的旧条目：保留执行记录，只把顺序挪到本次拓扑序之后
    var tail = maxOrder + 1
    for (d in docs) {
        if (!matched.contains(d.id)) {
            let _ = adminData.setPlanItemOrder(d.id, tail)
            tail++
        }
    }
    res
}

// 计划项的**执行顺序**：按当前依赖声明现算拓扑序（graph-cj，与 cjdep 同一实现），
// 不再信任建计划那一刻冻结的 `order`。
//
// 为什么必须现算：`order` 是建计划时的分析快照。依赖边解析错过一次（或依赖声明后来改了）
// 就会永远错下去，而界面上的「重新分析」只刷分类、改不了顺序 —— 结果是"重新分析没用"。
// 冻结顺序 + 依赖门同时失效时，计划会把依赖方先推出去（目标仓悬空依赖）。
//
// 同层先后用建计划时的 `order` 兜底（再按完整名定序），保持用户当初看到的相对顺序。
public func planExecutionOrder(items: ArrayList<PlanItem>, pkgStore: PackageStore): ArrayList<PlanItem> {
    let keyOf = { it: PlanItem => if (it.org == "") { it.name } else { it.org + "::" + it.name } }
    let byKey = HashMap<String, PlanItem>()
    let orderOf = HashMap<String, Int64>()
    for (it in items) {
        let k = keyOf(it)
        byKey[k] = it
        orderOf[k] = it.order
    }
    let edges = planDependencyEdges(items, pkgStore)   // pkgId → 依赖的 pkgId（同一条解析规则）
    let id2key = HashMap<Int64, String>()
    for (it in items) {
        id2key[it.pkgId] = keyOf(it)
    }
    let g = Graph<String, PlanItem>({ it: PlanItem => keyOf(it) }, [directed()])
    for (it in items) {
        g.addVertex(it, [])
    }
    for ((id, deps) in edges) {
        let toKey = match (id2key.get(id)) {
            case Some(k) => k
            case None => ""
        }
        if (toKey == "") {
            continue
        }
        for (d in deps) {
            match (id2key.get(d)) {
                case Some(fromKey) =>
                    if (fromKey != toKey) {
                        try {
                            g.addEdge(fromKey, toKey, [])
                        } catch (e: Exception) {
                            eprintln("[cjreg] 执行顺序：加依赖边失败（${fromKey} -> ${toKey}）：" + e.toString())
                        }
                    }
                case None => ()
            }
        }
    }
    let less = { a: String, b: String =>
        let (oa, ob) = (orderOf.get(a) ?? Int64.Max, orderOf.get(b) ?? Int64.Max)
        if (oa != ob) {
            oa < ob
        } else {
            a < b
        }
    }
    let sorted = ArrayList<PlanItem>()
    try {
        for (k in g.stableTopologicalSort(less)) {
            match (byKey.get(k)) {
                case Some(it) => sorted.add(it)
                case None => ()
            }
        }
    } catch (e: GraphError) {
        // 现算发现环（依赖声明互相指）：退回建计划时的 order，行为与旧版一致
        println("[cjreg] 执行顺序：依赖图有环，退回计划内既有顺序（" + e.message + "）")
        for (it in items) {
            sorted.add(it)
        }
        insertionSortByOrder(sorted)
    }
    if (sorted.size != items.size) {
        // 兜底：图里漏掉的项（理论上不会）追加到末尾，宁可多发也别漏项
        for (it in items) {
            var has = false
            for (s in sorted) {
                if (s.pkgId == it.pkgId) {
                    has = true
                    break
                }
            }
            if (!has) {
                sorted.add(it)
            }
        }
    }
    sorted
}

// 按 order 升序（同序按完整名）就地插入排序：不依赖 std.sort 对元素类型的约束
func planItemNameKey(it: PlanItem): String {
    if (it.org == "") {
        return it.name
    }
    it.org + "::" + it.name
}

func planItemBefore(a: PlanItem, b: PlanItem): Bool {
    if (a.order != b.order) {
        return a.order < b.order
    }
    planItemNameKey(a) < planItemNameKey(b)
}

func insertionSortByOrder(list: ArrayList<PlanItem>): Unit {
    var i: Int64 = 1
    while (i < list.size) {
        let key = list[i]
        var j = i - 1
        while (j >= 0 && planItemBefore(key, list[j])) {
            list[j + 1] = list[j]
            j--
        }
        list[j + 1] = key
        i++
    }
}

// pkgId 在本计划内直接/间接依赖的全部 pkgId
func transitivePlanDeps(id: Int64, edges: HashMap<Int64, ArrayList<Int64>>): ArrayList<Int64> {
    let out = ArrayList<Int64>()
    let seen = HashSet<Int64>()
    let stack = ArrayList<Int64>([id])
    while (stack.size > 0) {
        let cur = stack[stack.size - 1]
        stack.remove(stack.size - 1..stack.size)
        match (edges.get(cur)) {
            case Some(ds) =>
                for (d in ds) {
                    if (!seen.contains(d)) {
                        seen.add(d)
                        out.add(d)
                        stack.add(d)
                    }
                }
            case None => ()
        }
    }
    out
}

// 边表是「项 → 它的依赖」，这里把"依赖项"收集成"必须原地等索引的项"集合
func collectDeployDependents(edges: HashMap<Int64, ArrayList<Int64>>, pkgId: Int64, into: HashSet<Int64>): Unit {
    let deps = match (edges.get(pkgId)) {
        case Some(x) => x
        case None => ArrayList<Int64>()
    }
    for (d in deps) {
        into.add(d)
    }
}
