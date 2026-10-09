// 管理端上游管理（@Page /admin/upstreams）
package ystyle::cjreg.ui.admin

import ystyle::cjreg.ui.public.*
import ystyle::cjreg.ui.*
import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import ystyle::cjreg.store.*
import ystyle::cjreg.config.*
import ystyle::cjreg.server.{BlobStore, LifecycleOutcome, LifecycleResult, MemoryBlobStore, RefetchOutcome, hardDeleteVersion, refetchVersion, restoreVersion, shortSha, softDeleteVersion}
import ystyle::cjreg.semver_range.*
import std.collection.*
import std.convert.*
import std.sort.*
import std.time.*

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
    // 上游的两个正交开关。创建时的默认值：回源开、允许推送关 ——
    // 推送不可逆（推错到官方中心仓无法撤销），新上游要显式授权才能当目标仓。
    var formProxyEnabled = Signal<Bool>(true)
    var formAsTarget = Signal<Bool>(false)
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
        this.formProxyEnabled.set(true)
        this.formAsTarget.set(false)
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
                this.formProxyEnabled.set(u.proxyEnabled)
                this.formAsTarget.set(u.asTarget)
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
            match (upSvc.add(name, url, this.formPriority.get(), this.formToken.get(), this.formCacheTtl.get(),
                proxyEnabled: this.formProxyEnabled.get(), asTarget: this.formAsTarget.get())) {
                case Some(u) =>
                    this.msg.set("已添加 ${u.name}")
                    st.adminData.addLog(LogKind.Admin, sessionUid(ctx), sessionUsername(ctx), "add upstream ${u.name}", "ok", nowMs())
                case None =>
                    this.msg.set("添加失败（名称已存在？）")
            }
        } else {
            if (upSvc.update(this.editingId, Option<Bool>.None, Some(this.formPriority.get()), Some(this.formCacheTtl.get()), Some(this.formToken.get()),
                proxyEnabled: Some(this.formProxyEnabled.get()), asTarget: Some(this.formAsTarget.get()))) {
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
            // 两个正交开关的呈现：回源 = 读路径（镜像同步）；可推送 = 写路径（发布计划目标）
            .add(TableColumn<Upstream>().label("能力").width(150).render({ u, i =>
                div([
                    Tag([text(if (u.proxyEnabled) { "回源" } else { "不回源" })])
                        .kind(if (u.proxyEnabled) { ComponentKind.Success } else { ComponentKind.Info }),
                    Tag([text(if (u.asTarget) { "可推送" } else { "禁推送" })])
                        .kind(if (u.asTarget) { ComponentKind.Warning } else { ComponentKind.Info }),
                ], attrs: Some(HashMap<String, String>([("style", "display:flex;gap:6px;align-items:center;flex-wrap:nowrap;")])))
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
            FormItem([Switch().bind(this.formProxyEnabled).activeText("回源").inactiveText("不回源")])
                .label("参与回源（镜像同步）")
                .bindValue({ => this.formProxyEnabled.get().toString() }),
            FormItem([Switch().bind(this.formAsTarget).activeText("允许").inactiveText("不允许")])
                .label("可作为发布计划目标仓")
                .bindValue({ => this.formAsTarget.get().toString() }),
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
