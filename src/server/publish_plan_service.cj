// 发布计划：模型 + analyze（拓扑排序）+ 执行引擎
// analyze 复用 cjdep 语义：依赖解析 + 分类 + 拓扑发布顺序
package ystyle::cjreg.server

import ystyle::cjreg.index.*
import ystyle::cjreg.store.*
import ystyle::cjreg.config.*
import ystyle::cjreg.semver_range.*
import stdx.encoding.json.stream.*
import std.io.*
import std.collection.*

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
        this.overwriteAllowed = false
    }
}

// 目标仓是否允许覆盖已有同版本（官方仓明确不允许；自建仓由自身权限模式决定）
public func targetOverwritable(up: ?Upstream): Bool {
    match (up) {
        case Some(u) => !u.isOfficial
        case None => false
    }
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
                        fetchIndex!: (Upstream, String, String) -> ?String = { _, _, _ => None }): PlanAnalysis {
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

        // 3. 依赖图（从 indexJson 解析依赖名）→ 拓扑排序（后序 DFS）
        var visited = HashSet<Int64>()
        var inStack = HashSet<Int64>()
        var order = ArrayList<PackageDoc>()
        var hasCycle = false
        var stackTrace = ArrayList<Int64>()
        // docId → 把它拉进来的依赖方版本要求（根包没有要求）
        let requirements = HashMap<Int64, String>()

        // 递归 DFS（简化：用栈模拟）
        var stack = ArrayList<(Int64, Bool)>()  // (pkgId, processed)
        for (r in roots) {
            stack.add((r.id, false))
        }
        while (stack.size > 0) {
            let (id, processed) = stack[stack.size - 1]
            stack.remove(stack.size - 1..stack.size)
            if (processed) {
                if (!orderContains(order, id)) {
                    order.add(findDoc(all, id).getOrThrow())
                }
                inStack.remove(id)
                continue
            }
            if (visited.contains(id)) {
                continue
            }
            if (inStack.contains(id)) {
                hasCycle = true
                continue
            }
            visited.add(id)
            inStack.add(id)
            stack.add((id, true))
            // 依赖（从 indexJson 解析 dependencies）
            let doc = findDoc(all, id).getOrThrow()
            for ((depOrg, dep, require) in parseDependencyRefs(doc.indexJson)) {
                // 依赖按「满足声明版本要求里最新的那个」解析，并且同一包一个计划只出一个版本；
                // 跨组织依赖（`ystyle::crc`）按前缀里的 org 找，没有前缀才跟随依赖方的 org
                let org = if (depOrg != "") { depOrg } else { doc.organization }
                match (this.pickDepDoc(all, org, dep, require, chosen)) {
                    case Some(dd) =>
                        // 记下是哪个版本要求把它拉进来的（分类时判断 version_optional 用）
                        if (!requirements.contains(dd.id)) {
                            requirements[dd.id] = require
                        }
                        if (!visited.contains(dd.id)) {
                            stack.add((dd.id, false))
                        }
                    case None => ()
                }
            }
        }

        // 4. 目标仓索引：org::name → (version → sha)
        //    取不到的包要记下来（None 只代表"取不到"，不代表"目标仓没有这个包"）
        var targetChecked = false
        var targetError = ""
        let remote = HashMap<String, HashMap<String, String>>()
        let unreachable = ArrayList<String>()
        match (targetUpstream) {
            case Some(up) =>
                let fetched = HashSet<String>()
                for (d in order) {
                    let key = d.organization + "::" + d.name
                    if (fetched.contains(key)) {
                        continue
                    }
                    fetched.add(key)
                    match (fetchIndex(up, d.organization, d.name)) {
                        case Some(text) =>
                            let m = HashMap<String, String>()
                            for (e in parseNDJSON(text)) {
                                m[e.version] = e.sha256sum
                            }
                            remote[key] = m
                        case None => unreachable.add(packageLabel(d.organization, d.name, ""))
                    }
                }
                targetChecked = unreachable.size == 0
                if (unreachable.size > 0) {
                    targetError = "目标仓索引取不到：${unreachable.size} 个包（${unreachable[0]} 等）" +
                        "无法判断是否已存在，这些条目只能按「待发布」列出——执行时若目标仓已有同版本会得到 409"
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
            let remoteOf = match (remote.get(d.organization + "::" + d.name)) {
                case Some(m) => m
                case None => emptyRemote
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
                var best = ""
                for ((v, _) in remote) {
                    if (best.isEmpty() || compareVersions(v, best) > 0) {
                        best = v
                    }
                }
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

    // 从 indexJson 解析依赖 (org, 名字, 版本要求)。
    // 依赖名可能带 `org::` 前缀（如 `ystyle::crc`）——**前缀必须保留**：跨组织依赖
    // （snappy/badgercj → ystyle::crc）一旦丢掉前缀，就会去"依赖方自己的 org"里找，
    // 找不到 → 这条依赖边直接消失 → 拓扑序被打乱（实测 snappy 被排到了 crc 前面，
    // 等于先发依赖方）。org 为空表示"与依赖方同组织"。
    func parseDependencyRefs(indexJson: String): ArrayList<(String, String, String)> {
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

    func orderContains(order: ArrayList<PackageDoc>, id: Int64): Bool {
        for (d in order) {
            if (d.id == id) {
                return true
            }
        }
        return false
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
    // 中止：认证/权限/配额这类「后续必然同样失败」的情况，立刻停手
    public var aborted: Bool = false
    public var abortReason: String = ""
    public var errors: ArrayList<String> = ArrayList<String>()
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
                        indexProbe!: ?(String, String) -> ?String = None,
                        pollIntervalSec!: Int64 = 0,
                        pollTimeoutSec!: Int64 = 0): ExecuteReport {
        let report = ExecuteReport()
        report.total = items.size
        let MaxRetries: Int64 = 3

        // 先按 order 排序（拓扑顺序）
        var sorted = ArrayList<PlanItem>()
        for (it in items) {
            sorted.add(it)
        }
        // 插入排序（order 升序）
        var i: Int64 = 1
        while (i < sorted.size) {
            let key = sorted[i]
            var j = i - 1
            while (j >= 0 && sorted[j].order > key.order) {
                sorted[j + 1] = sorted[j]
                j--
            }
            sorted[j + 1] = key
            i++
        }

        var idx: Int64 = 0
        while (idx < sorted.size) {
            let it = sorted[idx]
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
                // （几分钟到几小时）。不等就推下一条，会出现「依赖还没出现在索引里」
                // 的假失败，或者推到一半自己把自己卡住。
                var ready = true
                match (indexProbe) {
                    case Some(probe) =>
                        if (pollIntervalSec > 0 && pollTimeoutSec > 0) {
                            it.status = PlanItemStatus.WaitingIndex
                            onItem(it, true, "等待目标仓索引就绪")
                            ready = waitIndexReady(probe, doc.organization, doc.name, doc.version,
                                pollIntervalSec, pollTimeoutSec)
                        }
                    case None => ()
                }
                if (ready) {
                    report.success++
                    it.status = PlanItemStatus.Completed
                    it.error = ""
                    onItem(it, true, "")
                } else {
                    // 索引迟迟不出现 → **暂停**而不是判失败：内容其实已经推上去了，
                    // 只是还没同步；用户稍后点「继续执行」会跳过已完成项、从这里接上。
                    // 状态保持 WaitingIndex（不是 Skipped）：续跑时据此**不再重推**，只继续等。
                    it.status = PlanItemStatus.WaitingIndex
                    it.error = "等待索引就绪超时（${pollTimeoutSec}s）：${doc.name}@${doc.version} 还没出现在目标仓索引里（已推送成功，续跑会继续等）"
                    report.skipped++
                    report.aborted = true
                    report.abortReason = "等待 ${doc.name}@${doc.version} 索引就绪超时" +
                        "（已等 ${pollTimeoutSec}s）：中心仓同步可能较慢，稍后点「继续执行」接着等"
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

// 轮询目标仓索引直到出现「该包该版本」：每次等 pollIntervalSec 秒，最多等 pollTimeoutSec 秒。
// 返回 false 表示超时（内容可能已经推上去了，只是索引还没同步）。
func waitIndexReady(probe: (String, String) -> ?String, org: String, name: String, version: String,
                    pollIntervalSec: Int64, pollTimeoutSec: Int64): Bool {
    var waited: Int64 = 0
    while (waited < pollTimeoutSec) {
        sleep(Duration.second * pollIntervalSec)
        waited += pollIntervalSec
        match (probe(org, name)) {
            case Some(text) =>
                if (indexHasVersion(text, name, version)) {
                    return true
                }
            case None => ()
        }
    }
    false
}

// 目标仓索引里是否已有该版本（索引是 NDJSON，逐行解析而不是做子串匹配——
// 子串会把 "1.0.1" 误命中成 "1.0.10"）
func indexHasVersion(indexJson: String, name: String, version: String): Bool {
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
