// 管理端审计日志页（@Page /admin/logs）
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

// ===== 日志页 =====
// 审计日志：类型/结果筛选 + 关键字搜索 + 分页 + 按类型清理（清理动作自身入审计）
@Page["/admin/logs", "日志", requireAdmin]
class LogsPage <: Component {
    var state: Option<CjregState> = None
    var rows = Signal<ArrayList<LogDoc>>(ArrayList<LogDoc>())
    var kindFilter = Signal<String>("all")
    var statusFilter = Signal<String>("all")
    var keyword = Signal<String>("")
    var currentPage = Signal<Int64>(1)
    var pageSize = Signal<Int64>(20)
    var total = Signal<Int64>(0)
    var msg = Signal<String>("")
    var confirmVisible = Signal<Bool>(false)
    var cleanKind = Signal<String>("all")
    // 数据版本：清理日志后强制重查（查询条件都没变时，信号不会变，派生不会自己再跑）
    var dataVersion = Signal<Int64>(0)
    // 派生绑定：页面实例是路由注册期创建、跨请求复用的，onMount 必须重建，否则订阅会累积
    private var binding: Option<Effect> = None

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        this.rebind()
    }

    public func onUnmount(ctx: LifecycleContext): Unit {
        match (this.binding) {
            case Some(e) => e.dispose()
            case None => ()
        }
        this.binding = None
    }

    private func rebind(): Unit {
        match (this.binding) {
            case Some(e) => e.dispose()
            case None => ()
        }
        this.binding = Some(Effect({ => this.reload() }))
    }

    func bump(): Unit {
        this.dataVersion.update({ v => v + 1 })
    }

    // 查询结果派生：查询条件全部从信号读，任一变（搜索框 bind、下拉 bind、翻页、改每页条数）自动重查。
    //
    // 旧写法把查询放在输入框的 action 里 refresh()，而前端对同一元素是**先 action 后 bind**
    // （cjxt public/js/cangjie-ui.js:333 立即发 action，:490 的 bind 有 300ms 防抖）——
    // action 里读到的关键字还是上一次的，表现就是「输入搜索无效，必须再点一次『筛选』」。
    //
    // 日志量大，过滤在服务端做（不像包管理那样全量拉进来在内存里筛）：所以派生的对象是
    // "这次查询的结果"，而不是"行的子集"。
    func reload(): Unit {
        let _ = this.dataVersion.get()
        let st = match (this.state) {
            case Some(x) => x
            case None => return
        }
        let kind = if (this.kindFilter.get() == "all") { Option<String>.None } else { Some(this.kindFilter.get()) }
        let status = if (this.statusFilter.get() == "all") { "" } else { this.statusFilter.get() }
        var size = this.pageSize.get()
        if (size <= 0) {
            size = 20
        }
        var page = this.currentPage.get()
        if (page < 1) {
            page = 1
        }
        var (rows, total) = st.adminData.queryLogs(kind, this.keyword.get().trimAscii(), status,
            0, 0, (page - 1) * size, size)
        // 页越界（上一页被清理、或条件变严后总页数变少）：退到最后一页重查一次。
        // 这里**不回写页码信号**（回写会让本 Effect 自订阅成环）；分页器自己会把显示页
        // 夹到有效范围（Pagination.render 的 clampPage），所以不会出现"表格第 1 页、页码显示第 3 页"。
        if (rows.size == 0 && total > 0 && (page - 1) * size >= total) {
            let last = (total + size - 1) / size
            let again = st.adminData.queryLogs(kind, this.keyword.get().trimAscii(), status,
                0, 0, (last - 1) * size, size)
            rows = again[0]
            total = again[1]
        }
        this.rows.set(rows)
        this.total.set(total)
    }

    func kindLabel(k: String): String {
        match (k) {
            case "publish" => "发布"
            case "auth" => "认证"
            case _ => "管理"
        }
    }

    // 「筛选」按钮：回到第一页再重查（条件没变时靠 bump 强制重查，否则点了像没反应）
    func doRefresh(ctx: ActionContext): PatchResult {
        this.currentPage.set(1)
        this.bump()
        PatchResult.ReRender
    }

    // 过滤条件变化时**不回写页码**：分页器（cjxt Pagination）的 total 是创建时的快照，
    // 而页码一变它自己就变脏、会在同一批补丁里被旧实例重渲染一次，那条补丁排在页面补丁
    // **之后** → 把页面刚算好的「共 N 条」又顶回上一次的值（实测：改筛选后行是对的、
    // 条数却是旧的，旧实例的 total 快照只有在页面重渲时才刷新）。
    // 页越界交给本地钳制：reload() 会退到最后一页重查，Pagination.render 也会把显示页
    // 夹进有效范围，所以不回写页码也不会出现"表格第 1 页、页码显示第 3 页"。

    func askClear(ctx: ActionContext): PatchResult {
        this.confirmVisible.set(true)
        PatchResult.ReRender
    }

    func cancelClear(ctx: ActionContext): PatchResult {
        this.confirmVisible.set(false)
        PatchResult.ReRender
    }

    func confirmClear(ctx: ActionContext): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            this.msg.set("无权限：需要管理员登录")
            return PatchResult.ReRender
        }
        let scope = this.cleanKind.get()
        let kind = if (scope == "all") { Option<String>.None } else { Some(scope) }
        let deleted = st.adminData.removeLogs(kind, 0)
        // 清理动作自身入审计（管理类；UI 操作无 HTTP 上下文，IP/UA 记为管理端）
        let _ = st.adminData.addLog(LogKind.Admin, sessionUid(ctx), sessionUsername(ctx), "clean_logs", "ok", nowMs(),
            target: if (scope == "all") { "all" } else { scope },
            detail: "deleted=${deleted} via=admin-ui", ipAddr: "admin-ui", userAgent: "cjxt-admin-ui")
        this.msg.set("已清理 ${deleted} 条${if (scope == "all") { "全部" } else { this.kindLabel(scope) }}日志")
        this.confirmVisible.set(false)
        this.currentPage.set(1)
        this.bump()
        PatchResult.ReRender
    }

    public func render(): IComponent {
        let kindOptions = ArrayList<IComponent>()
        kindOptions.add(SelectOption([text("全部类型")], "all"))
        kindOptions.add(SelectOption([text("发布")], "publish"))
        kindOptions.add(SelectOption([text("管理")], "admin"))
        kindOptions.add(SelectOption([text("认证")], "auth"))
        let statusOptions = ArrayList<IComponent>()
        statusOptions.add(SelectOption([text("全部结果")], "all"))
        statusOptions.add(SelectOption([text("成功")], "ok"))
        statusOptions.add(SelectOption([text("失败")], "failed"))
        let cleanOptions = ArrayList<IComponent>()
        cleanOptions.add(SelectOption([text("全部日志")], "all"))
        cleanOptions.add(SelectOption([text("仅发布日志")], "publish"))
        cleanOptions.add(SelectOption([text("仅管理日志")], "admin"))
        cleanOptions.add(SelectOption([text("仅认证日志")], "auth"))
        // 各控件固定宽度：日志页列多，工具栏需在一行内放下「筛选/清理」按钮。
        // 输入框与下拉都**只 bind**（不挂刷新动作）：过滤由派生查询跟着信号走，
        // 动作里读关键字会踩"先 action 后 bind"拿到上一次的值。
        let toolbar = div([
            div([Input().bind(this.keyword).placeholder("搜索操作者/操作/对象/错误")],
                attrs: Some(HashMap<String, String>([("style", "width:230px;display:inline-block;")]))),
            // 下拉只 bind：**不挂 onChange 回写页码**（见下面 reload 前的说明）
            div([Select(kindOptions.toArray()).bind(this.kindFilter)],
                attrs: Some(HashMap<String, String>([("style", "width:130px;display:inline-block;")]))),
            div([Select(statusOptions.toArray()).bind(this.statusFilter)],
                attrs: Some(HashMap<String, String>([("style", "width:130px;display:inline-block;")]))),
            Button([text("筛选")]).kind(ButtonKind.Primary).onClick(doRefresh),
            Button([text("清理日志")]).kind(ButtonKind.Danger).onClick(askClear),
            if (this.msg.get() != "") {
                Tag([text(this.msg.get())]).kind(ComponentKind.Success)
            } else {
                div()
            },
        ], attrs: Some(HashMap<String, String>([("class", cls("toolbar"))])))
        let table = Table<LogDoc>()
            .data(this.rows)
            .emptyText("暂无数据")
            .stripe()
            .add(TableColumn<LogDoc>().label("时间").width(120).render({ l, i =>
                text(formatTimeMs(l.createdAt))
            }))
            .add(TableColumn<LogDoc>().label("类型").width(70).render({ l, i =>
                text(this.kindLabel(l.kind))
            }))
            .add(TableColumn<LogDoc>().label("操作者").accessor({ l => l.actorName }).width(100))
            .add(TableColumn<LogDoc>().label("操作").accessor({ l => l.action }).minWidth(140).showOverflowTooltip())
            .add(TableColumn<LogDoc>().label("对象").accessor({ l => l.target }).minWidth(150).showOverflowTooltip())
            .add(TableColumn<LogDoc>().label("结果").width(80).render({ l, i =>
                if (l.status == "ok") {
                    Tag([text("成功")]).kind(ComponentKind.Success)
                } else {
                    Tag([text("失败")]).kind(ComponentKind.Danger)
                }
            }))
            .add(TableColumn<LogDoc>().label("IP").accessor({ l => l.ipAddr }).width(120))
            .add(TableColumn<LogDoc>().label("User-Agent").accessor({ l => l.userAgent }).minWidth(130).showOverflowTooltip())
            .add(TableColumn<LogDoc>().label("错误信息").accessor({ l => l.error }).minWidth(160).showOverflowTooltip())
        // 翻页/改每页条数由 Pagination 自己写 currentPage/pageSize 信号，派生查询跟着重跑，
        // 因此不再挂 onChange（挂了也只是重复查一次）
        let pager = Pagination()
            .currentPage(this.currentPage)
            .pageSize(this.pageSize)
            .total(this.total.get())
            .layout("total, prev, pager, next, sizes")
        let confirmDlg = Dialog([
            div([text("清理范围：")]),
            Select(cleanOptions.toArray()).bind(this.cleanKind),
            div([text("清理后不可恢复；清理动作本身会记入审计日志。")]),
        ])
            .visible(this.confirmVisible)
            .title("清理审计日志")
            .width("420px")
            .closeOnClickModal(false)
            .footer([
                Button([text("取消")]).onClick(cancelClear),
                Button([text("确认清理")]).kind(ButtonKind.Danger).onClick(confirmClear),
            ])
        adminLayout("/admin/logs", [
            div([text("审计日志")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            adminCard("操作日志", [toolbar, table, pager, confirmDlg]),
        ])
    }
}
