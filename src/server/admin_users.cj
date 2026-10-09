// 管理 API · 用户管理（列表 / 创建 / 管理员角色变更）——AdminService 的用户域扩展
package ystyle::cjreg.server

import tang.*
import ystyle::cjreg.store.*
import std.collection.*
import std.convert.*

extend AdminService {
    public func listUsers(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let users = this.userStore.listAllUsers()
        let rows = ArrayList<UserRowResp>()
        for (u in users) {
            rows.add(UserRowResp(u.id, u.username, u.isAdmin, u.isActive))
        }
        // 契约是**裸数组**（不是 {total,items} 包装）：外部脚本按 Array 解析
        writeDto(ctx, 200u16, rows)
    }

    // 创建用户（普通/管理员）：body {username, password, isAdmin?, email?}
    // isAdmin 显式传入（与管理端 UI 的「管理员」开关口径一致，不再硬编码 false）
    public func createUser(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let req = parseJsonBody<CreateUserRequest>(ctx.bodyRaw(), { r => CreateUserRequest.fromJson(r) })
        match (req) {
            case Some(r) =>
                if (r.username.isEmpty() || r.password.isEmpty()) {
                    writeDto(ctx, 400u16, ErrorResp("username and password required"))
                    return
                }
                let (actorId, actorName) = this.actorOf(ctx)
                match (this.auth.createUser(r.username, r.password, r.isAdmin, email: r.email)) {
                    case Some(u) =>
                        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "create_user", "ok", u.username, ctx,
                            detail: "isAdmin=${u.isAdmin} email=${r.email}")
                        writeDto(ctx, 200u16, UserAdminResp(u.id, u.username, u.isAdmin))
                    case None =>
                        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "create_user", "failed", r.username, ctx,
                            error: "user already exists")
                        writeDto(ctx, 409u16, ErrorResp("user already exists"))
                }
            case None =>
                writeDto(ctx, 400u16, ErrorResp("invalid JSON body"))
        }
    }

    // 提升/取消管理员：PUT /api/admin/users/:id/admin  body {isAdmin: bool}
    // 「最后一个启用管理员」不可被取消身份（409）——与管理端 UI 同一约束
    public func setUserAdmin(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let uid = match (Int64.tryParse(ctx.param("id"))) {
            case Some(n) => n
            case None => 0
        }
        if (uid <= 0) {
            writeDto(ctx, 400u16, ErrorResp("invalid user id"))
            return
        }
        let req = parseJsonBody<SetUserAdminRequest>(ctx.bodyRaw(), { r => SetUserAdminRequest.fromJson(r) })
        // 字段缺失（None）与显式 false 必须区分：前者 400，后者是「降级」语义
        var hasFlag = false
        var target = false
        match (req) {
            case Some(r) => match (r.isAdmin) {
                case Some(b) =>
                    target = b
                    hasFlag = true
                case None => ()
            }
            case None => ()
        }
        if (!hasFlag) {
            writeDto(ctx, 400u16, ErrorResp("isAdmin (bool) required in JSON body"))
            return
        }
        match (this.userStore.getUser(uid)) {
            case None =>
                writeDto(ctx, 404u16, ErrorResp("user not found"))
                return
            case Some(_) => ()
        }
        let (actorId, actorName) = this.actorOf(ctx)
        let action = if (target) { "grant_admin" } else { "revoke_admin" }
        if (!this.auth.setUserAdmin(uid, target)) {
            let name = match (this.userStore.getUser(uid)) {
                case Some(x) => x.username
                case None => "#${uid}"
            }
            writeAudit(this.adminData, LogKind.Admin, actorId, actorName, action, "failed", name, ctx,
                error: "cannot revoke the last active admin")
            writeDto(ctx, 409u16, ErrorResp("cannot revoke the last active admin"))
            return
        }
        let u = this.userStore.getUser(uid).getOrThrow()
        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, action, "ok", u.username, ctx,
            detail: "isAdmin=${u.isAdmin}")
        writeDto(ctx, 200u16, UserAdminResp(u.id, u.username, u.isAdmin))
    }
}
