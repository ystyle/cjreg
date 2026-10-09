// 发布计划 · 分析域：PublishPlanService 的 analyze（依赖展开 + graph-cj 拓扑排序 + 目标仓对照分类）
// 及其选包辅助（pickDepDoc / findDoc / localVersionsOf），末尾是同域的请求体解析
package ystyle::cjreg.server

import ystyle::cjreg.index.*
import ystyle::cjreg.store.*
import graph.*
import ystyle::cjreg.config.*
import ystyle::cjreg.semver_range.*
import stdx.encoding.json.stream.*
import std.io.*
import std.collection.*

extend PublishPlanService {
    // analyze：对给定包列表做依赖分析 + 拓扑排序 + **按目标仓索引分类**
    //
    // targetUpstream 给定时会去目标仓取索引，把每个条目分成
    //   need_publish    目标仓没有这个版本（真需要发）
    //   already_exists  目标仓已有同版本且 sha 一致（不必再发；推也只会换回 409）
    //   conflict        目标仓已有同版本但 sha 不同（要人工决策：升版 or 强制覆盖）
    //   version_optional 目标仓/本地已有更合适的版本，可不发
    // 没有这一步，界面上一切都是 need_publish —— 用户没法从计划里看出"哪些其实已经发过了"。
    public func analyze(rootPkgs: ArrayList<(String, String, String)>,
                        targetUpstream!: ?Upstream = None,
                        fetchIndex!: (Upstream, String, String) -> IndexProbe =
                            { _, _, _ => IndexProbe(0, "", detail: "未接入目标仓索引探测") }): PlanAnalysis {
        // 1. 加载所有本地包
        let allDocs = this.pkgStore.listVersions("", "")
        let all = ArrayList<PackageDoc>()
        for (d in this.pkgStore.storm.all<PackageDoc>()) {
            all.add(d)
        }
        // 2. 找根包文档
        var roots = ArrayList<PackageDoc>()
        // 每个包在一个计划里只出一个版本：org::name → 已选 docId
        var chosen = HashMap<String, Int64>()
        for (r in rootPkgs) {
            let (org, name, ver) = r
            // 按 org+name+**version** 精确匹配；version 为空时取该包**最新**版本。
            //
            // 此前写成 `let (org, name, _) = r` 再取「第一个匹配到的 doc」——doc 顺序
            // 近似按 id 升序，于是拿到的总是**最老**的版本（实测：请求 badgercj 1.6.18 /
            // snappy 1.0.1 / bstorm 1.4.8 / tsdb 0.3.2，返回的是 1.0.0 时代那批）。
            // 界面是按 doc id 选包的，plan 随后又按该 doc 的 id 取制品推送 → 用界面发版
            // 会**发出旧版本**。这里必须尊重调用方给的版本。
            var hit: ?PackageDoc = None
            var newest: ?PackageDoc = None
            for (d in all) {
                if (d.name != name || d.organization != org || d.deletedAt != 0) {
                    continue
                }
                if (ver != "" && d.version == ver) {
                    hit = Some(d)
                    break
                }
                match (newest) {
                    case Some(n) =>
                        if (compareVersions(d.version, n.version) > 0) {
                            newest = Some(d)
                        }
                    case None => newest = Some(d)
                }
            }
            match (hit) {
                case Some(d) =>
                    roots.add(d)
                    chosen[org + "::" + name] = d.id
                case None =>
                    match (newest) {
                        case Some(d) =>
                            if (ver != "") {
                                eprintln("[cjreg] 发布计划：未找到 ${org}::${name}@${ver}，回退该包最新版 ${d.version}")
                            }
                            roots.add(d)
                            chosen[org + "::" + name] = d.id
                        case None => ()
                    }
            }
        }
        if (roots.size == 0) {
            return PlanAnalysis(ArrayList<PlanItem>(), false, false, "")
        }

        // 3. 依赖图 + 拓扑排序：用 graph-cj（与 cjdep 同一个实现），不再手写 DFS。
        //
        // 手写版本踩过两次（都是只有自己实现才会有的毛病）：
        //   ① 依赖边解析按"跟随依赖方的 org"→ `ystyle::holt → badgercj` 的边消失，
        //      拓扑序把 holt 排到 badgercj 前面（先发依赖方 = 目标仓悬空依赖）；
        //   ② 显式栈是 LIFO，根包/依赖的弹出顺序与输入相反。
        // graph-cj 的 stableTopologicalSort 保证「依赖先于依赖方」，同层按传入的
        // less 比较器有序（这里用完整名字典序），环由 GraphError + SCC 统一报出。
        let byKey = HashMap<String, PackageDoc>()
        let nodeKeys = ArrayList<String>()        // 插入序（有环时兜底列出用）
        let g = Graph<String, PackageDoc>({ d: PackageDoc => dependencyNodeKey(d) }, [directed()])
        // docId → 把它拉进来的依赖方版本要求（根包没有要求）
        let requirements = HashMap<Int64, String>()
        // 依赖边先记下来，等所有节点都进图再加（addEdge 要求两端顶点已存在）
        let pendingEdges = ArrayList<(String, String)>()   // (依赖, 依赖方)

        // 从根包出发按依赖展开；pickDepDoc 内部把「本计划选中的版本」记进 chosen，
        // 保证同一个包在一个计划里只出一个版本
        let queue = ArrayList<PackageDoc>()
        for (r in roots) {
            queue.add(r)
        }
        var qi = 0
        while (qi < queue.size) {
            let doc = queue[qi]
            qi++
            let key = dependencyNodeKey(doc)
            if (byKey.contains(key)) {
                continue
            }
            byKey[key] = doc
            nodeKeys.add(key)
            g.addVertex(doc, [])
            for ((depOrg, dep, require) in parseDependencyRefs(doc.indexJson)) {
                // 依赖的**组织取自名字本身**：`org::name` 用前缀，不带前缀 = **无组织**模块
                // （与 cjpm / cjdep 的「依赖名即全名」一致）。
                //
                // 旧实现写成「没有前缀就跟随依赖方的 org」，于是 `ystyle::holt → badgercj`
                // 被拿去 `ystyle::` 里找 → 找不到 → **这条依赖边直接消失** → 拓扑序把 holt
                // 排到 badgercj 前面，计划先推依赖方（悬空依赖，publish-scope §四）。
                var picked = this.pickDepDoc(all, depOrg, dep, require, chosen)
                if (picked.isNone() && depOrg == "" && doc.organization != "") {
                    // 宽容兜底：历史声明里若把同组织依赖写成不带前缀，两个命名空间都试一次
                    picked = this.pickDepDoc(all, doc.organization, dep, require, chosen)
                }
                match (picked) {
                    case Some(dd) =>
                        // 记下是哪个版本要求把它拉进来的（分类时判断 version_optional 用）
                        if (!requirements.contains(dd.id)) {
                            requirements[dd.id] = require
                        }
                        pendingEdges.add((dependencyNodeKey(dd), key))
                        if (!byKey.contains(dependencyNodeKey(dd))) {
                            queue.add(dd)
                        }
                    case None => ()
                }
            }
        }
        for ((from, to) in pendingEdges) {
            if (from == to) {
                continue   // 自依赖：不进图，避免制造环
            }
            try {
                g.addEdge(from, to, [])
            } catch (e: Exception) {
                // 加边失败 = 依赖边丢失 → 顺序可能把被依赖包排到依赖方之后
                eprintln("[cjreg] 发布计划：加依赖边失败（${from} -> ${to}）：" + e.toString())
            }
        }

        var order = ArrayList<PackageDoc>()
        var hasCycle = false
        try {
            for (k in g.stableTopologicalSort({ a: String, b: String => a < b })) {
                match (byKey.get(k)) {
                    case Some(d) => order.add(d)
                    case None => ()
                }
            }
        } catch (e: GraphError) {
            // 有环：与 cjdep 一致 —— 标记 hasCycle（创建向导会直接拒绝建计划），
            // 节点按插入序列出（此时没有可信顺序）
            hasCycle = true
            for (k in nodeKeys) {
                match (byKey.get(k)) {
                    case Some(d) => order.add(d)
                    case None => ()
                }
            }
        }

        // 4. 目标仓索引：org::name → (version → sha)
        //    探测失败（401/403/429/5xx/网络）的包要记下来（"没问到" ≠ "目标仓没有这个包"）；
        //    404 则是**查过了、目标仓没有这个包**，按空索引处理（界面显示「无此包」而不是「未对照」）
        var targetChecked = false
        var targetError = ""
        let remote = HashMap<String, HashMap<String, String>>()
        let unreachable = ArrayList<String>()
        var failDetail = ""
        match (targetUpstream) {
            case Some(up) =>
                let fetched = HashSet<String>()
                for (d in order) {
                    let key = d.organization + "::" + d.name
                    if (fetched.contains(key)) {
                        continue
                    }
                    fetched.add(key)
                    let probe = fetchIndex(up, d.organization, d.name)
                    if (probe.ok()) {
                        let m = HashMap<String, String>()
                        for (e in parseNDJSON(probe.body)) {
                            m[e.version] = e.sha256sum
                        }
                        remote[key] = m
                    } else if (probe.status == 404) {
                        // 目标仓没有这个包：与"没查到"分开记账
                        remote[key] = HashMap<String, String>()
                    } else {
                        unreachable.add(packageLabel(d.organization, d.name, ""))
                        if (failDetail.isEmpty()) {
                            failDetail = probe.describe()
                        }
                    }
                }
                targetChecked = unreachable.size == 0
                if (unreachable.size > 0) {
                    targetError = "目标仓索引取不到：${unreachable.size} 个包（${unreachable[0]} 等，" +
                        "${failDetail}）无法判断是否已存在，这些条目只能按「待发布」列出" +
                        "——执行时若目标仓已有同版本会得到 409"
                }
            case None => ()
        }

        // 5. 生成 PlanItem（按拓扑顺序）+ 按目标仓索引分类
        let items = ArrayList<PlanItem>()
        var n: Int64 = 1
        for (d in order) {
            let it = PlanItem(d.id, d.name, d.organization, d.version, PlanCategory.NeedPublish, n)
            it.localSha256 = extractSha256(d.indexJson)
            it.localVersions = localVersionsOf(all, d.organization, d.name)
            match (requirements.get(d.id)) {
                case Some(r) => it.requirement = r
                case None => ()
            }
            // 依赖方声明的要求没被满足 → 本地还有更合适的版本可选
            if (!it.requirement.isEmpty() && !versionSatisfies(it.version, it.requirement)) {
                match (bestMatch(it.localVersions, it.requirement)) {
                    case Some(b) =>
                        if (b != it.version) {
                            it.category = PlanCategory.VersionOptional
                        }
                    case None => ()
                }
            }
            it.overwriteAllowed = targetOverwritable(targetUpstream)
            let emptyRemote = HashMap<String, String>()
            var remoteOf = emptyRemote
            let key = d.organization + "::" + d.name
            match (remote.get(key)) {
                case Some(m) =>
                    // 取到了索引 = 这个包的对照做成了（哪怕索引是空的：那表示目标仓没有这个包）
                    remoteOf = m
                    it.targetCompared = true
                    it.targetVersion = latestVersionOf(m)
                case None => ()
            }
            classifyItem(it, remoteOf)
            items.add(it)
            n++
        }
        return PlanAnalysis(items, hasCycle, targetChecked, targetError)
    }

    // 按目标仓索引给一个条目分类（对齐 cjrepo 的 Analyze）：
    //   目标仓有该版本且 sha 一致 → already_exists（默认不勾选：推上去也只会 409）
    //   目标仓有该版本但 sha 不同 → conflict（默认不勾选：要不要覆盖得人来定）
    //   目标仓没有该版本、但有更高版本 → version_optional（提示"可以不发"）
    func classifyItem(it: PlanItem, remote: HashMap<String, String>): Unit {
        match (remote.get(it.version)) {
            case Some(remoteSha) =>
                it.remoteSha256 = remoteSha
                if (!remoteSha.isEmpty() && remoteSha == it.localSha256) {
                    it.category = PlanCategory.AlreadyExists
                    it.selected = false
                } else if (!remoteSha.isEmpty() && remoteSha != it.localSha256) {
                    it.category = PlanCategory.Conflict
                    it.selected = false
                }
            case None =>
                let best = latestVersionOf(remote)
                if (!best.isEmpty() && compareVersions(it.version, best) < 0) {
                    it.category = PlanCategory.VersionOptional
                }
        }
    }

    // 本地该包（同 org 同 name）的全部版本，升序
    func localVersionsOf(all: ArrayList<PackageDoc>, org: String, name: String): ArrayList<String> {
        let vs = ArrayList<String>()
        for (d in all) {
            if (d.name == name && d.organization == org && d.deletedAt == 0) {
                insertSorted(vs, d.version)
            }
        }
        vs
    }

    // 从 indexJson 解析依赖名（保留旧签名：既有测试直接调它）
    func parseDependencyNames(indexJson: String): ArrayList<String> {
        let result = ArrayList<String>()
        for ((_, name, _) in parseDependencyRefs(indexJson)) {
            result.add(name)
        }
        return result
    }


    // 选一个依赖文档：在**满足声明版本要求**的候选里取最新；要求为空或无满足者则取最新。
    // chosen 保证同一个包在一个计划里只出一个版本（已选过就直接复用）。
    func pickDepDoc(all: ArrayList<PackageDoc>, org: String, name: String, require: String,
                    chosen: HashMap<String, Int64>): ?PackageDoc {
        let key = org + "::" + name
        match (chosen.get(key)) {
            case Some(id) => return findDoc(all, id)
            case None => ()
        }
        var newestOk: ?PackageDoc = None
        var newestAny: ?PackageDoc = None
        for (d in all) {
            if (d.name != name || d.organization != org || d.deletedAt != 0) {
                continue
            }
            match (newestAny) {
                case Some(n) =>
                    if (compareVersions(d.version, n.version) > 0) {
                        newestAny = Some(d)
                    }
                case None => newestAny = Some(d)
            }
            if (require == "" || versionSatisfies(d.version, require)) {
                match (newestOk) {
                    case Some(n) =>
                        if (compareVersions(d.version, n.version) > 0) {
                            newestOk = Some(d)
                        }
                    case None => newestOk = Some(d)
                }
            }
        }
        let picked = match (newestOk) {
            case Some(d) => Some(d)
            case None => newestAny
        }
        match (picked) {
            case Some(d) => chosen[key] = d.id
            case None => ()
        }
        picked
    }

    func findDoc(all: ArrayList<PackageDoc>, id: Int64): ?PackageDoc {
        for (d in all) {
            if (d.id == id) {
                return Some(d)
            }
        }
        return None
    }

    func findByName(all: ArrayList<PackageDoc>, org: String, name: String): ?PackageDoc {
        for (d in all) {
            if (d.name == name && d.organization == org && d.deletedAt == 0) {
                return Some(d)
            }
        }
        return None
    }
}

// 从 analyze 请求体解析 packages 列表 [{organization,name,version}]
// 从 analyze 请求体里读 target_upstream（0/缺省 = 不做目标仓对比）
public func parseTargetUpstream(body: String): Int64 {
    let bb = ByteBuffer()
    bb.write(body.toArray())
    let r = JsonReader(bb)
    var target: Int64 = 0
    try {
        while (let Some(v) <- r.peek()) {
            match (v) {
                case BeginObject =>
                    r.startObject()
                    while (r.peek() != EndObject) {
                        let n = r.readName()
                        if (n == "target_upstream") {
                            target = r.readValue<Int64>()
                        } else {
                            r.skip()
                        }
                    }
                    r.endObject()
                    return target
                case _ => r.skip()
            }
        }
    } catch (e: Exception) {
        // 解析不出来就是"没指定目标仓"（分类退回本地视角），但要留痕：
        // 静默吞掉会让人以为"对比过了、目标仓什么都没有"
        println("[cjreg] analyze 请求体解析 target_upstream 失败: " + e.toString())
    }
    target
}

public func parsePackagesBody(body: String, out: ArrayList<(String, String, String)>): Unit {
    let bb = ByteBuffer()
    bb.write(body.toArray())
    let r = JsonReader(bb)
    try {
        while (let Some(v) <- r.peek()) {
            match (v) {
                case BeginObject =>
                    r.startObject()
                    while (r.peek() != EndObject) {
                        let n = r.readName()
                        if (n == "packages") {
                            r.startArray()
                            while (r.peek() != EndArray) {
                                var org = ""
                                var name = ""
                                var version = ""
                                r.startObject()
                                while (r.peek() != EndObject) {
                                    let f = r.readName()
                                    match (f) {
                                        case "organization" => org = r.readValue<String>()
                                        case "name" => name = r.readValue<String>()
                                        case "version" => version = r.readValue<String>()
                                        case _ => r.skip()
                                    }
                                }
                                r.endObject()
                                if (!name.isEmpty()) {
                                    out.add((org, name, version))
                                }
                            }
                            r.endArray()
                        } else {
                            r.skip()
                        }
                    }
                    r.endObject()
                    return
                case _ => r.skip()
            }
        }
    } catch (e: Exception) {
        // 请求体解析中断此前完全静默：out 里只留下半截 packages 列表，调用方
        // 只在「一个都没解析出来」时才回 400，于是「body 坏了」被静默当成
        // 「用户只提交了这部分包」，发布计划按残缺列表执行。
        println("[cjreg] 发布计划请求体解析失败（已解析 " + out.size.toString() + " 个包）: " + e.toString())
    }
}
