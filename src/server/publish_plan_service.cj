// 发布计划：模型 + analyze（拓扑排序）+ 执行引擎
// analyze 复用 cjdep 语义：依赖解析 + 分类 + 拓扑发布顺序
package ystyle::cjreg.server

import ystyle::cjreg.index.*
import ystyle::cjreg.store.*
import graph.*
import ystyle::cjreg.config.*
import ystyle::cjreg.semver_range.*
import stdx.encoding.json.stream.*
import std.io.*
import std.collection.*

// 索引等待结果（waitIndexReady 的返回码）
let WAIT_READY: Int64 = 1
let WAIT_TIMEOUT: Int64 = 0
let WAIT_CANCELLED: Int64 = -1
// 探测本身失败（401/403/429/5xx/网络）：内容已推上去，但"索引里有"这件事问不出来
let WAIT_FATAL: Int64 = -2

// 等待目标仓索引的节奏（秒）：先短探一次（同进程的私有仓索引是即时生效的，不必先等一分钟），
// 然后 1 分钟、3 分钟、5 分钟，之后每 5 分钟一轮 —— 与 `cangjie-publish` 技能里的
// 「发布后 1、3、5 分钟各查一次」一致，只是**不设次数上限**（中心仓同步几十分钟到几天都正常）。
let IndexWaitLadder: Array<Int64> = [5, 60, 180, 300]
let IndexWaitSteadySec: Int64 = 300

// 索引等待上限的**出厂默认值**（旧语义：轮询间隔 60s / 总超时 600s）。
// 老计划里出现这一对就是"没配过"，按新语义迁移成 0（一直等）；
// 用户自己填过别的值（哪怕只是改了其中一个）则原样保留。
public func legacyPollDefaults(pollInterval: Int64, pollTimeout: Int64): Bool {
    pollInterval == 60 && pollTimeout == 600
}

// 目标仓索引探测结果：把 HTTP 状态码和正文一起带出来。
//
// 只返回 `?String` 会把两类完全不同的事抹平成同一个 None：
//   404 → 索引里还没有该版本（同步没到，继续等；也可能是目标仓确实没有这个包）
//   401/403/429/5xx/传输失败 → 没问到，再等也不会变好
// 判据对齐官方返回码表：200 成功 / 400 参数 / 401 认证 / 403 权限 / 404 不存在 /
// 409 冲突 / 429 频率 / >=500 服务器故障。
public class IndexProbe {
    public var status: Int64      // 0 = 传输层失败（DNS/TLS/超时/连接被拒）
    public var body: String
    public var detail: String     // 传输层失败原因（进文案）

    public init(status: Int64, body: String, detail!: String = "") {
        this.status = status
        this.body = body
        this.detail = detail
    }

    // 2xx：正文可用
    public func ok(): Bool {
        this.status >= 200 && this.status < 300
    }

    // 探测本身失败（不是"目标仓没有"，而是"没问到"）：继续等不会变好
    public func fatal(): Bool {
        this.status == 0 || this.status == 400 || this.status == 401 ||
            this.status == 403 || this.status == 429 || this.status >= 500
    }

    // 认证/权限/频率超限：与推送阶段同一判据 —— 继续跑整个计划也是白费
    public func planFatal(): Bool {
        this.status == 401 || this.status == 403 || this.status == 429
    }

    public func describe(): String {
        if (this.status == 0) {
            if (this.detail.isEmpty()) {
                return "网络不可达"
            }
            return "网络不可达：${this.detail}"
        }
        "HTTP ${this.status}"
    }
}

// 发布计划项状态
public enum PlanItemStatus {
    | Pending
    | Publishing
    | WaitingIndex
    | Completed
    | Failed
    | Skipped

    public operator func ==(other: PlanItemStatus): Bool {
        match (this) {
            case PlanItemStatus.Pending => match (other) {
                case PlanItemStatus.Pending => true
                case _ => false
            }
            case PlanItemStatus.Publishing => match (other) {
                case PlanItemStatus.Publishing => true
                case _ => false
            }
            case PlanItemStatus.WaitingIndex => match (other) {
                case PlanItemStatus.WaitingIndex => true
                case _ => false
            }
            case PlanItemStatus.Completed => match (other) {
                case PlanItemStatus.Completed => true
                case _ => false
            }
            case PlanItemStatus.Failed => match (other) {
                case PlanItemStatus.Failed => true
                case _ => false
            }
            case PlanItemStatus.Skipped => match (other) {
                case PlanItemStatus.Skipped => true
                case _ => false
            }
        }
    }
}

// 分类（对齐 cjrepo/cjdep）
public enum PlanCategory {
    | NeedPublish
    | VersionOptional
    | AlreadyExists
    | Conflict

    public operator func ==(other: PlanCategory): Bool {
        match (this) {
            case PlanCategory.NeedPublish => match (other) {
                case PlanCategory.NeedPublish => true
                case _ => false
            }
            case PlanCategory.VersionOptional => match (other) {
                case PlanCategory.VersionOptional => true
                case _ => false
            }
            case PlanCategory.AlreadyExists => match (other) {
                case PlanCategory.AlreadyExists => true
                case _ => false
            }
            case PlanCategory.Conflict => match (other) {
                case PlanCategory.Conflict => true
                case _ => false
            }
        }
    }
}

// 发布计划项
public class PlanItem {
    public var pkgId: Int64
    public var name: String
    public var org: String
    public var version: String
    public var category: PlanCategory
    public var status: PlanItemStatus
    public var order: Int64
    public var selected: Bool
    public var error: String
    // 目标仓对比所需的证据（都来自索引，供界面展示与人工判断）
    public var localSha256: String       // 本地制品 sha
    public var remoteSha256: String      // 目标仓同版本 sha（空 = 目标仓没有该版本）
    public var requirement: String       // 作为依赖被纳入时，依赖方声明的版本要求
    public var localVersions: ArrayList<String>  // 本地该包的全部版本（升序）
    // 目标仓对照的「另一边」：目标仓该包最新版本。只报一个版本号，人就够用了
    // （`bstorm@1.4.9` 对 `bstorm@1.4.8`）——同版本/更高/没有这三种情况由分类列区分。
    public var targetVersion: String     // 目标仓该包最新版本（空 = 目标仓没有这个包）
    public var targetCompared: Bool      // 本次分析是否真拿到了该包的对照（false = 索引取不到/没选目标上游）
    // 目标仓能不能覆盖「已有同版本」：
    //   官方中心仓 → **不能**（同版本一律 409，发布不可逆）→ 冲突只剩"升版重发"一条路
    //   自建仓（cjreg/cjrepo）→ 看它的 permission_mode，team 模式允许覆盖 → 可手工勾选强制重传
    // 没有这个判断时，「冲突由人来定」其实是个假选择：中心仓上勾了也只会换回 409。
    public var overwriteAllowed: Bool

    public init(pkgId: Int64, name: String, org: String, version: String,
                category: PlanCategory, order: Int64) {
        this.pkgId = pkgId
        this.name = name
        this.org = org
        this.version = version
        this.category = category
        this.status = PlanItemStatus.Pending
        this.order = order
        this.selected = true
        this.error = ""
        this.localSha256 = ""
        this.remoteSha256 = ""
        this.requirement = ""
        this.localVersions = ArrayList<String>()
        this.targetVersion = ""
        this.targetCompared = false
        this.overwriteAllowed = false
    }
}

// 目标仓索引里该包的最新版本（空 map → 空串 = 目标仓没有这个包）
public func latestVersionOf(remote: HashMap<String, String>): String {
    var best = ""
    for ((v, _) in remote) {
        if (best.isEmpty() || compareVersions(v, best) > 0) {
            best = v
        }
    }
    best
}

// 目标仓对照文案（计划详情列与创建向导共用，取值口径只有这一处）：
//   有对照且有版本   → `bstorm@1.4.8`
//   有对照但目标仓没有该包 → `无此包`
//   没做成对照（索引取不到 / 没选目标上游）→ `未对照`
// 「未对照」必须与「目标仓没有这个包」分开：前者是不知道，后者是查过了确实没有，
// 混成一种说法会让人把"没查到"当成"可以放心发"。
public func targetCompareText(name: String, targetVersion: String, targetCompared: Bool): String {
    if (!targetCompared) {
        return "未对照"
    }
    if (targetVersion.isEmpty()) {
        return "无此包"
    }
    packageLabel("", name, targetVersion)
}

// 目标仓是否允许覆盖已有同版本（官方仓明确不允许；自建仓由自身权限模式决定）
public func targetOverwritable(up: ?Upstream): Bool {
    match (up) {
        case Some(u) => !u.isOfficial
        case None => false
    }
}

// 计划进度里"需要发布"的项数：**不含 already_exists**。
// 目标仓已有同版本的项不用发（默认也没勾选），把它算进分母会让「0/6」看着像 6 个都要发；
// 反过来又不能在界面上消失——它们会在计划明细里以「目标仓已有 N」单独列出来。
public func countRequired(items: ArrayList<PlanItem>): Int64 {
    var n: Int64 = 0
    for (it in items) {
        if (it.category == PlanCategory.AlreadyExists) {
            continue
        }
        n++
    }
    n
}

// 进度文案（详情页与列表页共用）：全都不需要发时直说，别显示 0/0
public func progressTextOf(done: Int64, total: Int64): String {
    if (total <= 0) {
        return "无需发布"
    }
    "${done}/${total}"
}

// 分类 → 字符串（存储与接口取值，与 cjrepo 的 category 一致）
public func planCategoryName(c: PlanCategory): String {
    match (c) {
        case PlanCategory.NeedPublish => "need_publish"
        case PlanCategory.VersionOptional => "version_optional"
        case PlanCategory.AlreadyExists => "already_exists"
        case PlanCategory.Conflict => "conflict"
    }
}

// 包的全名：`org::name@version`（无组织时省略前缀）。
// 早先按 `org/name` 显示，界面上和"路径"混在一起，也看不出 org 与 name 的分界。
public func packageLabel(org: String, name: String, version: String): String {
    let n = if (org.isEmpty()) { name } else { org + "::" + name }
    if (version.isEmpty()) {
        n
    } else {
        n + "@" + version
    }
}

// analyze 结果：条目 + 环检测 + **目标仓对比是否真的做成了**
//
// targetChecked 必须显式带出来：索引取不到时所有条目都会退回 need_publish，
// 若不说，用户看到的就是一句「全部待发布」的假象（可能重复推已存在的版本）。
public class PlanAnalysis {
    public var items: ArrayList<PlanItem>
    public var hasCycle: Bool
    public var targetChecked: Bool
    public var targetError: String

    public init(items: ArrayList<PlanItem>, hasCycle: Bool, targetChecked: Bool, targetError: String) {
        this.items = items
        this.hasCycle = hasCycle
        this.targetChecked = targetChecked
        this.targetError = targetError
    }
}

// 发布计划
public class PublishPlan {
    public var id: Int64
    public var name: String
    public var items: ArrayList<PlanItem>
    public var status: String   // pending/running/paused/completed/failed
    public var totalCount: Int64
    public var completedCount: Int64

    public init(id: Int64, name: String) {
        this.id = id
        this.name = name
        this.items = ArrayList<PlanItem>()
        this.status = "pending"
        this.totalCount = 0
        this.completedCount = 0
    }
}

// 依赖解析（简化拓扑）：从本地 pkg 集合找包的依赖名集合
public class PublishPlanService {
    public var pkgStore: PackageStore

    public init(pkgStore: PackageStore) {
        this.pkgStore = pkgStore
    }

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

// 构造官方发布二进制段 [version(1B)][size(4B LE)][data]
func makePublishSection(version: UInt8, data: Array<Byte>): Array<Byte> {
    let buf = ArrayList<Byte>()
    buf.add(version)
    let size = data.size
    buf.add(UInt8(size & 0xFF))
    buf.add(UInt8((size >> 8) & 0xFF))
    buf.add(UInt8((size >> 16) & 0xFF))
    buf.add(UInt8((size >> 24) & 0xFF))
    for (b in data) {
        buf.add(b)
    }
    return buf.toArray()
}

// 执行报告（取代原来的三元组：既要分类计数，也要能表达「整个计划被中止」）
public class ExecuteReport {
    public var success: Int64 = 0
    public var total: Int64 = 0
    public var skipped: Int64 = 0
    public var failed: Int64 = 0
    // 推成功了但目标仓索引还没出现该版本（内容在、依赖它的项还不能发）。
    // 这类项**不是失败**：目标仓同步慢或审核没过，稍后续跑继续等。
    public var waitingIndex: Int64 = 0
    // 中止：认证/权限/配额这类「后续必然同样失败」的情况，立刻停手
    public var aborted: Bool = false
    public var abortReason: String = ""
    public var errors: ArrayList<String> = ArrayList<String>()
}

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

// 「检查索引」的结果
public class IndexCheckResult {
    public var checked: Int64 = 0          // 探测到了几个（含"目标仓确实没有"的 404）
    public var unreachable: Int64 = 0      // 探测本身失败的个数（401/403/429/5xx/网络）
    public var ready: ArrayList<Int64> = ArrayList<Int64>()   // 已在目标仓索引里的输入下标
    public var detail: String = ""         // 探测失败的最近一次原因（进文案）

    public init() {}
}

// 一次性检查若干 (org, name, version) 是否已出现在目标仓索引里。
//
// 用途：计划里那些「已推送成功、在等索引」的项，不该逼用户再点一次「继续执行」干等
// 一个轮询周期。这里只探一次：命中的就可以直接标成发布完成。
// 「目标仓到底有没有」永远是**现查**的（不在包记录上打标记），所以这个动作随时可重放。
//
// 探测失败与"目标仓没有这个版本"必须分开计数：404 是"确实没有"（继续等/等审核），
// 401/429/5xx 是"没问到"（得先解决认证/频率/服务问题），混在一起会让人以为在等一件不会发生的事。
public func checkVersionsInIndex(targets: ArrayList<(String, String, String)>,
                                 probe: (String, String) -> IndexProbe): IndexCheckResult {
    let r = IndexCheckResult()
    for (i in 0..targets.size) {
        let (org, name, version) = targets[i]
        let res = probe(org, name)
        if (res.ok()) {
            r.checked++
            if (indexHasVersion(res.body, name, version)) {
                r.ready.add(i)
            }
        } else if (res.status == 404) {
            r.checked++
        } else {
            r.unreachable++
            if (r.detail.isEmpty()) {
                r.detail = res.describe()
            }
        }
    }
    r
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

// 发布计划执行引擎：按拓扑顺序把本地包推送到目标上游
public class PublishExecutor {
    public var pkgStore: PackageStore
    public var blobStore: BlobStore

    public init(pkgStore: PackageStore, blobStore: BlobStore) {
        this.pkgStore = pkgStore
        this.blobStore = blobStore
    }

    // 执行：对 items（拓扑序）逐个推送。
    //
    // 状态码语义（对齐官方仓返回码规格）：
    //   200        成功
    //   400 / 404  该项失败（元数据/制品/路径问题，重试无用）→ 继续下一项
    //   401 / 403  认证 / 权限 → **中止整个计划**（后面每一项都会同样失败）
    //   409        目标仓已有同版本不同制品 → 该项**跳过**（需升版或先处理目标仓）→ 继续
    //   429        每日请求频率超限 → **中止整个计划**（保存进度，明日再执行）
    //   >=500 / 网络异常  服务器/连接故障 → 退避重试至多 MaxRetries 次，仍失败判该项失败
    //
    // poster：出网 POST 的注入点（单测用桩，默认走真实 HTTP）。
    public func execute(items: ArrayList<PlanItem>, targetUrl: String, token: String,
                        onItem!: (PlanItem, Bool, String) -> Unit = { _, _, _ => () },
                        poster!: (String, Array<Byte>, String) -> (Bool, Int64, String) = { u, b, t =>
                            httpPostBinary(u, b, t)
                        },
                        indexProbe!: ?(String, String) -> IndexProbe = None,
                        pollTimeoutSec!: Int64 = 0,
                        // 等待节奏可注入：单测用秒级阶梯，生产用 IndexWaitLadder
                        indexWaitLadder!: Array<Int64> = IndexWaitLadder,
                        indexWaitSteadySec!: Int64 = IndexWaitSteadySec,
                        shouldCancel!: () -> Bool = { => false }): ExecuteReport {
        let report = ExecuteReport()
        report.total = items.size
        let MaxRetries: Int64 = 3

        // 执行顺序**现算**：按 items 当前的依赖声明做拓扑排序（graph-cj），
        // 计划里的 `order` 只当同层先后的兜底 —— 建计划那一刻的快照会过期
        // （依赖边解析错过一次、或依赖后来改了，冻结的顺序就会一直错下去）。
        let sorted = planExecutionOrder(items, this.pkgStore)

        // 计划内依赖关系 + "目标仓里还没就绪"的项集合。
        // 只有（直接/间接）依赖这些项的项才该被卡住，与它们无关的项照发。
        let edges = planDependencyEdges(sorted, this.pkgStore)
        let unavailable = HashSet<Int64>()
        let labelOf = HashMap<Int64, String>()
        for (it in sorted) {
            labelOf[it.pkgId] = packageLabel(it.org, it.name, it.version)
        }

        var idx: Int64 = 0
        while (idx < sorted.size) {
            let it = sorted[idx]
            // 用户点了「停止执行」→ 收口成"中止"：剩下的项走已有的 aborted 分支统一记「未推送」
            if (!report.aborted && shouldCancel()) {
                report.aborted = true
                report.abortReason = "用户已停止执行"
            }
            // 依赖里有"发失败"或"索引一直没出现"的项 → 这项现在发上去也是缺依赖，直接说明原因
            var blockedBy: Int64 = 0
            for (d in transitivePlanDeps(it.pkgId, edges)) {
                if (unavailable.contains(d)) {
                    blockedBy = d
                    break
                }
            }
            if (blockedBy != 0) {
                it.status = PlanItemStatus.Skipped
                let bad = match (labelOf.get(blockedBy)) {
                    case Some(s) => s
                    case None => "#${blockedBy}"
                }
                it.error = "依赖 ${bad} 未在目标仓就绪，本次不推送（它发成功后重新执行本计划即可）"
                report.skipped++
                onItem(it, true, it.error)
                idx++
                continue
            }
            if (report.aborted) {
                // 中止后剩余项统一记成「未推送（计划已中止）」，避免看起来像各自失败了
                it.status = PlanItemStatus.Skipped
                it.error = "计划已中止：${report.abortReason}"
                report.skipped++
                onItem(it, true, it.error)
                idx++
                continue
            }
            if (!it.selected) {
                it.status = PlanItemStatus.Skipped
                it.error = unselectedReason(it)
                report.skipped++
                onItem(it, true, it.error)
                idx++
                continue
            }
            if (it.status == PlanItemStatus.Completed) {
                // 续跑（计划被中止后再次执行）时跳掉已成功的项：重复推同一版本只会换回 409
                it.error = "已完成：跳过"
                report.skipped++
                onItem(it, true, it.error)
                idx++
                continue
            }
            // 取本地包文档（含 meta + sha）
            let doc = match (this.pkgStore.getById(it.pkgId)) {
                case Some(d) => d
                case None =>
                    it.status = PlanItemStatus.Failed
                    it.error = "包文档不存在"
                    report.failed++
                    report.errors.add("pkg#${it.pkgId} 不存在")
                    onItem(it, false, it.error)
                    idx++
                    continue
            }
            let sha = extractSha256(doc.indexJson)
            if (sha.isEmpty()) {
                it.status = PlanItemStatus.Failed
                it.error = "无 sha256sum"
                report.failed++
                report.errors.add("${doc.name}@${doc.version}: 无 sha256sum")
                onItem(it, false, it.error)
                idx++
                continue
            }
            let tar = match (this.blobStore.get(sha)) {
                case Some(b) => b
                case None =>
                    it.status = PlanItemStatus.Failed
                    it.error = "制品缺失（sha=${sha}）"
                    report.failed++
                    report.errors.add("${doc.name}@${doc.version}: 制品缺失（sha=${sha}）")
                    onItem(it, false, it.error)
                    idx++
                    continue
            }
            // 组装官方发布二进制 [meta][tar]
            let metaBytes = doc.indexJson.toArray()
            let body = ArrayList<Byte>()
            for (b in makePublishSection(UInt8(1), metaBytes)) {
                body.add(b)
            }
            for (b in makePublishSection(UInt8(1), tar)) {
                body.add(b)
            }
            let url = buildPackagePublishURL(targetUrl, doc.name, doc.organization)
            // 续跑语义：状态是「等待索引」的项上一次**已经推成功了**，只是索引还没同步。
            // 这种项不能重推——同版本重推只会换回 409，还会被误判成「目标仓已有同版本不同制品」，
            // 于是直接进入等待分支，继续等依赖就绪。
            let alreadyPushed = (it.status == PlanItemStatus.WaitingIndex)
            var ok = alreadyPushed
            var code: Int64 = 0
            var text = ""
            if (alreadyPushed) {
                it.status = PlanItemStatus.WaitingIndex
                onItem(it, true, "已推送过，继续等目标仓索引就绪")
            } else {
                it.status = PlanItemStatus.Publishing
                onItem(it, true, "推送中")
                var attempt: Int64 = 0
                while (attempt < MaxRetries) {
                    attempt++
                    let (o, c, t) = poster(url, body.toArray(), token)
                    ok = o
                    code = c
                    text = t
                    if (ok || !isRetryable(code)) {
                        break
                    }
                    if (attempt < MaxRetries) {
                        // 退避：500ms / 1s（服务器故障多为瞬时）
                        sleep(Duration.millisecond * 500 * attempt)
                    }
                }
            }
            if (ok) {
                // 推送成功后还要**等目标仓索引就绪**才算完成：
                // 拓扑序里下一条依赖这一条，而中心仓的索引/缓存同步可能很慢
                // （几十分钟到几天，审核还可能更久）。不等就推下一条，会出现「依赖还没出现在
                // 索引里」的假失败，或者推到一半自己把自己卡住。
                //
                // 默认**不设总超时**（pollTimeoutSec <= 0）：没出现就是还没同步到，继续等；
                // 只有探测本身失败（401/403/429/5xx/网络）或用户点停止才收工。
                let lastProbe = Box<IndexProbe>(IndexProbe(404, ""))
                var waitCode = WAIT_READY
                match (indexProbe) {
                    case Some(probe) =>
                        it.status = PlanItemStatus.WaitingIndex
                        onItem(it, true, "等待目标仓索引就绪")
                        waitCode = waitIndexReady(probe, doc.organization, doc.name, doc.version,
                            pollTimeoutSec, shouldCancel: shouldCancel,
                            ladder: indexWaitLadder, steadySec: indexWaitSteadySec,
                            onWaiting: { waited, step, res =>
                                lastProbe.value = res
                                // 每轮把「已等多久 / 下一轮什么时候再探」写进条目说明：
                                // 否则界面只有一句「等待索引」，看不出是在正常等还是卡住了
                                let mins = waited / 60
                                onItem(it, true,
                                    "等待目标仓索引就绪（已等 ${mins} 分钟，${step} 秒后再探；最近一次：${res.describe()}）")
                            })
                    case None => ()
                }
                if (waitCode == WAIT_CANCELLED) {
                    // 用户在等索引期间点了停止：内容已经推上去了，记「等索引」并中止，
                    // 续跑时也是从这里接着等（不会重推）
                    it.status = PlanItemStatus.WaitingIndex
                    it.error = "等待索引期间用户停止执行：已推送成功，续跑会继续等"
                    report.waitingIndex++
                    unavailable.add(it.pkgId)
                    report.aborted = true
                    // 计划级原因只写「用户停止」：这句会被盖到**所有未处理项**的说明上，
                    // 而"谁在等索引"是该条目自己的事（it.error 已写清 1327 行）。
                    // 曾经把「holt@1.0.8 已推送成功，正在等目标仓索引」拼进计划级原因，
                    // 结果与 holt 毫无依赖关系的 bstorm/sunku/tsdb 也显示这句，
                    // 看起来像被 holt 的索引卡住了。
                    report.abortReason = "用户已停止执行"
                    onItem(it, false, it.error)
                } else if (waitCode == WAIT_READY) {
                    report.success++
                    it.status = PlanItemStatus.Completed
                    it.error = ""
                    onItem(it, true, "")
                } else if (waitCode == WAIT_FATAL) {
                    // 索引探测本身失败（401/403/429/5xx/网络）：内容已经推上去了，只是"索引里有"
                    // 这件事问不出来 → 记「等索引」而不是失败（重推只会换回 409）。
                    let res = lastProbe.value
                    it.status = PlanItemStatus.WaitingIndex
                    it.error = "索引确认失败（${res.describe()}）：已推送成功，稍后点「检查索引」再确认"
                    report.waitingIndex++
                    unavailable.add(it.pkgId)
                    report.errors.add("${doc.name}@${doc.version}: ${it.error}")
                    if (res.planFatal()) {
                        // 认证/权限/频率超限：与推送阶段同一判据 —— 继续跑整个计划也是白费。
                        // 已推送成功的项不受影响，暂停后可以「检查索引」或次日「继续执行」。
                        report.aborted = true
                        report.abortReason = "目标仓 ${res.describe()}：计划已暂停（已推送的项不受影响）"
                        onItem(it, false, it.error)
                    } else {
                        onItem(it, true, it.error)
                    }
                } else {
                    // 走到这里只有一种情况：配置了「索引等待上限」且等满了（可选保险丝）。
                    // 记「等索引」不是失败：内容其实已经推上去了，只是还没同步（中心仓同步慢、
                    // 或审核没过）。续跑时据此**不再重推**，只继续等。
                    //
                    // **不中止整个计划**：只有依赖它的项会被卡住（下面的 blockedBy 逻辑），
                    // 与它无关的项该发还是要发。以前这里 `aborted = true`，实测把不依赖
                    // 出问题那一项的包（bstorm 之于 tsdb）一起卡死了。
                    it.status = PlanItemStatus.WaitingIndex
                    it.error = "已等满索引等待上限（${pollTimeoutSec}s）：${doc.name}@${doc.version} 还没出现在目标仓索引里（已推送成功，续跑会继续等；可把上限设为 0 表示一直等）"
                    report.waitingIndex++
                    unavailable.add(it.pkgId)
                    report.errors.add("${doc.name}@${doc.version}: ${it.error}")
                    onItem(it, false, it.error)
                }
            } else {
                match (code) {
                    case 409 =>
                        // 目标仓已有同版本不同制品：不是「失败」，而是「这次发不上去」
                        it.status = PlanItemStatus.Skipped
                        it.error = "409 目标仓已有同版本不同制品（需升版后重发）${bodyTail(text)}"
                        report.skipped++
                        onItem(it, true, it.error)
                    case 401 | 403 =>
                        it.status = PlanItemStatus.Skipped
                        it.error = "${code} 目标仓认证/权限失败，计划已中止${bodyTail(text)}"
                        report.skipped++
                        report.aborted = true
                        report.abortReason = "${code} 认证/权限失败：请检查发布 Token 与组织权限"
                        report.errors.add("${doc.name}@${doc.version}: ${it.error}")
                        onItem(it, false, it.error)
                    case 429 =>
                        it.status = PlanItemStatus.Skipped
                        it.error = "429 每日请求频率超限，计划已中止${bodyTail(text)}"
                        report.skipped++
                        report.aborted = true
                        report.abortReason = "429 每日请求频率超限：进度已保存，请次日再执行剩余项"
                        report.errors.add("${doc.name}@${doc.version}: ${it.error}")
                        onItem(it, false, it.error)
                    case _ =>
                        it.status = PlanItemStatus.Failed
                        it.error = "HTTP ${code}${bodyTail(text)}"
                        if (code == 0) {
                            it.error = "推送失败（网络/连接）：${text}"
                        }
                        report.failed++
                        // 它没进目标仓：依赖它的项这次也不该发（发了就是缺依赖的包）
                        unavailable.add(it.pkgId)
                        report.errors.add("${doc.name}@${doc.version}: ${it.error}")
                        onItem(it, false, it.error)
                }
            }
            idx++
        }
        return report
    }
}

// 条目的「为什么这样分类 / 该怎么办」——界面「说明」列与跳过原因共用一份文案，
// 免得界面说"可勾选覆盖"、执行器又说别的。
public func categoryHint(c: PlanCategory, overwriteAllowed: Bool): String {
    match (c) {
        case PlanCategory.NeedPublish => "目标仓没有该版本，需要发布"
        case PlanCategory.AlreadyExists =>
            if (overwriteAllowed) {
                "目标仓已有同版本同制品，无需发布（要重传就勾选强制覆盖）"
            } else {
                "目标仓已有同版本同制品，无需发布"
            }
        case PlanCategory.Conflict =>
            if (overwriteAllowed) {
                "目标仓已有同版本但制品不同：勾选可强制覆盖（该仓允许覆盖），或升版重发"
            } else {
                "目标仓已有同版本但制品不同，且该仓不允许覆盖 —— 只能升版后重发"
            }
        case PlanCategory.VersionOptional => "目标仓已有更高版本，可不发"
    }
}

// 未勾选条目的跳过原因：按分类说清「为什么默认不发」，别让"未勾选"看起来像用户漏点了
func unselectedReason(it: PlanItem): String {
    match (it.category) {
        case PlanCategory.AlreadyExists =>
            if (it.overwriteAllowed) {
                "目标仓已有同版本同制品，默认不发（勾选可强制重传）"
            } else {
                "目标仓已有同版本同制品，无需发布，本次未推送"
            }
        case PlanCategory.Conflict =>
            if (it.overwriteAllowed) {
                "目标仓已有同版本但制品不同，默认不发（勾选可强制覆盖）"
            } else {
                // 中心仓：同版本一律 409，没法覆盖 —— 唯一出路是升版
                "目标仓不允许覆盖同版本（如官方中心仓），必须升版后重发，本次未推送"
            }
        case PlanCategory.VersionOptional =>
            "目标仓已有更合适的版本，默认不发（要发就手工勾选）"
        case PlanCategory.NeedPublish => "未勾选：不推送"
    }
}

// 服务器故障/网络异常可重试；4xx 一律不重试（重试也还是同一个结果，还会白烧配额）
func isRetryable(code: Int64): Bool {
    code == 0 || code >= 500
}

// 轮询目标仓索引直到出现「该包该版本」。
//
// 节奏：先短探一次（5s）→ 1 分钟 → 3 分钟 → 5 分钟 → 之后每 5 分钟一轮，**默认不设总超时**：
// 「索引里还没有」不是失败，中心仓索引/缓存同步慢是常态（几十分钟到几天，审核还可能更久），
// 让它一直等才是对的；人随时可以点「停止执行」，探测到 401/403/429/5xx/网络失败也会提前收工
// （那些再等也不会变好）。
//
// pollTimeoutSec > 0 时作为**总等待上限**（可选保险丝）；<= 0 表示不限。
// 返回 WAIT_READY / WAIT_TIMEOUT / WAIT_CANCELLED / WAIT_FATAL。
func waitIndexReady(probe: (String, String) -> IndexProbe, org: String, name: String, version: String,
                    pollTimeoutSec: Int64,
                    shouldCancel!: () -> Bool = { => false },
                    onWaiting!: (Int64, Int64, IndexProbe) -> Unit = { _, _, _ => () },
                    ladder!: Array<Int64> = IndexWaitLadder,
                    steadySec!: Int64 = IndexWaitSteadySec): Int64 {
    var waited: Int64 = 0
    var round: Int64 = 0
    while (true) {
        if (shouldCancel()) {
            return WAIT_CANCELLED
        }
        let step = if (round < ladder.size) { ladder[round] } else { steadySec }
        round++
        if (step > 0) {
            sleep(Duration.second * step)
            waited += step
        }
        let res = probe(org, name)
        if (res.ok()) {
            if (indexHasVersion(res.body, name, version)) {
                return WAIT_READY
            }
        } else if (res.fatal()) {
            // 失败的探测也要报给调用方（它要拿状态码决定"要不要把整个计划暂停"）
            onWaiting(waited, step, res)
            return WAIT_FATAL
        }
        onWaiting(waited, step, res)
        // 上限判定放在探测之后：等够时长就先探一次再收工（否则"上限 1 秒"会连一次都探不到）
        if (pollTimeoutSec > 0 && waited >= pollTimeoutSec) {
            return WAIT_TIMEOUT
        }
    }
    WAIT_TIMEOUT
}

// 目标仓索引里是否已有该版本（索引是 NDJSON，逐行解析而不是做子串匹配——
// 子串会把 "1.0.1" 误命中成 "1.0.10"）
public func indexHasVersion(indexJson: String, name: String, version: String): Bool {
    for (e in parseNDJSON(indexJson)) {
        if (e.name == name && e.version == version) {
            return true
        }
    }
    false
}

// 把目标仓返回的正文尾部拼进错误文案（正文里是官方仓的原因说明）
func bodyTail(text: String): String {
    if (text.isEmpty()) {
        return ""
    }
    ": ${text}"
}

// 目标上游发布 URL：POST /pkg/{name}?organization={org}
public func buildPackagePublishURL(targetUrl: String, name: String, org: String): String {
    var base = targetUrl
    // 去掉末尾斜杠
    while (base.endsWith("/")) {
        base = base[0..base.size - 1]
    }
    if (org.isEmpty()) {
        return "${base}/pkg/${name}"
    }
    return "${base}/pkg/${name}?organization=${org}"
}
