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
    // 新增 Dialog
    var dialogVisible = Signal<Bool>(false)
    var formUser = Signal<String>("")
    var formPass = Signal<String>("")
    var formEmail = Signal<String>("")
    var formIsAdmin = Signal<Bool>(false)
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
    }

    func refresh(): ArrayList<User> {
        match (this.state) {
            case Some(st) => st.userStore.listAllUsers()
            case None => ArrayList<User>()
        }
    }

    // ===== 新增用户 =====
    func openCreate(ctx: ActionContext): PatchResult {
        this.formUser.set("")
        this.formPass.set("")
        this.formEmail.set("")
        this.formIsAdmin.set(false)
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
        let uname = this.formUser.get()
        let pass = this.formPass.get()
        if (uname.isEmpty() || pass.isEmpty()) {
            this.msg.set("用户名和密码必填")
            return PatchResult.ReRender
        }
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
    func showToken(ctx: ActionContext, u: User): PatchResult {
        this.tokenUser = u.username
        this.tokenValue.set(u.publishToken)
        this.tokenUserId = u.id
        this.tokenVisible.set(true)
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
    func toggleActive(ctx: ActionContext, u: User): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            this.msg.set("无权限：需要管理员登录")
            return PatchResult.ReRender
        }
        if (st.auth.setUserActive(u.id, !u.isActive)) {
            this.msg.set(if (!u.isActive) { "已启用 ${u.username}" } else { "已禁用 ${u.username}" })
            st.adminData.addLog(LogKind.Admin, sessionUid(ctx), sessionUsername(ctx), "toggle user ${u.username}", "ok", nowMs())
        }
        PatchResult.ReRender
    }

    // ===== 删除 =====
    func askDelete(ctx: ActionContext, u: User): PatchResult {
        this.pendingDeleteId = u.id
        this.pendingDeleteName = u.username
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
    func renderUserRow(u: User): IComponent {
        let tokenHandler: ActionHandler = { c => this.showToken(c, u) }
        let toggleHandler: ActionHandler = { c => this.toggleActive(c, u) }
        let deleteHandler: ActionHandler = { c => this.askDelete(c, u) }
        let adminTag = if (u.isAdmin) {
            Tag([text("管理员")]).kind(ComponentKind.Primary)
        } else {
            Tag([text("普通")]).kind(ComponentKind.Info)
        }
        let activeTag = if (u.isActive) {
            Tag([text("正常")]).kind(ComponentKind.Success)
        } else {
            Tag([text("禁用")]).kind(ComponentKind.Danger)
        }
        div([
            div([text(u.id.toString())], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text(u.username)], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text(u.email)], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([adminTag], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([activeTag], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([
                Button([text("Token")]).size(ButtonSize.Small).onClick(tokenHandler),
                Button([text(if (u.isActive) { "禁用" } else { "启用" })]).size(ButtonSize.Small).onClick(toggleHandler),
                if (u.isAdmin) {
                    div()
                } else {
                    Button([text("删除")]).size(ButtonSize.Small).kind(ButtonKind.Danger).onClick(deleteHandler)
                },
            ], attrs: Some(HashMap<String, String>([("class", cls("admin-td") + " " + cls("admin-actions"))]))),
        ], attrs: Some(HashMap<String, String>([("class", cls("admin-tr"))])))
    }

    func renderList(): IComponent {
        let users = this.refresh()
        let rows = ArrayList<IComponent>()
        rows.add(div([
            div([text("ID")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text("用户名")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text("邮箱")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text("角色")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text("状态")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text("操作")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
        ], attrs: Some(HashMap<String, String>([("class", cls("admin-tr") + " " + cls("admin-th"))]))))
        for (u in users) {
            rows.add(this.renderUserRow(u))
        }
        div(rows.toArray(), attrs: Some(HashMap<String, String>([("class", cls("admin-table"))])))
    }

    func renderCreateDialog(): IComponent {
        let dlg = Dialog([
            div([
                div([text("用户名")], attrs: Some(HashMap<String, String>([("class", cls("dialog-form-label"))]))),
                Input().bind(this.formUser).placeholder("登录用户名"),
                div([text("密码")], attrs: Some(HashMap<String, String>([("class", cls("dialog-form-label"))]))),
                Input().bind(this.formPass).placeholder("初始密码").password(),
                div([text("邮箱")], attrs: Some(HashMap<String, String>([("class", cls("dialog-form-label"))]))),
                Input().bind(this.formEmail).placeholder("可选"),
                div([text("管理员")], attrs: Some(HashMap<String, String>([("class", cls("dialog-form-label"))]))),
                Switch().bind(this.formIsAdmin).activeText("管理员").inactiveText("普通"),
            ], attrs: Some(HashMap<String, String>([("class", cls("dialog-form"))]))),
        ])
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
        adminLayout("/admin/users", [
            div([text("用户管理")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            adminCard("用户列表", [toolbar, this.renderList(), this.renderCreateDialog(), this.renderTokenDialog(), this.renderConfirmDialog()]),
        ])
    }
}

// ===== 组织管理 =====
@Page["/admin/organizations", "组织管理", requireAdmin]
class OrganizationsPage <: Component {
    var state: Option<CjregState> = None
    var msg = Signal<String>("")
    // 新增/编辑 Dialog
    var dialogVisible = Signal<Bool>(false)
    var dialogMode = Signal<String>("create")
    var editingId: Int64 = 0
    var formName = Signal<String>("")
    var formDisplay = Signal<String>("")
    var formDesc = Signal<String>("")
    var formIsDefault = Signal<Bool>(false)
    // 删除确认
    var confirmVisible = Signal<Bool>(false)
    var pendingDeleteId: Int64 = 0
    var pendingDeleteName: String = ""

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
    }

    // ===== 新增/编辑 =====
    func openCreate(ctx: ActionContext): PatchResult {
        this.dialogMode.set("create")
        this.formName.set("")
        this.formDisplay.set("")
        this.formDesc.set("")
        this.formIsDefault.set(false)
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
        let name = this.formName.get()
        let display = this.formDisplay.get()
        let desc = this.formDesc.get()
        let isDefault = this.formIsDefault.get()
        if (name.isEmpty()) {
            this.msg.set("组织名必填")
            return PatchResult.ReRender
        }
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
        PatchResult.ReRender
    }

    // ===== 删除 =====
    func askDelete(ctx: ActionContext, o: OrgDoc): PatchResult {
        this.pendingDeleteId = o.id
        this.pendingDeleteName = o.name
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
    func renderOrgRow(o: OrgDoc): IComponent {
        let editHandler: ActionHandler = { c => this.openEdit(c, o.id) }
        let deleteHandler: ActionHandler = { c => this.askDelete(c, o) }
        let defaultTag = if (o.isDefault) {
            Tag([text("默认")]).kind(ComponentKind.Primary)
        } else {
            Tag([text("普通")]).kind(ComponentKind.Info)
        }
        div([
            div([text(o.id.toString())], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text(o.name)], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text(o.displayName)], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text(o.description)], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([defaultTag], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([
                Button([text("编辑")]).size(ButtonSize.Small).onClick(editHandler),
                Button([text("删除")]).size(ButtonSize.Small).kind(ButtonKind.Danger).onClick(deleteHandler),
            ], attrs: Some(HashMap<String, String>([("class", cls("admin-td") + " " + cls("admin-actions"))]))),
        ], attrs: Some(HashMap<String, String>([("class", cls("admin-tr"))])))
    }

    func renderList(): IComponent {
        let orgs = match (this.state) {
            case Some(st) => st.adminData.listOrgs()
            case None => ArrayList<OrgDoc>()
        }
        let rows = ArrayList<IComponent>()
        rows.add(div([
            div([text("ID")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text("组织名")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text("显示名")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text("描述")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text("默认")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text("操作")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
        ], attrs: Some(HashMap<String, String>([("class", cls("admin-tr") + " " + cls("admin-th"))]))))
        for (o in orgs) {
            rows.add(this.renderOrgRow(o))
        }
        div(rows.toArray(), attrs: Some(HashMap<String, String>([("class", cls("admin-table"))])))
    }

    func renderFormDialog(): IComponent {
        let title = if (this.dialogMode.get() == "create") { "新增组织" } else { "编辑组织" }
        let isEdit = this.dialogMode.get() == "edit"
        let nameInput = if (isEdit) {
            Input().bind(this.formName).disabled()
        } else {
            Input().bind(this.formName)
        }
        let dlg = Dialog([
            div([
                div([text("组织名")], attrs: Some(HashMap<String, String>([("class", cls("dialog-form-label"))]))),
                nameInput,
                div([text("显示名")], attrs: Some(HashMap<String, String>([("class", cls("dialog-form-label"))]))),
                Input().bind(this.formDisplay).placeholder("可选"),
                div([text("描述")], attrs: Some(HashMap<String, String>([("class", cls("dialog-form-label"))]))),
                Input().bind(this.formDesc).placeholder("可选"),
                div([text("默认组织")], attrs: Some(HashMap<String, String>([("class", cls("dialog-form-label"))]))),
                Switch().bind(this.formIsDefault).activeText("默认").inactiveText("普通"),
            ], attrs: Some(HashMap<String, String>([("class", cls("dialog-form"))]))),
        ])
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
        adminLayout("/admin/organizations", [
            div([text("组织管理")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            adminCard("组织列表", [toolbar, this.renderList(), this.renderFormDialog(), this.renderConfirmDialog()]),
        ])
    }
}

// ===== 团队管理 =====
@Page["/admin/teams", "团队管理", requireAdmin]
class TeamsPage <: Component {
    var state: Option<CjregState> = None
    var rows = Signal<ArrayList<HashMap<String, String>>>(ArrayList<HashMap<String, String>>())
    var newName = Signal<String>("")
    var msg = Signal<String>("")

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        refresh()
    }

    func refresh(): Unit {
        match (this.state) {
            case Some(st) =>
                let teams = st.adminData.listTeams()
                let data = ArrayList<HashMap<String, String>>()
                for (t in teams) {
                    let m = HashMap<String, String>()
                    m["id"] = t.id.toString()
                    m["name"] = t.name
                    m["display"] = t.displayName
                    m["permission"] = t.permission
                    m["memberCount"] = st.adminData.listTeamMembers(t.id).size.toString()
                    data.add(m)
                }
                this.rows.set(data)
            case None => ()
        }
    }

    public func render(): IComponent {
        let toolbar = div([
            Input().bind(this.newName).placeholder("团队名"),
            Button([text("创建团队")]).kind(ButtonKind.Primary).onClick(createTeam),
            if (this.msg.get() != "") {
                Tag([text(this.msg.get())]).kind(ComponentKind.Success)
            } else {
                div()
            },
        ], attrs: Some(HashMap<String, String>([("class", cls("toolbar"))])))
        let table = Table()
            .data(this.rows)
            .stripe()
            .add(TableColumn().label("ID").colProp("id").width(60))
            .add(TableColumn().label("团队名").colProp("name"))
            .add(TableColumn().label("显示名").colProp("display"))
            .add(TableColumn().label("权限").colProp("permission").width(100))
            .add(TableColumn().label("成员数").colProp("memberCount").width(80))
        adminLayout("/admin/teams", [
            div([text("团队管理")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            adminCard("团队列表", [toolbar, table]),
        ])
    }

    func createTeam(ctx: ActionContext): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            this.msg.set("无权限：需要管理员登录")
            return PatchResult.ReRender
        }
        let name = this.newName.get()
        if (name.isEmpty()) {
            this.msg.set("团队名必填")
            return PatchResult.ReRender
        }
        let uid = sessionUid(ctx)
        let uname = sessionUsername(ctx)
        let id = st.adminData.createTeam(name, nowMs())
        this.msg.set("已创建团队 #${id}")
        this.newName.set("")
        st.adminData.addLog(LogKind.Admin, uid, uname, "create team ${name}", "ok", nowMs())
        refresh()
        PatchResult.ReRender
    }
}
