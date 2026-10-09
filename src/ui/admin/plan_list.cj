// 管理端发布计划列表（@Page /admin/publish-plans）
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

public struct PlanRow {
    public let doc: PlanDoc
    public let upstream: String

    public init(doc: PlanDoc, upstream: String) {
        this.doc = doc
        this.upstream = upstream
    }
}

/// 创建向导包选择行：包实体 + 是否已选中
public struct PkgChoice {
    public let doc: PackageDoc
    public let selected: Bool

    public init(doc: PackageDoc, selected: Bool) {
        this.doc = doc
        this.selected = selected
    }
}

// ===== 发布计划列表 =====
@Page["/admin/publish-plans", "发布计划", requireAdmin]
class PublishPlansPage <: Component {
    var state: Option<CjregState> = None
    var msg = Signal<String>("")
    // 行数据 + 分页（泛型 Table<PlanRow>：计划实体 + 上游名）
    var rows = Signal<ArrayList<PlanRow>>(ArrayList<PlanRow>())
    var currentPage = Signal<Int64>(1)
    var pageSize = Signal<Int64>(20)
    var total = Signal<Int64>(0)
    // 删除确认
    var confirmVisible = Signal<Bool>(false)
    var pendingDeleteId: Int64 = 0
    // 用信号承载：cjxt 的 Dialog 只保留**首次渲染**的静态子节点，普通字段改了不会刷新
    //（实测：确认框里始终显示「确定要删除计划「」吗？」），必须包进 SignalView
    var pendingDeleteName = Signal<String>("")

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        refresh()
    }

    // 分页切片（行数据为 PlanRow 视图）
    func refresh(): Unit {
        match (this.state) {
            case Some(st) =>
                let plans = st.adminData.listPlans()
                this.total.set(plans.size)
                let (start, end) = pageWindow(plans.size, this.currentPage.get(), this.pageSize.get())
                let data = ArrayList<PlanRow>()
                var i = start
                while (i < end) {
                    let p = plans[i]
                    data.add(PlanRow(p, this.upstreamName(st, p.targetUpstream)))
                    i++
                }
                this.rows.set(data)
            case None => ()
        }
    }

    func onPageChange(ctx: ActionContext): PatchResult {
        this.refresh()
        PatchResult.ReRender
    }

    func upstreamName(st: CjregState, id: Int64): String {
        match (st.upStore.getById(id)) {
            case Some(u) => u.name
            case None => "#${id}"
        }
    }

    func statusTag(s: String): IComponent {
        match (s) {
            case "interrupted" => Tag([text("上次未收口")]).kind(ComponentKind.Danger)
            case "running" => Tag([text("执行中")]).kind(ComponentKind.Warning)
            case "completed" => Tag([text("已完成")]).kind(ComponentKind.Success)
            case "failed" => Tag([text("失败")]).kind(ComponentKind.Danger)
            case "paused" => Tag([text("已暂停")]).kind(ComponentKind.Info)
            case _ => Tag([text("待执行")]).kind(ComponentKind.Primary)
        }
    }

    func gotoCreate(ctx: ActionContext): PatchResult {
        ctx.route.push("/admin/publish-plans/create")
        PatchResult.ReRender
    }

    func gotoDetail(ctx: ActionContext, id: Int64): PatchResult {
        ctx.route.push("/admin/publish-plans/${id}")
        PatchResult.ReRender
    }

    func askDelete(ctx: ActionContext, id: Int64): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        match (st.adminData.getPlan(id)) {
            case Some(p) =>
                this.pendingDeleteId = p.id
                this.pendingDeleteName.set(p.name)
                this.confirmVisible.set(true)
            case None =>
                // 静默什么也不做的话，用户点「删除」会像按钮坏了
                this.msg.set("计划 #${id} 不存在（可能已被删除），请刷新列表")
        }
        PatchResult.ReRender
    }

    func cancelDelete(ctx: ActionContext): PatchResult {
        this.confirmVisible.set(false)
        PatchResult.ReRender
    }

    func confirmDelete(ctx: ActionContext): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            this.msg.set("无权限：需要管理员登录")
            return PatchResult.ReRender
        }
        if (st.adminData.deletePlan(this.pendingDeleteId)) {
            this.msg.set("已删除计划 ${this.pendingDeleteName.get()}")
            st.adminData.addLog(LogKind.Admin, sessionUid(ctx), sessionUsername(ctx), "delete plan ${this.pendingDeleteName.get()}", "ok", nowMs())
        } else {
            this.msg.set("删除失败")
        }
        this.confirmVisible.set(false)
        this.pendingDeleteId = 0
        // 必须重拉列表：只弹提示不刷新的话，被删的那行还挂在表上，
        // 看起来像"没删掉"（实测：提示"已删除计划 X"，行还在，刷新页面才消失）
        this.refresh()
        PatchResult.ReRender
    }

    func listHint(): String {
        if (this.rows.get().size == 0) {
            return "暂无发布计划，点击「创建计划」新建"
        }
        ""
    }

    func renderList(): IComponent {
        Table<PlanRow>()
            .data(this.rows)
            .emptyText("暂无数据")
            .stripe()
            .add(TableColumn<PlanRow>().label("ID").accessor({ r => r.doc.id.toString() }).width(50))
            .add(TableColumn<PlanRow>().label("计划名").accessor({ r => r.doc.name }).minWidth(140))
            .add(TableColumn<PlanRow>().label("状态").width(100).render({ r, i =>
                // 同上：库里 running 但没线程在执行 = 上次没收口
                let runIds = match (this.state) {
                    case Some(s) => s.planRunIds.get()
                    case None => ArrayList<Int64>()
                }
                this.statusTag(if (r.doc.status == "running" && !containsId(runIds, r.doc.id)) { "interrupted" } else { r.doc.status })
            }))
            .add(TableColumn<PlanRow>().label("目标上游").accessor({ r => r.upstream }).minWidth(140))
            .add(TableColumn<PlanRow>().label("进度").accessor({ r =>
                progressTextOf(r.doc.completedCount, r.doc.totalCount)
            }).width(100))
            .add(TableColumn<PlanRow>().label("操作").minWidth(180).render({ r, i =>
                let id = r.doc.id
                let detailH: ActionHandler = { c => this.gotoDetail(c, id) }
                let deleteH: ActionHandler = { c => this.askDelete(c, id) }
                div([
                    Button([text("详情")]).size(ButtonSize.Small).onClick(detailH),
                    Button([text("删除")]).size(ButtonSize.Small).kind(ButtonKind.Danger).onClick(deleteH),
                ])
            }))
    }

    func renderConfirmDialog(): IComponent {
        let dlg = Dialog([
            // SignalView 包一层：对话框里的动态内容要跟着信号刷新（见 SignalView 注释）
            SignalView({ => div([text("确定要删除计划「${this.pendingDeleteName.get()}」吗？")]) }),
        ])
            .visible(this.confirmVisible)
            .title("删除确认")
            .width("400px")
            .closeOnClickModal(false)
            .footer([
                Button([text("取消")]).onClick(cancelDelete),
                Button([text("删除")]).kind(ButtonKind.Danger).onClick(confirmDelete),
            ])
        dlg
    }

    public func render(): IComponent {
        let toolbar = div([
            Button([text("创建计划")]).kind(ButtonKind.Primary).onClick(gotoCreate),
            if (this.msg.get() != "") {
                Tag([text(this.msg.get())]).kind(ComponentKind.Success)
            } else {
                div()
            },
        ], attrs: Some(HashMap<String, String>([("class", cls("toolbar"))])))
        let pager = Pagination()
            .currentPage(this.currentPage)
            .pageSize(this.pageSize)
            .total(this.total.get())
            .layout("total, prev, pager, next, sizes")
            .onChange(onPageChange)
        adminLayout("/admin/publish-plans", [
            div([text("发布计划")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            adminCard("发布计划列表", [toolbar, listBody(this.listHint(), this.renderList()), pager,
                this.renderConfirmDialog()]),
        ])
    }
}
