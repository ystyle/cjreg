// 发布计划页面共用：分类/状态/时间/执行器接线等辅助
package ystyle::cjreg.ui.admin

import ystyle::cjreg.ui.*
import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import ystyle::cjreg.store.*
import ystyle::cjreg.config.*
import ystyle::cjreg.server.{BlobStore, DiskBlobStore, ExecuteReport, IndexProbe, PlanCategory, PlanItem, PlanItemStatus, PublishExecutor, PublishPlanService, applyAnalysisToPlan, categoryHint, checkVersionsInIndex, countRequired, indexWaitRhythmText, packageLabel, planCategoryName, progressTextOf, targetCompareText, targetOverwritable}
import ystyle::cjreg.index.*
import ystyle::cjreg.semver_range.*
import std.collection.*
import std.sort.*
import std.convert.*
import std.time.*

// PlanItemDoc.category 字符串 → PlanCategory 枚举
func toPlanCategory(s: String): PlanCategory {
    match (s) {
        case "version_optional" => PlanCategory.VersionOptional
        case "already_exists" => PlanCategory.AlreadyExists
        case "conflict" => PlanCategory.Conflict
        case _ => PlanCategory.NeedPublish
    }
}

// 索引生效时间：新记录用显式字段；本列上线前完成的旧记录退回 completedAt ——
// 在本计划里「完成」就是"目标仓索引里确认到了该版本"，两者是同一个事件。
func indexTimeOf(d: PlanItemDoc): Int64 {
    if (d.indexAt > 0) {
        return d.indexAt
    }
    if (d.status == "completed") {
        return d.completedAt
    }
    0
}

// 计划项时间戳 → `推送 HH:mm:ss` / `索引 HH:mm:ss`（0 = 没有这个时刻，显示「—」）。
// 具体日期由计划信息里的时间上下文给出，表格里只留时分秒。
func itemTimeText(label: String, ms: Int64): String {
    if (ms <= 0) {
        return "${label} —"
    }
    "${label} " + DateTime.fromUnixTimeStamp(Duration.millisecond * ms).inLocal().format("HH:mm:ss")
}

// 分类标签（详情页表格与创建页「版本对照」预览共用一份文案）。
// status 优先：已经推送成功的项不该再显示「待发布」（那是建计划那一刻的比对结果）。
func planCategoryTag(c: PlanCategory, status: String): IComponent {
    match (status) {
        case "completed" => return Tag([text("已发布")]).kind(ComponentKind.Success)
        case "waiting_index" => return Tag([text("已推送·等索引")]).kind(ComponentKind.Warning)
        case _ => ()
    }
    match (c) {
        case PlanCategory.AlreadyExists => Tag([text("已存在")]).kind(ComponentKind.Success)
        case PlanCategory.Conflict => Tag([text("冲突")]).kind(ComponentKind.Danger)
        case PlanCategory.VersionOptional => Tag([text("可升版")]).kind(ComponentKind.Warning)
        case _ => Tag([text("待发布")]).kind(ComponentKind.Primary)
    }
}

// 构造发布计划执行器：**制品库只能来自注入**（main.cj 按 -d/--data-dir 构造的那个）。
//
// 这里踩过一次：原来图省事写 `DiskBlobStore("./data/blobs")`（`getDataDir()` 是写死 "./data" 的桩）。
// 宿主仓库里工作目录就是仓库根、`./data` 恰好对，所以本地看着没问题；**容器里工作目录是 /app、
// 真实数据目录是 /data** → 执行器对着 /app/data/blobs（空目录）找制品，于是**每一项都报
// 「制品缺失（sha=…）」**，而同一时刻 /pkg/:name/:version 下载一切正常，看起来像包坏了。
// 抽成函数是为了让这条约束有回归测试（不能只靠"看代码"）。
public func buildPlanExecutor(pkgStore: PackageStore, blobStore: ?BlobStore): ?PublishExecutor {
    match (blobStore) {
        case Some(b) => Some(PublishExecutor(pkgStore, b))
        case None => None
    }
}

// 计划 id 是否在登记列表里
func containsId(ids: ArrayList<Int64>, id: Int64): Bool {
    for (x in ids) {
        if (x == id) {
            return true
        }
    }
    false
}

// 登记 / 注销：cancel = false → planRunIds（正在执行）；true → planCancelIds（已请求停止）。
// 用"换一个新列表再 set"而不是原地改：信号要看到新值才会触发重渲。
func addPlanId(st: CjregState, planId: Int64, cancel: Bool): Unit {
    let src = if (cancel) { st.planCancelIds.get() } else { st.planRunIds.get() }
    if (containsId(src, planId)) {
        return
    }
    let next = ArrayList<Int64>()
    for (x in src) {
        next.add(x)
    }
    next.add(planId)
    if (cancel) {
        st.planCancelIds.set(next)
    } else {
        st.planRunIds.set(next)
    }
}

func removePlanId(st: CjregState, planId: Int64, cancel: Bool): Unit {
    let src = if (cancel) { st.planCancelIds.get() } else { st.planRunIds.get() }
    let next = ArrayList<Int64>()
    for (x in src) {
        if (x != planId) {
            next.add(x)
        }
    }
    if (cancel) {
        st.planCancelIds.set(next)
    } else {
        st.planRunIds.set(next)
    }
}

// 计划项状态：字符串 ⇄ 枚举（续跑时要把库里的状态带回执行器，
// 否则已成功的项会被重复推送、换回 409）
func toPlanItemStatus(s: String): PlanItemStatus {
    match (s) {
        case "completed" => PlanItemStatus.Completed
        case "failed" => PlanItemStatus.Failed
        case "running" => PlanItemStatus.Pending
        case "waiting_index" => PlanItemStatus.WaitingIndex
        case "skipped" => PlanItemStatus.Skipped
        case _ => PlanItemStatus.Pending
    }
}

func planItemStatusName(s: PlanItemStatus): String {
    match (s) {
        case PlanItemStatus.Completed => "completed"
        case PlanItemStatus.Failed => "failed"
        case PlanItemStatus.Skipped => "skipped"
        case PlanItemStatus.Publishing => "running"
        case PlanItemStatus.WaitingIndex => "waiting_index"
        case PlanItemStatus.Pending => "pending"
    }
}
