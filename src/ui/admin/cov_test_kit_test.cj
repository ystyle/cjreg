// cov_* 系列测试共用桩：动作上下文装配 + 渲染序列化 + 造数。
//
// 与既有 `*_render_test.cj` 同一套路，但把「可观测的 ActionContext」独立出来：
// 管理页的动作大多要鉴权（isAdminSession）与写审计（sessionUid/sessionUsername），
// 所以每个用例都得有一个能拿 `ctx.getContext()` 的上下文，而不是只有一个生命周期上下文。
package ystyle::cjreg.ui.admin

import ystyle::cjreg.ui.*
import cjxt.*
import ystyle::cjreg.store.*
import ystyle::cjreg.config.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.util.*
import ystyle::cjreg.auth.model.*
import std.collection.*
import std.reflect.*

// 渲染整棵（子）树为 JSON 字符串
func covRender(c: IComponent): String {
    serializeSubtree(c, HashMap<String, ActionHandler>())
}

// 展开组件树后再序列化：组件级事件（Component.on）与 SignalView 的订阅只能在渲染遍历里生效
func covRenderExpanded(c: IComponent): String {
    serializeSubtree(RenderContext.expandTree(c, ""), HashMap<String, ActionHandler>())
}

// 造一个包版本文档（可按需设置来源/软删/制品/README 等展示字段）
func covSeedPkg(state: CjregState, org: String, name: String, version: String,
                desc!: String = "", deleted!: Bool = false, upstreamId!: Int64 = 0,
                upstreamName!: String = "", sha!: String = "", size!: Int64 = 0,
                downloads!: Int64 = 0, readme!: String = "", publisherId!: Int64 = 0,
                updatedAt!: Int64 = 2000): PackageDoc {
    let d = PackageDoc()
    d.organization = org
    d.name = name
    d.version = version
    d.description = desc
    d.deletedAt = if (deleted) { 1 } else { 0 }
    d.upstreamId = upstreamId
    d.upstreamName = upstreamName
    d.sha256 = sha
    d.tarballSize = size
    d.downloadCount = downloads
    d.readme = readme
    d.publisherId = publisherId
    d.createdAt = 1000
    d.updatedAt = updatedAt
    state.pkgStore.save(d)
    d
}

// 造一个上游（默认自建镜像仓，可回源、不可推送）
func covSeedUpstream(state: CjregState, name: String,
                     url!: String = "https://mirror.test/registry", enabled!: Bool = true,
                     isOfficial!: Bool = false, proxyEnabled!: Bool = true,
                     asTarget!: Bool = true, priority!: Int64 = 0,
                     cacheTtl!: Int64 = 86400, lastSyncAt!: Int64 = 0,
                     authToken!: String = ""): Int64 {
    let id = state.upStore.nextId()
    state.upStore.save(Upstream(id, name, url, enabled, cacheTtl, authToken, isOfficial,
        priority, lastSyncAt, proxyEnabled: proxyEnabled, asTarget: asTarget))
    id
}

// 造一个用户并返回其 id（同名已存在时复用）
func covActorId(state: CjregState, isAdmin!: Bool = true, username!: String = "covadmin"): Int64 {
    match (state.userStore.getUserByUsername(username)) {
        case Some(u) => u.id
        case None => state.auth.createUser(username, "CovPass123", isAdmin).getOrThrow().id
    }
}

// 可观测的 ActionContext：会话上下文可事后断言，导航被记录。
// dbIsAdmin 决定库里那条用户记录是不是管理员（isAdminSession 会反查 DB），
// ctxIsAdmin 决定会话上下文里的 isAdmin（页面守卫读它）—— 两者分开才能覆盖"上下文说自己是管理员、
// 但库里已经被降级/禁用"这类越权路径。
func covActx(state: CjregState, dbIsAdmin!: Bool = true, ctxIsAdmin!: Bool = true,
             username!: String = "covadmin",
             key!: Option<KeyEvent> = Option<KeyEvent>.None): (ActionContext, ArrayList<String>) {
    let uid = covActorId(state, isAdmin: dbIsAdmin, username: username)
    let sessionCtx = HashMap<String, String>()
    sessionCtx["uid"] = uid.toString()
    sessionCtx["username"] = username
    sessionCtx["isAdmin"] = if (ctxIsAdmin) { "1" } else { "0" }
    sessionCtx["token"] = "sess-cov"
    let nav = ArrayList<String>()
    let router = Router("sid-test", { p => nav.add(p) })
    let states = HashMap<String, AppState>()
    states.add(TypeInfo.of<CjregState>().qualifiedName, state)
    let actx = ActionContext("sid-test", sessionCtx, HashMap<String, String>(), router,
        sessionStates: states, keyEvent: key)
    (actx, nav)
}

// 未登录上下文（uid 缺失）：应被所有管理动作拒绝
func covAnonActx(state: CjregState): ActionContext {
    let sessionCtx = HashMap<String, String>()
    let router = Router("sid-test", { _ => () })
    let states = HashMap<String, AppState>()
    states.add(TypeInfo.of<CjregState>().qualifiedName, state)
    ActionContext("sid-test", sessionCtx, HashMap<String, String>(), router, sessionStates: states)
}

// 回车键事件（登录页 onEnter 用）
func covEnterKey(): Option<KeyEvent> {
    Some(KeyEvent("Enter", "Enter", 13, false, false, false, false))
}

// 重复拼接出一段长文本（String 没有 repeat，这里手写；用于"超长文本不被截断"这类边界断言）
func covLongText(chunk: String, times: Int64): String {
    let sb = StringBuilder()
    for (_ in 0..times) {
        sb.append(chunk)
    }
    sb.toString()
}
