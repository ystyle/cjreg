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
    // 登录态
    public var currentUser: Signal<Option<User>> = Signal<Option<User>>(Option<User>.None)
    public var sessionToken: Signal<String> = Signal<String>("")

    public init(pkgStore: PackageStore, userStore: BstormUserStore,
                upStore: BstormUpstreamStore, adminData: AdminDataStore, auth: AuthService) {
        this.pkgStore = pkgStore
        this.userStore = userStore
        this.upStore = upStore
        this.adminData = adminData
        this.auth = auth
    }

    /// 操作级权限校验：会话上下文标记为管理员，且该用户仍存在、启用、isAdmin
    /// （上下文可跨 HTTP 刷新恢复，是鉴权权威来源；再反查 DB 防止已禁用账号越权）
    public func isAdminSession(ctx: ActionContext): Bool {
        if (requireAdmin(ctx.getContext()).isSome()) {
            return false
        }
        match (ctx.getContext().get("uid")) {
            case Some(uidStr) =>
                let uid = match (Int64.tryParse(uidStr)) {
                    case Some(n) => n
                    case None => return false
                }
                match (this.userStore.getUser(uid)) {
                    case Some(u) => u.isAdmin && u.isActive
                    case None => false
                }
            case None => false
        }
    }
}
