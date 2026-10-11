// 管理 API · 团队管理（含 owner 自助开关）——AdminService 的团队域扩展
//
// 权限口径：本文件所有端点都是 `requireAdmin`（/api/admin/* 语义不变，§7.4 约束 5）。
// owner 自助不走这里，走门户 /api/user/me/teams/*（那里用 canManageTeam 裁决）。
package ystyle::cjreg.server

import tang.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.model.*
import std.collection.*
import std.convert.*

extend AdminService {
    // 团队端点需要的 store：缺失时写 500 并返回 None
    func teamStores(ctx: TangHttpContext): ?AdminDataStore {
        match (this.adminData) {
            case Some(x) => Some(x)
            case None =>
                writeDto(ctx, 500u16, ErrorResp("admin data store unavailable"))
                None
        }
    }

    // 用户名解析（owner 展示用；不存在返回 ""）
    func usernameOf(userId: Int64): String {
        if (userId <= 0) {
            return ""
        }
        match (this.userStore.getUser(userId)) {
            case Some(u) => u.username
            case None => ""
        }
    }

    // GET /api/admin/teams → 团队列表（含 owner 与成员数；裸数组，与管理端用户列表同口径）
    public func listTeams(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let ad = match (this.teamStores(ctx)) {
            case Some(x) => x
            case None => return
        }
        let rows = ArrayList<TeamRowResp>()
        for (t in ad.listTeams()) {
            rows.add(TeamRowResp(t.id, t.name, t.displayName, t.description, t.permission,
                t.ownerId, this.usernameOf(t.ownerId), t.selfService, ad.listTeamMembers(t.id).size))
        }
        writeDto(ctx, 200u16, rows)
    }

    // POST /api/admin/teams  body {name, displayName?, description?, permission?, ownerId?, selfService?}
    public func createTeam(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let ad = match (this.teamStores(ctx)) {
            case Some(x) => x
            case None => return
        }
        let req = match (parseJsonBody<TeamUpsertRequest>(ctx.bodyRaw(), { r => TeamUpsertRequest.fromJson(r) })) {
            case Some(b) => b
            case None =>
                writeDto(ctx, 400u16, ErrorResp("invalid JSON body"))
                return
        }
        let name = req.name.trimAscii()
        if (name.isEmpty()) {
            writeDto(ctx, 400u16, ErrorResp("name required"))
            return
        }
        // 团队名唯一（软删的也算占用，避免同名复活造成歧义）
        for (t in ad.listTeams()) {
            if (t.name == name) {
                writeDto(ctx, 409u16, ErrorResp("team name already exists"))
                return
            }
        }
        // owner 若指定，必须存在且启用（否则会出现无人可管理的团队）
        if (req.hasOwnerId && req.ownerId > 0) {
            let ownerOk = match (this.userStore.getUser(req.ownerId)) {
                case Some(u) => u.isActive
                case None => false
            }
            if (!ownerOk) {
                writeDto(ctx, 400u16, ErrorResp("owner not found or inactive"))
                return
            }
        }
        let now = auditNowMs()
        let id = ad.createTeam(name, now, displayName: req.displayName, description: req.description,
            permission: if (req.hasPermission) { req.permission } else { "read" },
            ownerId: if (req.hasOwnerId) { req.ownerId } else { 0 },
            selfService: if (req.hasSelfService) { req.selfService } else { false })
        // owner 自动成为成员（避免「有管理权但无发布权」；owner 身份本身不给权限）
        if (req.hasOwnerId && req.ownerId > 0 && !isTeamMember(ad, id, req.ownerId)) {
            ad.addTeamMember(id, req.ownerId)
        }
        let (actorId, actorName) = this.actorOf(ctx)
        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "create_team", "ok", name, ctx,
            detail: "id=${id} ownerId=${req.ownerId} selfService=${req.selfService}")
        writeDto(ctx, 200u16, TeamSelfServiceResp(true, "ok", "已创建团队 ${name}", id))
    }

    // PUT /api/admin/teams/:id  body {displayName?, description?, permission?, ownerId?, selfService?}
    // 未传的字段保持原值；ownerId 只允许设成「已存在的启用用户」
    public func updateTeam(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let ad = match (this.teamStores(ctx)) {
            case Some(x) => x
            case None => return
        }
        let id = match (Int64.tryParse(ctx.param("id"))) {
            case Some(n) => n
            case None => 0
        }
        let cur = match (ad.getTeam(id)) {
            case Some(t) => if (t.deletedAt == 0) { t } else {
                writeDto(ctx, 404u16, ErrorResp("team not found"))
                return
            }
            case None =>
                writeDto(ctx, 404u16, ErrorResp("team not found"))
                return
        }
        let req = match (parseJsonBody<TeamUpsertRequest>(ctx.bodyRaw(), { r => TeamUpsertRequest.fromJson(r) })) {
            case Some(b) => b
            case None =>
                writeDto(ctx, 400u16, ErrorResp("invalid JSON body"))
                return
        }
        let now = auditNowMs()
        let (actorId, actorName) = this.actorOf(ctx)

        // ① owner 变更（独立于 updateTeam：走 setTeamOwner 才能带上「自动入队」语义）
        var ownerNote = ""
        if (req.hasOwnerId && req.ownerId != cur.ownerId) {
            if (req.ownerId > 0) {
                let r = transferTeamOwnerChecked(ad, this.userStore, id, req.ownerId, now)
                if (!r.ok) {
                    writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "transfer_team_owner", "failed",
                        cur.name, ctx, error: r.message, detail: "id=${id} newOwnerId=${req.ownerId}")
                    writeDto(ctx, 400u16, ErrorResp(r.message))
                    return
                }
                ownerNote = " ownerId=${req.ownerId}"
            } else {
                let _ = ad.setTeamOwner(id, 0, now)
                ownerNote = " ownerId=0"
            }
        }

        // ② 其余字段
        let displayName = if (req.hasDisplayName) { req.displayName } else { cur.displayName }
        let description = if (req.hasDescription) { req.description } else { cur.description }
        let permission = if (req.hasPermission) { req.permission } else { cur.permission }
        let _ = ad.updateTeam(id, displayName, description, permission, now,
            selfService: if (req.hasSelfService) { Some(req.selfService) } else { Option<Bool>.None })
        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "update_team", "ok", cur.name, ctx,
            detail: "id=${id} permission=${permission} selfService=${if (req.hasSelfService) { req.selfService } else { cur.selfService }}${ownerNote}")
        writeDto(ctx, 200u16, TeamSelfServiceResp(true, "ok", "已更新团队", id))
    }

    // PUT /api/admin/teams/:id/self-service  body {enabled: bool}
    // 单独一个端点：语义清晰（开关自助），且避免与 updateTeam 的局部更新混在一起
    public func setTeamSelfService(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let ad = match (this.teamStores(ctx)) {
            case Some(x) => x
            case None => return
        }
        let id = match (Int64.tryParse(ctx.param("id"))) {
            case Some(n) => n
            case None => 0
        }
        let cur = match (ad.getTeam(id)) {
            case Some(t) => if (t.deletedAt == 0) { t } else {
                writeDto(ctx, 404u16, ErrorResp("team not found"))
                return
            }
            case None =>
                writeDto(ctx, 404u16, ErrorResp("team not found"))
                return
        }
        let req = match (parseJsonBody<TeamSelfServiceRequest>(ctx.bodyRaw(), { r => TeamSelfServiceRequest.fromJson(r) })) {
            case Some(b) => b
            case None =>
                writeDto(ctx, 400u16, ErrorResp("invalid JSON body"))
                return
        }
        // 开启自助前必须有 owner，否则开了也没人能用（提早报错比事后困惑好）
        if (req.enabled && cur.ownerId <= 0) {
            writeDto(ctx, 400u16, ErrorResp("请先指定团队所有者再开启自助"))
            return
        }
        let _ = ad.setTeamSelfService(id, req.enabled, auditNowMs())
        let (actorId, actorName) = this.actorOf(ctx)
        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "set_team_self_service",
            "ok", cur.name, ctx, detail: "id=${id} enabled=${req.enabled} ownerId=${cur.ownerId}")
        writeDto(ctx, 200u16, TeamSelfServiceResp(true, "ok",
            if (req.enabled) { "已开启 owner 自助" } else { "已关闭 owner 自助" }, id))
    }

    // DELETE /api/admin/teams/:id → 软删
    public func deleteTeam(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let ad = match (this.teamStores(ctx)) {
            case Some(x) => x
            case None => return
        }
        let id = match (Int64.tryParse(ctx.param("id"))) {
            case Some(n) => n
            case None => 0
        }
        let cur = match (ad.getTeam(id)) {
            case Some(t) => if (t.deletedAt == 0) { t } else {
                writeDto(ctx, 404u16, ErrorResp("team not found"))
                return
            }
            case None =>
                writeDto(ctx, 404u16, ErrorResp("team not found"))
                return
        }
        let _ = ad.deleteTeam(id, auditNowMs())
        let (actorId, actorName) = this.actorOf(ctx)
        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "delete_team", "ok", cur.name, ctx,
            detail: "id=${id}")
        writeDto(ctx, 200u16, TeamSelfServiceResp(true, "ok", "已删除团队 ${cur.name}", id))
    }

    // GET /api/admin/teams/:id/members → 成员列表（标注谁是 owner）
    public func listTeamMembers(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let ad = match (this.teamStores(ctx)) {
            case Some(x) => x
            case None => return
        }
        let id = match (Int64.tryParse(ctx.param("id"))) {
            case Some(n) => n
            case None => 0
        }
        let team = match (ad.getTeam(id)) {
            case Some(t) => if (t.deletedAt == 0) { t } else {
                writeDto(ctx, 404u16, ErrorResp("team not found"))
                return
            }
            case None =>
                writeDto(ctx, 404u16, ErrorResp("team not found"))
                return
        }
        writeDto(ctx, 200u16, teamMemberRows(ad, team.id, team.ownerId, this.userStore))
    }

    // POST /api/admin/teams/:id/members  body {userId}
    public func addTeamMember(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let ad = match (this.teamStores(ctx)) {
            case Some(x) => x
            case None => return
        }
        let id = match (Int64.tryParse(ctx.param("id"))) {
            case Some(n) => n
            case None => 0
        }
        let team = match (ad.getTeam(id)) {
            case Some(t) => if (t.deletedAt == 0) { t } else {
                writeDto(ctx, 404u16, ErrorResp("team not found"))
                return
            }
            case None =>
                writeDto(ctx, 404u16, ErrorResp("team not found"))
                return
        }
        let req = match (parseJsonBody<TeamMemberRequest>(ctx.bodyRaw(), { r => TeamMemberRequest.fromJson(r) })) {
            case Some(b) => b
            case None =>
                writeDto(ctx, 400u16, ErrorResp("invalid JSON body"))
                return
        }
        let r = addTeamMemberChecked(ad, this.userStore, id, req.userId)
        let (actorId, actorName) = this.actorOf(ctx)
        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "add_team_member",
            if (r.ok) { "ok" } else { "failed" }, team.name, ctx,
            error: if (r.ok) { "" } else { r.message }, detail: "id=${id} userId=${req.userId}")
        writeDto(ctx, teamSelfServiceCode(r), teamSelfServiceResp(r))
    }

    // DELETE /api/admin/teams/:id/members/:userId
    public func removeTeamMember(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let ad = match (this.teamStores(ctx)) {
            case Some(x) => x
            case None => return
        }
        let id = match (Int64.tryParse(ctx.param("id"))) {
            case Some(n) => n
            case None => 0
        }
        let team = match (ad.getTeam(id)) {
            case Some(t) => if (t.deletedAt == 0) { t } else {
                writeDto(ctx, 404u16, ErrorResp("team not found"))
                return
            }
            case None =>
                writeDto(ctx, 404u16, ErrorResp("team not found"))
                return
        }
        let uid = match (Int64.tryParse(ctx.param("userId"))) {
            case Some(n) => n
            case None => 0
        }
        let r = removeTeamMemberChecked(ad, id, uid)
        let (actorId, actorName) = this.actorOf(ctx)
        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "remove_team_member",
            if (r.ok) { "ok" } else { "failed" }, team.name, ctx,
            error: if (r.ok) { "" } else { r.message }, detail: "id=${id} userId=${uid}")
        writeDto(ctx, teamSelfServiceCode(r), teamSelfServiceResp(r))
    }
}

// 自助结果的 outcome → HTTP 状态码（供管理端与门户共用一份口径）
public func teamSelfServiceCode(r: TeamSelfServiceResult): UInt16 {
    if (r.ok) {
        return 200u16
    }
    match (r.outcome) {
        case "user_not_found" => 404u16
        case "team_not_found" => 404u16
        case _ => 400u16
    }
}

// 团队成员行（标注 owner）；usernames 由调用方提供的 UserStore 解析
public func teamMemberRows(adminData: AdminDataStore, teamId: Int64, ownerId: Int64,
                           userStore: UserStore): ArrayList<TeamMemberResp> {
    let rows = ArrayList<TeamMemberResp>()
    for (uid in adminData.listTeamMemberIds(teamId)) {
        let name = match (userStore.getUser(uid)) {
            case Some(u) => u.username
            case None => "#${uid}"
        }
        rows.add(TeamMemberResp(uid, name, uid == ownerId))
    }
    rows
}
