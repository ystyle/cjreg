// cjxt 管理界面全局状态：持有 cjreg 服务引用供页面组件访问
package ystyle::cjreg.ui

import cjxt.*
import ystyle::cjreg.store.*
import ystyle::cjreg.config.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*

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
}
