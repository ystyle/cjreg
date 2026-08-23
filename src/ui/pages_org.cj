// cjxt 管理界面：用户 / 组织 / 团队 管理页
package ystyle::cjreg.ui

import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.model.*
import std.collection.*
import std.convert.*

// ===== 用户管理 =====
@Page["/admin/users", "用户管理", requireAdmin]
class UsersPage <: Component {
    var state: Option<CjregState> = None
    var msg = Signal<String>("")
    // 行数据 + 分页
    var rows = Signal<ArrayList<HashMap<String, String>>>(ArrayList<HashMap<String, String>>())
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

    // 分页切片 + 行数据组装（Table 数据模型为 HashMap<String, String>）
    func refresh(): Unit {
        match (this.state) {
            case Some(st) =>
                let users = st.userStore.listAllUsers()
                this.total.set(users.size)
                let (start, end) = pageWindow(users.size, this.currentPage.get(), this.pageSize.get())
                let data = ArrayList<HashMap<String, String>>()
                var i = start
                while (i < end) {
                    let u = users[i]
                    let m = HashMap<String, String>()
                    m["id"] = u.id.toString()
                    m["username"] = u.username
                    m["email"] = u.email
                    m["isAdmin"] = if (u.isAdmin) { "1" } else { "0" }
                    m["isActive"] = if (u.isActive) { "1" } else { "0" }
                    data.add(m)
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
        Table()
            .data(this.rows)
            .stripe()
            .add(TableColumn().label("ID").colProp("id").width(60))
            .add(TableColumn().label("用户名").colProp("username").minWidth(120))
            .add(TableColumn().label("邮箱").colProp("email").minWidth(160))
            .add(TableColumn().label("角色").colProp("isAdmin").width(90).render({ r, i =>
                if (r["isAdmin"] == "1") {
                    Tag([text("管理员")]).kind(ComponentKind.Primary)
                } else {
                    Tag([text("普通")]).kind(ComponentKind.Info)
                }
            }))
            .add(TableColumn().label("状态").colProp("isActive").width(90).render({ r, i =>
                if (r["isActive"] == "1") {
                    Tag([text("正常")]).kind(ComponentKind.Success)
                } else {
                    Tag([text("禁用")]).kind(ComponentKind.Danger)
                }
            }))
            .add(TableColumn().label("操作").colProp("id").minWidth(230).render({ r, i =>
                let id = Int64.parse(r["id"], radix: 10)
                let tokenH: ActionHandler = { c => this.showToken(c, id) }
                let toggleH: ActionHandler = { c => this.toggleActive(c, id) }
                let deleteH: ActionHandler = { c => this.askDelete(c, id) }
                div([
                    Button([text("Token")]).size(ButtonSize.Small).onClick(tokenH),
                    Button([text(if (r["isActive"] == "1") { "禁用" } else { "启用" })]).size(ButtonSize.Small).onClick(toggleH),
                    if (r["isAdmin"] == "1") {
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
    // 行数据 + 分页
    var rows = Signal<ArrayList<HashMap<String, String>>>(ArrayList<HashMap<String, String>>())
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

    // 分页切片 + 行数据组装
    func refresh(): Unit {
        match (this.state) {
            case Some(st) =>
                let orgs = st.adminData.listOrgs()
                this.total.set(orgs.size)
                let (start, end) = pageWindow(orgs.size, this.currentPage.get(), this.pageSize.get())
                let data = ArrayList<HashMap<String, String>>()
                var i = start
                while (i < end) {
                    let o = orgs[i]
                    let m = HashMap<String, String>()
                    m["id"] = o.id.toString()
                    m["name"] = o.name
                    m["displayName"] = o.displayName
                    m["description"] = o.description
                    m["isDefault"] = if (o.isDefault) { "1" } else { "0" }
                    data.add(m)
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
        Table()
            .data(this.rows)
            .stripe()
            .add(TableColumn().label("ID").colProp("id").width(60))
            .add(TableColumn().label("组织名").colProp("name").minWidth(140))
            .add(TableColumn().label("显示名").colProp("displayName").minWidth(140))
            .add(TableColumn().label("描述").colProp("description").minWidth(200))
            .add(TableColumn().label("默认").colProp("isDefault").width(80).render({ r, i =>
                if (r["isDefault"] == "1") {
                    Tag([text("默认")]).kind(ComponentKind.Primary)
                } else {
                    Tag([text("普通")]).kind(ComponentKind.Info)
                }
            }))
            .add(TableColumn().label("操作").colProp("id").minWidth(160).render({ r, i =>
                let id = Int64.parse(r["id"], radix: 10)
                let editH: ActionHandler = { c => this.openEdit(c, id) }
                let deleteH: ActionHandler = { c => this.askDelete(c, id) }
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
    // 行数据 + 分页
    var rows = Signal<ArrayList<HashMap<String, String>>>(ArrayList<HashMap<String, String>>())
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
    var pkgRows = Signal<ArrayList<HashMap<String, String>>>(ArrayList<HashMap<String, String>>())
    // 成员关联 Dialog
    var memberDialogVisible = Signal<Bool>(false)
    var memberSearch = Signal<String>("")
    var memberRows = Signal<ArrayList<HashMap<String, String>>>(ArrayList<HashMap<String, String>>())
    // 删除确认
    var confirmVisible = Signal<Bool>(false)
    var pendingDeleteId: Int64 = 0
    var pendingDeleteName: String = ""

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        refresh()
    }

    // 分页切片 + 行数据组装
    func refresh(): Unit {
        match (this.state) {
            case Some(st) =>
                let teams = st.adminData.listTeams()
                this.total.set(teams.size)
                let (start, end) = pageWindow(teams.size, this.currentPage.get(), this.pageSize.get())
                let data = ArrayList<HashMap<String, String>>()
                var i = start
                while (i < end) {
                    let t = teams[i]
                    let m = HashMap<String, String>()
                    m["id"] = t.id.toString()
                    m["name"] = t.name
                    m["displayName"] = t.displayName
                    m["permission"] = t.permission
                    m["members"] = st.adminData.listTeamMembers(t.id).size.toString()
                    m["orgs"] = st.adminData.listTeamOrganizations(t.id).size.toString()
                    m["pkgs"] = st.adminData.listTeamPackages(t.id).size.toString()
                    data.add(m)
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
                let data = ArrayList<HashMap<String, String>>()
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
                    let m = HashMap<String, String>()
                    m["org"] = if (d.organization.isEmpty()) { "-" } else { d.organization }
                    m["name"] = d.name
                    m["version"] = d.version
                    m["linked"] = if (isLinked) { "1" } else { "0" }
                    data.add(m)
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
                let data = ArrayList<HashMap<String, String>>()
                for (u in st.userStore.listAllUsers()) {
                    if (kw != "" && !u.username.contains(kw)) { continue }
                    var isLinked = false
                    for (uid in linked) {
                        if (uid == u.id) {
                            isLinked = true
                            break
                        }
                    }
                    let m = HashMap<String, String>()
                    m["id"] = u.id.toString()
                    m["username"] = u.username
                    m["linked"] = if (isLinked) { "1" } else { "0" }
                    data.add(m)
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
        Table()
            .data(this.rows)
            .stripe()
            .add(TableColumn().label("ID").colProp("id").width(50))
            .add(TableColumn().label("团队名").colProp("name").minWidth(130))
            .add(TableColumn().label("显示名").colProp("displayName").minWidth(130))
            .add(TableColumn().label("权限").colProp("permission").width(90).render({ r, i =>
                this.permTag(rowStr(r, "permission"))
            }))
            .add(TableColumn().label("成员").colProp("members").width(70))
            .add(TableColumn().label("组织").colProp("orgs").width(70))
            .add(TableColumn().label("包").colProp("pkgs").width(70))
            .add(TableColumn().label("操作").colProp("id").minWidth(260).render({ r, i =>
                let id = Int64.parse(r["id"], radix: 10)
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
                Table()
                    .data(this.pkgRows)
                    .stripe()
                    .add(TableColumn().label("包").colProp("name").minWidth(280).render({ r, i =>
                        text("${rowStr(r, "org")}/${rowStr(r, "name")}@${rowStr(r, "version")}")
                    }))
                    .add(TableColumn().label("操作").colProp("linked").width(100).render({ r, i =>
                        let org = rowStr(r, "org")
                        let name = rowStr(r, "name")
                        let isLinked = rowStr(r, "linked") == "1"
                        let toggleH: ActionHandler = { c => this.togglePkg(c, org, name) }
                        Button([text(if (isLinked) { "移除" } else { "关联" })]).size(ButtonSize.Small).kind(if (isLinked) { ButtonKind.Danger } else { ButtonKind.Primary }).onClick(toggleH)
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
                Table()
                    .data(this.memberRows)
                    .stripe()
                    .add(TableColumn().label("用户名").colProp("username").minWidth(200))
                    .add(TableColumn().label("操作").colProp("linked").width(100).render({ r, i =>
                        let uid = Int64.parse(rowStr(r, "id"), radix: 10)
                        let isLinked = rowStr(r, "linked") == "1"
                        let toggleH: ActionHandler = { c => this.toggleMember(c, uid) }
                        Button([text(if (isLinked) { "移除" } else { "添加" })]).size(ButtonSize.Small).kind(if (isLinked) { ButtonKind.Danger } else { ButtonKind.Primary }).onClick(toggleH)
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
