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
        div([
            div([text("cjreg 管理控制台")], attrs: Some(HashMap<String, String>([("class", cls("login-title"))]))),
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
    // 完成后经 App.pushUpdate 回到会话串行上下文收尾（见 runLoginAsync）
    func doLogin(ctx: ActionContext): PatchResult {
        if (this.busy.get()) {
            return PatchResult.ReRender
        }
        let s = match (this.state) {
            case Some(x) => x
            case None =>
                return PatchResult.ReRender
        }
        // 表单校验（FormRule required）
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
        // 无推送通道（未注入 App）：同步收尾
        this.finishLogin(ctx, u, p)
    }

    // 登录结果收尾（在 pushUpdate 的串行上下文里执行）：
    // 成功 → 写会话上下文（token 由框架同步给前端 localStorage，刷新后凭它恢复会话）+ 跳转；
    // 失败/非管理员 → 复位 busy 并给出提示
    func finishLogin(ctx: ActionContext, u: String, p: String): PatchResult {
        let s = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        match (s.auth.login(u, p)) {
            case Some((user, token)) =>
                if (!user.isAdmin) {
                    this.errorMsg.set("无权限：仅管理员可登录管理后台")
                    this.busy.set(false)
                    return PatchResult.ReRender
                }
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
                this.errorMsg.set("用户名或密码错误")
                this.busy.set(false)
        }
        PatchResult.ReRender
    }
}

// 异步登录：本动作先返回（前端立即显示 loading），后台线程里做 PBKDF2 校验，
// 完成后经 App.pushUpdate 回到会话串行上下文执行 finish（信号写入/导航/补丁与用户
// 操作同构）。返回 false 表示无 App（无推送通道），调用方应同步收尾。
func runLoginAsync(st: CjregState, sid: String, uname: String, pass: String,
                   finish: (ActionContext, String, String) -> PatchResult): Bool {
    let app = match (st.app) {
        case Some(a) => a
        case None => return false
    }
    spawn { =>
        let _ = app.pushUpdate(sid, { actx => finish(actx, uname, pass) })
    }
    true
}

// 当前毫秒时间戳（UTC）
public func nowMs(): Int64 {
    DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
}
