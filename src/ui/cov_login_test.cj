// 登录页（/admin/login）渲染 + 交互回归。
//
// 原先 3.2% 行覆盖。这一页的分支集中在 busy 三态（用户名框/密码框/按钮同时切 disabled）
// 与登录结果的四条出口：管理员成功（写会话上下文 + 跳 /admin）、非管理员被拒、
// 密码错误、以及"没有推送通道时同步收尾"。回车提交只在密码框上挂。
package ystyle::cjreg.ui

import cjxt.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*
import std.collection.*
import std.reflect.*
import std.unittest.*
import std.unittest.testmacro.*

// 登录页挂在 ui 包（不是 ui.admin），admin 的 cov_* 桩在这里不可见 —— 本文件自带一份。
func covLoginRender(c: IComponent): String {
    serializeSubtree(c, HashMap<String, ActionHandler>())
}

// 展开后再序列化：组件级事件（Input().on("keydown", …)）只在渲染遍历里挂到 VNode 上
func covLoginRenderExpanded(c: IComponent): String {
    serializeSubtree(RenderContext.expandTree(c, ""), HashMap<String, ActionHandler>())
}

// 回车键事件（登录页 onEnter 用）
func covLoginEnterKey(): Option<KeyEvent> {
    Some(KeyEvent("Enter", "Enter", 13, false, false, false, false))
}

func covLoginActx(state: CjregState, key!: Option<KeyEvent> = Option<KeyEvent>.None):
    (ActionContext, HashMap<String, String>, ArrayList<String>) {
    let sessionCtx = HashMap<String, String>()
    let nav = ArrayList<String>()
    let router = Router("sid-test", { p => nav.add(p) })
    let states = HashMap<String, AppState>()
    states.add(TypeInfo.of<CjregState>().qualifiedName, state)
    (ActionContext("sid-test", sessionCtx, HashMap<String, String>(), router,
        sessionStates: states, keyEvent: key), sessionCtx, nav)
}

func covMountLogin(state: CjregState): LoginPage {
    let page = LoginPage()
    page.onMount(mountCtx(state, HashMap<String, String>()))
    page
}

@Test
public class CovLoginPageTest {
    // 空表单：页面骨架 + 两个必填星号 + 未 busy 时的按钮文案
    @TestCase
    public func covLogin_rendersEmptyForm(): Unit {
        let state = makePortalState("open")
        let json = covLoginRenderExpanded(covMountLogin(state).render())
        @Expect(json.contains("管理控制台"), true)
        @Expect(json.contains("登 录"), true)
        @Expect(json.contains("用户名"), true)
        @Expect(json.contains("密码"), true)
        @Expect(json.contains("登录中..."), true)   // Loading 组件文案常驻
        @Expect(json.contains("is-required"), true)
        // 未 busy：按钮可点、密码框挂 keydown（回车提交）
        @Expect(json.contains("\"disabled\":\"disabled\""), false)
        @Expect(json.contains("keydown"), true)
    }

    // busy 态：用户名/密码框都禁用、按钮换成「登录中...」并禁用
    @TestCase
    public func covLogin_busyDisablesInputsAndButton(): Unit {
        let state = makePortalState("open")
        let page = covMountLogin(state)
        page.busy.set(true)
        let json = covLoginRenderExpanded(page.render())
        @Expect(json.contains("登录中..."), true)
        @Expect(json.contains("登 录"), false)
        @Expect(json.contains("\"disabled\":\"disabled\""), true)
        // busy 态不再挂回车提交
        @Expect(json.contains("keydown"), false)
    }

    // 错误提示：errorMsg 非空时渲染 login-error 区块，空时不渲染
    @TestCase
    public func covLogin_errorBannerFollowsSignal(): Unit {
        let state = makePortalState("open")
        let page = covMountLogin(state)
        @Expect(covLoginRender(page.render()).contains("login-error"), false)
        page.errorMsg.set("用户名或密码错误")
        let json = covLoginRender(page.render())
        @Expect(json.contains("login-error"), true)
        @Expect(json.contains("用户名或密码错误"), true)
        page.errorMsg.set("")
        @Expect(covLoginRender(page.render()).contains("login-error"), false)
    }

    // 表单必填校验：用户名/密码为空时 doLogin 直接返回，不置 busy、不写上下文
    @TestCase
    public func covLogin_emptyFormFailsValidation(): Unit {
        let state = makePortalState("open")
        let page = covMountLogin(state)
        // loginForm 是 render() 里建的（FormItem 的 errorSignal 也在那里接线）：
        // 不先渲染一次，validate() 面对的是一个空 Form，永远返回 true
        let _ = covLoginRender(page.render())
        let (actx, sessionCtx, nav) = covLoginActx(state)

        let _ = page.doLogin(actx)
        @Expect(page.userError.get(), "请输入用户名")
        @Expect(page.busy.get(), false)
        @Expect(sessionCtx.contains("uid"), false)
        @Expect(nav.size, 0)

        // 只填用户名 → 报密码必填
        page.username.set("someone")
        let _ = page.doLogin(actx)
        @Expect(page.passError.get(), "请输入密码")
        @Expect(page.busy.get(), false)
    }

    // busy 时重复提交：直接返回，不做第二次校验/登录
    @TestCase
    public func covLogin_doLoginIsIdempotentWhileBusy(): Unit {
        let state = makePortalState("open")
        let page = covMountLogin(state)
        let (actx, _, _) = covLoginActx(state)
        page.busy.set(true)
        let _ = page.doLogin(actx)
        @Expect(page.busy.get(), true)
        // 密码为空也不该写校验错误（根本没走到校验）
        @Expect(page.userError.get(), "")
    }

    // 未挂载 state：doLogin / finishLogin 走 None 分支
    @TestCase
    public func covLogin_withoutState(): Unit {
        let state = makePortalState("open")
        let page = LoginPage()
        let (actx, _, _) = covLoginActx(state)
        let _ = page.doLogin(actx)
        @Expect(page.busy.get(), false)
        let _ = page.finishLogin(actx, "x", "y")
        @Expect(page.errorMsg.get(), "")
        @Expect(covLoginRender(page.render()).contains("管理控制台"), true)
    }

    // 管理员登录成功：写会话上下文（含 token）、清错误、复位 busy、跳 /admin
    @TestCase
    public func covLogin_adminLoginSucceeds(): Unit {
        let state = makePortalState("open")
        let admin = state.auth.createUser("root", "RootPass123", true).getOrThrow()
        let page = covMountLogin(state)
        let (actx, sessionCtx, nav) = covLoginActx(state)

        let _ = page.finishLogin(actx, "root", "RootPass123")
        @Expect(sessionCtx.get("uid").getOrThrow(), admin.id.toString())
        @Expect(sessionCtx.get("username").getOrThrow(), "root")
        @Expect(sessionCtx.get("isAdmin").getOrThrow(), "1")
        @Expect(sessionCtx.get("token").getOrThrow().isEmpty(), false)
        @Expect(nav[0], "/admin")
        @Expect(page.errorMsg.get(), "")
        @Expect(page.busy.get(), false)
        // 登录态信号与审计
        @Expect(state.currentUser.get().getOrThrow().username, "root")
        @Expect(state.sessionToken.get().isEmpty(), false)
        let (logs, total) = state.adminData.queryLogs(Some("auth"), "login", "", 0, 0, 0, 10)
        @Expect(total, 1)
        @Expect(logs[0].actorName, "root")
    }

    // 非管理员：明确拒绝，不写上下文、不跳转、清 busy
    @TestCase
    public func covLogin_nonAdminIsRejected(): Unit {
        let state = makePortalState("open")
        let _ = state.auth.createUser("plain", "PlainPass123", false).getOrThrow()
        let page = covMountLogin(state)
        page.busy.set(true)
        let (actx, sessionCtx, nav) = covLoginActx(state)

        let _ = page.finishLogin(actx, "plain", "PlainPass123")
        @Expect(page.errorMsg.get(), "无权限：仅管理员可登录管理后台")
        @Expect(page.busy.get(), false)
        @Expect(sessionCtx.contains("uid"), false)
        @Expect(nav.size, 0)
        @Expect(state.currentUser.get().isNone(), true)
    }

    // 密码错误：提示「用户名或密码错误」，清 busy
    @TestCase
    public func covLogin_wrongPasswordFails(): Unit {
        let state = makePortalState("open")
        let _ = state.auth.createUser("root2", "RootPass123", true).getOrThrow()
        let page = covMountLogin(state)
        page.busy.set(true)
        let (actx, sessionCtx, nav) = covLoginActx(state)

        let _ = page.finishLogin(actx, "root2", "WrongPass")
        @Expect(page.errorMsg.get(), "用户名或密码错误")
        @Expect(page.busy.get(), false)
        @Expect(sessionCtx.contains("uid"), false)
        @Expect(nav.size, 0)
    }

    // 被禁用的管理员也登录不上（login 先判 isActive）
    @TestCase
    public func covLogin_disabledAdminCannotLogin(): Unit {
        let state = makePortalState("open")
        let a = state.auth.createUser("admin-x", "Pass123456", true).getOrThrow()
        let b = state.auth.createUser("admin-y", "Pass123456", true).getOrThrow()
        @Expect(state.auth.setUserActive(a.id, false), true)
        let page = covMountLogin(state)
        let (actx, _, nav) = covLoginActx(state)
        let _ = page.finishLogin(actx, "admin-x", "Pass123456")
        @Expect(page.errorMsg.get(), "用户名或密码错误")
        @Expect(nav.size, 0)
        // 反向对照：另一个启用管理员能进
        let _ = page.finishLogin(actx, "admin-y", "Pass123456")
        @Expect(nav[0], "/admin")
        @Expect(state.userStore.getUser(b.id).isSome(), true)
    }

    // 回车提交：密码框回车 → 走登录流程（无 App 时同步收尾）
    @TestCase
    public func covLogin_enterSubmitsLogin(): Unit {
        let state = makePortalState("open")
        let _ = state.auth.createUser("root3", "RootPass123", true).getOrThrow()
        let page = covMountLogin(state)
        let (actx, _, nav) = covLoginActx(state, key: covLoginEnterKey())

        page.username.set("root3")
        page.password.set("RootPass123")
        let _ = page.onEnter(actx)
        // makePortalState 不注入 App → runLoginAsync 返回 false → 同步 finishLogin
        @Expect(nav[0], "/admin")
        @Expect(page.busy.get(), false)
        @Expect(page.errorMsg.get(), "")
    }

    // 非回车键：onEnter 什么都不做，也不清已有错误
    @TestCase
    public func covLogin_nonEnterKeyIsIgnored(): Unit {
        let state = makePortalState("open")
        let page = covMountLogin(state)
        page.errorMsg.set("keep-me")
        let ke = Some(KeyEvent("a", "KeyA", 65, false, false, false, false))
        let (actx, _, nav) = covLoginActx(state, key: ke)
        let _ = page.onEnter(actx)
        @Expect(page.errorMsg.get(), "keep-me")
        @Expect(nav.size, 0)
    }

    // 没有 keyEvent（普通点击路径）：onEnter 走 None 分支
    @TestCase
    public func covLogin_onEnterWithoutKeyEvent(): Unit {
        let state = makePortalState("open")
        let page = covMountLogin(state)
        let (actx, _, nav) = covLoginActx(state)
        let _ = page.onEnter(actx)
        @Expect(nav.size, 0)
        @Expect(page.busy.get(), false)
    }

    // doLogin 走通（无 App 时同步 finishLogin）：busy 会先置真再被收尾复位
    @TestCase
    public func covLogin_doLoginSyncPathOnSuccess(): Unit {
        let state = makePortalState("open")
        let _ = state.auth.createUser("root4", "RootPass123", true).getOrThrow()
        let page = covMountLogin(state)
        let (actx, sessionCtx, nav) = covLoginActx(state)

        page.username.set("root4")
        page.password.set("RootPass123")
        let _ = page.doLogin(actx)
        @Expect(page.busy.get(), false)
        @Expect(sessionCtx.get("username").getOrThrow(), "root4")
        @Expect(nav[0], "/admin")
    }

    // 登录失败后重新输入再登：错误清空、这次成功（守住 errorMsg 不会被粘住）
    @TestCase
    public func covLogin_retryAfterFailureSucceeds(): Unit {
        let state = makePortalState("open")
        let _ = state.auth.createUser("root5", "RootPass123", true).getOrThrow()
        let page = covMountLogin(state)
        let (actx, _, nav) = covLoginActx(state)

        page.username.set("root5")
        page.password.set("bad")
        let _ = page.doLogin(actx)
        @Expect(page.errorMsg.get(), "用户名或密码错误")
        @Expect(nav.size, 0)

        page.password.set("RootPass123")
        let _ = page.doLogin(actx)
        @Expect(page.errorMsg.get(), "")
        @Expect(nav[0], "/admin")
    }
}
