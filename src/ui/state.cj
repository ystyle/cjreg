// cjxt 管理界面全局状态：持有 cjreg 服务引用供页面组件访问
package ystyle::cjreg.ui

import cjxt.*
import ystyle::cjreg.store.*
import ystyle::cjreg.config.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*
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
