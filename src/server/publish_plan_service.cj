// 发布计划：模型 + analyze（拓扑排序）+ 执行引擎
// analyze 复用 cjdep 语义：依赖解析 + 分类 + 拓扑发布顺序
package ystyle::cjreg.server

import ystyle::cjreg.index.*
import ystyle::cjreg.store.*
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
        for (r in rootPkgs) {
            let (org, name, _) = r
            for (d in all) {
                if (d.name == name && d.organization == org) {
                    roots.add(d)
                    break
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
            let deps = parseDependencyNames(doc.indexJson)
            for (dep in deps) {
                // 找到本地同名依赖
                let depDoc = findByName(all, doc.organization, dep)
                if (depDoc.isSome() && !visited.contains(depDoc.getOrThrow().id)) {
                    stack.add((depDoc.getOrThrow().id, false))
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

    // 从 indexJson 解析依赖名（简化：从 index 条目 dependencies）
    func parseDependencyNames(indexJson: String): ArrayList<String> {
        let result = ArrayList<String>()
        let entries = parseNDJSON(indexJson)
        if (entries.size == 0) {
            return result
        }
        for (d in entries[0].dependencies) {
            // 依赖名可能 org::name，取 name 部分
            let depName = d.name
            let idx = depName.indexOf("::")
            if (idx.isSome()) {
                result.add(depName[idx.getOrThrow() + 2..depName.size])
            } else {
                result.add(depName)
            }
        }
        return result
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
        ()
    }
}
