// cjxt 管理界面页面：仪表盘 / 上游管理 / 包管理
package ystyle::cjreg.ui

import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import ystyle::cjreg.store.*
import ystyle::cjreg.config.*
import std.collection.*
import std.convert.*

// ===== 仪表盘 =====
@Page["/admin", "仪表盘", requireAdmin]
class DashboardPage <: Component {
    var state: Option<CjregState> = None

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
    }

    public func render(): IComponent {
        let st = match (this.state) {
            case Some(s) => s
            case None => return div()
        }
        let allPkgs = st.pkgStore.storm.all<PackageDoc>()
        var versions: Int64 = 0
        var downloads: Int64 = 0
        for (d in allPkgs) {
            versions++
            downloads += d.downloadCount
        }
        let userCount = st.userStore.listAllUsers().size
        let upCount = st.upStore.listAll().size
        let planCount = st.adminData.listPlans().size
        let logCount = st.adminData.listLogs(Option<String>.None, 1000).size
        let stats = ArrayList<IComponent>()
        stats.add(statCard("${allPkgs.size}", "包总数"))
        stats.add(statCard("${versions}", "版本总数"))
        stats.add(statCard("${downloads}", "累计下载"))
        stats.add(statCard("${userCount}", "用户数"))
        stats.add(statCard("${upCount}", "上游数"))
        stats.add(statCard("${planCount}", "发布计划"))
        stats.add(statCard("${logCount}", "日志条数"))
        // 快捷入口
        let quick = ArrayList<IComponent>()
        quick.add(quickLink("/admin/packages", "包管理"))
        quick.add(quickLink("/admin/upstreams", "上游管理"))
        quick.add(quickLink("/admin/publish-plans", "发布计划"))
        quick.add(quickLink("/admin/organizations", "组织管理"))
        quick.add(quickLink("/admin/teams", "团队管理"))
        quick.add(quickLink("/admin/users", "用户管理"))
        quick.add(quickLink("/admin/logs", "日志"))
        adminLayout("/admin", [
            div([text("仪表盘")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            div(stats.toArray(), attrs: Some(HashMap<String, String>([("class", cls("stat-grid"))]))),
            adminCard("快捷入口", [
                div(quick.toArray(), attrs: Some(HashMap<String, String>([("class", cls("stat-grid"))]))),
            ]),
        ])
    }
}

// 快捷入口卡片
func quickLink(path: String, label: String): IComponent {
    let go: ActionHandler = { c =>
        c.route.push(path)
        PatchResult.ReRender
    }
    div([
        div([text(label)], attrs: Some(HashMap<String, String>([("class", cls("stat-label"))]))),
    ], attrs: Some(HashMap<String, String>([("class", cls("stat-card"))]))).onClick(go)
}

func statCard(value: String, label: String): IComponent {
    div([
        div([text(value)], attrs: Some(HashMap<String, String>([("class", cls("stat-value"))]))),
        div([text(label)], attrs: Some(HashMap<String, String>([("class", cls("stat-label"))]))),
    ], attrs: Some(HashMap<String, String>([("class", cls("stat-card"))])))
}

// ===== 上游管理 =====
@Page["/admin/upstreams", "上游管理", requireAdmin]
class UpstreamsPage <: Component {
    var state: Option<CjregState> = None
    var rows = Signal<ArrayList<HashMap<String, String>>>(ArrayList<HashMap<String, String>>())
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
    // 删除确认 Dialog
    var confirmVisible = Signal<Bool>(false)
    var pendingDeleteId: Int64 = 0
    var pendingDeleteName: String = ""

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        refresh()
    }

    func refresh(): Unit {
        match (this.state) {
            case Some(st) =>
                let list = st.upStore.listAll()
                let data = ArrayList<HashMap<String, String>>()
                for (u in list) {
                    let m = HashMap<String, String>()
                    m["id"] = u.id.toString()
                    m["name"] = u.name
                    m["url"] = u.url
                    m["enabled"] = if (u.enabled) { "是" } else { "否" }
                    m["official"] = if (u.isOfficial) { "官方" } else { "镜像" }
                    m["priority"] = u.priority.toString()
                    m["cacheTtl"] = "${u.cacheTtl}s"
                    m["lastSync"] = if (u.lastSyncAt > 0) { u.lastSyncAt.toString() } else { "-" }
                    data.add(m)
                }
                this.rows.set(data)
            case None => ()
        }
    }

    // ===== 表单 Dialog =====
    func openCreate(ctx: ActionContext): PatchResult {
        this.dialogMode.set("create")
        this.formName.set("")
        this.formUrl.set("")
        this.formPriority.set(0)
        this.formCacheTtl.set(86400)
        this.formToken.set("")
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
        let name = this.formName.get()
        let url = this.formUrl.get()
        if (name.isEmpty() || url.isEmpty()) {
            this.msg.set("名称和 URL 必填")
            return PatchResult.ReRender
        }
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
    func toggleEnabled(ctx: ActionContext, u: Upstream): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            this.msg.set("无权限：需要管理员登录")
            return PatchResult.ReRender
        }
        let upSvc = UpstreamService(st.upStore)
        if (upSvc.update(u.id, Some(!u.enabled), Option<Int64>.None, Option<Int64>.None, Option<String>.None)) {
            this.msg.set(if (!u.enabled) { "已启用 ${u.name}" } else { "已禁用 ${u.name}" })
            st.adminData.addLog(LogKind.Admin, sessionUid(ctx), sessionUsername(ctx), "toggle upstream ${u.name}", "ok", nowMs())
        }
        refresh()
        PatchResult.ReRender
    }

    // ===== 删除（确认） =====
    func askDelete(ctx: ActionContext, u: Upstream): PatchResult {
        this.pendingDeleteId = u.id
        this.pendingDeleteName = u.name
        this.confirmVisible.set(true)
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
    func renderUpRow(u: Upstream): IComponent {
        let editHandler: ActionHandler = { c => this.openEdit(c, u.id) }
        let toggleHandler: ActionHandler = { c => this.toggleEnabled(c, u) }
        let deleteHandler: ActionHandler = { c => this.askDelete(c, u) }
        let statusTag = if (u.enabled) {
            Tag([text("启用")]).kind(ComponentKind.Success)
        } else {
            Tag([text("禁用")]).kind(ComponentKind.Info)
        }
        let typeTag = if (u.isOfficial) {
            Tag([text("官方")]).kind(ComponentKind.Primary)
        } else {
            Tag([text("镜像")]).kind(ComponentKind.Warning)
        }
        div([
            div([text(u.id.toString())], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text(u.name)], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text(u.url)], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([typeTag], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([statusTag], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text(u.priority.toString())], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text("${u.cacheTtl}s")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text(if (u.lastSyncAt > 0) { u.lastSyncAt.toString() } else { "-" })], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([
                Button([text("编辑")]).size(ButtonSize.Small).onClick(editHandler),
                Button([text(if (u.enabled) { "禁用" } else { "启用" })]).size(ButtonSize.Small).onClick(toggleHandler),
                if (u.isOfficial) {
                    div()
                } else {
                    Button([text("删除")]).size(ButtonSize.Small).kind(ButtonKind.Danger).onClick(deleteHandler)
                },
            ], attrs: Some(HashMap<String, String>([("class", cls("admin-td") + " " + cls("admin-actions"))]))),
        ], attrs: Some(HashMap<String, String>([("class", cls("admin-tr"))])))
    }

    func renderList(): IComponent {
        match (this.state) {
            case Some(st) =>
                let list = st.upStore.listAll()
                if (list.size == 0) {
                    return emptyState("暂无上游，点击「新增上游」添加")
                }
                let rows = ArrayList<IComponent>()
                rows.add(div([
                    div([text("ID")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
                    div([text("名称")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
                    div([text("URL")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
                    div([text("类型")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
                    div([text("状态")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
                    div([text("优先级")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
                    div([text("缓存")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
                    div([text("最后同步")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
                    div([text("操作")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
                ], attrs: Some(HashMap<String, String>([("class", cls("admin-tr") + " " + cls("admin-th"))]))))
                for (u in list) {
                    rows.add(this.renderUpRow(u))
                }
                div(rows.toArray(), attrs: Some(HashMap<String, String>([("class", cls("admin-table"))])))
            case None => div()
        }
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
        let dlg = Dialog([
            div([
                div([text("名称")], attrs: Some(HashMap<String, String>([("class", cls("dialog-form-label"))]))),
                nameInput,
                div([text("URL")], attrs: Some(HashMap<String, String>([("class", cls("dialog-form-label"))]))),
                urlInput,
                div([text("优先级（小者优先）")], attrs: Some(HashMap<String, String>([("class", cls("dialog-form-label"))]))),
                InputNumber().bind(this.formPriority).min(0),
                div([text("缓存时间（秒）")], attrs: Some(HashMap<String, String>([("class", cls("dialog-form-label"))]))),
                InputNumber().bind(this.formCacheTtl).min(0),
                div([text("认证 Token（可选）")], attrs: Some(HashMap<String, String>([("class", cls("dialog-form-label"))]))),
                Input().bind(this.formToken).placeholder("私有仓访问令牌").password(),
            ], attrs: Some(HashMap<String, String>([("class", cls("dialog-form"))]))),
        ])
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
        adminLayout("/admin/upstreams", [
            div([text("上游管理")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            adminCard("多仓上游配置", [toolbar, this.renderList(), this.renderFormDialog(), this.renderConfirmDialog()]),
        ])
    }
}

// ===== 包管理 =====
@Page["/admin/packages", "包管理", requireAdmin]
class PackagesPage <: Component {
    var state: Option<CjregState> = None
    var rows = Signal<ArrayList<HashMap<String, String>>>(ArrayList<HashMap<String, String>>())
    var search = Signal<String>("")
    var orgFilter = Signal<String>("all")
    var msg = Signal<String>("")
    // 分页
    var currentPage = Signal<Int64>(1)
    var pageSize = Signal<Int64>(20)
    var total = Signal<Int64>(0)
    // 版本对话框
    var verDialogVisible = Signal<Bool>(false)
    var verRows = Signal<ArrayList<HashMap<String, String>>>(ArrayList<HashMap<String, String>>())
    var verTitle = Signal<String>("")
    // 删除确认
    var confirmVisible = Signal<Bool>(false)
    var pendingDeleteId: Int64 = 0
    var pendingDeleteName: String = ""

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
                let start = (this.currentPage.get() - 1) * this.pageSize.get()
                let data = ArrayList<HashMap<String, String>>()
                var i = start
                while (i < filtered.size && data.size < this.pageSize.get()) {
                    let d = filtered[i]
                    let m = HashMap<String, String>()
                    m["id"] = d.id.toString()
                    m["org"] = d.organization
                    m["name"] = d.name
                    m["version"] = d.version
                    m["downloads"] = d.downloadCount.toString()
                    m["deleted"] = if (d.deletedAt != 0) { "已删" } else { "正常" }
                    data.add(m)
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
        let data = ArrayList<HashMap<String, String>>()
        for (d in versions) {
            let m = HashMap<String, String>()
            m["id"] = d.id.toString()
            m["version"] = d.version
            m["downloads"] = d.downloadCount.toString()
            m["deleted"] = if (d.deletedAt != 0) { "已删" } else { "正常" }
            data.add(m)
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

    // ===== 删除 =====
    func askDelete(ctx: ActionContext, id: Int64, name: String, version: String): PatchResult {
        this.pendingDeleteId = id
        this.pendingDeleteName = "${name}@${version}"
        this.confirmVisible.set(true)
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
        match (st.pkgStore.getById(this.pendingDeleteId)) {
            case Some(doc) =>
                st.pkgStore.softDelete(doc, nowMs())
                this.msg.set("已删除 ${this.pendingDeleteName}")
                st.adminData.addLog(LogKind.Admin, sessionUid(ctx), sessionUsername(ctx), "delete package ${this.pendingDeleteName}", "ok", nowMs())
            case None => ()
        }
        this.confirmVisible.set(false)
        this.pendingDeleteId = 0
        refresh()
        PatchResult.ReRender
    }

    // ===== 渲染 =====
    func renderPkgRow(d: HashMap<String, String>): IComponent {
        let versionsHandler: ActionHandler = { c => this.showVersions(c, d["org"], d["name"]) }
        let deleteHandler: ActionHandler = { c => this.askDelete(c, Int64.parse(d["id"]), d["name"], d["version"]) }
        let statusTag = if (d["deleted"] == "已删") {
            Tag([text("已删")]).kind(ComponentKind.Danger)
        } else {
            Tag([text("正常")]).kind(ComponentKind.Success)
        }
        div([
            div([text(d["id"])], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text(d["org"])], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text(d["name"])], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text(d["version"])], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text(d["downloads"])], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([statusTag], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([
                Button([text("版本")]).size(ButtonSize.Small).onClick(versionsHandler),
                Button([text("删除")]).size(ButtonSize.Small).kind(ButtonKind.Danger).onClick(deleteHandler),
            ], attrs: Some(HashMap<String, String>([("class", cls("admin-td") + " " + cls("admin-actions"))]))),
        ], attrs: Some(HashMap<String, String>([("class", cls("admin-tr"))])))
    }

    func renderList(): IComponent {
        let rows = ArrayList<IComponent>()
        if (this.rows.get().size == 0) {
            return emptyState("暂无包数据")
        }
        rows.add(div([
            div([text("ID")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text("组织")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text("包名")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text("版本")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text("下载")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text("状态")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text("操作")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
        ], attrs: Some(HashMap<String, String>([("class", cls("admin-tr") + " " + cls("admin-th"))]))))
        for (m in this.rows.get()) {
            rows.add(this.renderPkgRow(m))
        }
        div(rows.toArray(), attrs: Some(HashMap<String, String>([("class", cls("admin-table"))])))
    }

    func renderVersionDialog(): IComponent {
        let table = Table()
            .data(this.verRows)
            .stripe()
            .add(TableColumn().label("ID").colProp("id").width(60))
            .add(TableColumn().label("版本").colProp("version"))
            .add(TableColumn().label("下载").colProp("downloads").width(80))
            .add(TableColumn().label("状态").colProp("deleted").width(80))
        let dlg = Dialog([
            table,
        ])
            .visible(this.verDialogVisible)
            .title(this.verTitle.get())
            .width("520px")
            .closeOnClickModal(false)
            .footer([
                Button([text("关闭")]).onClick(closeVersions),
            ])
        dlg
    }

    func renderConfirmDialog(): IComponent {
        let dlg = Dialog([
            div([text("确定要删除包「${this.pendingDeleteName}」吗？此操作不可恢复。")]),
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
            adminCard("已发布包", [toolbar, this.renderList(), pager, this.renderVersionDialog(), this.renderConfirmDialog()]),
        ])
    }
}
