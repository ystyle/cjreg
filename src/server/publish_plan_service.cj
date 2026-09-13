// 发布计划：模型 + analyze（拓扑排序）+ 执行引擎
// analyze 复用 cjdep 语义：依赖解析 + 分类 + 拓扑发布顺序
package ystyle::cjreg.server

import ystyle::cjreg.index.*
import ystyle::cjreg.store.*
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

    // analyze：对给定包列表做依赖分析 + 拓扑排序
    // 返回 (排序后的 PlanItem 列表, 环检测标志)
    public func analyze(rootPkgs: ArrayList<(String, String, String)>): (ArrayList<PlanItem>, Bool) {
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
            return (ArrayList<PlanItem>(), false)
        }

        // 3. 依赖图（从 indexJson 解析依赖名）→ 拓扑排序（后序 DFS）
        var visited = HashSet<Int64>()
        var inStack = HashSet<Int64>()
        var order = ArrayList<PackageDoc>()
        var hasCycle = false
        var stackTrace = ArrayList<Int64>()

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
                        if (!visited.contains(dd.id)) {
                            stack.add((dd.id, false))
                        }
                    case None => ()
                }
            }
        }

        // 4. 生成 PlanItem（按拓扑顺序）
        let items = ArrayList<PlanItem>()
        var n: Int64 = 1
        for (d in order) {
            items.add(PlanItem(d.id, d.name, d.organization, d.version,
                classify(d), n))
            n++
        }
        return (items, hasCycle)
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

    // 分类（简化：本地有即已存在；真实逻辑按中心仓对比，M5 简化为本地视角）
    func classify(d: PackageDoc): PlanCategory {
        PlanCategory.NeedPublish
    }
}

// 从 analyze 请求体解析 packages 列表 [{organization,name,version}]
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
                it.error = "未勾选：不推送"
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
            it.status = PlanItemStatus.Publishing
            onItem(it, true, "推送中")

            var ok = false
            var code: Int64 = 0
            var text = ""
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
                    // 只是还没同步；用户稍后点「继续执行」会跳过已完成项、从这里接上
                    it.status = PlanItemStatus.Skipped
                    it.error = "等待索引就绪超时（${pollTimeoutSec}s）：${doc.name}@${doc.version} 还没出现在目标仓索引里"
                    report.skipped++
                    report.aborted = true
                    report.abortReason = "等待 ${doc.name}@${doc.version} 索引就绪超时" +
                        "（已等 ${pollTimeoutSec}s）：中心仓同步可能较慢，稍后点「继续执行」接着发"
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
