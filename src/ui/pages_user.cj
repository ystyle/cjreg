// cjxt 用户门户：普通用户登录页（/user/login）+ 个人中心（/me）
//
// 角色模型（见 docs/user-portal-design.md §1）：
//   - 管理员与普通用户是同一套用户体系、同一个 AuthService.login；
//   - /admin/login 仍只接受管理员（同时是 requireAdmin 的跳转目标）；
//   - /user/login 接受所有启用用户（含管理员），登录态里 isAdmin 从用户对象取；
//   - /me 由 requireUser 守卫（登录即可），三区块：发布 Token / 我的包 / 我的团队与权限。
package ystyle::cjreg.ui

import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.model.*
import ystyle::cjreg.server.*
import std.collection.*
import std.time.*
import std.convert.*

// ===== 用户登录页 =====
@Page["/user/login", "用户登录"]
class UserLoginPage <: Component {
    var state: Option<CjregState> = None
    var username = Signal<String>("")
    var password = Signal<String>("")
    var errorMsg = Signal<String>("")
    var busy = Signal<Bool>(false)
    var userError = Signal<String>("")
    var passError = Signal<String>("")
    var loginForm = Form([])

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
    }

    public func render(): IComponent {
        let userInput = if (this.busy.get()) {
            Input().bind(this.username).placeholder("用户名").size(ComponentSize.Large).disabled()
        } else {
            Input().bind(this.username).placeholder("用户名").size(ComponentSize.Large)
        }
        let passInput = if (this.busy.get()) {
            Input().bind(this.password).placeholder("密码").password().size(ComponentSize.Large).disabled()
        } else {
            Input().bind(this.password).placeholder("密码").password().size(ComponentSize.Large).on("keydown", onEnter)
        }
        let loginBtn = if (this.busy.get()) {
            Button([text("登录中...")]).kind(ButtonKind.Primary).size(ButtonSize.Large).disabled()
        } else {
            Button([text("登 录")]).kind(ButtonKind.Primary).size(ButtonSize.Large).onClick(doLogin)
        }
        let form = Form([
            FormItem([userInput]).label("用户名")
                .bindValue({ => this.username.get() })
                .rule(FormRule(required: true, message: "请输入用户名"))
                .errorSignal(this.userError),
            FormItem([passInput]).label("密码")
                .bindValue({ => this.password.get() })
                .rule(FormRule(required: true, message: "请输入密码"))
                .errorSignal(this.passError),
        ]).labelTop()
        this.loginForm = form
        let toAdmin: ActionHandler = { c => c.route.push("/admin/login"); PatchResult.ReRender }
        div([
            div([text("cjreg 用户门户")], attrs: Some(HashMap<String, String>([("class", cls("login-title"))]))),
            div([
                form,
                if (this.errorMsg.get() != "") {
                    div([text(this.errorMsg.get())], attrs: Some(HashMap<String, String>([("class", cls("login-error"))])))
                } else {
                    div()
                },
                div([
                    loginBtn,
                ], attrs: Some(HashMap<String, String>([("class", cls("toolbar"))]))),
                div([
                    text("普通用户与管理员均可从此登录；管理员可进入管理后台。"),
                ], attrs: Some(HashMap<String, String>([("class", cls("login-foot-hint"))]))),
                div([
                    Button([text("管理员登录入口")]).size(ButtonSize.Small).onClick(toAdmin),
                ], attrs: Some(HashMap<String, String>([("class", cls("toolbar"))]))),
                // 登录中遮罩（cjxt Loading 组件；卡片 position:relative 见 admin.css）
                Loading().bind(this.busy).label("登录中..."),
            ], attrs: Some(HashMap<String, String>([("class", cls("login-card"))]))),
        ], attrs: Some(HashMap<String, String>([("class", cls("login-container"))])))
    }

    // 回车提交（密码框 keydown）
    func onEnter(ctx: ActionContext): PatchResult {
        match (ctx.keyEvent) {
            case Some(ke) =>
                if (ke.isEnter()) {
                    return this.doLogin(ctx)
                }
            case None => ()
        }
        PatchResult.ReRender
    }

    // 登录：先置 busy 并立即返回（前端先收到 loading 补丁），密码校验放后台线程，
    // 完成后经 App.pushUpdate 回到会话串行上下文收尾（共用 runLoginAsync，见 login.cj）
    func doLogin(ctx: ActionContext): PatchResult {
        if (this.busy.get()) {
            return PatchResult.ReRender
        }
        let s = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!this.loginForm.validate()) {
            return PatchResult.ReRender
        }
        let u = this.username.get()
        let p = this.password.get()
        this.errorMsg.set("")
        this.busy.set(true)
        if (runLoginAsync(s, ctx.getSessionId(), u, p, { actx, name, pass => this.finishLogin(actx, name, pass) })) {
            return PatchResult.ReRender
        }
        this.finishLogin(ctx, u, p)
    }

    // 登录结果收尾（在 pushUpdate 的串行上下文里执行）
    func finishLogin(ctx: ActionContext, u: String, p: String): PatchResult {
        let s = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        match (s.auth.login(u, p)) {
            case Some((user, token)) =>
                // 所有启用用户都可登录；isAdmin 从用户对象取（不再硬编码），
                // 这样管理员从门户登录后同样能进管理后台
                ctx.setContext("uid", user.id.toString())
                ctx.setContext("username", user.username)
                ctx.setContext("isAdmin", if (user.isAdmin) { "1" } else { "0" })
                ctx.setContext("token", token.token)
                s.currentUser.set(Some(user))
                s.sessionToken.set(token.token)
                s.adminData.addLog(LogKind.Auth, user.id, user.username, "user login", "ok", nowMs())
                this.errorMsg.set("")
                this.busy.set(false)
                ctx.route.push("/me")
            case None =>
                this.errorMsg.set("用户名或密码错误")
                this.busy.set(false)
        }
        PatchResult.ReRender
    }
}

// ===== 个人中心（/me）=====
@Page["/me", "我的", requireUser]
class UserPortalPage <: Component {
    var state: Option<CjregState> = None
    // 会话上下文：onMount 取引用，render 期读（令牌恢复后的就地重渲不重跑 onMount）
    var sctx: Option<SessionContext> = None
    // 已加载数据的用户 id（会话换人时就地重渲也能纠正列表）
    var loadedUid: Int64 = 0

    var msg = Signal<String>("")
    var msgOk = Signal<Bool>(true)

    // 发布 Token
    var tokenValue = Signal<String>("")
    var resetVisible = Signal<Bool>(false)

    // 我的包
    var pkgSearch = Signal<String>("")
    var pkgRows = Signal<ArrayList<MyPackageRow>>(ArrayList<MyPackageRow>())
    var pkgTotal = Signal<Int64>(0)
    var pkgPage = Signal<Int64>(1)
    var pkgPageSize = Signal<Int64>(10)

    // 我的团队与权限
    var teamRows = Signal<ArrayList<MyTeamRow>>(ArrayList<MyTeamRow>())

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        this.sctx = ctx.getSessionContext()
        this.refresh()
    }

    // 当前登录用户 id（会话上下文为空 → 0）
    func currentUid(): Int64 {
        match (this.sctx) {
            case Some(s) => s.uid
            case None => 0
        }
    }

    // 用户名（未登录为空串）
    func currentUsername(): String {
        match (this.sctx) {
            case Some(s) => s.username
            case None => ""
        }
    }

    // 会话用户与已加载数据不一致时重新加载（就地重渲路径不会重跑 onMount）
    func refreshIfUserChanged(): Unit {
        if (this.currentUid() != this.loadedUid) {
            this.refresh()
        }
    }

    // 加载/刷新三个区块的数据
    func refresh(): Unit {
        let uid = this.currentUid()
        this.loadedUid = uid
        if (uid <= 0) {
            return
        }
        let st = match (this.state) {
            case Some(x) => x
            case None => return
        }
        match (st.userStore.getUser(uid)) {
            case Some(u) => this.tokenValue.set(u.publishToken)
            case None => ()
        }
        // 我的包：我发布过版本的包（owner 标记由读模型给出）+ 名称/组织过滤 + 分页
        let all = myPackageRows(st.pkgStore, st.adminData, uid)
        let kw = this.pkgSearch.get()
        let hits = ArrayList<MyPackageRow>()
        for (r in all) {
            if (kw.isEmpty() || r.name.contains(kw) || r.org.contains(kw)) {
                hits.add(r)
            }
        }
        this.pkgTotal.set(hits.size)
        let (start, end) = pageWindow(hits.size, this.pkgPage.get(), this.pkgPageSize.get())
        let rows = ArrayList<MyPackageRow>()
        var i = start
        while (i < end) {
            rows.add(hits[i])
            i++
        }
        this.pkgRows.set(rows)
        // 我的团队与权限
        this.teamRows.set(myTeamRows(st.adminData, uid))
    }

    // 统一提示（成功/失败决定 Tag 颜色）
    func notify(text: String, ok: Bool): Unit {
        this.msg.set(text)
        this.msgOk.set(ok)
    }

    // ===== 交互 =====
    func onSearch(ctx: ActionContext): PatchResult {
        this.pkgPage.set(1)
        this.refresh()
        PatchResult.ReRender
    }

    func onPageChange(ctx: ActionContext): PatchResult {
        this.refresh()
        PatchResult.ReRender
    }

    func askResetToken(ctx: ActionContext): PatchResult {
        this.resetVisible.set(true)
        PatchResult.ReRender
    }

    func cancelResetToken(ctx: ActionContext): PatchResult {
        this.resetVisible.set(false)
        PatchResult.ReRender
    }

    // 重置发布 Token：只能重置自己的（用户 id 取自会话，不接受客户端传入）
    func confirmResetToken(ctx: ActionContext): PatchResult {
        this.resetVisible.set(false)
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        let user = match (st.userSession(ctx)) {
            case Some(u) => u
            case None =>
                this.notify("会话已失效，请重新登录", false)
                return PatchResult.ReRender
        }
        match (st.auth.resetPublishToken(user.id)) {
            case Some(t) =>
                this.tokenValue.set(t)
                st.adminData.addLog(LogKind.Auth, user.id, user.username, "reset publish token (portal)", "ok", nowMs())
                this.notify("已重置发布 Token（旧 Token 已失效）", true)
            case None =>
                this.notify("重置失败：用户不存在", false)
        }
        PatchResult.ReRender
    }

    func doLogout(ctx: ActionContext): PatchResult {
        clearSessionContext(ctx)
        try {
            ctx.getState<CjregState>().currentUser.set(Option<User>.None)
        } catch (e: Exception) {
            // 同 layout.cj 的退出登录：用户回调里吞异常，登录态没清干净也查不到原因。
            println("[cjreg] 用户门户退出登录清空 currentUser 失败: " + e.toString())
        }
        ctx.route.push("/user/login")
        PatchResult.ReRender
    }

    // ===== 渲染 =====

    // 区块一：我的发布 Token（完整值 + 重置；重置后旧 Token 立即失效）
    func renderTokenSection(): IComponent {
        let resetH: ActionHandler = { c => this.askResetToken(c) }
        // registry 示例用配置的对外地址（cjreg.toml 的 server.public_url）
        let base = match (this.state) {
            case Some(st) => if (st.config.publicUrl.isEmpty()) { "http://<cjreg 地址>" } else { st.config.publicUrl }
            case None => "http://<cjreg 地址>"
        }
        let example = "[repository.home]\n" +
            "registry = \"${base}\"\n" +
            "token = \"${this.tokenValue.get()}\""
        div([
            div([text("我的发布 Token")], attrs: Some(HashMap<String, String>([("class", cls("portal-section-title"))]))),
            div([text("用于 cjpm 发布鉴权：写入项目根目录 cangjie-repo.toml 的 token 字段。请勿泄漏——持有它即可发布。")],
                attrs: Some(HashMap<String, String>([("class", cls("portal-hint"))]))),
            div([
                Input().readonly().bind(this.tokenValue),
                Button([text("重置 Token")]).kind(ButtonKind.Warning).onClick(resetH),
            ], attrs: Some(HashMap<String, String>([("class", cls("portal-token-row"))]))),
            div([text("cangjie-repo.toml 示例（registry 取自服务配置，可直接复制）")],
                attrs: Some(HashMap<String, String>([("class", cls("portal-hint"))]))),
            div([text(example)], attrs: Some(HashMap<String, String>([("class", cls("code-block"))]))),
        ], attrs: Some(HashMap<String, String>([("class", cls("portal-section"))])))
    }

    // 区块二：我的包（我发布过版本的包 + owner 标记 + 搜索/分页）
    func renderPackagesSection(): IComponent {
        let pager = Pagination()
            .currentPage(this.pkgPage)
            .pageSize(this.pkgPageSize)
            .total(this.pkgTotal.get())
            .layout("total, prev, pager, next")
            .onChange(onPageChange)
        let table = Table<MyPackageRow>()
            .data(this.pkgRows)
            .stripe()
            .add(TableColumn<MyPackageRow>().label("包名").minWidth(240).render({ r, i =>
                div([
                    text(r.displayName()),
                ])
            }))
            .add(TableColumn<MyPackageRow>().label("版本数").width(90).accessor({ r => r.versionCount.toString() }))
            .add(TableColumn<MyPackageRow>().label("最新版本").width(120).accessor({ r => if (r.latestVersion.isEmpty()) { "-" } else { r.latestVersion } }))
            .add(TableColumn<MyPackageRow>().label("角色").width(110).render({ r, i =>
                if (r.isOwner) {
                    Tag([text("所有者")]).kind(ComponentKind.Primary)
                } else {
                    Tag([text("协作者")]).kind(ComponentKind.Info)
                }
            }))
            .add(TableColumn<MyPackageRow>().label("最近发布").width(140).render({ r, i =>
                text(formatTimeMs(r.updatedAt))
            }))
            .add(TableColumn<MyPackageRow>().label("操作").width(100).render({ r, i =>
                let go: ActionHandler = { c =>
                    c.route.push("/packages/${pkgDisplayName(r.org, r.name)}")
                    PatchResult.ReRender
                }
                Button([text("详情")]).size(ButtonSize.Small).onClick(go)
            }))
        div([
            div([text("我的包")], attrs: Some(HashMap<String, String>([("class", cls("portal-section-title"))]))),
            div([text("我发布过版本的包（含参与协作的包）；「所有者」= 该包最早一条版本记录的发布者，只有所有者能凭个人身份发新版本。")],
                attrs: Some(HashMap<String, String>([("class", cls("portal-hint"))]))),
            div([Input().bind(this.pkgSearch).placeholder("按包名/组织搜索").on("keydown", onEnterSearch)],
                attrs: Some(HashMap<String, String>([("class", cls("portal-search"))]))),
            if (this.pkgTotal.get() == 0) {
                emptyState("还没有发布过包——用上面的 Token 发布第一个包吧")
            } else {
                div([table])
            },
            if (this.pkgTotal.get() > 0) {
                div([pager], attrs: Some(HashMap<String, String>([("class", cls("pager-wrap"))])))
            } else {
                div()
            },
        ], attrs: Some(HashMap<String, String>([("class", cls("portal-section"))])))
    }

    func onEnterSearch(ctx: ActionContext): PatchResult {
        match (ctx.keyEvent) {
            case Some(ke) =>
                if (ke.isEnter()) {
                    return this.onSearch(ctx)
                }
            case None => ()
        }
        PatchResult.ReRender
    }

    // 区块三：我的团队与权限（只读）+ 发布权限模式提示
    func renderTeamsSection(): IComponent {
        let mode = match (this.state) {
            case Some(st) => st.config.permissionMode
            case None => "open"
        }
        let table = Table<MyTeamRow>()
            .data(this.teamRows)
            .stripe()
            .add(TableColumn<MyTeamRow>().label("团队").minWidth(160).render({ r, i => text(r.label()) }))
            .add(TableColumn<MyTeamRow>().label("权限").width(110).render({ r, i =>
                let kind = match (r.permission) {
                    case "overwrite" => ComponentKind.Danger
                    case "write" => ComponentKind.Warning
                    case _ => ComponentKind.Info
                }
                Tag([text(r.permission)]).kind(kind)
            }))
            .add(TableColumn<MyTeamRow>().label("关联组织").minWidth(160).render({ r, i =>
                text(if (r.orgNames.size == 0) { "-" } else { joinList(r.orgNames) })
            }))
            .add(TableColumn<MyTeamRow>().label("关联包").minWidth(200).render({ r, i =>
                text(if (r.packages.size == 0) { "-" } else { joinList(r.packages) })
            }))
        div([
            div([text("我的团队与权限")], attrs: Some(HashMap<String, String>([("class", cls("portal-section-title"))]))),
            div([
                Tag([text(permissionHint(mode))]).kind(if (mode == "team") { ComponentKind.Warning } else { ComponentKind.Info }),
            ], attrs: Some(HashMap<String, String>([("class", cls("portal-hint"))]))),
            if (this.teamRows.get().size == 0) {
                emptyState("暂未加入任何团队（发布权限由管理员配置）")
            } else {
                div([table])
            },
        ], attrs: Some(HashMap<String, String>([("class", cls("portal-section"))])))
    }

    func renderResetDialog(): IComponent {
        MessageBox(this.resetVisible)
            .kind(MessageBoxKind2.Confirm)
            .icon(MessageBoxIcon2.Warning)
            .title("重置发布 Token")
            .message("重置后旧 Token 立即失效，正在使用它的本地配置与 CI 需要同步更新。确定继续？")
            .confirmText("重置")
            .cancelText("取消")
            .onConfirm(confirmResetToken)
            .onCancel(cancelResetToken)
    }

    public func render(): IComponent {
        this.refreshIfUserChanged()
        let msgKind = if (this.msgOk.get()) { ComponentKind.Success } else { ComponentKind.Danger }
        div([
            publicNav("/me", this.sctx),
            div([
                div([text("个人门户")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
                div([text("当前登录：${this.currentUsername()}")], attrs: Some(HashMap<String, String>([("class", cls("page-subtitle"))]))),
                if (this.msg.get() != "") {
                    div([Tag([text(this.msg.get())]).kind(msgKind)], attrs: Some(HashMap<String, String>([("class", cls("empty-line"))])))
                } else {
                    div()
                },
                this.renderTokenSection(),
                this.renderPackagesSection(),
                this.renderTeamsSection(),
                div([
                    Button([text("退出登录")]).size(ButtonSize.Small).onClick(doLogout),
                ], attrs: Some(HashMap<String, String>([("class", cls("toolbar"))]))),
                this.renderResetDialog(),
            ], attrs: Some(HashMap<String, String>([("class", cls("public-main"))]))),
        ])
    }
}

// ===== 工具 =====

// 列表拼接（团队关联组织/包展示）
func joinList(items: ArrayList<String>): String {
    let sb = StringBuilder()
    for (i in 0..items.size) {
        if (i > 0) {
            sb.append("、")
        }
        sb.append(items[i])
    }
    sb.toString()
}

// 时间戳 → "MM-dd HH:mm"（与日志页展示口径一致）
func formatTimeMs(ms: Int64): String {
    if (ms <= 0) {
        return "-"
    }
    DateTime.fromUnixTimeStamp(Duration.millisecond * ms).inLocal().format("MM-dd HH:mm")
}
