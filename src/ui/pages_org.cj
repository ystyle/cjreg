// cjxt 管理界面：用户 / 组织 / 团队 管理页
package ystyle::cjreg.ui

import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.model.*
import std.collection.*
import std.convert.*

// ===== 列表行视图类型（泛型 Table<T> 行：实体 + 按需计算的次要字段） =====

/// 团队列表行：团队实体 + 成员/组织/包关联计数
public struct TeamRow {
    public let doc: TeamDoc
    public let members: Int64
    public let orgs: Int64
    public let pkgs: Int64

    public init(doc: TeamDoc, members: Int64, orgs: Int64, pkgs: Int64) {
        this.doc = doc
        this.members = members
        this.orgs = orgs
        this.pkgs = pkgs
    }
}

/// 团队-包关联行：包实体 + 是否已关联
public struct PkgRow {
    public let doc: PackageDoc
    public let linked: Bool

    public init(doc: PackageDoc, linked: Bool) {
        this.doc = doc
        this.linked = linked
    }
}

/// 团队-成员关联行：用户实体 + 是否已关联
public struct MemberRow {
    public let user: User
    public let linked: Bool

    public init(user: User, linked: Bool) {
        this.user = user
        this.linked = linked
    }
}

// ===== 用户管理 =====
@Page["/admin/users", "用户管理", requireAdmin]
class UsersPage <: Component {
    var state: Option<CjregState> = None
    var msg = Signal<String>("")
    // 行数据 + 分页（泛型 Table<User>）
    var rows = Signal<ArrayList<User>>(ArrayList<User>())
    var currentPage = Signal<Int64>(1)
    var pageSize = Signal<Int64>(20)
    var total = Signal<Int64>(0)
    // 新增 Dialog
    var dialogVisible = Signal<Bool>(false)
    var formUser = Signal<String>("")
    var formPass = Signal<String>("")
    var formEmail = Signal<String>("")
    var formIsAdmin = Signal<Bool>(false)
    var userError = Signal<String>("")
    var passError = Signal<String>("")
    var createForm = Form([])
    // Token 展示/重置 Dialog
    var tokenVisible = Signal<Bool>(false)
    var tokenUser: String = ""
    var tokenValue = Signal<String>("")
    var tokenUserId: Int64 = 0
    // 删除确认 Dialog
    var confirmVisible = Signal<Bool>(false)
    var pendingDeleteId: Int64 = 0
    var pendingDeleteName: String = ""

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        refresh()
    }

    // 分页切片（行数据直接为强类型 User）
    func refresh(): Unit {
        match (this.state) {
            case Some(st) =>
                let users = st.userStore.listAllUsers()
                this.total.set(users.size)
                let (start, end) = pageWindow(users.size, this.currentPage.get(), this.pageSize.get())
                let data = ArrayList<User>()
                var i = start
                while (i < end) {
                    data.add(users[i])
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

    // ===== 新增用户 =====
    func openCreate(ctx: ActionContext): PatchResult {
        this.formUser.set("")
        this.formPass.set("")
        this.formEmail.set("")
        this.formIsAdmin.set(false)
        this.userError.set("")
        this.passError.set("")
        this.dialogVisible.set(true)
        PatchResult.ReRender
    }

    func closeDialog(ctx: ActionContext): PatchResult {
        this.dialogVisible.set(false)
        PatchResult.ReRender
    }

    func submitCreate(ctx: ActionContext): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            this.msg.set("无权限：需要管理员登录")
            return PatchResult.ReRender
        }
        // Form 校验（FormItem.errorSignal 展示错误）
        if (!this.createForm.validate()) {
            return PatchResult.ReRender
        }
        let uname = this.formUser.get()
        let pass = this.formPass.get()
        match (st.auth.createUser(uname, pass, this.formIsAdmin.get(), email: this.formEmail.get())) {
            case Some(u) =>
                this.dialogVisible.set(false)
                this.msg.set("已创建 ${u.username}")
                st.adminData.addLog(LogKind.Admin, sessionUid(ctx), sessionUsername(ctx), "create user ${u.username}", "ok", nowMs())
                // 展示新用户发布 Token
                this.tokenUser = u.username
                this.tokenValue.set(u.publishToken)
                this.tokenUserId = u.id
                this.tokenVisible.set(true)
            case None =>
                this.msg.set("创建失败（用户已存在）")
        }
        PatchResult.ReRender
    }

    // ===== Token 展示/重置 =====
    func showToken(ctx: ActionContext, id: Int64): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        match (st.userStore.getUser(id)) {
            case Some(u) =>
                this.tokenUser = u.username
                this.tokenValue.set(u.publishToken)
                this.tokenUserId = u.id
                this.tokenVisible.set(true)
            case None => ()
        }
        PatchResult.ReRender
    }

    func closeToken(ctx: ActionContext): PatchResult {
        this.tokenVisible.set(false)
        PatchResult.ReRender
    }

    func resetToken(ctx: ActionContext): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            return PatchResult.ReRender
        }
        match (st.auth.resetPublishToken(this.tokenUserId)) {
            case Some(t) =>
                this.tokenValue.set(t)
                this.msg.set("已重置 ${this.tokenUser} 的 Token")
                st.adminData.addLog(LogKind.Admin, sessionUid(ctx), sessionUsername(ctx), "reset token ${this.tokenUser}", "ok", nowMs())
            case None => ()
        }
        PatchResult.ReRender
    }

    // ===== 启停 =====
    func toggleActive(ctx: ActionContext, id: Int64): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            this.msg.set("无权限：需要管理员登录")
            return PatchResult.ReRender
        }
        match (st.userStore.getUser(id)) {
            case Some(u) =>
                if (st.auth.setUserActive(u.id, !u.isActive)) {
                    this.msg.set(if (!u.isActive) { "已启用 ${u.username}" } else { "已禁用 ${u.username}" })
                    st.adminData.addLog(LogKind.Admin, sessionUid(ctx), sessionUsername(ctx), "toggle user ${u.username}", "ok", nowMs())
                }
            case None => ()
        }
        this.refresh()
        PatchResult.ReRender
    }

    // ===== 删除 =====
    func askDelete(ctx: ActionContext, id: Int64): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        match (st.userStore.getUser(id)) {
            case Some(u) =>
                this.pendingDeleteId = u.id
                this.pendingDeleteName = u.username
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
        if (st.auth.deleteUser(this.pendingDeleteId)) {
            this.msg.set("已删除用户 ${this.pendingDeleteName}")
            st.adminData.addLog(LogKind.Admin, sessionUid(ctx), sessionUsername(ctx), "delete user ${this.pendingDeleteName}", "ok", nowMs())
        } else {
            this.msg.set("删除失败（管理员受保护）")
        }
        this.confirmVisible.set(false)
        this.pendingDeleteId = 0
        PatchResult.ReRender
    }

    // ===== 渲染 =====
    func renderList(): IComponent {
        if (this.rows.get().size == 0) {
            return emptyState("暂无用户，点击「新增用户」创建")
        }
        Table<User>()
            .data(this.rows)
            .stripe()
            .add(TableColumn<User>().label("ID").accessor({ u => u.id.toString() }).width(60))
            .add(TableColumn<User>().label("用户名").accessor({ u => u.username }).minWidth(120))
            .add(TableColumn<User>().label("邮箱").accessor({ u => u.email }).minWidth(160))
            .add(TableColumn<User>().label("角色").width(90).render({ u, i =>
                if (u.isAdmin) {
                    Tag([text("管理员")]).kind(ComponentKind.Primary)
                } else {
                    Tag([text("普通")]).kind(ComponentKind.Info)
                }
            }))
            .add(TableColumn<User>().label("状态").width(90).render({ u, i =>
                if (u.isActive) {
                    Tag([text("正常")]).kind(ComponentKind.Success)
                } else {
                    Tag([text("禁用")]).kind(ComponentKind.Danger)
                }
            }))
            .add(TableColumn<User>().label("操作").minWidth(230).render({ u, i =>
                let tokenH: ActionHandler = { c => this.showToken(c, u.id) }
                let toggleH: ActionHandler = { c => this.toggleActive(c, u.id) }
                let deleteH: ActionHandler = { c => this.askDelete(c, u.id) }
                div([
                    Button([text("Token")]).size(ButtonSize.Small).onClick(tokenH),
                    Button([text(if (u.isActive) { "禁用" } else { "启用" })]).size(ButtonSize.Small).onClick(toggleH),
                    if (u.isAdmin) {
                        div()
                    } else {
                        Button([text("删除")]).size(ButtonSize.Small).kind(ButtonKind.Danger).onClick(deleteH)
                    },
                ])
            }))
    }

    func renderCreateDialog(): IComponent {
        let form = Form([
            FormItem([Input().bind(this.formUser).placeholder("登录用户名")])
                .label("用户名")
                .bindValue({ => this.formUser.get() })
                .rule(FormRule(required: true, message: "用户名必填"))
                .errorSignal(this.userError),
            FormItem([Input().bind(this.formPass).placeholder("初始密码").password()])
                .label("密码")
                .bindValue({ => this.formPass.get() })
                .rule(FormRule(required: true, message: "密码必填"))
                .errorSignal(this.passError),
            FormItem([Input().bind(this.formEmail).placeholder("可选")])
                .label("邮箱")
                .bindValue({ => this.formEmail.get() }),
            FormItem([Switch().bind(this.formIsAdmin).activeText("管理员").inactiveText("普通")])
                .label("管理员")
                .bindValue({ => if (this.formIsAdmin.get()) { "1" } else { "0" } }),
        ]).labelTop()
        // 保存最新 Form 实例供 submitCreate 的 validate() 使用
        this.createForm = form
        let dlg = Dialog([form])
            .visible(this.dialogVisible)
            .title("新增用户")
            .width("440px")
            .closeOnClickModal(false)
            .footer([
                Button([text("取消")]).onClick(closeDialog),
                Button([text("创建")]).kind(ButtonKind.Primary).onClick(submitCreate),
            ])
        dlg
    }

    func renderTokenDialog(): IComponent {
        let dlg = Dialog([
            div([
                div([text("用户 ${this.tokenUser} 的发布 Token：")], attrs: Some(HashMap<String, String>([("class", cls("dialog-form-label"))]))),
                Input().bind(this.tokenValue).disabled(),
                div([text("用于 cjpm 发布上传鉴权（cangjie-repo.toml 的 token）")], attrs: Some(HashMap<String, String>([("class", cls("dialog-form-label"))]))),
            ], attrs: Some(HashMap<String, String>([("class", cls("dialog-form"))]))),
        ])
            .visible(this.tokenVisible)
            .title("用户 Token")
            .width("480px")
            .closeOnClickModal(false)
            .footer([
                Button([text("关闭")]).onClick(closeToken),
                Button([text("重置 Token")]).kind(ButtonKind.Warning).onClick(resetToken),
            ])
        dlg
    }

    func renderConfirmDialog(): IComponent {
        let dlg = Dialog([
            div([text("确定要删除用户「${this.pendingDeleteName}」吗？其发布权限将立即失效。")]),
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
            Button([text("新增用户")]).kind(ButtonKind.Primary).onClick(openCreate),
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
        adminLayout("/admin/users", [
            div([text("用户管理")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            adminCard("用户列表", [toolbar, this.renderList(), pager, this.renderCreateDialog(), this.renderTokenDialog(), this.renderConfirmDialog()]),
        ])
    }
}

// ===== 组织管理 =====
@Page["/admin/organizations", "组织管理", requireAdmin]
class OrganizationsPage <: Component {
    var state: Option<CjregState> = None
    var msg = Signal<String>("")
    // 行数据 + 分页（泛型 Table<OrgDoc>）
    var rows = Signal<ArrayList<OrgDoc>>(ArrayList<OrgDoc>())
    var currentPage = Signal<Int64>(1)
    var pageSize = Signal<Int64>(20)
    var total = Signal<Int64>(0)
    // 新增/编辑 Dialog
    var dialogVisible = Signal<Bool>(false)
    var dialogMode = Signal<String>("create")
    var editingId: Int64 = 0
    var formName = Signal<String>("")
    var formDisplay = Signal<String>("")
    var formDesc = Signal<String>("")
    var formIsDefault = Signal<Bool>(false)
    var nameError = Signal<String>("")
    var orgForm = Form([])
    // 删除确认
    var confirmVisible = Signal<Bool>(false)
    var pendingDeleteId: Int64 = 0
    var pendingDeleteName: String = ""

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        refresh()
    }

    // 分页切片（行数据直接为强类型 OrgDoc）
    func refresh(): Unit {
        match (this.state) {
            case Some(st) =>
                let orgs = st.adminData.listOrgs()
                this.total.set(orgs.size)
                let (start, end) = pageWindow(orgs.size, this.currentPage.get(), this.pageSize.get())
                let data = ArrayList<OrgDoc>()
                var i = start
                while (i < end) {
                    data.add(orgs[i])
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

    // ===== 新增/编辑 =====
    func openCreate(ctx: ActionContext): PatchResult {
        this.dialogMode.set("create")
        this.formName.set("")
        this.formDisplay.set("")
        this.formDesc.set("")
        this.formIsDefault.set(false)
        this.nameError.set("")
        this.dialogVisible.set(true)
        PatchResult.ReRender
    }

    func openEdit(ctx: ActionContext, id: Int64): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        match (st.adminData.getOrg(id)) {
            case Some(o) =>
                this.dialogMode.set("edit")
                this.editingId = o.id
                this.formName.set(o.name)
                this.formDisplay.set(o.displayName)
                this.formDesc.set(o.description)
                this.formIsDefault.set(o.isDefault)
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
        if (!this.orgForm.validate()) {
            return PatchResult.ReRender
        }
        let name = this.formName.get()
        let display = this.formDisplay.get()
        let desc = this.formDesc.get()
        let isDefault = this.formIsDefault.get()
        let uid = sessionUid(ctx)
        let uname = sessionUsername(ctx)
        if (this.dialogMode.get() == "create") {
            let id = st.adminData.createOrg(name, display, uid, nowMs(), description: desc, isDefault: isDefault)
            this.msg.set("已创建组织 #${id}")
            st.adminData.addLog(LogKind.Admin, uid, uname, "create org ${name}", "ok", nowMs())
        } else {
            if (st.adminData.updateOrg(this.editingId, display, desc, isDefault, nowMs())) {
                this.msg.set("已更新组织 ${name}")
                st.adminData.addLog(LogKind.Admin, uid, uname, "update org ${name}", "ok", nowMs())
            } else {
                this.msg.set("更新失败")
            }
        }
        this.dialogVisible.set(false)
        this.refresh()
        PatchResult.ReRender
    }

    // ===== 删除 =====
    func askDelete(ctx: ActionContext, id: Int64): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        match (st.adminData.getOrg(id)) {
            case Some(o) =>
                this.pendingDeleteId = o.id
                this.pendingDeleteName = o.name
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
        if (st.adminData.deleteOrg(this.pendingDeleteId, nowMs())) {
            this.msg.set("已删除组织 ${this.pendingDeleteName}")
            st.adminData.addLog(LogKind.Admin, sessionUid(ctx), sessionUsername(ctx), "delete org ${this.pendingDeleteName}", "ok", nowMs())
        } else {
            this.msg.set("删除失败")
        }
        this.confirmVisible.set(false)
        this.pendingDeleteId = 0
        PatchResult.ReRender
    }

    // ===== 渲染 =====
    func renderList(): IComponent {
        if (this.rows.get().size == 0) {
            return emptyState("暂无组织，点击「新增组织」创建")
        }
        Table<OrgDoc>()
            .data(this.rows)
            .stripe()
            .add(TableColumn<OrgDoc>().label("ID").accessor({ o => o.id.toString() }).width(60))
            .add(TableColumn<OrgDoc>().label("组织名").accessor({ o => o.name }).minWidth(140))
            .add(TableColumn<OrgDoc>().label("显示名").accessor({ o => o.displayName }).minWidth(140))
            .add(TableColumn<OrgDoc>().label("描述").accessor({ o => o.description }).minWidth(200))
            .add(TableColumn<OrgDoc>().label("默认").width(80).render({ o, i =>
                if (o.isDefault) {
                    Tag([text("默认")]).kind(ComponentKind.Primary)
                } else {
                    Tag([text("普通")]).kind(ComponentKind.Info)
                }
            }))
            .add(TableColumn<OrgDoc>().label("操作").minWidth(160).render({ o, i =>
                let editH: ActionHandler = { c => this.openEdit(c, o.id) }
                let deleteH: ActionHandler = { c => this.askDelete(c, o.id) }
                div([
                    Button([text("编辑")]).size(ButtonSize.Small).onClick(editH),
                    Button([text("删除")]).size(ButtonSize.Small).kind(ButtonKind.Danger).onClick(deleteH),
                ])
            }))
    }

    func renderFormDialog(): IComponent {
        let title = if (this.dialogMode.get() == "create") { "新增组织" } else { "编辑组织" }
        let isEdit = this.dialogMode.get() == "edit"
        let nameInput = if (isEdit) {
            Input().bind(this.formName).disabled()
        } else {
            Input().bind(this.formName)
        }
        let form = Form([
            FormItem([nameInput]).label("组织名")
                .bindValue({ => this.formName.get() })
                .rule(FormRule(required: true, message: "组织名必填"))
                .errorSignal(this.nameError),
            FormItem([Input().bind(this.formDisplay).placeholder("可选")]).label("显示名")
                .bindValue({ => this.formDisplay.get() }),
            FormItem([Input().bind(this.formDesc).placeholder("可选")]).label("描述")
                .bindValue({ => this.formDesc.get() }),
            FormItem([Switch().bind(this.formIsDefault).activeText("默认").inactiveText("普通")]).label("默认组织")
                .bindValue({ => if (this.formIsDefault.get()) { "1" } else { "0" } }),
        ]).labelTop()
        this.orgForm = form
        let dlg = Dialog([form])
            .visible(this.dialogVisible)
            .title(title)
            .width("440px")
            .closeOnClickModal(false)
            .footer([
                Button([text("取消")]).onClick(closeDialog),
                Button([text("确定")]).kind(ButtonKind.Primary).onClick(submitForm),
            ])
        dlg
    }

    func renderConfirmDialog(): IComponent {
        let dlg = Dialog([
            div([text("确定要删除组织「${this.pendingDeleteName}」吗？")]),
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
            Button([text("新增组织")]).kind(ButtonKind.Primary).onClick(openCreate),
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
        adminLayout("/admin/organizations", [
            div([text("组织管理")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            adminCard("组织列表", [toolbar, this.renderList(), pager, this.renderFormDialog(), this.renderConfirmDialog()]),
        ])
    }
}

// ===== 团队管理 =====
@Page["/admin/teams", "团队管理", requireAdmin]
class TeamsPage <: Component {
    var state: Option<CjregState> = None
    var msg = Signal<String>("")
    // 行数据 + 分页（泛型 Table<TeamRow>：实体 + 关联计数视图）
    var rows = Signal<ArrayList<TeamRow>>(ArrayList<TeamRow>())
    var currentPage = Signal<Int64>(1)
    var pageSize = Signal<Int64>(20)
    var total = Signal<Int64>(0)
    // 基础表单 Dialog
    var dialogVisible = Signal<Bool>(false)
    var dialogMode = Signal<String>("create")
    var editingId: Int64 = 0
    var formName = Signal<String>("")
    var formDisplay = Signal<String>("")
    var formDesc = Signal<String>("")
    var formPermission = Signal<String>("read")
    var teamNameError = Signal<String>("")
    var teamForm = Form([])
    // 组织关联 Dialog
    var orgDialogVisible = Signal<Bool>(false)
    var orgSelect = Signal<ArrayList<String>>(ArrayList<String>())
    // 包关联 Dialog
    var pkgDialogVisible = Signal<Bool>(false)
    var pkgSearch = Signal<String>("")
    var pkgRows = Signal<ArrayList<PkgRow>>(ArrayList<PkgRow>())
    // 成员关联 Dialog
    var memberDialogVisible = Signal<Bool>(false)
    var memberSearch = Signal<String>("")
    var memberRows = Signal<ArrayList<MemberRow>>(ArrayList<MemberRow>())
    // 删除确认
    var confirmVisible = Signal<Bool>(false)
    var pendingDeleteId: Int64 = 0
    var pendingDeleteName: String = ""

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        refresh()
    }

    // 分页切片（行数据为 TeamRow 视图）
    func refresh(): Unit {
        match (this.state) {
            case Some(st) =>
                let teams = st.adminData.listTeams()
                this.total.set(teams.size)
                let (start, end) = pageWindow(teams.size, this.currentPage.get(), this.pageSize.get())
                let data = ArrayList<TeamRow>()
                var i = start
                while (i < end) {
                    let t = teams[i]
                    data.add(TeamRow(t,
                        st.adminData.listTeamMembers(t.id).size,
                        st.adminData.listTeamOrganizations(t.id).size,
                        st.adminData.listTeamPackages(t.id).size))
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

    // ===== 基础表单 =====
    func openCreate(ctx: ActionContext): PatchResult {
        this.dialogMode.set("create")
        this.formName.set("")
        this.formDisplay.set("")
        this.formDesc.set("")
        this.formPermission.set("read")
        this.teamNameError.set("")
        this.dialogVisible.set(true)
        PatchResult.ReRender
    }

    func openEdit(ctx: ActionContext, id: Int64): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        match (st.adminData.getTeam(id)) {
            case Some(t) =>
                this.dialogMode.set("edit")
                this.editingId = t.id
                this.formName.set(t.name)
                this.formDisplay.set(t.displayName)
                this.formDesc.set(t.description)
                this.formPermission.set(t.permission)
                this.teamNameError.set("")
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
        if (!this.teamForm.validate()) {
            return PatchResult.ReRender
        }
        let name = this.formName.get()
        let display = this.formDisplay.get()
        let desc = this.formDesc.get()
        let perm = this.formPermission.get()
        let uid = sessionUid(ctx)
        let uname = sessionUsername(ctx)
        if (this.dialogMode.get() == "create") {
            let id = st.adminData.createTeam(name, nowMs(), displayName: display, description: desc, permission: perm)
            this.msg.set("已创建团队 #${id}")
            st.adminData.addLog(LogKind.Admin, uid, uname, "create team ${name}", "ok", nowMs())
        } else {
            if (st.adminData.updateTeam(this.editingId, display, desc, perm, nowMs())) {
                this.msg.set("已更新团队 ${name}")
                st.adminData.addLog(LogKind.Admin, uid, uname, "update team ${name}", "ok", nowMs())
            } else {
                this.msg.set("更新失败")
            }
        }
        this.dialogVisible.set(false)
        this.refresh()
        PatchResult.ReRender
    }

    // ===== 组织关联 =====
    func openOrgs(ctx: ActionContext, id: Int64): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        this.editingId = id
        let ids = ArrayList<String>()
        for (oid in st.adminData.listTeamOrganizationIds(id)) {
            ids.add(oid.toString())
        }
        this.orgSelect.set(ids)
        this.orgDialogVisible.set(true)
        PatchResult.ReRender
    }

    func closeOrgs(ctx: ActionContext): PatchResult {
        this.orgDialogVisible.set(false)
        PatchResult.ReRender
    }

    func saveOrgs(ctx: ActionContext): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            this.msg.set("无权限：需要管理员登录")
            return PatchResult.ReRender
        }
        let ids = ArrayList<Int64>()
        for (v in this.orgSelect.get()) {
            let n = match (Int64.tryParse(v)) {
                case Some(x) => x
                case None => 0
            }
            ids.add(n)
        }
        st.adminData.setTeamOrganizations(this.editingId, ids.toArray(), nowMs())
        this.msg.set("已更新团队组织关联")
        st.adminData.addLog(LogKind.Admin, sessionUid(ctx), sessionUsername(ctx), "update team orgs #${this.editingId}", "ok", nowMs())
        this.orgDialogVisible.set(false)
        PatchResult.ReRender
    }

    // ===== 包关联 =====
    func openPackages(ctx: ActionContext, id: Int64): PatchResult {
        this.editingId = id
        this.pkgSearch.set("")
        this.refreshPkgs()
        this.pkgDialogVisible.set(true)
        PatchResult.ReRender
    }

    func closePackages(ctx: ActionContext): PatchResult {
        this.pkgDialogVisible.set(false)
        PatchResult.ReRender
    }

    // 包关联列表：全量包 + 搜索过滤 + 关联标记
    func refreshPkgs(): Unit {
        match (this.state) {
            case Some(st) =>
                let kw = this.pkgSearch.get()
                let linked = st.adminData.listTeamPackages(this.editingId)
                let data = ArrayList<PkgRow>()
                for (d in st.pkgStore.storm.all<PackageDoc>()) {
                    if (d.deletedAt != 0) { continue }
                    if (kw != "" && !d.name.contains(kw)) { continue }
                    var isLinked = false
                    for (p in linked) {
                        if (p.organization == d.organization && p.packageName == d.name) {
                            isLinked = true
                            break
                        }
                    }
                    data.add(PkgRow(d, isLinked))
                }
                this.pkgRows.set(data)
            case None => ()
        }
    }

    func togglePkg(ctx: ActionContext, org: String, name: String): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            this.msg.set("无权限：需要管理员登录")
            return PatchResult.ReRender
        }
        let cur = st.adminData.listTeamPackages(this.editingId)
        var found = false
        let next = ArrayList<(String, String)>()
        for (p in cur) {
            if (p.organization == org && p.packageName == name) {
                found = true
            } else {
                next.add((p.organization, p.packageName))
            }
        }
        if (!found) {
            next.add((org, name))
        }
        st.adminData.setTeamPackages(this.editingId, next.toArray(), nowMs())
        this.msg.set(if (!found) { "已关联 ${name}" } else { "已移除 ${name}" })
        this.refreshPkgs()
        PatchResult.ReRender
    }

    // ===== 成员关联 =====
    func openMembers(ctx: ActionContext, id: Int64): PatchResult {
        this.editingId = id
        this.memberSearch.set("")
        this.refreshMembers()
        this.memberDialogVisible.set(true)
        PatchResult.ReRender
    }

    func closeMembers(ctx: ActionContext): PatchResult {
        this.memberDialogVisible.set(false)
        PatchResult.ReRender
    }

    // 成员列表：全量用户 + 搜索过滤 + 关联标记
    func refreshMembers(): Unit {
        match (this.state) {
            case Some(st) =>
                let kw = this.memberSearch.get()
                let linked = st.adminData.listTeamMemberIds(this.editingId)
                let data = ArrayList<MemberRow>()
                for (u in st.userStore.listAllUsers()) {
                    if (kw != "" && !u.username.contains(kw)) { continue }
                    var isLinked = false
                    for (uid in linked) {
                        if (uid == u.id) {
                            isLinked = true
                            break
                        }
                    }
                    data.add(MemberRow(u, isLinked))
                }
                this.memberRows.set(data)
            case None => ()
        }
    }

    func toggleMember(ctx: ActionContext, userId: Int64): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            this.msg.set("无权限：需要管理员登录")
            return PatchResult.ReRender
        }
        let cur = st.adminData.listTeamMemberIds(this.editingId)
        var found = false
        let next = ArrayList<Int64>()
        for (uid in cur) {
            if (uid == userId) {
                found = true
            } else {
                next.add(uid)
            }
        }
        if (!found) {
            next.add(userId)
        }
        st.adminData.setTeamMembers(this.editingId, next.toArray())
        this.msg.set(if (!found) { "已添加成员" } else { "已移除成员" })
        this.refreshMembers()
        PatchResult.ReRender
    }

    // ===== 删除 =====
    func askDelete(ctx: ActionContext, id: Int64): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        match (st.adminData.getTeam(id)) {
            case Some(t) =>
                this.pendingDeleteId = t.id
                this.pendingDeleteName = t.name
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
        if (st.adminData.deleteTeam(this.pendingDeleteId, nowMs())) {
            this.msg.set("已删除团队 ${this.pendingDeleteName}")
            st.adminData.addLog(LogKind.Admin, sessionUid(ctx), sessionUsername(ctx), "delete team ${this.pendingDeleteName}", "ok", nowMs())
        } else {
            this.msg.set("删除失败")
        }
        this.confirmVisible.set(false)
        this.pendingDeleteId = 0
        PatchResult.ReRender
    }

    // ===== 渲染 =====
    func permTag(p: String): IComponent {
        match (p) {
            case "write" => Tag([text("写入")]).kind(ComponentKind.Warning)
            case "overwrite" => Tag([text("覆盖")]).kind(ComponentKind.Danger)
            case _ => Tag([text("读取")]).kind(ComponentKind.Info)
        }
    }

    func renderList(): IComponent {
        if (this.rows.get().size == 0) {
            return emptyState("暂无团队，点击「新增团队」创建")
        }
        Table<TeamRow>()
            .data(this.rows)
            .stripe()
            .add(TableColumn<TeamRow>().label("ID").accessor({ r => r.doc.id.toString() }).width(50))
            .add(TableColumn<TeamRow>().label("团队名").accessor({ r => r.doc.name }).minWidth(130))
            .add(TableColumn<TeamRow>().label("显示名").accessor({ r => r.doc.displayName }).minWidth(130))
            .add(TableColumn<TeamRow>().label("权限").width(90).render({ r, i =>
                this.permTag(r.doc.permission)
            }))
            .add(TableColumn<TeamRow>().label("成员").accessor({ r => r.members.toString() }).width(70))
            .add(TableColumn<TeamRow>().label("组织").accessor({ r => r.orgs.toString() }).width(70))
            .add(TableColumn<TeamRow>().label("包").accessor({ r => r.pkgs.toString() }).width(70))
            .add(TableColumn<TeamRow>().label("操作").minWidth(260).render({ r, i =>
                let id = r.doc.id
                let editH: ActionHandler = { c => this.openEdit(c, id) }
                let orgH: ActionHandler = { c => this.openOrgs(c, id) }
                let pkgH: ActionHandler = { c => this.openPackages(c, id) }
                let memberH: ActionHandler = { c => this.openMembers(c, id) }
                let deleteH: ActionHandler = { c => this.askDelete(c, id) }
                div([
                    Button([text("编辑")]).size(ButtonSize.Small).onClick(editH),
                    Button([text("组织")]).size(ButtonSize.Small).onClick(orgH),
                    Button([text("包")]).size(ButtonSize.Small).onClick(pkgH),
                    Button([text("成员")]).size(ButtonSize.Small).onClick(memberH),
                    Button([text("删除")]).size(ButtonSize.Small).kind(ButtonKind.Danger).onClick(deleteH),
                ])
            }))
    }

    func renderFormDialog(): IComponent {
        let title = if (this.dialogMode.get() == "create") { "新增团队" } else { "编辑团队" }
        let isEdit = this.dialogMode.get() == "edit"
        let nameInput = if (isEdit) {
            Input().bind(this.formName).disabled()
        } else {
            Input().bind(this.formName)
        }
        let permSelect = Select([
            SelectOption([text("读取（可下载）")], "read"),
            SelectOption([text("写入（可发布）")], "write"),
            SelectOption([text("覆盖（可覆盖版本）")], "overwrite"),
        ]).bind(this.formPermission).placeholder("默认权限")
        let form = Form([
            FormItem([nameInput]).label("团队名")
                .bindValue({ => this.formName.get() })
                .rule(FormRule(required: true, message: "团队名必填"))
                .errorSignal(this.teamNameError),
            FormItem([Input().bind(this.formDisplay).placeholder("可选")]).label("显示名")
                .bindValue({ => this.formDisplay.get() }),
            FormItem([Input().bind(this.formDesc).placeholder("可选")]).label("描述")
                .bindValue({ => this.formDesc.get() }),
            FormItem([permSelect]).label("默认权限")
                .bindValue({ => this.formPermission.get() }),
        ]).labelTop()
        this.teamForm = form
        let dlg = Dialog([form])
            .visible(this.dialogVisible)
            .title(title)
            .width("440px")
            .closeOnClickModal(false)
            .footer([
                Button([text("取消")]).onClick(closeDialog),
                Button([text("确定")]).kind(ButtonKind.Primary).onClick(submitForm),
            ])
        dlg
    }

    func renderOrgDialog(): IComponent {
        let orgOptions = ArrayList<IComponent>()
        let st = match (this.state) {
            case Some(x) => x
            case None => return div()
        }
        // 无组织包选项（value=0，对齐 cjrepo NULL 语义）
        orgOptions.add(SelectOption([text("（无组织包）")], "0"))
        for (o in st.adminData.listOrgs()) {
            let label = if (o.displayName.isEmpty()) { o.name } else { "${o.displayName}（${o.name}）" }
            orgOptions.add(SelectOption([text(label)], o.id.toString()))
        }
        let dlg = Dialog([
            div([
                div([text("选择团队可操作的组织（含「无组织包」；可多选）")], attrs: Some(HashMap<String, String>([("class", cls("dialog-form-label"))]))),
                Select(orgOptions.toArray()).bindMulti(this.orgSelect).multiple().placeholder("选择组织"),
            ], attrs: Some(HashMap<String, String>([("class", cls("dialog-form"))]))),
        ])
            .visible(this.orgDialogVisible)
            .title("团队组织关联")
            .width("480px")
            .closeOnClickModal(false)
            .footer([
                Button([text("取消")]).onClick(closeOrgs),
                Button([text("保存")]).kind(ButtonKind.Primary).onClick(saveOrgs),
            ])
        dlg
    }

    func renderPkgDialog(): IComponent {
        let dlg = Dialog([
            div([
                div([text("搜索包并关联/移除（权限走团队默认权限）")], attrs: Some(HashMap<String, String>([("class", cls("dialog-form-label"))]))),
                Input().bind(this.pkgSearch).placeholder("搜索包名").on("input", { _ =>
                    this.refreshPkgs()
                    PatchResult.ReRender
                }),
                Table<PkgRow>()
                    .data(this.pkgRows)
                    .stripe()
                    .add(TableColumn<PkgRow>().label("包").minWidth(280).render({ r, i =>
                        text("${if (r.doc.organization.isEmpty()) { "-" } else { r.doc.organization }}/${r.doc.name}@${r.doc.version}")
                    }))
                    .add(TableColumn<PkgRow>().label("操作").width(100).render({ r, i =>
                        let org = r.doc.organization
                        let name = r.doc.name
                        let toggleH: ActionHandler = { c => this.togglePkg(c, org, name) }
                        Button([text(if (r.linked) { "移除" } else { "关联" })]).size(ButtonSize.Small).kind(if (r.linked) { ButtonKind.Danger } else { ButtonKind.Primary }).onClick(toggleH)
                    })),
            ], attrs: Some(HashMap<String, String>([("class", cls("dialog-form"))]))),
        ])
            .visible(this.pkgDialogVisible)
            .title("团队包关联")
            .width("560px")
            .closeOnClickModal(false)
            .footer([
                Button([text("关闭")]).onClick(closePackages),
            ])
        dlg
    }

    func renderMemberDialog(): IComponent {
        let dlg = Dialog([
            div([
                div([text("搜索用户并添加/移除成员")], attrs: Some(HashMap<String, String>([("class", cls("dialog-form-label"))]))),
                Input().bind(this.memberSearch).placeholder("搜索用户名").on("input", { _ =>
                    this.refreshMembers()
                    PatchResult.ReRender
                }),
                Table<MemberRow>()
                    .data(this.memberRows)
                    .stripe()
                    .add(TableColumn<MemberRow>().label("用户名").accessor({ r => r.user.username }).minWidth(200))
                    .add(TableColumn<MemberRow>().label("操作").width(100).render({ r, i =>
                        let uid = r.user.id
                        let toggleH: ActionHandler = { c => this.toggleMember(c, uid) }
                        Button([text(if (r.linked) { "移除" } else { "添加" })]).size(ButtonSize.Small).kind(if (r.linked) { ButtonKind.Danger } else { ButtonKind.Primary }).onClick(toggleH)
                    })),
            ], attrs: Some(HashMap<String, String>([("class", cls("dialog-form"))]))),
        ])
            .visible(this.memberDialogVisible)
            .title("团队成员管理")
            .width("480px")
            .closeOnClickModal(false)
            .footer([
                Button([text("关闭")]).onClick(closeMembers),
            ])
        dlg
    }

    func renderConfirmDialog(): IComponent {
        let dlg = Dialog([
            div([text("确定要删除团队「${this.pendingDeleteName}」吗？其组织/包/成员关联将一并移除。")]),
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
            Button([text("新增团队")]).kind(ButtonKind.Primary).onClick(openCreate),
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
        adminLayout("/admin/teams", [
            div([text("团队管理")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            adminCard("团队列表", [toolbar, this.renderList(), pager, this.renderFormDialog(), this.renderOrgDialog(), this.renderPkgDialog(), this.renderMemberDialog(), this.renderConfirmDialog()]),
        ])
    }
}
