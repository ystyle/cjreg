// 管理 API · 认证端点（login / logout / me）——AdminService 的认证域扩展
package ystyle::cjreg.server

import tang.*
import ystyle::cjreg.store.*

extend AdminService {
    public func login(ctx: TangHttpContext): Unit {
        let req = parseLoginBody(ctx.bodyRaw())
        match (req) {
            case Some(lr) =>
                if (lr.username.isEmpty() || lr.password.isEmpty()) {
                    writeAudit(this.adminData, LogKind.Auth, 0, lr.username, "login", "failed", lr.username, ctx,
                        error: "username and password required")
                    writeDto(ctx, 400u16, ErrorResp("username and password required"))
                    return
                }
                match (this.auth.login(lr.username, lr.password)) {
                    case Some((user, token)) =>
                        writeAudit(this.adminData, LogKind.Auth, user.id, user.username, "login", "ok", user.username, ctx,
                            detail: "isAdmin=${user.isAdmin}")
                        writeDto(ctx, 200u16, LoginResp(user.id, user.username, user.isAdmin,
                            token.token, token.expiresAt))
                    case None =>
                        writeAudit(this.adminData, LogKind.Auth, 0, lr.username, "login", "failed", lr.username, ctx,
                            error: "invalid username or password")
                        writeDto(ctx, 401u16, ErrorResp("invalid username or password"))
                }
            case None =>
                writeDto(ctx, 400u16, ErrorResp("invalid JSON body"))
        }
    }

    public func me(ctx: TangHttpContext): Unit {
        match (this.currentUser(ctx)) {
            case Some(user) =>
                writeDto(ctx, 200u16, AdminMeResp(user.id, user.username, user.isAdmin,
                    user.isActive, user.publishToken))
            case None =>
                writeDto(ctx, 401u16, ErrorResp("not authenticated"))
        }
    }

    public func logout(ctx: TangHttpContext): Unit {
        let actor = this.currentUser(ctx)
        let token = this.extractToken(ctx)
        if (token.isSome()) {
            this.auth.logout(token.getOrThrow())
        }
        match (actor) {
            case Some(u) =>
                writeAudit(this.adminData, LogKind.Auth, u.id, u.username, "logout", "ok", u.username, ctx)
            case None => ()
        }
        writeDto(ctx, 200u16, OkResp())
    }
}

// 解析登录 JSON body（{username, password}）
public func parseLoginBody(body: Array<Byte>): ?LoginRequest {
    parseJsonBody<LoginRequest>(body, { r => LoginRequest.fromJson(r) })
}
