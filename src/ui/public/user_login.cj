// 用户登录页（@Page /user/login）
package ystyle::cjreg.ui.public

import ystyle::cjreg.ui.*
import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.model.*
import ystyle::cjreg.server.{MyPackageRow, MyTeamRow, myPackageRows, myTeamRows, permissionHint}
import std.collection.*
import std.time.*
import std.convert.*

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
            div([text("${SITE_NAME} 用户门户")], attrs: Some(HashMap<String, String>([("class", cls("login-title"))]))),
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
