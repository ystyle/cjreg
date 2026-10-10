// 用户登录页单元测试（user_login.cj）
//
// 登录是「表单校验 → 异步校验口令 → 收尾」三段，任何一段断了都表现为"点登录没反应"：
//   ① 空字段必须被表单规则拦住（不发请求、不置 busy）；
//   ② 校验期间置 busy 并立刻返回（前端先拿到 loading 补丁），完成后收尾；
//   ③ 成功后写会话上下文（uid/username/isAdmin/token）并跳 /me —— 管理员从门户登录后
//      必须带 isAdmin=1，否则进不了管理后台；失败只提示、绝不写上下文、也不跳转。
// 本文件用 makePortalState 的同步路径（app=None → runLoginAsync 返回 false）跑完整流程。
package ystyle::cjreg.ui.public

import ystyle::cjreg.ui.*

import cjxt.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.util.*
import ystyle::cjreg.auth.model.*
import ystyle::cjreg.config.*
import std.collection.*
import std.reflect.*
import std.unittest.*
import std.unittest.testmacro.*

// ===== 夹具 =====

func mountLogin(state: CjregState): UserLoginPage {
    let page = UserLoginPage()
    page.onMount(mountCtx(state, HashMap<String, String>()))
    return page
}

func renderLogin(page: UserLoginPage): String {
    serializeSubtree(page.render(), HashMap<String, ActionHandler>())
}

// 可观测的 ActionContext：会话上下文可事后断言、导航被记录、可按需注入 keyEvent
func loginActionCtx(state: CjregState, keyEnter!: Bool = false, withKeyEvent!: Bool = false)
    : (ActionContext, HashMap<String, String>, ArrayList<String>) {
    let sessionCtx = HashMap<String, String>()
    let nav = ArrayList<String>()
    let router = Router("sid-login", { p => nav.add(p) })
    let states = HashMap<String, AppState>()
    states.add(TypeInfo.of<CjregState>().qualifiedName, state)
    let ke = if (withKeyEvent) {
        Some(KeyEvent(if (keyEnter) { "Enter" } else { "a" }, "", 13, false, false, false, false))
    } else {
        Option<KeyEvent>.None
    }
    let actx = ActionContext("sid-login", sessionCtx, HashMap<String, String>(), router,
        sessionStates: states, keyEvent: ke)
    (actx, sessionCtx, nav)
}

@Test
public class UserLoginRenderTest {
    // 页面骨架：标题、两个字段、管理员入口、Loading 遮罩常驻（隐藏时 display:none）
    @TestCase
    public func testLoginPageSkeleton(): Unit {
        let state = makePortalState("open")
        let page = mountLogin(state)
        let json = renderLogin(page)
        @Expect(json.contains("cjreg 用户门户"), true)
        @Expect(json.contains("用户名"), true)
        @Expect(json.contains("密码"), true)
        @Expect(json.contains("登 录"), true)
        @Expect(json.contains("管理员登录入口"), true)
        @Expect(json.contains("普通用户与管理员均可从此登录"), true)
        @Expect(json.contains("el-loading-mask"), true)
        @Expect(json.contains("登录中..."), true)
        @Expect(json.contains("display:none"), true)      // 非 busy 时遮罩隐藏
        @Expect(json.contains("login-container"), true)
        @Expect(json.contains("login-card"), true)
    }

    // 未 onMount（state=None）也能渲染，不崩
    @TestCase
    public func testRenderWithoutMount(): Unit {
        let page = UserLoginPage()
        let json = renderLogin(page)
        @Expect(json.contains("cjreg 用户门户"), true)
    }

    // busy=true → 输入禁用、按钮变「登录中...」并 disabled（遮罩显示）
    @TestCase
    public func testBusyStateDisablesForm(): Unit {
        let state = makePortalState("open")
        let page = mountLogin(state)
        page.busy.set(true)
        let json = renderLogin(page)
        @Expect(json.contains("登录中..."), true)
        @Expect(json.contains("disabled"), true)
        @Expect(json.contains("登 录"), false)          // 换成「登录中...」
    }

    // errorMsg 非空才渲染错误行；空串时给空 div
    @TestCase
    public func testErrorLineAppearsOnlyWhenSet(): Unit {
        let state = makePortalState("open")
        let page = mountLogin(state)
        @Expect(renderLogin(page).contains("login-error"), false)
        page.errorMsg.set("用户名或密码错误")
        let json = renderLogin(page)
        @Expect(json.contains("用户名或密码错误"), true)
        @Expect(json.contains("login-error"), true)
    }

    // 密码框回车提交：keydown 事件挂在密码输入上（expandTree 后才可见）
    @TestCase
    public func testPasswordInputCarriesKeydownAction(): Unit {
        let state = makePortalState("open")
        let page = mountLogin(state)
        let json = serializeSubtree(RenderContext.expandTree(page.render(), ""), HashMap<String, ActionHandler>())
        @Expect(json.contains("keydown"), true)
        @Expect(json.contains("data-bind-id"), true)
    }
}

@Test
public class UserLoginFlowTest {
    // 表单校验：两个字段都空 → 不进入登录（不置 busy、不发跳转、上下文不写）
    @TestCase
    public func testEmptyFieldsBlockedByFormValidation(): Unit {
        let state = makePortalState("open")
        let _ = state.auth.createUser("alice", "AlicePass1", false)
        let page = mountLogin(state)
        let _ = renderLogin(page)     // 建立表单实例（doLogin 依赖 render 期创建的 loginForm）
        @Expect(page.username.get(), "")
        @Expect(page.password.get(), "")

        let (actx, sessionCtx, nav) = loginActionCtx(state)
        let _ = page.doLogin(actx)
        @Expect(page.busy.get(), false)          // 被校验拦住，没进入登录流程
        @Expect(nav.size, 0)
        @Expect(sessionCtx.contains("uid"), false)
    }

    // 只填用户名 → 仍然被拦（密码 required）
    @TestCase
    public func testMissingPasswordBlocked(): Unit {
        let state = makePortalState("open")
        let _ = state.auth.createUser("alice", "AlicePass1", false)
        let page = mountLogin(state)
        page.username.set("alice")
        let _ = renderLogin(page)
        let (actx, _, nav) = loginActionCtx(state)
        let _ = page.doLogin(actx)
        @Expect(page.busy.get(), false)
        @Expect(nav.size, 0)
    }

    // 登录成功（同步路径）：写全会话上下文 + 跳 /me
    @TestCase
    public func testSuccessfulLoginWritesContextAndRedirects(): Unit {
        let state = makePortalState("open")
        let alice = state.auth.createUser("alice", "AlicePass1", false).getOrThrow()
        let page = mountLogin(state)
        page.username.set("alice")
        page.password.set("AlicePass1")
        let _ = renderLogin(page)

        let (actx, sessionCtx, nav) = loginActionCtx(state)
        let _ = page.doLogin(actx)

        @Expect(sessionCtx.get("uid").getOrThrow(), alice.id.toString())
        @Expect(sessionCtx.get("username").getOrThrow(), "alice")
        @Expect(sessionCtx.get("isAdmin").getOrThrow(), "0")
        @Expect(sessionCtx.get("token").getOrThrow().startsWith("sess-"), true)
        @Expect(nav.size, 1)
        @Expect(nav[0], "/me")
        @Expect(page.busy.get(), false)          // busy 复位
        @Expect(page.errorMsg.get(), "")         // 无错误提示
        @Expect(state.currentUser.get().isSome(), true)
        @Expect(state.sessionToken.get().startsWith("sess-"), true)
    }

    // 管理员从门户登录 → isAdmin=1（否则进不了 /admin）
    @TestCase
    public func testAdminLoginSetsAdminFlag(): Unit {
        let state = makePortalState("team")
        let _ = state.auth.createUser("admin2", "AdminPass1", true)
        let page = mountLogin(state)
        page.username.set("admin2")
        page.password.set("AdminPass1")
        let _ = renderLogin(page)
        let (actx, sessionCtx, nav) = loginActionCtx(state)
        let _ = page.doLogin(actx)
        @Expect(sessionCtx.get("isAdmin").getOrThrow(), "1")
        @Expect(nav[0], "/me")                   // 门户登录仍先回门户，再由导航进后台
    }

    // 口令错误：提示文案 + busy 复位 + 不写上下文、不跳转
    @TestCase
    public func testWrongPasswordShowsErrorAndStays(): Unit {
        let state = makePortalState("open")
        let _ = state.auth.createUser("alice", "AlicePass1", false)
        let page = mountLogin(state)
        page.username.set("alice")
        page.password.set("WrongPass1")
        let _ = renderLogin(page)

        let (actx, sessionCtx, nav) = loginActionCtx(state)
        let _ = page.doLogin(actx)

        @Expect(page.errorMsg.get(), "用户名或密码错误")
        @Expect(page.busy.get(), false)
        @Expect(sessionCtx.contains("uid"), false)
        @Expect(nav.size, 0)
        @Expect(renderLogin(page).contains("用户名或密码错误"), true)
    }

    // 用户不存在：同样只提示、不写上下文（不泄漏"用户不存在"与"密码错"的区别）
    @TestCase
    public func testUnknownUserShowsSameError(): Unit {
        let state = makePortalState("open")
        let page = mountLogin(state)
        page.username.set("nosuch")
        page.password.set("Whatever1")
        let _ = renderLogin(page)
        let (actx, sessionCtx, nav) = loginActionCtx(state)
        let _ = page.doLogin(actx)
        @Expect(page.errorMsg.get(), "用户名或密码错误")
        @Expect(sessionCtx.contains("uid"), false)
        @Expect(nav.size, 0)
    }

    // 已禁用用户不能登录（AuthService.login 拒绝）
    @TestCase
    public func testInactiveUserCannotLogin(): Unit {
        let state = makePortalState("open")
        let u = state.auth.createUser("frozen", "FrozenPass1", false).getOrThrow()
        u.isActive = false
        state.userStore.saveUser(u)
        let page = mountLogin(state)
        page.username.set("frozen")
        page.password.set("FrozenPass1")
        let _ = renderLogin(page)
        let (actx, sessionCtx, nav) = loginActionCtx(state)
        let _ = page.doLogin(actx)
        @Expect(sessionCtx.contains("uid"), false)
        @Expect(nav.size, 0)
        @Expect(page.errorMsg.get(), "用户名或密码错误")
    }

    // busy 期间重复点击：直接返回，不做第二次校验
    @TestCase
    public func testSecondSubmitWhileBusyIsIgnored(): Unit {
        let state = makePortalState("open")
        let _ = state.auth.createUser("alice", "AlicePass1", false)
        let page = mountLogin(state)
        page.username.set("alice")
        page.password.set("AlicePass1")
        let _ = renderLogin(page)
        page.busy.set(true)
        let (actx, sessionCtx, nav) = loginActionCtx(state)
        let _ = page.doLogin(actx)
        @Expect(sessionCtx.contains("uid"), false)     // 完全没走登录
        @Expect(nav.size, 0)
    }

    // 未挂载（state=None）时 doLogin 直接返回，不抛异常
    @TestCase
    public func testDoLoginWithoutStateIsSafe(): Unit {
        let state = makePortalState("open")
        let page = UserLoginPage()          // 不 onMount
        page.username.set("alice")
        page.password.set("AlicePass1")
        let _ = renderLogin(page)
        let (actx, _, nav) = loginActionCtx(state)
        let _ = page.doLogin(actx)
        @Expect(nav.size, 0)
    }

    // 回车提交：keyEvent 是 Enter → 走登录；非 Enter → 只重渲
    @TestCase
    public func testEnterKeySubmitsLogin(): Unit {
        let state = makePortalState("open")
        let _ = state.auth.createUser("alice", "AlicePass1", false)
        let page = mountLogin(state)
        page.username.set("alice")
        page.password.set("AlicePass1")
        let _ = renderLogin(page)

        let (actx, sessionCtx, nav) = loginActionCtx(state, keyEnter: true, withKeyEvent: true)
        let _ = page.onEnter(actx)
        @Expect(nav[0], "/me")
        @Expect(sessionCtx.get("username").getOrThrow(), "alice")
    }

    // 非 Enter 键：不提交（上下文不写、不跳转）
    @TestCase
    public func testNonEnterKeyDoesNotSubmit(): Unit {
        let state = makePortalState("open")
        let _ = state.auth.createUser("alice", "AlicePass1", false)
        let page = mountLogin(state)
        page.username.set("alice")
        page.password.set("AlicePass1")
        let _ = renderLogin(page)
        let (actx, sessionCtx, nav) = loginActionCtx(state, keyEnter: false, withKeyEvent: true)
        let _ = page.onEnter(actx)
        @Expect(nav.size, 0)
        @Expect(sessionCtx.contains("uid"), false)
    }

    // 没有 keyEvent（普通点击路径）时 onEnter 不提交
    @TestCase
    public func testEnterWithoutKeyEventDoesNothing(): Unit {
        let state = makePortalState("open")
        let _ = state.auth.createUser("alice", "AlicePass1", false)
        let page = mountLogin(state)
        page.username.set("alice")
        page.password.set("AlicePass1")
        let _ = renderLogin(page)
        let (actx, _, nav) = loginActionCtx(state)   // withKeyEvent=false
        let _ = page.onEnter(actx)
        @Expect(nav.size, 0)
    }

    // finishLogin 未挂载时安全返回
    @TestCase
    public func testFinishLoginWithoutStateIsSafe(): Unit {
        let state = makePortalState("open")
        let page = UserLoginPage()
        let (actx, sessionCtx, nav) = loginActionCtx(state)
        let _ = page.finishLogin(actx, "alice", "AlicePass1")
        @Expect(sessionCtx.contains("uid"), false)
        @Expect(nav.size, 0)
    }

    // 登录成功写审计日志（Auth 类别）
    @TestCase
    public func testSuccessfulLoginWritesAuditLog(): Unit {
        let state = makePortalState("open")
        let alice = state.auth.createUser("alice", "AlicePass1", false).getOrThrow()
        let page = mountLogin(state)
        page.username.set("alice")
        page.password.set("AlicePass1")
        let _ = renderLogin(page)
        let (actx, _, _) = loginActionCtx(state)
        let _ = page.doLogin(actx)
        let logs = state.adminData.listLogs(None, 100)
        var found = false
        for (l in logs) {
            if (l.actorId == alice.id && l.action.contains("login") && l.kind == "auth") { found = true }
        }
        @Expect(found, true)
    }
}
