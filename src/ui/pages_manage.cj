// cjxt 管理界面页面：仪表盘 / 上游管理 / 包管理
package ystyle::cjreg.ui

import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import ystyle::cjreg.store.*
import ystyle::cjreg.config.*
import ystyle::cjreg.server.*
import std.collection.*
import std.convert.*
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
                text(formatLogTime(l.createdAt))
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
    var pendingDeleteName: String = ""

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
                this.pendingDeleteName = u.name
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
            this.msg.set("已删除 ${this.pendingDeleteName}")
            st.adminData.addLog(LogKind.Admin, sessionUid(ctx), sessionUsername(ctx), "delete upstream ${this.pendingDeleteName}", "ok", nowMs())
        } else {
            this.msg.set("删除失败（官方仓受保护）")
        }
        this.confirmVisible.set(false)
        this.pendingDeleteId = 0
        refresh()
        PatchResult.ReRender
    }

    // ===== 渲染 =====
    func renderList(): IComponent {
        if (this.rows.get().size == 0) {
            return emptyState("暂无上游，点击「新增上游」添加")
        }
        Table<Upstream>()
            .data(this.rows)
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
            .add(TableColumn<Upstream>().label("操作").minWidth(280).render({ u, i =>
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
                ])
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
        let dlg = Dialog([
            div([text("确定要删除上游「${this.pendingDeleteName}」吗？此操作不可恢复。")]),
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
            adminCard("多仓上游配置", [toolbar, this.renderList(), pager, this.renderFormDialog(), this.renderConfirmDialog()]),
        ])
    }
}

// ===== 包管理 =====
@Page["/admin/packages", "包管理", requireAdmin]
class PackagesPage <: Component {
    var state: Option<CjregState> = None
    // 行数据 + 分页（泛型 Table<PackageDoc>）
    var rows = Signal<ArrayList<PackageDoc>>(ArrayList<PackageDoc>())
    var search = Signal<String>("")
    var orgFilter = Signal<String>("all")
    var msg = Signal<String>("")
    // 分页
    var currentPage = Signal<Int64>(1)
    var pageSize = Signal<Int64>(20)
    var total = Signal<Int64>(0)
    // 版本对话框
    var verDialogVisible = Signal<Bool>(false)
    var verRows = Signal<ArrayList<PackageDoc>>(ArrayList<PackageDoc>())
    var verTitle = Signal<String>("")
    // 删除确认（mode: soft = 软删可恢复；hard = 硬删不可恢复）
    var confirmVisible = Signal<Bool>(false)
    var pendingDeleteId: Int64 = 0
    var pendingDeleteName: String = ""
    var pendingMode = Signal<String>("soft")
    // 单版本详情对话框（含 README 全文）：doc 用信号承载，SignalView 才能跟着刷新
    var detailVisible = Signal<Bool>(false)
    var detailDoc = Signal<PackageDoc>(PackageDoc())
    // 重拉确认（force = 上游同版本 sha 已变，需二次确认覆盖）
    var refetchVisible = Signal<Bool>(false)
    var refetchDocId: Int64 = 0
    var refetchForce = Signal<Bool>(false)
    var refetchInfo = Signal<String>("")

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        refresh()
    }

    func refresh(): Unit {
        match (this.state) {
            case Some(st) =>
                let all = st.pkgStore.storm.all<PackageDoc>()
                let filtered = ArrayList<PackageDoc>()
                for (d in all) {
                    if (this.orgFilter.get() != "all" && d.organization != this.orgFilter.get()) {
                        continue
                    }
                    if (this.search.get() != "" && !d.name.contains(this.search.get())) {
                        continue
                    }
                    filtered.add(d)
                }
                this.total.set(filtered.size)
                let (start, end) = pageWindow(filtered.size, this.currentPage.get(), this.pageSize.get())
                let data = ArrayList<PackageDoc>()
                var i = start
                while (i < end) {
                    data.add(filtered[i])
                    i++
                }
                this.rows.set(data)
            case None => ()
        }
    }

    func doRefresh(ctx: ActionContext): PatchResult {
        this.refresh()
        PatchResult.ReRender
    }

    func onPageChange(ctx: ActionContext): PatchResult {
        this.refresh()
        PatchResult.ReRender
    }

    // ===== 版本对话框 =====
    func showVersions(ctx: ActionContext, org: String, name: String): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        let versions = st.pkgStore.listVersions(org, name)
        let data = ArrayList<PackageDoc>()
        for (d in versions) {
            data.add(d)
        }
        this.verTitle.set("${name} 版本列表（${data.size}）")
        this.verRows.set(data)
        this.verDialogVisible.set(true)
        PatchResult.ReRender
    }

    func closeVersions(ctx: ActionContext): PatchResult {
        this.verDialogVisible.set(false)
        PatchResult.ReRender
    }

    // ===== 三级删除：软删 / 恢复 / 硬删 =====
    func askDelete(ctx: ActionContext, id: Int64, name: String, version: String): PatchResult {
        this.pendingDeleteId = id
        this.pendingDeleteName = "${name}@${version}"
        this.pendingMode.set("soft")
        this.confirmVisible.set(true)
        PatchResult.ReRender
    }

    func askHardDelete(ctx: ActionContext, id: Int64, name: String, version: String): PatchResult {
        this.pendingDeleteId = id
        this.pendingDeleteName = "${name}@${version}"
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
        this.refreshVersions(st)
        refresh()
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
        let target = this.pendingDeleteName
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
        this.refreshVersions(st)
        refresh()
        PatchResult.ReRender
    }

    // 刷新版本对话框数据（软删/恢复/硬删后保持对话框同步）
    func refreshVersions(st: CjregState): Unit {
        if (!this.verDialogVisible.get()) {
            return
        }
        let cur = this.verRows.get()
        if (cur.size == 0) {
            return
        }
        let org = cur[0].organization
        let name = cur[0].name
        let data = ArrayList<PackageDoc>()
        for (d in st.pkgStore.listVersions(org, name)) {
            data.add(d)
        }
        this.verRows.set(data)
        this.verTitle.set("${name} 版本列表（${data.size}）")
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
                // 收起版本列表：两个对话框同时开会把 footer 叠在一起（关闭按钮重影）
                this.verDialogVisible.set(false)
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
        this.refreshVersions(st)
        refresh()
        PatchResult.ReRender
    }

    // ===== 渲染 =====
    func renderList(): IComponent {
        if (this.rows.get().size == 0) {
            return emptyState("暂无包数据")
        }
        Table<PackageDoc>()
            .data(this.rows)
            .stripe()
            .add(TableColumn<PackageDoc>().label("ID").accessor({ d => d.id.toString() }).width(60))
            .add(TableColumn<PackageDoc>().label("组织").accessor({ d => d.organization }).width(110))
            .add(TableColumn<PackageDoc>().label("包名").accessor({ d => d.name }).minWidth(140))
            .add(TableColumn<PackageDoc>().label("版本").accessor({ d => d.version }).width(110))
            .add(TableColumn<PackageDoc>().label("下载").accessor({ d => d.downloadCount.toString() }).width(80))
            .add(TableColumn<PackageDoc>().label("状态").width(80).render({ d, i =>
                if (d.deletedAt != 0) {
                    Tag([text("已删")]).kind(ComponentKind.Danger)
                } else {
                    Tag([text("正常")]).kind(ComponentKind.Success)
                }
            }))
            .add(TableColumn<PackageDoc>().label("操作").minWidth(320).render({ d, i =>
                let org = d.organization
                let name = d.name
                let version = d.version
                let id = d.id
                let deleted = d.deletedAt != 0
                let versionsH: ActionHandler = { c => this.showVersions(c, org, name) }
                let deleteH: ActionHandler = { c => this.askDelete(c, id, name, version) }
                let restoreH: ActionHandler = { c => this.doRestore(c, id, name, version) }
                let hardH: ActionHandler = { c => this.askHardDelete(c, id, name, version) }
                if (deleted) {
                    // 已软删：恢复（校验制品仍在）或硬删（记录 + 制品，不可恢复）
                    div([
                        Button([text("恢复")]).size(ButtonSize.Small).kind(ButtonKind.Success).onClick(restoreH),
                        Button([text("硬删除")]).size(ButtonSize.Small).kind(ButtonKind.Danger).onClick(hardH),
                    ])
                } else {
                    div([
                        Button([text("版本")]).size(ButtonSize.Small).onClick(versionsH),
                        Button([text("软删除")]).size(ButtonSize.Small).kind(ButtonKind.Danger).onClick(deleteH),
                    ])
                }
            }))
    }

    func renderVersionDialog(): IComponent {
        let table = Table<PackageDoc>()
            .data(this.verRows)
            .stripe()
            .add(TableColumn<PackageDoc>().label("ID").accessor({ d => d.id.toString() }).width(56))
            .add(TableColumn<PackageDoc>().label("版本").accessor({ d => d.version }).width(96))
            .add(TableColumn<PackageDoc>().label("来源").width(130).render({ d, i =>
                if (d.upstreamId == 0) {
                    Tag([text("本地发布")]).kind(ComponentKind.Primary)
                } else {
                    Tag([text(versionSource(d))]).kind(ComponentKind.Warning)
                }
            }))
            .add(TableColumn<PackageDoc>().label("大小").accessor({ d => fmtSize(d.tarballSize) }).width(80))
            .add(TableColumn<PackageDoc>().label("sha256").accessor({ d => shortSha(d.sha256) }).width(110))
            .add(TableColumn<PackageDoc>().label("时间").accessor({ d => formatLogTime(versionTimeMs(d)) }).width(96))
            .add(TableColumn<PackageDoc>().label("下载").accessor({ d => d.downloadCount.toString() }).width(64))
            .add(TableColumn<PackageDoc>().label("状态").width(70).render({ d, i =>
                if (d.deletedAt != 0) {
                    Tag([text("已删")]).kind(ComponentKind.Danger)
                } else {
                    Tag([text("正常")]).kind(ComponentKind.Success)
                }
            }))
            .add(TableColumn<PackageDoc>().label("操作").minWidth(240).render({ d, i =>
                let name = d.name
                let version = d.version
                let id = d.id
                let restoreH: ActionHandler = { c => this.doRestore(c, id, name, version) }
                let hardH: ActionHandler = { c => this.askHardDelete(c, id, name, version) }
                let deleteH: ActionHandler = { c => this.askDelete(c, id, name, version) }
                let detailH: ActionHandler = { c => this.showDetail(c, id) }
                let refetchH: ActionHandler = { c => this.askRefetch(c, id, name, version, false, "") }
                if (d.deletedAt != 0) {
                    div([
                        Button([text("详情")]).size(ButtonSize.Small).onClick(detailH),
                        Button([text("恢复")]).size(ButtonSize.Small).kind(ButtonKind.Success).onClick(restoreH),
                        Button([text("硬删除")]).size(ButtonSize.Small).kind(ButtonKind.Danger).onClick(hardH),
                    ])
                } else {
                    div([
                        Button([text("详情")]).size(ButtonSize.Small).onClick(detailH),
                        // 重拉只对回源镜像版本开放（本地发布的版本本地才是权威）
                        if (d.upstreamId != 0) {
                            Button([text("重拉")]).size(ButtonSize.Small).kind(ButtonKind.Warning).onClick(refetchH)
                        } else {
                            div()
                        },
                        Button([text("软删除")]).size(ButtonSize.Small).kind(ButtonKind.Danger).onClick(deleteH),
                    ])
                }
            }))
        let dlg = Dialog([
            // 动态标题必须信号驱动：Dialog.title 与静态子节点都是首次渲染的快照
            div([SignalView({ => text(this.verTitle.get()) })],
                attrs: Some(HashMap<String, String>([("class", cls("dialog-section"))]))),
            table,
            div([text("重拉：按上游内容重新拉取该版本并覆盖本地缓存（仅回源镜像版本）；" +
                "软删除：可在列表恢复（恢复时校验制品仍在）；硬删除：删除记录 + 制品文件（制品仍被其它版本引用时保留）。")]),
        ])
            .visible(this.verDialogVisible)
            .title("版本列表")
            .width("1060px")
            .closeOnClickModal(false)
            .footer([
                Button([text("关闭")]).onClick(closeVersions),
            ])
        dlg
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

    func renderConfirmDialog(): IComponent {
        let hard = this.pendingMode.get() == "hard"
        let body = if (hard) {
            div([
                div([text("确定要硬删除「${this.pendingDeleteName}」吗？")]),
                div([text("将同时删除制品文件（若仍被其它版本引用则保留），且不可恢复——请确认该版本已软删且无人依赖。")]),
            ])
        } else {
            div([
                div([text("确定要软删除「${this.pendingDeleteName}」吗？")]),
                div([text("索引/下载/公开 API 立即不可见，可在包列表随时恢复。")]),
            ])
        }
        let dlg = Dialog([body])
            .visible(this.confirmVisible)
            .title(if (hard) { "硬删除确认" } else { "软删除确认" })
            .width("460px")
            .closeOnClickModal(false)
            .footer([
                Button([text("取消")]).onClick(cancelDelete),
                Button([text(if (hard) { "硬删除" } else { "软删除" })]).kind(ButtonKind.Danger).onClick(confirmDelete),
            ])
        dlg
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
            Input().bind(this.search).placeholder("搜索包名").on("input", { _ =>
                this.currentPage.set(1)
                this.refresh()
                PatchResult.ReRender
            }),
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
        adminLayout("/admin/packages", [
            div([text("包管理")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            adminCard("已发布包", [toolbar, this.renderList(), pager, this.renderVersionDialog(),
                this.renderDetailDialog(), this.renderRefetchDialog(), this.renderConfirmDialog()]),
        ])
    }
}
