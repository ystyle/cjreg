// cjxt 管理界面全局状态：持有 cjreg 服务引用供页面组件访问
package ystyle::cjreg.ui

import cjxt.*
import ystyle::cjreg.store.*
import ystyle::cjreg.config.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*
import ystyle::cjreg.server.*
import std.collection.*
import std.convert.*

public class CjregState <: AppState {
    public var pkgStore: PackageStore
    public var userStore: BstormUserStore
    public var upStore: BstormUpstreamStore
    public var adminData: AdminDataStore
    public var auth: AuthService
    // cjxt App 实例（异步执行时服务端推送进度用）
    public var app: Option<App>
    // 服务端运行配置（cjreg.toml）：门户提示权限模式、门户/文档里的示例地址都取自它
    public var config: CjregConfig
    // 制品库（包硬删除时清理 blob；None = 未注入，硬删不可用）——由 main.cj 的状态工厂注入
    public var blobStore: ?BlobStore = None
    // 回源代理（管理端「重拉」用；None = 未注入，重拉不可用）
    public var proxySvc: ?ProxyService = None
    // 登录态
    public var currentUser: Signal<Option<User>> = Signal<Option<User>>(Option<User>.None)
    public var sessionToken: Signal<String> = Signal<String>("")
    // 计划执行进度（异步执行时 pushUpdate 更新，详情页订阅渲染）
    public var planBusy = Signal<Bool>(false)
    public var planProgress = Signal<String>("")
    public var planStatus = Signal<String>("")

    public init(pkgStore: PackageStore, userStore: BstormUserStore,
                upStore: BstormUpstreamStore, adminData: AdminDataStore, auth: AuthService,
                app!: Option<App> = None, config!: CjregConfig = CjregConfig()) {
        this.pkgStore = pkgStore
        this.userStore = userStore
        this.upStore = upStore
        this.adminData = adminData
        this.auth = auth
        this.app = app
        this.config = config
    }

    /// 操作级用户校验：已登录且用户仍存在、启用（不要求管理员）——用户门户动作用
    public func userSession(ctx: ActionContext): ?User {
        match (ctx.getContext().get("uid")) {
            case Some(uidStr) =>
                let uid = match (Int64.tryParse(uidStr)) {
                    case Some(n) => n
                    case None => return None
                }
                match (this.userStore.getUser(uid)) {
                    case Some(u) => if (u.isActive) { Some(u) } else { None }
                    case None => None
                }
            case None => None
        }
    }

    /// 操作级权限校验：会话上下文标记为管理员，且该用户仍存在、启用、isAdmin
    /// （上下文可跨 HTTP 刷新恢复，是鉴权权威来源；再反查 DB 防止已禁用账号越权）
    public func isAdminSession(ctx: ActionContext): Bool {
        if (requireAdmin(ctx.getContext()).isSome()) {
            return false
        }
        match (this.userSession(ctx)) {
            case Some(u) => u.isAdmin
            case None => false
        }
    }
}

// ===== UI 侧审计 =====
// HTTP 侧审计见 src/server/audit.cj（writeAudit，带真实 IP/UA）；
// 管理端页面是 WS 调用，无 HTTP 请求上下文，故 IP/UA 记为来源标记（admin-ui）。
// action 用下划线动词（create_user/enable_user/...），与 HTTP 侧口径一致；
// target 为被操作对象（用户名/团队名/组织名/包名），detail 放补充信息。
public func uiAudit(st: CjregState, ctx: ActionContext, action: String, target: String,
                    status!: String = "ok", error!: String = "", detail!: String = ""): Unit {
    let _ = st.adminData.addLog(LogKind.Admin, sessionUid(ctx), sessionUsername(ctx), action, status, nowMs(),
        target: target, error: error, detail: detail, ipAddr: "admin-ui", userAgent: "cjxt-admin-ui")
}

// 同上：调用点已持有操作者身份（如创建组织/团队时从会话取出的 uid/uname）
public func uiAuditAs(st: CjregState, actorId: Int64, actorName: String, action: String, target: String,
                      status!: String = "ok", error!: String = "", detail!: String = ""): Unit {
    let _ = st.adminData.addLog(LogKind.Admin, actorId, actorName, action, status, nowMs(),
        target: target, error: error, detail: detail, ipAddr: "admin-ui", userAgent: "cjxt-admin-ui")
}
