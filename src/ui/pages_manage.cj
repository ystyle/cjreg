// cjxt 管理界面页面：仪表盘 / 上游管理 / 包管理
package ystyle::cjreg.ui

import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import ystyle::cjreg.store.*
import ystyle::cjreg.config.*
import ystyle::cjreg.server.*
import ystyle::cjreg.semver_range.*
import std.collection.*
import std.convert.*
import std.sort.*
import std.time.*

// ===== 仪表盘 =====
@Page["/admin", "仪表盘", requireAdmin]
class DashboardPage <: Component {
    var state: Option<CjregState> = None
    // 最近操作日志（Table 信号）
    var recentLogs = Signal<ArrayList<LogDoc>>(ArrayList<LogDoc>())

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        refreshLogs()
    }

    func refreshLogs(): Unit {
        match (this.state) {
            case Some(st) =>
                let logs = st.adminData.listLogs(Option<String>.None, 8)
                let data = ArrayList<LogDoc>()
                for (l in logs) { data.add(l) }
                this.recentLogs.set(data)
            case None => ()
        }
    }

    public func render(): IComponent {
        let st = match (this.state) {
            case Some(s) => s
            case None => return div()
        }
        let allPkgs = st.pkgStore.storm.all<PackageDoc>()
        var versions: Int64 = 0
        var downloads: Int64 = 0
        var deletedPkgs: Int64 = 0
        for (d in allPkgs) {
            if (d.deletedAt != 0) {
                deletedPkgs++
            } else {
                versions++
            }
            downloads += d.downloadCount
        }
        // 用户
        let users = st.userStore.listAllUsers()
        var disabledUsers: Int64 = 0
        for (u in users) {
            if (!u.isActive) { disabledUsers++ }
        }
        // 上游
        let ups = st.upStore.listAll()
        var enabledUps: Int64 = 0
        for (u in ups) {
            if (u.enabled) { enabledUps++ }
        }
        // 计划
        let plans = st.adminData.listPlans()
        var runningPlans: Int64 = 0
        for (p in plans) {
            if (p.status == "running") { runningPlans++ }
        }
        // 日志
        let logs = st.adminData.listLogs(Option<String>.None, 1000)
        var failedLogs: Int64 = 0
        for (l in logs) {
            if (l.status == "failed") { failedLogs++ }
        }
        let stats = ArrayList<IComponent>()
        stats.add(statCard("${allPkgs.size}", "包总数", "view", "#409eff"))
        stats.add(statCard("${versions}", "发布版本", "more", "#409eff"))
        stats.add(statCard("${downloads}", "累计下载", "arrow-down", "#67c23a"))
        stats.add(statCard("${deletedPkgs}", "软删包", "circle-close", "#f56c6c"))
        stats.add(statCard("${users.size}", "注册用户", "user", "#e6a23c"))
        stats.add(statCard("${disabledUsers}", "禁用用户", "lock", "#f56c6c"))
        stats.add(statCard("${ups.size}", "上游总数", "arrow-up", "#409eff"))
        stats.add(statCard("${enabledUps}", "启用上游", "check", "#67c23a"))
        stats.add(statCard("${plans.size}", "发布计划", "calendar", "#9b59b6"))
        stats.add(statCard("${runningPlans}", "执行中", "loading", "#e6a23c"))
        stats.add(statCard("${logs.size}", "操作日志", "edit", "#909399"))
        stats.add(statCard("${failedLogs}", "失败操作", "error-filled", "#f56c6c"))
        // 最近操作
        let recentTable = Table<LogDoc>()
            .data(this.recentLogs)
            .stripe()
            .add(TableColumn<LogDoc>().label("时间").width(150).render({ l, i =>
                timeCell(formatLogTime(l.createdAt))
            }))
            .add(TableColumn<LogDoc>().label("操作者").accessor({ l => l.actorName }).width(110))
            .add(TableColumn<LogDoc>().label("操作").accessor({ l => l.action }).minWidth(260).showOverflowTooltip())
            .add(TableColumn<LogDoc>().label("对象").accessor({ l => l.target }).minWidth(150).showOverflowTooltip())
            .add(TableColumn<LogDoc>().label("结果").width(80).render({ l, i =>
                if (l.status == "ok") {
                    Tag([text("成功")]).kind(ComponentKind.Success)
                } else {
                    Tag([text("失败")]).kind(ComponentKind.Danger)
                }
            }))
        adminLayout("/admin", [
            div([text("仪表盘")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            div([text("仓库运行概览")], attrs: Some(HashMap<String, String>([("class", cls("page-subtitle"))]))),
            div(stats.toArray(), attrs: Some(HashMap<String, String>([("class", cls("stat-grid"))]))),
            adminCard("最近操作", [recentTable]),
        ])
    }
}

// 统计卡：左侧彩色圆底图标 + Statistic 指标，顶部色条
func statCard(value: String, label: String, icon: String, color: String): IComponent {
    div([
        div([
            div([
                Icon(icon).size("20px").color("#ffffff"),
            ], attrs: Some(HashMap<String, String>([("class", cls("stat-card-icon")), ("style", "background-color: ${color}")]))),
            div([
                Statistic()
                    .title(label)
                    .value(value)
                    .valueStyle("font-size: 26px; font-weight: 700; color: #303133"),
            ], attrs: Some(HashMap<String, String>([("class", cls("stat-card-text"))]))),
        ], attrs: Some(HashMap<String, String>([("class", cls("stat-card-inner"))]))),
    ], attrs: Some(HashMap<String, String>([("class", cls("stat-card")),
        ("style", "border-top: 3px solid ${color}")])))
}

// 秒级时间戳 → 可读时间（本地时区）
func formatLogTime(ms: Int64): String {
    if (ms <= 0) { return "-" }
    DateTime.fromUnixTimeStamp(Duration.millisecond * ms).inLocal().format("MM-dd HH:mm")
}

// 制品字节数 → 可读体积（版本列表/详情用）
func fmtSize(bytes: Int64): String {
    if (bytes <= 0) { return "-" }
    let k = 1024
    if (bytes < k) { return "${bytes} B" }
    if (bytes < k * k) { return "${bytes / k} KB" }
    if (bytes < k * k * k) { return "${bytes / (k * k)} MB" }
    return "${bytes / (k * k * k)} GB"
}

// 信号驱动的内容包装：cjxt 的 Dialog 保留首次构造的静态子节点（只有自带订阅的组件如 Table 才会更新），
// 所以对话框里的动态内容必须包在「组件 + 信号」里 —— 组件 render 时读信号会登记依赖，信号变即重渲染。
class SignalView <: Component {
    let build: () -> IComponent

    init(build: () -> IComponent) {
        this.build = build
    }

    public func render(): IComponent {
        this.build()
    }
}

// 时间单元格：不换行。时间戳里有空格（"09-16 00:24"），单元格宽度不足时会折成两行、
// 整张表跟着变高；列宽已按格式给足，这里再钉一次 white-space。
func timeCell(t: String): IComponent {
    div([text(t)], attrs: Some(HashMap<String, String>([("style", "white-space:nowrap;")])))
}

// 版本来源：回源镜像显示上游名，本地发布标出来
func versionSource(d: PackageDoc): String {
    if (d.upstreamId == 0) {
        return "本地发布"
    }
    if (d.upstreamName.isEmpty()) {
        return "上游 #${d.upstreamId}"
    }
    return "回源 · ${d.upstreamName}"
}

// ===== 上游管理 =====
@Page["/admin/upstreams", "上游管理", requireAdmin]
class UpstreamsPage <: Component {
    var state: Option<CjregState> = None
    // 行数据 + 分页（泛型 Table<Upstream>）
    var rows = Signal<ArrayList<Upstream>>(ArrayList<Upstream>())
    var currentPage = Signal<Int64>(1)
    var pageSize = Signal<Int64>(20)
    var total = Signal<Int64>(0)
    var msg = Signal<String>("")
    // 新增/编辑 Dialog
    var dialogVisible = Signal<Bool>(false)
    var dialogMode = Signal<String>("create")
    var editingId: Int64 = 0
    var formName = Signal<String>("")
    var formUrl = Signal<String>("")
    var formPriority = Signal<Int64>(0)
    var formCacheTtl = Signal<Int64>(86400)
    var formToken = Signal<String>("")
    var nameError = Signal<String>("")
    var urlError = Signal<String>("")
    var upForm = Form([])
    // 删除确认 Dialog
    var confirmVisible = Signal<Bool>(false)
    var pendingDeleteId: Int64 = 0
    // **必须是信号**：确认框正文是渲染时插值的，而"点删除"只让 Dialog 组件自己变脏
    //（页面并不读它）—— Dialog 的 children 是**页面渲染那一刻的快照**，用普通字段就会渲染出
    // 首次渲染时的空名字。做成信号 + SignalView 现读，才会显示当前对象名。
    var pendingDeleteName = Signal<String>("")

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        refresh()
    }

    // 分页切片（行数据直接为强类型 Upstream）
    func refresh(): Unit {
        match (this.state) {
            case Some(st) =>
                let list = st.upStore.listAll()
                this.total.set(list.size)
                let (start, end) = pageWindow(list.size, this.currentPage.get(), this.pageSize.get())
                let data = ArrayList<Upstream>()
                var i = start
                while (i < end) {
                    data.add(list[i])
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

    // ===== 表单 Dialog =====
    func openCreate(ctx: ActionContext): PatchResult {
        this.dialogMode.set("create")
        this.formName.set("")
        this.formUrl.set("")
        this.formPriority.set(0)
        this.formCacheTtl.set(86400)
        this.formToken.set("")
        this.nameError.set("")
        this.urlError.set("")
        this.dialogVisible.set(true)
        PatchResult.ReRender
    }

    func openEdit(ctx: ActionContext, id: Int64): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        match (st.upStore.getById(id)) {
            case Some(u) =>
                this.dialogMode.set("edit")
                this.editingId = u.id
                this.formName.set(u.name)
                this.formUrl.set(u.url)
                this.formPriority.set(u.priority)
                this.formCacheTtl.set(u.cacheTtl)
                this.formToken.set(u.authToken)
                this.nameError.set("")
                this.urlError.set("")
                this.dialogVisible.set(true)
            case None => ()
        }
        PatchResult.ReRender
    }

    func closeDialog(ctx: ActionContext): PatchResult {
        this.dialogVisible.set(false)
        PatchResult.ReRender
    }

    func submitForm(ctx: ActionContext): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            this.msg.set("无权限：需要管理员登录")
            return PatchResult.ReRender
        }
        if (!this.upForm.validate()) {
            return PatchResult.ReRender
        }
        let name = this.formName.get()
        let url = this.formUrl.get()
        let upSvc = UpstreamService(st.upStore)
        if (this.dialogMode.get() == "create") {
            match (upSvc.add(name, url, this.formPriority.get(), this.formToken.get(), this.formCacheTtl.get())) {
                case Some(u) =>
                    this.msg.set("已添加 ${u.name}")
                    st.adminData.addLog(LogKind.Admin, sessionUid(ctx), sessionUsername(ctx), "add upstream ${u.name}", "ok", nowMs())
                case None =>
                    this.msg.set("添加失败（名称已存在？）")
            }
        } else {
            if (upSvc.update(this.editingId, Option<Bool>.None, Some(this.formPriority.get()), Some(this.formCacheTtl.get()), Some(this.formToken.get()))) {
                this.msg.set("已更新上游 ${name}")
                st.adminData.addLog(LogKind.Admin, sessionUid(ctx), sessionUsername(ctx), "update upstream ${name}", "ok", nowMs())
            } else {
                this.msg.set("更新失败")
            }
        }
        this.dialogVisible.set(false)
        refresh()
        PatchResult.ReRender
    }

    // ===== 启用/禁用 =====
    func toggleEnabled(ctx: ActionContext, id: Int64): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            this.msg.set("无权限：需要管理员登录")
            return PatchResult.ReRender
        }
        match (st.upStore.getById(id)) {
            case Some(u) =>
                let upSvc = UpstreamService(st.upStore)
                if (upSvc.update(u.id, Some(!u.enabled), Option<Int64>.None, Option<Int64>.None, Option<String>.None)) {
                    this.msg.set(if (!u.enabled) { "已启用 ${u.name}" } else { "已禁用 ${u.name}" })
                    st.adminData.addLog(LogKind.Admin, sessionUid(ctx), sessionUsername(ctx), "toggle upstream ${u.name}", "ok", nowMs())
                }
            case None => ()
        }
        refresh()
        PatchResult.ReRender
    }

    // ===== 删除（确认） =====
    func askDelete(ctx: ActionContext, id: Int64): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        match (st.upStore.getById(id)) {
            case Some(u) =>
                this.pendingDeleteId = u.id
                this.pendingDeleteName.set(u.name)
                this.confirmVisible.set(true)
            case None => ()
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
        let upSvc = UpstreamService(st.upStore)
        if (upSvc.remove(this.pendingDeleteId)) {
            this.msg.set("已删除 ${this.pendingDeleteName.get()}")
            st.adminData.addLog(LogKind.Admin, sessionUid(ctx), sessionUsername(ctx), "delete upstream ${this.pendingDeleteName.get()}", "ok", nowMs())
        } else {
            this.msg.set("删除失败（官方仓受保护）")
        }
        this.confirmVisible.set(false)
        this.pendingDeleteId = 0
        refresh()
        PatchResult.ReRender
    }

    // ===== 渲染 =====
    // 空态提示走 listBody 的固定槽位（见 layout.cj）：表格永远渲染，提示只是"有没有内容"
    func listHint(): String {
        if (this.rows.get().size == 0) {
            return "暂无上游，点击「新增上游」添加"
        }
        ""
    }

    func renderList(): IComponent {
        Table<Upstream>()
            .data(this.rows)
            .emptyText("暂无数据")
            .stripe()
            .add(TableColumn<Upstream>().label("ID").accessor({ u => u.id.toString() }).width(50))
            .add(TableColumn<Upstream>().label("名称").accessor({ u => u.name }).minWidth(130))
            .add(TableColumn<Upstream>().label("URL").accessor({ u => u.url }).minWidth(220))
            .add(TableColumn<Upstream>().label("类型").width(80).render({ u, i =>
                if (u.isOfficial) {
                    Tag([text("官方")]).kind(ComponentKind.Primary)
                } else {
                    Tag([text("镜像")]).kind(ComponentKind.Warning)
                }
            }))
            .add(TableColumn<Upstream>().label("状态").width(80).render({ u, i =>
                if (u.enabled) {
                    Tag([text("启用")]).kind(ComponentKind.Success)
                } else {
                    Tag([text("禁用")]).kind(ComponentKind.Info)
                }
            }))
            .add(TableColumn<Upstream>().label("优先级").accessor({ u => u.priority.toString() }).width(80))
            .add(TableColumn<Upstream>().label("缓存").accessor({ u => "${u.cacheTtl}s" }).width(90))
            .add(TableColumn<Upstream>().label("最后同步").accessor({ u => if (u.lastSyncAt > 0) { u.lastSyncAt.toString() } else { "-" } }).minWidth(110))
            // 操作列：三个按钮要在一行内放下。minWidth 单独用不够 —— 单元格被压到小于按钮总宽时
            // 最后一个按钮会掉到第二行（实测「编辑 禁用」一行、「删除」另起一行），所以给足宽度
            // 并用不换行的 flex 容器排按钮。
            .add(TableColumn<Upstream>().label("操作").width(260).render({ u, i =>
                let id = u.id
                let editH: ActionHandler = { c => this.openEdit(c, id) }
                let toggleH: ActionHandler = { c => this.toggleEnabled(c, id) }
                let deleteH: ActionHandler = { c => this.askDelete(c, id) }
                div([
                    Button([text("编辑")]).size(ButtonSize.Small).onClick(editH),
                    Button([text(if (u.enabled) { "禁用" } else { "启用" })]).size(ButtonSize.Small).onClick(toggleH),
                    if (u.isOfficial) {
                        div()
                    } else {
                        Button([text("删除")]).size(ButtonSize.Small).kind(ButtonKind.Danger).onClick(deleteH)
                    },
                ], attrs: Some(HashMap<String, String>([("style", "display:flex;gap:8px;align-items:center;flex-wrap:nowrap;")])))
            }))
    }

    func renderFormDialog(): IComponent {
        let title = if (this.dialogMode.get() == "create") { "新增上游" } else { "编辑上游" }
        let isEdit = this.dialogMode.get() == "edit"
        let nameInput = if (isEdit) {
            Input().bind(this.formName).disabled()
        } else {
            Input().bind(this.formName)
        }
        let urlInput = if (isEdit) {
            Input().bind(this.formUrl).disabled()
        } else {
            Input().bind(this.formUrl)
        }
        let form = Form([
            FormItem([nameInput]).label("名称")
                .bindValue({ => this.formName.get() })
                .rule(FormRule(required: true, message: "名称必填"))
                .errorSignal(this.nameError),
            FormItem([urlInput]).label("URL")
                .bindValue({ => this.formUrl.get() })
                .rule(FormRule(required: true, message: "URL 必填"))
                .errorSignal(this.urlError),
            FormItem([InputNumber().bind(this.formPriority).min(0)]).label("优先级（小者优先）")
                .bindValue({ => this.formPriority.get().toString() }),
            FormItem([InputNumber().bind(this.formCacheTtl).min(0)]).label("缓存时间（秒）")
                .bindValue({ => this.formCacheTtl.get().toString() }),
            FormItem([Input().bind(this.formToken).placeholder("私有仓访问令牌").password()]).label("认证 Token（可选）")
                .bindValue({ => this.formToken.get() }),
        ]).labelTop()
        this.upForm = form
        let dlg = Dialog([form])
            .visible(this.dialogVisible)
            .title(title)
            .width("460px")
            .closeOnClickModal(false)
            .footer([
                Button([text("取消")]).onClick(closeDialog),
                Button([text("确定")]).kind(ButtonKind.Primary).onClick(submitForm),
            ])
        dlg
    }

    func renderConfirmDialog(): IComponent {
        // 正文走 SignalView：Dialog 的静态子节点是首次渲染的快照，直写会显示空名字
        let dlg = Dialog([
            SignalView({ =>
                div([text("确定要删除上游「${this.pendingDeleteName.get()}」吗？此操作不可恢复。")])
            }),
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
            Button([text("新增上游")]).kind(ButtonKind.Primary).onClick(openCreate),
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
        adminLayout("/admin/upstreams", [
            div([text("上游管理")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            adminCard("多仓上游配置", [toolbar, listBody(this.listHint(), this.renderList()), pager,
                this.renderFormDialog(), this.renderConfirmDialog()]),
        ])
    }
}

// ===== 包管理 =====
@Page["/admin/packages", "包管理", requireAdmin]
class PackagesPage <: Component {
    var state: Option<CjregState> = None
    // 主表（包）显示行：由 list_binding 的 Effect 从「数据版本 + 过滤 + 分页」信号派生。
    // 不能像旧实现那样把过滤结果缓存进 rows：render 不读过滤信号 → 表格永不重算，
    // 搜索看起来完全无效（详见 list_binding.cj 的根因说明）。
    var rows = Signal<ArrayList<PackageRow>>(ArrayList<PackageRow>())
    var search = Signal<String>("")
    var orgFilter = Signal<String>("all")
    var msg = Signal<String>("")
    // 数据版本：store 不是信号，写库后 bump 一次让派生重算
    var dataVersion = Signal<Int64>(0)
    // 分页
    var currentPage = Signal<Int64>(1)
    var pageSize = Signal<Int64>(20)
    var total = Signal<Int64>(0)
    // 选中的包（子表 = 该包的版本列表，走 Drawer 抽屉）。**必须是信号**：点「查看版本」是
    // 动作驱动的，而动作只写信号；页面上没人读它时不会产生任何补丁 —— 于是"点一下没反应"
    // （实测：浏览器里抽屉一直不出现，而单测直接调 select() + render() 是好的）。
    var selOrg = Signal<String>("")
    var selName = Signal<String>("")
    var verDrawerVisible = Signal<Bool>(false)
    // 版本列表：verAll 是全量（**倒序**，新版本在前），verRows 是当前页（bindPaged 派生）
    var verAll = Signal<ArrayList<PackageDoc>>(ArrayList<PackageDoc>())
    var verRows = Signal<ArrayList<PackageDoc>>(ArrayList<PackageDoc>())
    var verTitle = Signal<String>("")
    var verPage = Signal<Int64>(1)
    var verPageSize = Signal<Int64>(10)
    var verTotal = Signal<Int64>(0)
    // 删除确认（mode: soft = 软删可恢复；hard = 硬删不可恢复）
    var confirmVisible = Signal<Bool>(false)
    var pendingDeleteId: Int64 = 0
    // 同上游页：确认框正文要现读，否则显示首次渲染时的空名字（Dialog 保留静态子节点）
    var pendingDeleteName = Signal<String>("")
    var pendingMode = Signal<String>("soft")
    // 单版本详情对话框（含 README 全文）：doc 用信号承载，SignalView 才能跟着刷新
    var detailVisible = Signal<Bool>(false)
    var detailDoc = Signal<PackageDoc>(PackageDoc())
    // 重拉确认（force = 上游同版本 sha 已变，需二次确认覆盖）
    var refetchVisible = Signal<Bool>(false)
    var refetchDocId: Int64 = 0
    var refetchForce = Signal<Bool>(false)
    var refetchInfo = Signal<String>("")
    // 派生绑定：页面实例是路由注册期创建、跨请求复用的，onMount 必须重建，否则订阅会累积
    private var binding: Option<Effect> = None
    private var verBinding: Option<Effect> = None

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        this.rebind()
    }

    public func onUnmount(ctx: LifecycleContext): Unit {
        match (this.binding) {
            case Some(e) => e.dispose()
            case None => ()
        }
        match (this.verBinding) {
            case Some(e) => e.dispose()
            case None => ()
        }
        this.binding = None
        this.verBinding = None
    }

    private func rebind(): Unit {
        match (this.binding) {
            case Some(e) => e.dispose()
            case None => ()
        }
        match (this.verBinding) {
            case Some(e) => e.dispose()
            case None => ()
        }
        this.binding = Some(bindPaged(this.rows, this.total, { => this.filteredRows() },
            this.currentPage, this.pageSize))
        // 版本表分页：全量（倒序）按 10 条/页切片
        this.verBinding = Some(bindPaged(this.verRows, this.verTotal, { => this.verAll.get() },
            this.verPage, this.verPageSize))
    }

    // store 不是信号：写库后 bump 一次，主表派生自动重算
    func bump(): Unit {
        this.dataVersion.update({ v => v + 1 })
    }

    // 主表数据：按 org::name 分组 → 组织过滤 → 关键字过滤。
    // 这里读到的每个信号都会被 bindPaged 的 Effect 订阅，所以过滤条件一变就自动重算。
    func filteredRows(): ArrayList<PackageRow> {
        let _ = this.dataVersion.get()
        let st = match (this.state) {
            case Some(x) => x
            case None => return ArrayList<PackageRow>()
        }
        let all = groupPackages(st.pkgStore.storm.all<PackageDoc>())
        let q = this.search.get().trimAscii().toAsciiLower()
        let org = this.orgFilter.get()
        let out = ArrayList<PackageRow>()
        for (r in all) {
            if (org != "all" && r.organization != org) {
                continue
            }
            if (!matchesPackage(r, q)) {
                continue
            }
            out.add(r)
        }
        out
    }

    // 过滤条件变化时**不回写页码**：分页器的 total 是创建时的快照，页码一变它就变脏，
    // 同一批补丁里旧实例会重渲一次并排在页面补丁之后 → 把新的「共 N 条」顶回旧值。
    // 页越界由 bindPaged 本地钳制（分页器自己也会夹显示页），不回写同样不会错位。

    func doRefresh(ctx: ActionContext): PatchResult {
        this.bump()
        PatchResult.ReRender
    }

    func onPageChange(ctx: ActionContext): PatchResult {
        // 页码信号变了，派生会自动重算本页行；这里只需重画一次
        PatchResult.ReRender
    }

    // ===== 主子表：选中一个包 → 右栏列出它的版本 =====
    // 选中逻辑独立成无 ctx 的方法：渲染层测试可以直接驱动（动作只负责转调 + 重画）
    func select(org: String, name: String): Unit {
        this.selOrg.set(org)
        this.selName.set(name)
        match (this.state) {
            case Some(st) => this.refreshVersions(st, org, name)
            case None => ()
        }
        this.verDrawerVisible.set(true)
    }

    func closeVersionDrawer(ctx: ActionContext): PatchResult {
        this.verDrawerVisible.set(false)
        PatchResult.ReRender
    }

    func selectPackage(ctx: ActionContext, org: String, name: String): PatchResult {
        this.select(org, name)
        PatchResult.ReRender
    }

    // 刷新右栏版本表（软删/恢复/硬删/重拉后保持同步）
    func refreshVersions(st: CjregState, org: String, name: String): Unit {
        if (name == "") {
            return
        }
        // **先复位页码**：写页码会让"上一轮渲染留下的旧分页器实例"变脏，它的 total 是创建时的
        // 快照；先写页码，这条补丁就排在内容补丁之前，会被随后的抽屉内容覆盖（反过来写就会把
        // 新条数顶回旧值——这个坑在日志页踩过一次）。
        this.verPage.set(1)
        let data = ArrayList<PackageDoc>()
        for (d in st.pkgStore.listVersions(org, name)) {
            data.add(d)
        }
        // 倒序：新版本在前（库里是插入序，界面上"刚发的"要在最上面）
        sort(data, lessThan: { a, b => compareVersions(a.version, b.version) > 0 })
        this.verAll.set(data)
        this.verTitle.set("${pkgKeyText(org, name)} 的版本（${data.size}）")
    }

    // ===== 三级删除：软删 / 恢复 / 硬删 =====
    func askDelete(ctx: ActionContext, id: Int64, name: String, version: String): PatchResult {
        this.pendingDeleteId = id
        this.pendingDeleteName.set("${name}@${version}")
        this.pendingMode.set("soft")
        this.confirmVisible.set(true)
        PatchResult.ReRender
    }

    func askHardDelete(ctx: ActionContext, id: Int64, name: String, version: String): PatchResult {
        this.pendingDeleteId = id
        this.pendingDeleteName.set("${name}@${version}")
        this.pendingMode.set("hard")
        this.confirmVisible.set(true)
        PatchResult.ReRender
    }

    // 恢复（校验制品仍在）：无需二次确认，直接执行并提示
    func doRestore(ctx: ActionContext, id: Int64, name: String, version: String): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            this.msg.set("无权限：需要管理员登录")
            return PatchResult.ReRender
        }
        let doc = match (st.pkgStore.getById(id)) {
            case Some(d) => d
            case None =>
                this.msg.set("版本不存在")
                return PatchResult.ReRender
        }
        let blobs: BlobStore = match (st.blobStore) {
            case Some(b) => b
            case None => MemoryBlobStore()
        }
        let r = restoreVersion(st.pkgStore, blobs, doc)
        let target = "${name}@${version}"
        if (r.outcome == LifecycleOutcome.Ok) {
            this.msg.set("已恢复 ${target}")
            uiAudit(st, ctx, "restore_package", target, detail: "artifactPresent=${r.artifactPresent}")
        } else {
            this.msg.set("恢复失败：${r.message}")
            uiAudit(st, ctx, "restore_package", target, status: "failed", error: r.message)
        }
        this.refreshVersions(st, this.selOrg.get(), this.selName.get())
        this.bump()
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
        let doc = match (st.pkgStore.getById(this.pendingDeleteId)) {
            case Some(d) => d
            case None =>
                this.confirmVisible.set(false)
                this.pendingDeleteId = 0
                this.msg.set("版本不存在")
                return PatchResult.ReRender
        }
        let now = nowMs()
        let hard = this.pendingMode.get() == "hard"
        var r: LifecycleResult
        var action = "delete_package"
        if (hard) {
            match (st.blobStore) {
                case Some(blobs) =>
                    action = "hard_delete_package"
                    r = hardDeleteVersion(st.pkgStore, blobs, Some(st.adminData), doc, now)
                case None =>
                    // 未注入制品库时拒绝硬删，避免删了记录却留下孤儿制品
                    this.confirmVisible.set(false)
                    this.pendingDeleteId = 0
                    this.msg.set("硬删除不可用：该进程未注入制品库")
                    return PatchResult.ReRender
            }
        } else {
            r = softDeleteVersion(st.pkgStore, Some(st.adminData), doc, now)
        }
        let target = this.pendingDeleteName.get()
        let detail = "skippedPlanItems=${r.skippedPlanItems} blobRemoved=${r.blobRemoved}"
        if (r.outcome == LifecycleOutcome.Ok || r.outcome == LifecycleOutcome.AlreadyDeleted) {
            this.msg.set("${if (hard) { "已硬删除" } else { "已软删除（可恢复）" }} ${target}")
            uiAudit(st, ctx, action, target, detail: detail)
        } else {
            this.msg.set("删除失败：${r.message}")
            uiAudit(st, ctx, action, target, status: "failed", error: r.message, detail: detail)
        }
        this.confirmVisible.set(false)
        this.pendingDeleteId = 0
        this.refreshVersions(st, this.selOrg.get(), this.selName.get())
        this.bump()
        PatchResult.ReRender
    }

    // ===== 单版本详情 =====
    func showDetail(ctx: ActionContext, id: Int64): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        match (st.pkgStore.getById(id)) {
            case Some(d) =>
                this.detailDoc.set(d)
                this.detailVisible.set(true)
            case None => this.msg.set("版本不存在")
        }
        PatchResult.ReRender
    }

    func closeDetail(ctx: ActionContext): PatchResult {
        this.detailVisible.set(false)
        PatchResult.ReRender
    }

    // ===== 上游重拉（覆盖本地缓存）=====
    // 第一次点「重拉」→ 确认框；上游同版本 sha 已变时后端返回 sha_changed，再弹一次带 force 的确认
    func askRefetch(ctx: ActionContext, id: Int64, name: String, version: String, force: Bool, info: String): PatchResult {
        this.refetchDocId = id
        this.refetchForce.set(force)
        this.refetchInfo.set(info)
        this.refetchVisible.set(true)
        PatchResult.ReRender
    }

    func cancelRefetch(ctx: ActionContext): PatchResult {
        this.refetchVisible.set(false)
        this.refetchDocId = 0
        PatchResult.ReRender
    }

    func doRefetch(ctx: ActionContext): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            this.msg.set("无权限：需要管理员登录")
            return PatchResult.ReRender
        }
        let proxy = match (st.proxySvc) {
            case Some(p) => p
            case None =>
                this.refetchVisible.set(false)
                this.msg.set("重拉不可用：该进程未注入回源代理")
                return PatchResult.ReRender
        }
        let doc = match (st.pkgStore.getById(this.refetchDocId)) {
            case Some(d) => d
            case None =>
                this.refetchVisible.set(false)
                this.msg.set("版本不存在")
                return PatchResult.ReRender
        }
        let force = this.refetchForce.get()
        let target = "${doc.name}@${doc.version}"
        let r = refetchVersion(proxy, doc, force)
        let detail = "upstream=${r.upstreamName} old=${shortSha(r.oldSha)} new=${shortSha(r.newSha)} " +
            "changed=${r.changed} force=${force}"
        match (r.outcome) {
            case RefetchOutcome.Ok =>
                this.msg.set("已重拉 ${target}（${if (r.changed) { "内容已更新" } else { "内容一致" }}，${fmtSize(r.size)}）")
                uiAudit(st, ctx, "refetch_package", target, detail: detail)
                this.refetchVisible.set(false)
                this.refetchDocId = 0
            case RefetchOutcome.ShaChanged =>
                // 上游同版本内容变了：二次确认（force）后才覆盖
                this.refetchInfo.set(r.message)
                this.refetchForce.set(true)
                this.msg.set("上游同版本内容已变，请确认后覆盖")
            case _ =>
                this.msg.set("重拉失败：${r.message}")
                uiAudit(st, ctx, "refetch_package", target, status: "failed", error: r.message, detail: detail)
                this.refetchVisible.set(false)
                this.refetchDocId = 0
        }
        this.refreshVersions(st, this.selOrg.get(), this.selName.get())
        this.bump()
        PatchResult.ReRender
    }

    // ===== 单版本详情对话框 =====
    func renderDetailDialog(): IComponent {
        let dlg = Dialog([
            SignalView({ => this.buildDetailBody() }),
        ])
            .visible(this.detailVisible)
            .title("版本详情")
            .width("860px")
            .closeOnClickModal(false)
            .footer([
                Button([text("关闭")]).onClick(closeDetail),
            ])
        dlg
    }

    // 详情正文（每次重渲染都按当前 detailDoc 重建）
    func buildDetailBody(): IComponent {
        let d = this.detailDoc.get()
        func kv(label: String, value: String): IComponent {
            div([
                span([text(label)], attrs: Some(HashMap<String, String>([("class", cls("kv-label"))]))),
                span([text(if (value.isEmpty()) { "-" } else { value })]),
            ], attrs: Some(HashMap<String, String>([("class", cls("kv-row"))])))
        }
        let full = if (d.organization.isEmpty()) { d.name } else { "${d.organization}::${d.name}" }
        let head = ArrayList<IComponent>()
        head.add(kv("完整包名", full))
        head.add(kv("版本", d.version))
        head.add(kv("来源", versionSource(d)))
        head.add(kv("大小", fmtSize(d.tarballSize)))
        head.add(kv("sha256", d.sha256))
        head.add(kv("下载次数", d.downloadCount.toString()))
        head.add(kv("发布者", if (d.publisherId > 0) { "#${d.publisherId}" } else { "-" }))
        head.add(kv(if (d.upstreamId == 0) { "发布于" } else { "收录于" }, formatLogTime(versionTimeMs(d))))
        head.add(kv("记录更新", formatLogTime(d.updatedAt)))
        head.add(kv("SDK 版本", d.cjcVersion))
        head.add(kv("描述", d.description))
        head.add(kv("协议", joinList(d.license)))
        head.add(kv("作者", joinList(d.authors)))
        head.add(kv("标签", joinList(d.tag)))
        head.add(kv("分类", joinList(d.category)))
        head.add(kv("仓库", d.repository))
        head.add(kv("主页 / 文档", "${d.homepage} ${d.documentation}".trimAscii()))
        head.add(kv("状态", if (d.deletedAt != 0) { "已软删除" } else { "正常" }))
        let readmePart: IComponent = if (d.readme.isEmpty()) {
            div([text("（该版本没有提取到 README —— 制品内没有 README.md/README_zh.md，或制品不是可解压的 .cjp）")])
        } else {
            Markdown().content(d.readme)
        }
        // README 可能很长：正文自己滚动（对话框本身不滚，否则底部按钮会跑出视口）
        div([
            div([text("${full}@${d.version}")],
                attrs: Some(HashMap<String, String>([("class", cls("dialog-section"))]))),
            div(head.toArray(), attrs: Some(HashMap<String, String>([("class", cls("kv-block"))]))),
            div([text("README（${d.readme.size} 字节）")],
                attrs: Some(HashMap<String, String>([("class", cls("dialog-section"))]))),
            readmePart,
        ], attrs: Some(HashMap<String, String>([("class", cls("detail-scroll"))])))
    }

    // ===== 重拉确认对话框 =====
    // 标题/按钮文案取常量（Dialog 的静态子节点是首次渲染快照），动态内容一律放进 SignalView
    func renderRefetchDialog(): IComponent {
        let dlg = Dialog([
            SignalView({ => this.buildRefetchBody() }),
        ])
            .visible(this.refetchVisible)
            .title("重拉确认")
            .width("560px")
            .closeOnClickModal(false)
            .footer([
                Button([text("取消")]).onClick(cancelRefetch),
                Button([text("重拉")]).kind(ButtonKind.Warning).onClick(doRefetch),
            ])
        dlg
    }

    // 重拉确认正文（force = 上游同版本 sha 已变，需二次确认覆盖）
    func buildRefetchBody(): IComponent {
        let force = this.refetchForce.get()
        if (force) {
            return div([
                div([text("⚠ 上游同版本的内容已经变了。")]),
                div([text(this.refetchInfo.get())]),
                div([text("继续将用上游内容覆盖本地该版本（sha、制品、README、展示字段都会刷新）；" +
                    "下载过旧内容的客户端不会自动感知。")]),
            ])
        }
        div([
            div([text("将按上游内容重新拉取该版本，并覆盖本地缓存的制品与元数据。")]),
            div([text("本地该版本的下载计数、发布者、创建时间保持不变；上游不可达时不会改动本地。")]),
        ])
    }

    // 删除确认正文（现读信号：模式与对象名都可能在上一次渲染之后才变）
    func buildConfirmBody(): IComponent {
        if (this.pendingMode.get() == "hard") {
            return div([
                div([text("确定要硬删除「${this.pendingDeleteName.get()}」吗？")]),
                div([text("将同时删除制品文件（若仍被其它版本引用则保留），且不可恢复——请确认该版本已软删且无人依赖。")]),
            ])
        }
        div([
            div([text("确定要软删除「${this.pendingDeleteName.get()}」吗？")]),
            div([text("索引/下载/公开 API 立即不可见，可在包列表随时恢复。")]),
        ])
    }

    func renderConfirmDialog(): IComponent {
        let hard = this.pendingMode.get() == "hard"
        // 正文与标题都走 SignalView/现读：Dialog 的静态子节点与 title 是**首次渲染**的快照，
        // 而"点删除"只会让 Dialog 组件自己变脏（页面并不读它）→ 直写会显示空名字/旧标题。
        let dlg = Dialog([SignalView({ => this.buildConfirmBody() })])
            .visible(this.confirmVisible)
            .header([SignalView({ =>
                div([text(if (this.pendingMode.get() == "hard") { "硬删除确认" } else { "软删除确认" })])
            })])
            .width("460px")
            .closeOnClickModal(false)
            .footer([
                Button([text("取消")]).onClick(cancelDelete),
                Button([text(if (hard) { "硬删除" } else { "软删除" })]).kind(ButtonKind.Danger).onClick(confirmDelete),
            ])
        dlg
    }

    // ===== 渲染：左主（包）右子（版本）=====
    func listHint(): String {
        if (this.rows.get().size == 0) {
            return "没有匹配的包"
        }
        ""
    }

    func renderList(): IComponent {
        Table<PackageRow>()
            .data(this.rows)
            .emptyText("暂无数据")
            .stripe()
            // 包名给固定宽度就够（原先的 minWidth 让它把整行留白全吃掉）；多出来的空间给「描述」列
            .add(TableColumn<PackageRow>().label("包").width(220).render({ r, i =>
                let label = pkgKeyText(r.organization, r.name)
                let curOrg = this.selOrg.get()
                let curName = this.selName.get()
                let sel = curOrg == r.organization && curName == r.name
                if (sel) {
                    Tag([text("● " + label)]).kind(ComponentKind.Primary)
                } else {
                    text(label)
                }
            }).showOverflowTooltip())
            .add(TableColumn<PackageRow>().label("描述").accessor({ r => r.latestDesc }).minWidth(220).showOverflowTooltip())
            .add(TableColumn<PackageRow>().label("最新版本").accessor({ r => r.latestVersion }).width(100))
            .add(TableColumn<PackageRow>().label("版本数").accessor({ r => r.versionCount.toString() }).width(76))
            .add(TableColumn<PackageRow>().label("下载").accessor({ r => r.downloadCount.toString() }).width(70))
            // 时间戳是 'MM-DD HH:MM'：96px 放不下会折成"日期 / 时间"两行，加宽并禁止换行
            .add(TableColumn<PackageRow>().label("最近更新").width(122).render({ r, i => timeCell(formatLogTime(r.updatedAt)) }))
            .add(TableColumn<PackageRow>().label("状态").width(76).render({ r, i =>
                if (r.allDeleted) {
                    Tag([text("已删")]).kind(ComponentKind.Danger)
                } else {
                    Tag([text("正常")]).kind(ComponentKind.Success)
                }
            }))
            .add(TableColumn<PackageRow>().label("操作").width(110).render({ r, i =>
                let org = r.organization
                let name = r.name
                let h: ActionHandler = { c => this.selectPackage(c, org, name) }
                Button([text("查看版本")]).size(ButtonSize.Small).onClick(h)
            }))
    }

    // 版本列表用 **Drawer（抽屉）**：同页左右分栏在窄屏（手机）会被挤到换行，宽屏上主表的
    // 包名那一列又会被拉着填满整行；抽屉从右侧滑出，主表就能占满整行。
    //
    // 抽屉内容必须包在 SignalView 里：Drawer 的 children 是**页面渲染那一刻的快照**，而"打开抽屉"
    // 本身会让 Drawer 组件变脏 —— 同一批补丁里父页面与子组件都会脏、子补丁后应用，直接塞表格
    // 就会渲染出上一次选择的内容。SignalView 在 render 里现读信号，谁后渲染都是新值。
    func renderVersionDrawer(): IComponent {
        Drawer([SignalView({ =>
            div([
                // 表格外面包一层：① `position:relative; z-index:2` 让下拉面板浮在分页器之上
                //（单元格 td 自带 z-index:1 的层叠上下文，面板的 z-index 再高出不去）；
                // ② `version-table-wrap` 放开表格容器的 overflow —— 版本表不需要横向滚动，
                // 而 EP 的表格容器是 `position:relative + overflow:hidden`、在面板包含块链上，
                // 不放开就会把下拉面板裁在表体下沿（实测点到的还是分页器）。
                listBody(this.versionHint(),
                    div([this.renderVersionTable()],
                        attrs: Some(HashMap<String, String>([
                            ("class", cls("version-table-wrap")),
                            ("style", "position:relative;z-index:2;")])))),
                this.renderVersionPager(),
            ])
        })])
            .visible(this.verDrawerVisible)
            .direction(DrawerDirection.RTL)
            .size("min(94vw, 880px)")
            .header([SignalView({ => div([text(this.verTitle.get())]) })])
            .footer([Button([text("关闭")]).onClick(closeVersionDrawer)])
    }

    // 版本行「操作」菜单的命令分发：命令字符串来自 DropdownItem().command(...)，
    // ctx 来自 cjxt Dropdown 的 onCommandCtx（菜单项点击本身就在一个 action 里）。
    // 删除/重拉/恢复这些动作要版本号与包名，从当前全量列表里按 id 现取，避免把状态塞进命令串。
    func onVersionCommand(ctx: ActionContext, id: Int64, cmd: String): Unit {
        var name = ""
        var version = ""
        for (d in this.verAll.get()) {
            if (d.id == id) {
                name = d.name
                version = d.version
            }
        }
        let _ = match (cmd) {
            case "detail" => this.showDetail(ctx, id)
            case "refetch" => this.askRefetch(ctx, id, name, version, false, "")
            case "soft" => this.askDelete(ctx, id, name, version)
            case "restore" => this.doRestore(ctx, id, name, version)
            case "hard" => this.askHardDelete(ctx, id, name, version)
            case _ => PatchResult.ReRender
        }
    }

    // 版本表分页（10 条/页）：版本多的包（mcp 19、jsonrpc 16）一屏放不下。
    // 分页器整块在 SignalView 里，total 是现读的，不会出现"条数停在上一包"的旧快照问题。
    func renderVersionPager(): IComponent {
        Pagination()
            .currentPage(this.verPage)
            .pageSize(this.verPageSize)
            .pageSizes([10, 20, 50])
            .total(this.verTotal.get())
            .layout("total, prev, pager, next, sizes")
    }

    func versionHint(): String {
        if (this.verAll.get().size == 0) {
            return "该包还没有版本记录"
        }
        ""
    }

    func renderVersionTable(): IComponent {
        Table<PackageDoc>()
            .data(this.verRows)
            .emptyText("暂无数据")
            .stripe()
            .add(TableColumn<PackageDoc>().label("版本").accessor({ d => d.version }).width(96))
            .add(TableColumn<PackageDoc>().label("来源").width(108).render({ d, i =>
                if (d.upstreamId == 0) {
                    Tag([text("本地发布")]).kind(ComponentKind.Primary)
                } else {
                    Tag([text(versionSource(d))]).kind(ComponentKind.Warning)
                }
            }))
            .add(TableColumn<PackageDoc>().label("大小").accessor({ d => fmtSize(d.tarballSize) }).width(68))
            .add(TableColumn<PackageDoc>().label("sha256").accessor({ d => shortSha(d.sha256) }).width(104))
            .add(TableColumn<PackageDoc>().label("时间").width(110).render({ d, i => timeCell(formatLogTime(versionTimeMs(d))) }))
            .add(TableColumn<PackageDoc>().label("下载").accessor({ d => d.downloadCount.toString() }).width(56))
            .add(TableColumn<PackageDoc>().label("状态").width(62).render({ d, i =>
                if (d.deletedAt != 0) {
                    Tag([text("已删")]).kind(ComponentKind.Danger)
                } else {
                    Tag([text("正常")]).kind(ComponentKind.Success)
                }
            }))
            // 操作收进下拉菜单（cjxt Dropdown）：抽屉里列宽有限，横排按钮会折行。
            // 用 onCommandCtx 而不是 onCommand —— 这些动作要按操作者鉴权（isAdminSession）与写审计
            // （sessionUid/sessionUsername），没有 ctx 就只能瞎记或自己再拼一份下拉结构。
            .add(TableColumn<PackageDoc>().label("操作").width(92).render({ d, i =>
                let id = d.id
                let items = ArrayList<IComponent>()
                items.add(DropdownItem().content("详情").command("detail"))
                if (d.deletedAt != 0) {
                    items.add(DropdownItem().content("恢复").command("restore"))
                    items.add(DropdownItem().content("硬删除").command("hard"))
                } else {
                    // 重拉只对回源镜像版本开放（本地发布的版本本地才是权威）
                    if (d.upstreamId != 0) {
                        items.add(DropdownItem().content("重拉").command("refetch"))
                    }
                    items.add(DropdownItem().content("软删除").command("soft"))
                }
                let onCmd: (ActionContext, String) -> Unit = { ctx, cmd => this.onVersionCommand(ctx, id, cmd) }
                Dropdown(Button([text("操作")]).size(ButtonSize.Small))
                    .menu(items.toArray())
                    .onCommandCtx(onCmd)
            }))
    }

    public func render(): IComponent {
        let st = match (this.state) {
            case Some(x) => x
            case None => return div()
        }
        let orgOptions = ArrayList<IComponent>()
        orgOptions.add(SelectOption([text("全部组织")], "all"))
        let seen = ArrayList<String>()
        for (d in st.pkgStore.storm.all<PackageDoc>()) {
            var dup = false
            for (s in seen) {
                if (s == d.organization) {
                    dup = true
                    break
                }
            }
            if (!dup && d.organization != "") {
                orgOptions.add(SelectOption([text(d.organization)], d.organization))
                seen.add(d.organization)
            }
        }
        let toolbar = div([
            // 搜索框**只 bind，绝不能同时挂 input 动作**：动作会在输入的那一刻就回一次
            // 服务端并推回补丁，而补丁应用完会把客户端的 bindDirty 守卫清掉、把输入框的值
            // 退回服务端旧值（cjxt public/js/cangjie-ui.js:710）——300ms 后才发的 bind 于是
            // 把**空串**写回信号，表现就是"打字完全没反应"。回第一页由 bindPaged 本地钳制
            // （页越界只影响切片，Pagination 自己会把显示页夹进有效范围）。
            Input().bind(this.search).placeholder("搜索包名 / 组织 / 描述"),
            // 只 bind：改条件不回写页码（见下面 resetPage 处的说明）
            Select(orgOptions.toArray()).bind(this.orgFilter).placeholder("组织"),
            Button([text("刷新")]).onClick(doRefresh),
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
        // 主子表：左主（包，带分页）右子（该包的版本）
        adminLayout("/admin/packages", [
            div([text("包管理")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            adminCard("已发布包", [toolbar, listBody(this.listHint(), this.renderList()), pager,
                this.renderDetailDialog(), this.renderRefetchDialog(), this.renderConfirmDialog(),
                this.renderVersionDrawer()]),
        ])
    }
}
