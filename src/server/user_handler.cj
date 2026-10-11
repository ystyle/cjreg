// 用户门户只读 API（/api/user/*）：session token 鉴权（普通用户与管理员均可）
//
// 与管理 API（/api/admin/*，requireAdmin）分离：这里只暴露「我自己的」数据，
// 不提供任何跨用户读写能力（用户 id 一律取自会话，不接受客户端传入）。
package ystyle::cjreg.server

import tang.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*
import std.collection.*
import std.convert.*
import std.io.*
import stdx.encoding.json.stream.*

public class UserApi {
    public var auth: AuthService
    public var pkgStore: PackageStore
    public var adminData: AdminDataStore
    public var permissionMode: String

    public init(auth: AuthService, pkgStore: PackageStore, adminData: AdminDataStore, permissionMode: String) {
        this.auth = auth
        this.pkgStore = pkgStore
        this.adminData = adminData
        this.permissionMode = permissionMode
    }

    // ===== 守卫：session token（缺失/无效 → 401）=====

    func currentUser(ctx: TangHttpContext): ?User {
        let token = extractAuthToken(ctx)
        if (token.isEmpty()) {
            return None
        }
        this.auth.validateSessionToken(token)
    }

    // ===== GET /api/user/me =====
    // 当前用户信息 + 掩码 Token + 权限模式；mcp/cjpm 侧可用它确认「我是谁、能不能发」
    public func me(ctx: TangHttpContext): Unit {
        let user = match (this.currentUser(ctx)) {
            case Some(u) => u
            case None =>
                writeDto(ctx, 401u16, ErrorResp("not authenticated"))
                return
        }
        writeDto(ctx, 200u16, PortalMeResp(user.id, user.username, user.email, user.isAdmin,
            maskToken(user.publishToken), this.permissionMode, permissionHint(this.permissionMode)))
    }

    // ===== POST /api/user/me/publish-token =====
    // 重置自己的发布 Token（旧 Token 立即失效）；响应返回新 Token（仅此一次由调用方保存）
    public func resetPublishToken(ctx: TangHttpContext): Unit {
        let user = match (this.currentUser(ctx)) {
            case Some(u) => u
            case None =>
                writeDto(ctx, 401u16, ErrorResp("not authenticated"))
                return
        }
        match (this.auth.resetPublishToken(user.id)) {
            case Some(t) =>
                this.adminData.addLog(LogKind.Auth, user.id, user.username, "reset publish token (portal)", "ok", nowMsUtc())
                writeDto(ctx, 200u16, PublishTokenResp(t))
            case None =>
                writeDto(ctx, 404u16, ErrorResp("user not found"))
        }
    }

    // ===== GET /api/user/me/packages?page=&size=&q= =====
    // 我发布过版本的包（服务端分页 + 名称/组织模糊搜索）
    public func myPackages(ctx: TangHttpContext): Unit {
        let user = match (this.currentUser(ctx)) {
            case Some(u) => u
            case None =>
                writeDto(ctx, 401u16, ErrorResp("not authenticated"))
                return
        }
        let page = parseQueryInt(ctx, "page", 1)
        let size = parseQueryInt(ctx, "size", 20)
        let q = ctx.query("q") ?? ""
        let all = myPackageRows(this.pkgStore, this.adminData, user.id)
        let hits = ArrayList<MyPackageRow>()
        for (r in all) {
            if (q.isEmpty() || r.name.contains(q) || r.org.contains(q)) {
                hits.add(r)
            }
        }
        let (start, end) = pageWindow(hits.size, page, size)
        let items = ArrayList<MyPackageRowDto>()
        var i = start
        while (i < end) {
            let r = hits[i]
            items.add(MyPackageRowDto(r.org, r.name, r.versionCount, r.latestVersion, r.isOwner, r.updatedAt))
            i++
        }
        writeDto(ctx, 200u16, MyPackageListResp(hits.size, page, size, items))
    }

    // ===== GET /api/user/me/teams =====
    // 我所属团队 + 团队权限 + 关联组织/包（只读，供门户与外部工具展示）
    public func myTeams(ctx: TangHttpContext): Unit {
        let user = match (this.currentUser(ctx)) {
            case Some(u) => u
            case None =>
                writeDto(ctx, 401u16, ErrorResp("not authenticated"))
                return
        }
        let rows = myTeamRows(this.adminData, user.id)
        let items = ArrayList<MyTeamRowDto>()
        for (r in rows) {
            items.add(MyTeamRowDto(r.teamId, r.name, r.displayName, r.permission, r.orgNames, r.packages))
        }
        writeDto(ctx, 200u16, MyTeamsResp(this.permissionMode, items))
    }

    // ===== owner 自助（/api/user/me/teams/:id/...）=====
    //
    // 身份一律取自**服务端会话**（currentUser → session token），客户端无法伪造 uid；
    // 权限一律过 canManageTeam（管理员超集 / owner 且 selfService 开），
    // 与门户页 action 共用同一裁决 —— 两套入口两套判权是最容易漏的地方。
    //
    // 越权返回：401 未登录 / 404 团队不存在 / 403 其它（含「是 owner 但自助未开」）
    public func manageTeamMembers(ctx: TangHttpContext): Unit {
        let teamId = match (Int64.tryParse(ctx.param("id"))) {
            case Some(n) => n
            case None => 0
        }
        let v = this.guardTeamManage(ctx, teamId)
        if (!v.allowed) {
            return
        }
        match (ctx.request.method) {
            case "GET" =>
                let team = this.adminData.getTeam(teamId).getOrThrow()
                writeDto(ctx, 200u16, teamMemberRows(this.adminData, teamId, team.ownerId, this.auth.store))
            case "POST" =>
                let req = match (parseJsonBody<TeamMemberRequest>(ctx.bodyRaw(), { r => TeamMemberRequest.fromJson(r) })) {
                    case Some(b) => b
                    case None =>
                        writeDto(ctx, 400u16, ErrorResp("invalid JSON body"))
                        return
                }
                let r = addTeamMemberChecked(this.adminData, this.auth.store, teamId, req.userId)
                this.auditTeamManage(ctx, v, "add_team_member", r, teamId)
                writeDto(ctx, teamSelfServiceCode(r), teamSelfServiceResp(r))
            case _ =>
                writeDto(ctx, 405u16, ErrorResp("method not allowed"))
        }
    }

    // DELETE /api/user/me/teams/:id/members/:userId
    public func removeTeamMemberSelf(ctx: TangHttpContext): Unit {
        let teamId = match (Int64.tryParse(ctx.param("id"))) {
            case Some(n) => n
            case None => 0
        }
        let v = this.guardTeamManage(ctx, teamId)
        if (!v.allowed) {
            return
        }
        let uid = match (Int64.tryParse(ctx.param("userId"))) {
            case Some(n) => n
            case None => 0
        }
        let r = removeTeamMemberChecked(this.adminData, teamId, uid)
        this.auditTeamManage(ctx, v, "remove_team_member", r, teamId)
        writeDto(ctx, teamSelfServiceCode(r), teamSelfServiceResp(r))
    }

    // POST /api/user/me/teams/:id/transfer  body {userId}
    // 转让所有权：owner 或管理员（自助开启时）可发起
    public func transferTeamOwnerSelf(ctx: TangHttpContext): Unit {
        let teamId = match (Int64.tryParse(ctx.param("id"))) {
            case Some(n) => n
            case None => 0
        }
        let v = this.guardTeamManage(ctx, teamId)
        if (!v.allowed) {
            return
        }
        let req = match (parseJsonBody<TeamMemberRequest>(ctx.bodyRaw(), { r => TeamMemberRequest.fromJson(r) })) {
            case Some(b) => b
            case None =>
                writeDto(ctx, 400u16, ErrorResp("invalid JSON body"))
                return
        }
        let r = transferTeamOwnerChecked(this.adminData, this.auth.store, teamId, req.userId, nowMsUtc())
        this.auditTeamManage(ctx, v, "transfer_team_owner", r, teamId)
        writeDto(ctx, teamSelfServiceCode(r), teamSelfServiceResp(r))
    }

    // 自助守卫：未登录 → 401；团队不存在 → 404；其余拒绝 → 403（含自助未开启）
    func guardTeamManage(ctx: TangHttpContext, teamId: Int64): TeamManageVerdict {
        let user = this.currentUser(ctx)
        let v = canManageTeam(this.adminData, user, teamId)
        if (!v.allowed) {
            writeDto(ctx, teamManageDeniedCode(v.reason), ErrorResp(teamManageDeniedMessage(v.reason),
                detail: Some(v.reason)))
        }
        v
    }

    // 自助操作审计：actor = 实际操作者（owner 自己），detail 标注命中身份
    func auditTeamManage(ctx: TangHttpContext, v: TeamManageVerdict, action: String,
                         r: TeamSelfServiceResult, teamId: Int64): Unit {
        let u = this.currentUser(ctx)
        let (actorId, actorName) = match (u) {
            case Some(x) => (x.id, x.username)
            case None => (0, "")
        }
        let _ = this.adminData.addLog(LogKind.Admin, actorId, actorName, action,
            if (r.ok) { "ok" } else { "failed" }, nowMsUtc(),
            target: "team=${teamId}", error: if (r.ok) { "" } else { r.message },
            ipAddr: "portal-api", userAgent: "cjreg-portal",
            detail: "via=${v.via} teamId=${teamId} outcome=${r.outcome}")
    }

    // ===== 工具 =====

    // 分页切片（与 UI 层 pageWindow 同语义：越界安全）
    func pageWindow(total: Int64, page: Int64, size: Int64): (Int64, Int64) {
        let safePage = if (page < 1) { 1 } else { page }
        let safeSize = if (size < 1) { 1 } else { if (size > 100) { 100 } else { size } }
        let start = (safePage - 1) * safeSize
        let end = if (start + safeSize > total) { total } else { start + safeSize }
        (start, end)
    }

    func parseQueryInt(ctx: TangHttpContext, key: String, fallback: Int64): Int64 {
        let raw = ctx.query(key) ?? ""
        if (raw.isEmpty()) {
            return fallback
        }
        match (Int64.tryParse(raw)) {
            case Some(n) => n
            case None => fallback
        }
    }
}
