// 团队 owner 自助：裁决与准入（迭代 6 / §7.4 路线 A）
//
// 把「谁能管理某团队」收敛成**一个**纯函数 canManageTeam，供三条入口共用：
//   ① 门户页 action（cjxt WS handler 内执行，身份取自服务端注入的会话上下文）
//   ② 门户 HTTP API（/api/user/me/teams/...）
//   ③ 管理端 HTTP API（/api/admin/teams/...）
// 三条入口各写各的判权是最容易出事的地方（漏一处就是越权），所以这里只留一份口径。
//
// 设计要点（对应 docs/team-owner-plan.md 的五条约束）：
//   - 管理员永远是**超集**：第一个分支直接放行，不被 owner 机制削弱（约束 1/3）；
//   - owner 自助必须 **selfService 打开**（默认关，只有管理员能开）——「加人 = 授予发布权」
//     这件事不能默认下放（约束 2）；
//   - 拒绝原因区分「不是 owner」与「自助未开启」，便于排障与给用户准确提示；
//   - owner 身份**不**带来任何发布权限：本文件不碰 TeamDoc.permission（约束 4）。
package ystyle::cjreg.server

import ystyle::cjreg.store.*
import ystyle::cjreg.auth.model.*
import std.collection.*

// 裁决结果：能否管理 + 拒绝原因 + 命中的身份（给审计/文案用）
public class TeamManageVerdict {
    public let allowed: Bool
    // "admin" / "owner" / "" —— 命中的身份，用于审计 detail
    public let via: String
    // 允许时为空；拒绝时是稳定标识（非用户可见文案）
    public let reason: String

    public init(allowed: Bool, via: String, reason: String) {
        this.allowed = allowed
        this.via = via
        this.reason = reason
    }
}

public let TeamManageDeniedNotAuthenticated = "not_authenticated"
public let TeamManageDeniedTeamNotFound = "team_not_found"
public let TeamManageDeniedNotOwner = "not_team_owner"
public let TeamManageDeniedSelfServiceOff = "self_service_disabled"

// 能否管理该团队（成员/关联的增删改）
//
// user 为 None = 未登录。注意这里**不**读任何请求参数里的身份：
// 调用方必须传入从服务端会话/令牌解析出的 user。
public func canManageTeam(adminData: AdminDataStore, user: ?User, teamId: Int64): TeamManageVerdict {
    let u = match (user) {
        case Some(x) => x
        case None => return TeamManageVerdict(false, "", TeamManageDeniedNotAuthenticated)
    }
    // 被禁用/降级的账号不参与任何自助（isActive=false 视为无身份）
    if (!u.isActive) {
        return TeamManageVerdict(false, "", TeamManageDeniedNotAuthenticated)
    }
    let team = match (adminData.getTeam(teamId)) {
        case Some(t) => if (t.deletedAt == 0) { t } else {
            return TeamManageVerdict(false, "", TeamManageDeniedTeamNotFound)
        }
        case None => return TeamManageVerdict(false, "", TeamManageDeniedTeamNotFound)
    }
    // ① 管理员 = 超集：不受 selfService 与 ownerId 影响
    if (u.isAdmin) {
        return TeamManageVerdict(true, "admin", "")
    }
    // ② owner 且自助已开启
    if (team.ownerId != u.id) {
        return TeamManageVerdict(false, "", TeamManageDeniedNotOwner)
    }
    if (!team.selfService) {
        return TeamManageVerdict(false, "", TeamManageDeniedSelfServiceOff)
    }
    TeamManageVerdict(true, "owner", "")
}

// 拒绝原因的稳定标识 → 面向用户的提示（HTTP 层与门户页共用同一套文案）
public func teamManageDeniedMessage(reason: String): String {
    match (reason) {
        case "not_authenticated" => "请先登录"
        case "team_not_found" => "团队不存在"
        case "not_team_owner" => "只有团队所有者可以自助管理"
        case "self_service_disabled" => "该团队未开启 owner 自助，请联系管理员"
        case _ => "无权管理该团队"
    }
}

// 拒绝原因 → HTTP 状态码（越权 403、未登录 401、团队不存在 404）
public func teamManageDeniedCode(reason: String): UInt16 {
    match (reason) {
        case "not_authenticated" => 401u16
        case "team_not_found" => 404u16
        case _ => 403u16
    }
}

// ===== owner 自助的写操作（供门户/管理端共用）=====

// 自助操作的结果：稳定 outcome + 用户可见文案 + 关联 id
public class TeamSelfServiceResult {
    public let ok: Bool
    public let outcome: String
    public let message: String
    public let teamId: Int64

    public init(ok: Bool, outcome: String, message: String, teamId: Int64) {
        this.ok = ok
        this.outcome = outcome
        this.message = message
        this.teamId = teamId
    }
}

public func teamSelfServiceOk(message: String, teamId: Int64): TeamSelfServiceResult {
    TeamSelfServiceResult(true, "ok", message, teamId)
}

public func teamSelfServiceErr(outcome: String, message: String, teamId: Int64): TeamSelfServiceResult {
    TeamSelfServiceResult(false, outcome, message, teamId)
}

// 加入成员：校验「用户存在且启用」+ 幂等（已是成员则直接成功，不重复写记录）。
// **不**校验调用者权限 —— 权限由调用方用 canManageTeam 先判（保持纯函数可测）。
public func addTeamMemberChecked(adminData: AdminDataStore, userStore: UserStore,
                                 teamId: Int64, userId: Int64): TeamSelfServiceResult {
    if (userId <= 0) {
        return teamSelfServiceErr("invalid_user", "用户 id 非法", teamId)
    }
    let target = match (userStore.getUser(userId)) {
        case Some(x) => x
        case None => return teamSelfServiceErr("user_not_found", "用户不存在", teamId)
    }
    if (!target.isActive) {
        // 把禁用账号拉进团队等于给它发布权，必须挡住
        return teamSelfServiceErr("user_inactive", "该用户已被禁用，无法加入团队", teamId)
    }
    if (isTeamMember(adminData, teamId, userId)) {
        return teamSelfServiceOk("${target.username} 已在团队中", teamId)
    }
    adminData.addTeamMember(teamId, userId)
    teamSelfServiceOk("已加入 ${target.username}", teamId)
}

// 移出成员：ownerId 本人不可被移出（否则会出现「有管理权但不在团队成员里」的孤儿状态）。
// 想换 owner 请走转让。
public func removeTeamMemberChecked(adminData: AdminDataStore, teamId: Int64,
                                    userId: Int64): TeamSelfServiceResult {
    if (userId <= 0) {
        return teamSelfServiceErr("invalid_user", "用户 id 非法", teamId)
    }
    let team = match (adminData.getTeam(teamId)) {
        case Some(t) => t
        case None => return teamSelfServiceErr("team_not_found", "团队不存在", teamId)
    }
    if (team.ownerId == userId) {
        return teamSelfServiceErr("cannot_remove_owner", "不能移出团队所有者，请先转让所有权", teamId)
    }
    if (!isTeamMember(adminData, teamId, userId)) {
        return teamSelfServiceErr("not_a_member", "该用户不在团队中", teamId)
    }
    let keep = ArrayList<Int64>()
    for (uid in adminData.listTeamMemberIds(teamId)) {
        if (uid != userId) {
            keep.add(uid)
        }
    }
    adminData.setTeamMembers(teamId, keep.toArray())
    teamSelfServiceOk("已移出团队成员", teamId)
}

// 转让所有者：新 owner 必须是**现有成员**（避免「有管理权但无发布权」），
// 转让后旧 owner 保留成员身份；新 owner 不在成员里时自动补进去。
public func transferTeamOwnerChecked(adminData: AdminDataStore, userStore: UserStore,
                                     teamId: Int64, newOwnerId: Int64,
                                     now: Int64): TeamSelfServiceResult {
    if (newOwnerId <= 0) {
        return teamSelfServiceErr("invalid_user", "用户 id 非法", teamId)
    }
    let team = match (adminData.getTeam(teamId)) {
        case Some(t) => if (t.deletedAt == 0) { t } else {
            return teamSelfServiceErr("team_not_found", "团队不存在", teamId)
        }
        case None => return teamSelfServiceErr("team_not_found", "团队不存在", teamId)
    }
    let target = match (userStore.getUser(newOwnerId)) {
        case Some(x) => x
        case None => return teamSelfServiceErr("user_not_found", "用户不存在", teamId)
    }
    if (!target.isActive) {
        return teamSelfServiceErr("user_inactive", "该用户已被禁用，无法成为团队所有者", teamId)
    }
    if (team.ownerId == newOwnerId) {
        return teamSelfServiceOk("${target.username} 已是团队所有者", teamId)
    }
    if (!isTeamMember(adminData, teamId, newOwnerId)) {
        return teamSelfServiceErr("not_a_member", "只能转让给团队成员，请先把他加入团队", teamId)
    }
    adminData.setTeamOwner(teamId, newOwnerId, now)
    teamSelfServiceOk("已把团队所有权转让给 ${target.username}", teamId)
}

// 某人是否为团队 owner（服务端守卫的薄封装，供 handler 与 UI 共用一份判定）
public func isTeamOwner(adminData: AdminDataStore, userId: Int64, teamId: Int64): Bool {
    adminData.isTeamOwnerAt(teamId, userId)
}

// 删除/禁用用户前的孤儿检查：该用户是任一团队的 owner → 返回第一个团队名（"" = 无冲突）。
// 与「最后一个启用管理员不可降级」同构：先转让再删人，避免留下无人能管理的团队。
public func ownedTeamBlockingUserRemoval(adminData: AdminDataStore, userId: Int64): String {
    if (userId <= 0) {
        return ""
    }
    for (t in adminData.listTeams()) {
        if (t.ownerId == userId) {
            return t.name
        }
    }
    ""
}

// ===== owner 自助：团队关联（组织 / 包）=====
//
// 这一步是「owner 加人 = 授予发布权」的关键：团队绑定哪些组织/包，决定了成员的有效权限范围
// （effectivePermission 按团队关联命中来给 level）。所以 owner 自助若只能改成员、不能改关联，
// 「下放边界」其实没有落地。

// 设置团队关联的组织（覆盖式，与 UI 的管理端行为一致）。
// 校验：组织必须存在且未软删 —— 关联到不存在的组织等于给出无效权限。
public func setTeamOrgsChecked(adminData: AdminDataStore, teamId: Int64,
                               orgIds: Array<Int64>, now: Int64): TeamSelfServiceResult {
    let team = match (adminData.getTeam(teamId)) {
        case Some(t) => if (t.deletedAt == 0) { t } else {
            return teamSelfServiceErr("team_not_found", "团队不存在", teamId)
        }
        case None => return teamSelfServiceErr("team_not_found", "团队不存在", teamId)
    }
    // 0 = 「无组织包」哨兵值，允许；其余必须存在且未删
    for (oid in orgIds) {
        if (oid == 0) {
            continue
        }
        let ok = match (adminData.getOrg(oid)) {
            case Some(o) => o.deletedAt == 0
            case None => false
        }
        if (!ok) {
            return teamSelfServiceErr("org_not_found", "组织不存在（id=${oid}）", teamId)
        }
    }
    adminData.setTeamOrganizations(teamId, orgIds, now)
    teamSelfServiceOk("已更新关联组织（${orgIds.size} 个）", teamId)
}

// 设置团队关联的包（覆盖式）。校验：包在该组织下必须存在本地版本。
public func setTeamPkgsChecked(adminData: AdminDataStore, pkgStore: PackageStore, teamId: Int64,
                               pkgs: Array<(String, String)>, now: Int64): TeamSelfServiceResult {
    let team = match (adminData.getTeam(teamId)) {
        case Some(t) => if (t.deletedAt == 0) { t } else {
            return teamSelfServiceErr("team_not_found", "团队不存在", teamId)
        }
        case None => return teamSelfServiceErr("team_not_found", "团队不存在", teamId)
    }
    for ((org, name) in pkgs) {
        if (pkgStore.listVersions(org, name).size == 0) {
            return teamSelfServiceErr("package_not_found", "包不存在：${org}::${name}", teamId)
        }
    }
    adminData.setTeamPackages(teamId, pkgs, now)
    teamSelfServiceOk("已更新关联包（${pkgs.size} 个）", teamId)
}
