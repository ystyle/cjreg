// 管理端用户管理（@Page /admin/users）
package ystyle::cjreg.ui.admin

import ystyle::cjreg.ui.*
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
    // 提示语气：true=成功（绿），false=失败/受阻（红）
    var msgOk = Signal<Bool>(true)
    // 行数据 + 分页（泛型 Table<User>）：rows/total 由 list_binding 的 Effect 从
    // 「数据版本 + 关键字 + 分页」信号派生（搜索输入即生效，见 list_binding.cj）
    var rows = Signal<ArrayList<User>>(ArrayList<User>())
    var userSearch = Signal<String>("")
    var dataVersion = Signal<Int64>(0)
    var currentPage = Signal<Int64>(1)
    var pageSize = Signal<Int64>(20)
    var total = Signal<Int64>(0)
    // 派生绑定：页面实例跨请求复用，onMount 重建、onUnmount 释放
    private var binding: Option<Effect> = None
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
        this.binding = Some(bindPaged(this.rows, this.total, { => this.filteredUsers() },
            this.currentPage, this.pageSize))
    }

    // 用户 store 不是信号：写库后 bump 一次让派生重算（原 refresh() 的调用点）
    func bump(): Unit {
        this.dataVersion.update({ v => v + 1 })
    }

    // 列表数据：关键字过滤（用户名/邮箱，trim + ASCII 小写）。
    // 读到的信号都会被 bindPaged 的 Effect 订阅 → 输入即过滤。
    func filteredUsers(): ArrayList<User> {
        let _ = this.dataVersion.get()
        let st = match (this.state) {
            case Some(x) => x
            case None => return ArrayList<User>()
        }
        let q = this.userSearch.get().trimAscii().toAsciiLower()
        let out = ArrayList<User>()
        for (u in st.userStore.listAllUsers()) {
            if (q == "" || u.username.toAsciiLower().contains(q) || u.email.toAsciiLower().contains(q)) {
                out.add(u)
            }
        }
        out
    }

    func onPageChange(ctx: ActionContext): PatchResult {
        // 页码信号变了，派生自动重算本页行；这里只需重画一次
        PatchResult.ReRender
    }

    // 统一提示（成功/失败决定 Tag 颜色）
    func notify(text: String, ok: Bool): Unit {
        this.msg.set(text)
        this.msgOk.set(ok)
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
            this.notify("无权限：需要管理员登录", false)
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
                let role = if (u.isAdmin) { "（管理员）" } else { "" }
                this.notify("已创建 ${u.username}${role}", true)
                uiAudit(st, ctx, "create_user", u.username, detail: "isAdmin=${u.isAdmin}")
                // 展示新用户发布 Token
                this.tokenUser = u.username
                this.tokenValue.set(u.publishToken)
                this.tokenUserId = u.id
                this.tokenVisible.set(true)
            case None =>
                uiAudit(st, ctx, "create_user", uname, status: "failed", error: "user already exists")
                this.notify("创建失败（用户已存在）", false)
        }
        // 行数据由 dataVersion 派生（store 不是信号）：不 bump 的话新建的用户不会出现在列表里
        this.bump()
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
            this.notify("无权限：需要管理员登录", false)
            return PatchResult.ReRender
        }
        match (st.auth.resetPublishToken(this.tokenUserId)) {
            case Some(t) =>
                this.tokenValue.set(t)
                this.notify("已重置 ${this.tokenUser} 的 Token", true)
                uiAudit(st, ctx, "reset_publish_token", this.tokenUser)
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
            this.notify("无权限：需要管理员登录", false)
            return PatchResult.ReRender
        }
        match (st.userStore.getUser(id)) {
            case Some(u) =>
                if (st.auth.setUserActive(u.id, !u.isActive)) {
                    let text = if (!u.isActive) { "已启用 ${u.username}" } else { "已禁用 ${u.username}" }
                    this.notify(text, true)
                    uiAudit(st, ctx, if (!u.isActive) { "enable_user" } else { "disable_user" }, u.username)
                } else {
                    // 唯一失败原因：目标是最后一个启用管理员
                    uiAudit(st, ctx, "disable_user", u.username, status: "failed",
                        error: "cannot disable the last active admin")
                    this.notify("不能禁用最后一个启用管理员（否则管理端将无人可登录）", false)
                }
            case None => ()
        }
        this.bump()
        PatchResult.ReRender
    }

    // ===== 管理员身份 =====
    func toggleAdmin(ctx: ActionContext, id: Int64): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            this.notify("无权限：需要管理员登录", false)
            return PatchResult.ReRender
        }
        match (st.userStore.getUser(id)) {
            case Some(u) =>
                let target = !u.isAdmin
                if (st.auth.setUserAdmin(u.id, target)) {
                    uiAudit(st, ctx, if (target) { "grant_admin" } else { "revoke_admin" }, u.username)
                    let text = if (target) { "已设为管理员 ${u.username}" } else { "已取消管理员 ${u.username}" }
                    this.notify(text, true)
                } else {
                    // 唯一失败原因：目标是最后一个启用管理员
                    uiAudit(st, ctx, "revoke_admin", u.username, status: "failed",
                        error: "cannot revoke the last active admin")
                    this.notify("不能取消最后一个启用管理员的身份（否则管理端将无人可登录）", false)
                }
            case None => ()
        }
        this.bump()
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
            this.notify("无权限：需要管理员登录", false)
            return PatchResult.ReRender
        }
        if (st.auth.deleteUser(this.pendingDeleteId)) {
            this.notify("已删除用户 ${this.pendingDeleteName}", true)
            uiAudit(st, ctx, "delete_user", this.pendingDeleteName)
        } else {
            uiAudit(st, ctx, "delete_user", this.pendingDeleteName, status: "failed", error: "admin protected")
            this.notify("删除失败（管理员受保护）", false)
        }
        this.confirmVisible.set(false)
        this.pendingDeleteId = 0
        // 同 submitCreate：删除后必须 bump，否则被删用户仍留在表上（与 toggleActive/toggleAdmin 一致）
        this.bump()
        PatchResult.ReRender
    }

    // ===== 渲染 =====
    // 空态提示走 listBody 的固定槽位（见 layout.cj）：区分"搜不到"与"一个都没有"
    func listHint(): String {
        if (this.rows.get().size > 0) {
            return ""
        }
        if (this.userSearch.get().trimAscii() != "") {
            return "没有匹配的用户"
        }
        "暂无用户，点击「新增用户」创建"
    }

    func renderList(): IComponent {
        Table<User>()
            .data(this.rows)
            .emptyText("暂无数据")
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
            .add(TableColumn<User>().label("操作").minWidth(380).render({ u, i =>
                let tokenH: ActionHandler = { c => this.showToken(c, u.id) }
                let toggleH: ActionHandler = { c => this.toggleActive(c, u.id) }
                let adminH: ActionHandler = { c => this.toggleAdmin(c, u.id) }
                let deleteH: ActionHandler = { c => this.askDelete(c, u.id) }
                div([
                    Button([text("Token")]).size(ButtonSize.Small).onClick(tokenH),
                    Button([text(if (u.isAdmin) { "取消管理员" } else { "设为管理员" })]).size(ButtonSize.Small).kind(ButtonKind.Primary).onClick(adminH),
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
        let msgKind = if (this.msgOk.get()) { ComponentKind.Success } else { ComponentKind.Danger }
        let toolbar = div([
            // 搜索框**只 bind**：再挂一个 input 动作会立刻推回补丁、清掉客户端的 bindDirty
            // 守卫并把输入框退回旧值，300ms 后的 bind 就把空串写回信号（见 packages 页同处注释）
            Input().bind(this.userSearch).placeholder("搜索用户名 / 邮箱"),
            Button([text("新增用户")]).kind(ButtonKind.Primary).onClick(openCreate),
            if (this.msg.get() != "") {
                Tag([text(this.msg.get())]).kind(msgKind)
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
            adminCard("用户列表", [toolbar, listBody(this.listHint(), this.renderList()), pager,
                this.renderCreateDialog(), this.renderTokenDialog(), this.renderConfirmDialog()]),
        ])
    }
}
