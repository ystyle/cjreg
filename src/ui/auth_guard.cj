// 管理界面鉴权守卫：页面级守卫 + 操作级权限校验
package ystyle::cjreg.ui

import cjxt.*
import std.collection.*
import std.convert.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*

/// 页面守卫：仅已登录管理员可访问 /admin*。
/// cjxt 守卫签名 (HashMap<String,String>) -> Option<String>：
/// None = 放行；Some(path) = 拒绝访问并跳转到 path（由应用自己决定跳转目标）。
public func requireAdmin(ctx: HashMap<String, String>): Option<String> {
    match (ctx.get("isAdmin")) {
        case Some(v) => if (v == "1") { None } else { Some("/admin/login") }
        case None => Some("/admin/login")
    }
}

/// 会话上下文中的操作者 uid（未登录返回 0）
public func sessionUid(ctx: ActionContext): Int64 {
    match (ctx.getContext().get("uid")) {
        case Some(v) =>
            match (Int64.tryParse(v)) {
                case Some(n) => n
                case None => 0
            }
        case None => 0
    }
}

/// 会话上下文中的操作者用户名（未登录返回 "system"）
public func sessionUsername(ctx: ActionContext): String {
    match (ctx.getContext().get("username")) {
        case Some(v) => v
        case None => "system"
    }
}

/// token 校验钩子（cjxt App.auth）：校验会话 token，返回要写入会话上下文的
/// 信息（uid/username/isAdmin）。校验失败或用户非管理员返回 None。
public func restoreAdminSession(auth: AuthService, token: String): Option<HashMap<String, String>> {
    match (auth.validateSessionToken(token)) {
        case Some(u) =>
            let m = HashMap<String, String>()
            m["uid"] = u.id.toString()
            m["username"] = u.username
            m["isAdmin"] = if (u.isAdmin) { "1" } else { "0" }
            Some(m)
        case None => None
    }
}
