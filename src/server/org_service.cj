// 组织 CRUD 的服务端语义（管理 REST 与单测共用；纯逻辑，不依赖 HTTP）
//
// 设计要点：
//   - 组织名是**命名空间锚点**：包文档里以字符串形式存 organization，团队关联存 organizationId。
//     因此改名只在「该组织下没有任何未软删版本」时允许（否则会造成孤儿包），删除前也要挡住
//     「组织下还有包」与「团队仍关联该组织」两种情况。
//   - 名称格式：1–64 字符，仅 [A-Za-z0-9_-]（它会出现在 URL 的 organization= 参数与包键里）。
//   - 同一时间只保留一个默认组织（isDefault=true 时清除其它组织的默认标记）。
package ystyle::cjreg.server

import ystyle::cjreg.store.*
import std.collection.*
import std.sort.*

public enum OrgOutcome {
    | Ok
    | NotFound            // 组织不存在（或已删除）
    | DuplicateName       // 组织名已被占用
    | InvalidName         // 名称格式非法（含非法字符/超长）
    | HasPackages         // 组织下仍有包（禁止删除）
    | ReferencedByTeams   // 仍被团队关联（禁止删除）
    | RenameWithPackages  // 有包的组织不允许改名
    | Failed

    public operator func ==(other: OrgOutcome): Bool {
        match (this) {
            case OrgOutcome.Ok => match (other) {
                case OrgOutcome.Ok => true
                case _ => false
            }
            case OrgOutcome.NotFound => match (other) {
                case OrgOutcome.NotFound => true
                case _ => false
            }
            case OrgOutcome.DuplicateName => match (other) {
                case OrgOutcome.DuplicateName => true
                case _ => false
            }
            case OrgOutcome.InvalidName => match (other) {
                case OrgOutcome.InvalidName => true
                case _ => false
            }
            case OrgOutcome.HasPackages => match (other) {
                case OrgOutcome.HasPackages => true
                case _ => false
            }
            case OrgOutcome.ReferencedByTeams => match (other) {
                case OrgOutcome.ReferencedByTeams => true
                case _ => false
            }
            case OrgOutcome.RenameWithPackages => match (other) {
                case OrgOutcome.RenameWithPackages => true
                case _ => false
            }
            case OrgOutcome.Failed => match (other) {
                case OrgOutcome.Failed => true
                case _ => false
            }
        }
    }
}

public struct OrgResult {
    public let outcome: OrgOutcome
    public let message: String
    public let orgId: Int64
    public let affected: Int64      // 关联影响数（包数/团队数/被清默认标记的组织数）

    public init(outcome: OrgOutcome, message: String, orgId: Int64, affected: Int64) {
        this.outcome = outcome
        this.message = message
        this.orgId = orgId
        this.affected = affected
    }
}

/// 组织名格式校验：返回空串 = 合法，否则返回错误说明
public func validateOrgName(name: String): String {
    if (name.isEmpty()) {
        return "组织名不能为空"
    }
    if (name.size > 64) {
        return "组织名过长（上限 64 字符）"
    }
    for (c in name.toRuneArray()) {
        let isDigit = c >= r'0' && c <= r'9'
        let isUpper = c >= r'A' && c <= r'Z'
        let isLower = c >= r'a' && c <= r'z'
        let isDash = c == r'-' || c == r'_'
        if (!isDigit && !isUpper && !isLower && !isDash) {
            return "组织名只允许字母、数字、下划线与连字符"
        }
    }
    return ""
}

/// 按名称查未删除组织（excludeId 用于改名时排除自身）
public func findOrgByName(adminData: AdminDataStore, name: String, excludeId: Int64): ?OrgDoc {
    for (o in adminData.listOrgs()) {
        if (o.name == name && o.id != excludeId) {
            return Some(o)
        }
    }
    None
}

/// 组织下未软删的统计：(包名去重数, 版本数)
public func orgPackageStats(pkgStore: PackageStore, orgName: String): (Int64, Int64) {
    var versions: Int64 = 0
    let names = HashMap<String, Bool>()
    if (orgName.isEmpty()) {
        return (0, 0)
    }
    for (d in pkgStore.storm.all<PackageDoc>()) {
        if (d.deletedAt != 0 || d.organization != orgName) {
            continue
        }
        versions++
        names[d.name] = true
    }
    (names.size, versions)
}

/// 仍关联该组织的团队名列表（未软删团队）
public func orgReferencingTeams(adminData: AdminDataStore, orgId: Int64): ArrayList<String> {
    let out = ArrayList<String>()
    for (t in adminData.listTeams()) {
        for (rel in adminData.listTeamOrganizations(t.id)) {
            if (rel.organizationId == orgId) {
                out.add(t.name)
                break
            }
        }
    }
    out
}

/// 默认组织唯一化：把除 keepId 外的组织默认标记清掉，返回被清除的个数
public func clearOtherDefaults(adminData: AdminDataStore, keepId: Int64, now: Int64): Int64 {
    var n: Int64 = 0
    for (o in adminData.listOrgs()) {
        if (o.id == keepId || !o.isDefault) {
            continue
        }
        if (adminData.updateOrg(o.id, o.displayName, o.description, false, now)) {
            n++
        }
    }
    n
}

/// 创建组织（名称校验 + 唯一性 + 默认唯一化）
public func createOrgChecked(adminData: AdminDataStore, name: String, displayName: String,
                             description: String, isDefault: Bool, ownerId: Int64, now: Int64): OrgResult {
    let bad = validateOrgName(name)
    if (!bad.isEmpty()) {
        return OrgResult(OrgOutcome.InvalidName, bad, 0, 0)
    }
    match (findOrgByName(adminData, name, 0)) {
        case Some(o) => return OrgResult(OrgOutcome.DuplicateName, "组织名已被占用（id=${o.id}）", 0, 0)
        case None => ()
    }
    let id = adminData.createOrg(name, displayName, ownerId, now, description: description, isDefault: isDefault)
    var cleared: Int64 = 0
    if (isDefault) {
        cleared = clearOtherDefaults(adminData, id, now)
    }
    OrgResult(OrgOutcome.Ok, "已创建组织 #${id}", id, cleared)
}

/// 更新组织：name 非空表示改名（有包时拒绝），并做唯一性校验与默认唯一化
public func updateOrgChecked(pkgStore: PackageStore, adminData: AdminDataStore, id: Int64, name: String,
                             displayName: String, description: String, isDefault: Bool, now: Int64): OrgResult {
    let cur = match (adminData.getOrg(id)) {
        case Some(o) => if (o.deletedAt == 0) { o } else {
            return OrgResult(OrgOutcome.NotFound, "组织不存在或已删除", id, 0)
        }
        case None => return OrgResult(OrgOutcome.NotFound, "组织不存在", id, 0)
    }
    var newName = ""
    if (!name.isEmpty() && name != cur.name) {
        let bad = validateOrgName(name)
        if (!bad.isEmpty()) {
            return OrgResult(OrgOutcome.InvalidName, bad, id, 0)
        }
        let (pkgs, _) = orgPackageStats(pkgStore, cur.name)
        if (pkgs > 0) {
            return OrgResult(OrgOutcome.RenameWithPackages,
                "该组织下仍有 ${pkgs} 个包，改名会造成孤儿包；请先迁移或删除这些包", id, pkgs)
        }
        match (findOrgByName(adminData, name, id)) {
            case Some(o) => return OrgResult(OrgOutcome.DuplicateName, "组织名已被占用（id=${o.id}）", id, 0)
            case None => ()
        }
        newName = name
    }
    if (!adminData.updateOrg(id, displayName, description, isDefault, now, newName: newName)) {
        return OrgResult(OrgOutcome.Failed, "更新失败", id, 0)
    }
    var cleared: Int64 = 0
    if (isDefault) {
        cleared = clearOtherDefaults(adminData, id, now)
    }
    OrgResult(OrgOutcome.Ok, "已更新组织 ${if (newName.isEmpty()) { cur.name } else { newName }}", id, cleared)
}

/// 删除组织（软删）：有包或仍被团队关联时拒绝
public func deleteOrgChecked(pkgStore: PackageStore, adminData: AdminDataStore, id: Int64, now: Int64): OrgResult {
    let cur = match (adminData.getOrg(id)) {
        case Some(o) => if (o.deletedAt == 0) { o } else {
            return OrgResult(OrgOutcome.NotFound, "组织不存在或已删除", id, 0)
        }
        case None => return OrgResult(OrgOutcome.NotFound, "组织不存在", id, 0)
    }
    let (pkgs, versions) = orgPackageStats(pkgStore, cur.name)
    if (pkgs > 0) {
        return OrgResult(OrgOutcome.HasPackages,
            "该组织下仍有 ${pkgs} 个包（${versions} 个版本），请先删除包再删除组织", id, pkgs)
    }
    let teams = orgReferencingTeams(adminData, id)
    if (teams.size > 0) {
        return OrgResult(OrgOutcome.ReferencedByTeams,
            "仍有 ${teams.size} 个团队关联该组织：${joinNames(teams, 3)}", id, teams.size)
    }
    if (!adminData.deleteOrg(id, now)) {
        return OrgResult(OrgOutcome.Failed, "删除失败", id, 0)
    }
    OrgResult(OrgOutcome.Ok, "已删除组织 ${cur.name}（软删，可由数据层恢复）", id, 0)
}

// 团队名拼接（最多前 n 个，便于错误消息里定位）
func joinNames(items: ArrayList<String>, limit: Int64): String {
    let sb = StringBuilder()
    var i: Int64 = 0
    for (v in items) {
        if (i >= limit) {
            sb.append("…")
            break
        }
        if (i > 0) {
            sb.append("、")
        }
        sb.append(v)
        i++
    }
    sb.toString()
}

// ===== JSON =====

public func orgResultJson(r: OrgResult): String {
    let status = match (r.outcome) {
        case OrgOutcome.Ok => "ok"
        case OrgOutcome.NotFound => "not_found"
        case OrgOutcome.DuplicateName => "duplicate_name"
        case OrgOutcome.InvalidName => "invalid_name"
        case OrgOutcome.HasPackages => "has_packages"
        case OrgOutcome.ReferencedByTeams => "referenced_by_teams"
        case OrgOutcome.RenameWithPackages => "rename_with_packages"
        case OrgOutcome.Failed => "failed"
    }
    "{\"status\":\"${status}\",\"message\":\"${escapeJsonStr(r.message)}\",\"id\":${r.orgId}," +
        "\"affected\":${r.affected}}"
}

public func orgResultCode(r: OrgResult): UInt16 {
    match (r.outcome) {
        case OrgOutcome.Ok => 200u16
        case OrgOutcome.NotFound => 404u16
        case OrgOutcome.DuplicateName => 409u16
        case OrgOutcome.InvalidName => 400u16
        case OrgOutcome.HasPackages => 409u16
        case OrgOutcome.ReferencedByTeams => 409u16
        case OrgOutcome.RenameWithPackages => 409u16
        case OrgOutcome.Failed => 500u16
    }
}

public func orgJson(o: OrgDoc, packageCount: Int64, versionCount: Int64, teamCount: Int64): String {
    let sb = StringBuilder()
    sb.append("{\"id\":${o.id},\"name\":\"${escapeJsonStr(o.name)}\",")
    sb.append("\"displayName\":\"${escapeJsonStr(o.displayName)}\",")
    sb.append("\"description\":\"${escapeJsonStr(o.description)}\",\"isDefault\":${o.isDefault},")
    sb.append("\"ownerId\":${o.ownerId},\"packageCount\":${packageCount},\"versionCount\":${versionCount},")
    sb.append("\"teamCount\":${teamCount},\"createdAt\":${o.createdAt},\"updatedAt\":${o.updatedAt}}")
    sb.toString()
}

public func orgListJson(items: ArrayList<String>, total: Int64): String {
    let sb = StringBuilder()
    sb.append("{\"total\":${total},\"items\":[")
    for (i in 0..items.size) {
        if (i > 0) {
            sb.append(",")
        }
        sb.append(items[i])
    }
    sb.append("]}")
    sb.toString()
}
