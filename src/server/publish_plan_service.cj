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

// 发布计划执行引擎：按拓扑顺序把本地包推送到目标上游
public class PublishExecutor {
    public var pkgStore: PackageStore
    public var blobStore: BlobStore

    public init(pkgStore: PackageStore, blobStore: BlobStore) {
        this.pkgStore = pkgStore
        this.blobStore = blobStore
    }

    // 执行：对 items（拓扑序）逐个推送；返回 (成功数, 总数, 失败详情)
    // targetUrl 为目标上游 registry base（如 http://localhost:8070）
    public func execute(items: ArrayList<PlanItem>, targetUrl: String, token: String, onItem!: (PlanItem, Bool, String) -> Unit = { _, _, _ => () }): (Int64, Int64, ArrayList<String>) {
        let total = items.size
        var success: Int64 = 0
        let errors = ArrayList<String>()

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

        for (it in sorted) {
            // 取本地包文档（含 meta + sha）
            match (this.pkgStore.getById(it.pkgId)) {
                case Some(doc) =>
                    // 从 indexJson 提取 sha256sum
                    let sha = extractSha256(doc.indexJson)
                    if (sha.isEmpty()) {
                        it.status = PlanItemStatus.Failed
                        it.error = "无 sha256sum"
                        errors.add("${doc.name}@${doc.version}: 无 sha256sum")
                        onItem(it, false, "无 sha256sum")
                        continue
                    }
                    // 从 blob 取制品
                    match (this.blobStore.get(sha)) {
                        case Some(tar) =>
                            // 组装官方二进制 [meta][tar]
                            let metaBytes = doc.indexJson.toArray()
                            let body = ArrayList<Byte>()
                            for (b in makePublishSection(UInt8(1), metaBytes)) {
                                body.add(b)
                            }
                            for (b in makePublishSection(UInt8(1), tar)) {
                                body.add(b)
                            }
                            let url = buildPackagePublishURL(targetUrl, doc.name, doc.organization)
                            let (ok, code) = httpPostBinary(url, body.toArray(), token)
                            if (ok) {
                                success++
                                it.status = PlanItemStatus.Completed
                                onItem(it, true, "")
                            } else {
                                it.status = PlanItemStatus.Failed
                                it.error = "HTTP ${code}"
                                errors.add("${doc.name}@${doc.version}: 推送失败 HTTP ${code}")
                                onItem(it, false, "HTTP ${code}")
                            }
                        case None =>
                            it.status = PlanItemStatus.Failed
                            it.error = "制品缺失（sha=${sha}）"
                            errors.add("${doc.name}@${doc.version}: 制品缺失（sha=${sha}）")
                            onItem(it, false, "制品缺失")
                    }
                case None =>
                    errors.add("pkg#${it.pkgId} 不存在")
            }
        }
        return (success, total, errors)
    }
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
