// 发布计划 · 模型与常量：索引等待码与节奏、条目/分类/分析/计划模型、执行报告，
// 以及围着这些模型转的小函数（版本对照、进度/分类/包名文案、分类说明）
// 类的实现见同包 publish_plan_analyze.cj（PublishPlanService）与 publish_plan_execute.cj（PublishExecutor）
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

// 「已推送成功、索引确认攒到本批末尾」的条目说明（叶子项 defer 时写一次）
let DEFER_INDEX_MSG = "已推送成功，索引确认攒到本批末尾一起做"

// 等待目标仓索引的节奏（秒）：先短探一次（同进程的私有仓索引是即时生效的，不必先等一分钟），
// 然后 1 分钟一轮探三次，之后每 5 分钟一轮。
//
// 中间三次都用 1 分钟（而不是递增到 3 分钟）：索引要么很快就出现（同一台机器的私有仓几乎即时、
// 中心仓通常几分钟内），要么就是慢同步（几十分钟到几天，甚至卡审核）——递增到 3 分钟只是在
// "快要出现"和"还早"之间各让一半，两边都不讨好。
//
// **不设次数上限**：中心仓同步几十分钟到几天都正常，等到就收工，等不到就继续等；
// 需要保险丝就配 pollTimeoutSec > 0。
let IndexWaitLadder: Array<Int64> = [5, 60, 60, 60]
let IndexWaitSteadySec: Int64 = 300

// 阶梯的人话说法（界面/提示语共用一份，改常量就不会漏改文案）。
// 只描述"节奏"，不描述次数上限：上限由计划自己的 pollTimeoutSec 决定（0=一直等）。
public func indexWaitRhythmText(): String {
    var s = ""
    for (i in 0..IndexWaitLadder.size) {
        if (i > 0) {
            s += " → "
        }
        s += waitSecText(IndexWaitLadder[i])
    }
    s + " → 每 ${waitSecText(IndexWaitSteadySec)}"
}

// 秒数的人话：60 的倍数说分钟，其余说秒（5 → "5s"，60 → "1m"，300 → "5m"）
func waitSecText(sec: Int64): String {
    if (sec > 0 && sec % 60 == 0) {
        return "${sec / 60}m"
    }
    "${sec}s"
}

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
