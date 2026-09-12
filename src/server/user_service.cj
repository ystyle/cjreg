// 用户门户读模型与展示辅助（纯逻辑，不依赖 HTTP/UI → 可直接单测）
//
// 门户页面（server-rendered cjxt）与只读 API（/api/user/*）共用这一层：
//   - 我的包：我发布过版本的包（版本级 publisherId 命中），标注是否为包名所有者（owner）
//   - 我的团队与权限：我所属团队 + 团队权限 + 关联组织/包
// 权限语义见 docs/design.md §5.3.6 / §5.4.3（owner 唯一，版本级 publisherId 不授权）。
package ystyle::cjreg.server

import ystyle::cjreg.store.*
import ystyle::cjreg.semver_range.*
import std.collection.*

/// 我的包（按 org::name 聚合的一行）
public struct MyPackageRow {
    public let org: String
    public let name: String
    public let versionCount: Int64      // 未软删版本数
    public let latestVersion: String
    public let isOwner: Bool            // 包名所有者（最早一条版本记录的发布者）
    public let updatedAt: Int64         // 最近一次发布时间（毫秒）

    public init(org: String, name: String, versionCount: Int64, latestVersion: String, isOwner: Bool, updatedAt: Int64) {
        this.org = org
        this.name = name
        this.versionCount = versionCount
        this.latestVersion = latestVersion
        this.isOwner = isOwner
        this.updatedAt = updatedAt
    }

    /// 展示名（无组织包只显示 name）
    public func displayName(): String {
        if (this.org.isEmpty()) { this.name } else { "${this.org}::${this.name}" }
    }
}

/// 我的团队（一行 = 一个团队的权限与关联）
public struct MyTeamRow {
    public let teamId: Int64
    public let name: String
    public let displayName: String
    public let permission: String       // read/write/overwrite
    public let orgNames: ArrayList<String>
    public let packages: ArrayList<String>

    public init(teamId: Int64, name: String, displayName: String, permission: String,
                orgNames: ArrayList<String>, packages: ArrayList<String>) {
        this.teamId = teamId
        this.name = name
        this.displayName = displayName
        this.permission = permission
        this.orgNames = orgNames
        this.packages = packages
    }

    /// 展示名（无显示名时用标识名）
    public func label(): String {
        if (this.displayName.isEmpty()) { this.name } else { this.displayName }
    }
}

/// 我发布过版本的包：任一版本 publisherId == uid（含软删版本，历史贡献不因删版本消失）
/// 每行给出未软删版本数、最新版本（semver 最大）、owner 标记、最近发布时间
public func myPackageRows(pkgStore: PackageStore, adminData: AdminDataStore, uid: Int64): ArrayList<MyPackageRow> {
    let keys = ArrayList<String>()
    let orgs = ArrayList<String>()
    let names = ArrayList<String>()
    let counts = ArrayList<Int64>()
    let latest = ArrayList<String>()
    let owners = ArrayList<Int64>()
    let updated = ArrayList<Int64>()
    for (d in pkgStore.storm.all<PackageDoc>()) {
        let key = d.organization + "::" + d.name
        var idx = -1
        for (i in 0..keys.size) {
            if (keys[i] == key) {
                idx = i
                break
            }
        }
        if (idx < 0) {
            keys.add(key)
            orgs.add(d.organization)
            names.add(d.name)
            counts.add(0)
            latest.add("")
            owners.add(0)
            updated.add(0)
            idx = keys.size - 1
        }
        // 历史贡献：软删版本也算「我发过」
        if (d.publisherId == uid) {
            owners[idx] = 1
        }
        if (d.deletedAt != 0) {
            continue
        }
        counts[idx] = counts[idx] + 1
        if (latest[idx].isEmpty() || compareVersions(d.version, latest[idx]) > 0) {
            latest[idx] = d.version
        }
        if (d.updatedAt > updated[idx]) {
            updated[idx] = d.updatedAt
        }
    }
    let rows = ArrayList<MyPackageRow>()
    for (i in 0..keys.size) {
        if (owners[i] == 0) {
            continue
        }
        let isOwner = packageOwner(pkgStore, orgs[i], names[i]) == uid
        rows.add(MyPackageRow(orgs[i], names[i], counts[i], latest[i], isOwner, updated[i]))
    }
    rows
}

/// 我的团队：我是成员的团队（权限 + 关联组织名 + 关联包名）
public func myTeamRows(adminData: AdminDataStore, uid: Int64): ArrayList<MyTeamRow> {
    let rows = ArrayList<MyTeamRow>()
    for (t in adminData.listTeams()) {
        if (!isTeamMember(adminData, t.id, uid)) {
            continue
        }
        let orgNames = ArrayList<String>()
        for (oid in adminData.listTeamOrganizationIds(t.id)) {
            orgNames.add(orgLabel(adminData, oid))
        }
        let pkgs = ArrayList<String>()
        for (p in adminData.listTeamPackages(t.id)) {
            if (p.organization.isEmpty()) {
                pkgs.add(p.packageName)
            } else {
                pkgs.add("${p.organization}::${p.packageName}")
            }
        }
        rows.add(MyTeamRow(t.id, t.name, t.displayName, t.permission, orgNames, pkgs))
    }
    rows
}

/// 组织 ID → 展示名（0 = 无组织包）
func orgLabel(adminData: AdminDataStore, orgId: Int64): String {
    if (orgId == 0) {
        return "（无组织包）"
    }
    for (o in adminData.listOrgs()) {
        if (o.id == orgId) {
            return o.name
        }
    }
    "#${orgId}"
}

/// 发布 Token 掩码（只留后 8 位随机部分，其余打码）——API 响应等非完整展示场景
/// （门户页面本身在登录后展示完整 Token，否则用户无法配置 cjpm）
public func maskToken(token: String): String {
    if (token.size <= 8) {
        return "****"
    }
    "****" + token[token.size - 8..token.size]
}

/// 发布权限模式提示文案（门户「我的团队与权限」区块）
public func permissionHint(mode: String): String {
    if (mode == "team") {
        "当前为团队模式：发布需对目标包/组织具备 write 权限，覆盖已存在版本需 overwrite"
    } else {
        "当前为内部开放模式（open）：持有有效发布 Token 即可发布，无需团队授权"
    }
}
