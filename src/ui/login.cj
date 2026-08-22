// cjxt 管理界面：登录 + 导航布局 + 页面
package ystyle::cjreg.ui

import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import std.collection.*
import std.time.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*
import ystyle::cjreg.auth.util.*

// ===== 登录页 =====
@Page["/admin/login"]
class LoginPage <: Component {
    var state: Option<CjregState> = None
    var username = Signal<String>("")
    var password = Signal<String>("")
    var errorMsg = Signal<String>("")
    var busy = Signal<Bool>(false)

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
        div([
            div([text("cjreg 管理控制台")], attrs: Some(HashMap<String, String>([("class", cls("login-title"))]))),
            div([
                Form([
                    div([FormItem([text("用户名")])], attrs: Some(HashMap<String, String>([("class", cls("form-item"))]))),
                    userInput,
                    div([FormItem([text("密码")])], attrs: Some(HashMap<String, String>([("class", cls("form-item"))]))),
                    passInput,
                    if (this.errorMsg.get() != "") {
                        div([text(this.errorMsg.get())], attrs: Some(HashMap<String, String>([("class", cls("login-error"))])))
                    } else {
                        div()
                    },
                    loginBtn,
                ]),
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

    func doLogin(ctx: ActionContext): PatchResult {
        if (this.busy.get()) {
            return PatchResult.ReRender
        }
        this.busy.set(true)
        println("[login] doLogin clicked")
        let s = match (this.state) {
            case Some(x) => x
            case None =>
                this.busy.set(false)
                return PatchResult.ReRender
        }
        let u = this.username.get()
        let p = this.password.get()
        if (u.isEmpty() || p.isEmpty()) {
            this.errorMsg.set("请输入用户名和密码")
            this.busy.set(false)
            return PatchResult.ReRender
        }
        match (s.auth.login(u, p)) {
            case Some((user, token)) =>
                if (!user.isAdmin) {
                    println("[login] denied: user ${user.username} is not admin")
                    this.errorMsg.set("无权限：仅管理员可登录管理后台")
                    this.busy.set(false)
                    return PatchResult.ReRender
                }
                println("[login] success user=${user.username}")
                // 写会话上下文（守卫/操作鉴权的权威来源；token 由框架同步给前端 localStorage，
                // 页面刷新后随 WS 连接回传恢复会话）
                ctx.setContext("uid", user.id.toString())
                ctx.setContext("username", user.username)
                ctx.setContext("isAdmin", "1")
                ctx.setContext("token", token.token)
                s.currentUser.set(Some(user))
                s.sessionToken.set(token.token)
                s.adminData.addLog(LogKind.Auth, user.id, user.username, "login", "ok", nowMs())
                this.errorMsg.set("")
                this.busy.set(false)
                ctx.route.push("/admin")
            case None =>
                let u2 = s.userStore.getUserByUsername(u)
                match (u2) {
                    case Some(us) =>
                        println("[login] failed: hash=${us.passwordHash[0..40]}... iters=${PasswordHash.ITERATIONS}")
                    case None =>
                        println("[login] failed: user not found")
                }
                this.errorMsg.set("用户名或密码错误")
                this.busy.set(false)
        }
        PatchResult.ReRender
    }
}

// 当前毫秒时间戳（UTC）
public func nowMs(): Int64 {
    DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
}
