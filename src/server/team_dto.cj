// 管理面 · 团队（含 owner 自助开关）请求/响应 DTO
//
// 响应体一律交给 JsonWriter 序列化（字段名与顺序即客户端契约，新增字段只能追加在末尾）。
package ystyle::cjreg.server

import std.collection.*
import stdx.encoding.json.stream.*
import ystyle::cjreg.store.*

// 团队行：{"id":N,"name":"..","displayName":"..","description":"..","permission":"..",
//  "ownerId":N,"ownerName":"..","selfService":bool,"memberCount":N}
public class TeamRowResp <: JsonSerializable {
    public let id: Int64
    public let name: String
    public let displayName: String
    public let description: String
    public let permission: String
    public let ownerId: Int64
    public let ownerName: String
    public let selfService: Bool
    public let memberCount: Int64

    public init(id: Int64, name: String, displayName: String, description: String, permission: String,
                ownerId: Int64, ownerName: String, selfService: Bool, memberCount: Int64) {
        this.id = id
        this.name = name
        this.displayName = displayName
        this.description = description
        this.permission = permission
        this.ownerId = ownerId
        this.ownerName = ownerName
        this.selfService = selfService
        this.memberCount = memberCount
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(id)
        w.writeName("name").writeValue(name)
        w.writeName("displayName").writeValue(displayName)
        w.writeName("description").writeValue(description)
        w.writeName("permission").writeValue(permission)
        w.writeName("ownerId").writeValue(ownerId)
        w.writeName("ownerName").writeValue(ownerName)
        w.writeName("selfService").writeValue(selfService)
        w.writeName("memberCount").writeValue(memberCount)
        w.endObject()
    }
}

// 团队列表（裸数组，与管理端用户列表同一口径）
// 团队成员行：{"userId":N,"username":"..","isOwner":bool}
public class TeamMemberResp <: JsonSerializable {
    public let userId: Int64
    public let username: String
    public let isOwner: Bool

    public init(userId: Int64, username: String, isOwner: Bool) {
        this.userId = userId
        this.username = username
        this.isOwner = isOwner
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("userId").writeValue(userId)
        w.writeName("username").writeValue(username)
        w.writeName("isOwner").writeValue(isOwner)
        w.endObject()
    }
}

// 自助操作回执：{"ok":bool,"outcome":"..","message":"..","teamId":N}
public class TeamSelfServiceResp <: JsonSerializable {
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

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("ok").writeValue(ok)
        w.writeName("outcome").writeValue(outcome)
        w.writeName("message").writeValue(message)
        w.writeName("teamId").writeValue(teamId)
        w.endObject()
    }
}

public func teamSelfServiceResp(r: TeamSelfServiceResult): TeamSelfServiceResp {
    TeamSelfServiceResp(r.ok, r.outcome, r.message, r.teamId)
}

// ===== 请求体 =====

// 创建/更新团队：{name?, displayName?, description?, permission?, ownerId?, selfService?}
// hasX 区分「字段未传」与「显式传空/false」（PUT 未传字段保持原值）
public class TeamUpsertRequest <: JsonDeserializable<TeamUpsertRequest> {
    public var name: String = ""
    public var displayName: String = ""
    public var description: String = ""
    public var permission: String = "read"
    public var ownerId: Int64 = 0
    public var selfService: Bool = false
    public var hasDisplayName: Bool = false
    public var hasDescription: Bool = false
    public var hasPermission: Bool = false
    public var hasOwnerId: Bool = false
    public var hasSelfService: Bool = false

    public init() {}

    public static func fromJson(r: JsonReader): TeamUpsertRequest {
        let req = TeamUpsertRequest()
        r.startObject()
        while (r.peek() != EndObject) {
            let n = r.readName()
            match (n) {
                case "name" => req.name = r.readValue<String>()
                case "displayName" =>
                    req.displayName = r.readValue<String>()
                    req.hasDisplayName = true
                case "description" =>
                    req.description = r.readValue<String>()
                    req.hasDescription = true
                case "permission" =>
                    req.permission = r.readValue<String>()
                    req.hasPermission = true
                case "ownerId" =>
                    req.ownerId = r.readValue<Int64>()
                    req.hasOwnerId = true
                case "selfService" =>
                    req.selfService = r.readValue<Bool>()
                    req.hasSelfService = true
                case _ => r.skip()
            }
        }
        r.endObject()
        return req
    }
}

// 成员操作请求：{userId:N} / 转让：{userId:N}
public class TeamMemberRequest <: JsonDeserializable<TeamMemberRequest> {
    public var userId: Int64 = 0

    public init() {}

    public static func fromJson(r: JsonReader): TeamMemberRequest {
        let req = TeamMemberRequest()
        r.startObject()
        while (r.peek() != EndObject) {
            let n = r.readName()
            match (n) {
                case "userId" => req.userId = r.readValue<Int64>()
                case _ => r.skip()
            }
        }
        r.endObject()
        return req
    }
}

// 自助开关请求：{enabled: bool}
public class TeamSelfServiceRequest <: JsonDeserializable<TeamSelfServiceRequest> {
    public var enabled: Bool = false

    public init() {}

    public static func fromJson(r: JsonReader): TeamSelfServiceRequest {
        let req = TeamSelfServiceRequest()
        r.startObject()
        while (r.peek() != EndObject) {
            let n = r.readName()
            match (n) {
                case "enabled" => req.enabled = r.readValue<Bool>()
                case _ => r.skip()
            }
        }
        r.endObject()
        return req
    }
}

// 团队关联设置请求：
//   组织：{"organizationIds":[1,2,0]}（0 = 「无组织包」哨兵）
//   包：  {"packages":[{"organization":"acme","name":"demo"}]}
public class TeamLinksRequest <: JsonDeserializable<TeamLinksRequest> {
    public var organizationIds: ArrayList<Int64> = ArrayList<Int64>()
    public var packages: ArrayList<(String, String)> = ArrayList<(String, String)>()
    public var hasOrganizations: Bool = false
    public var hasPackages: Bool = false

    public init() {}

    public static func fromJson(r: JsonReader): TeamLinksRequest {
        let req = TeamLinksRequest()
        r.startObject()
        while (r.peek() != EndObject) {
            let n = r.readName()
            match (n) {
                case "organizationIds" =>
                    req.hasOrganizations = true
                    r.startArray()
                    while (r.peek() != EndArray) {
                        req.organizationIds.add(r.readValue<Int64>())
                    }
                    r.endArray()
                case "packages" =>
                    req.hasPackages = true
                    r.startArray()
                    while (r.peek() != EndArray) {
                        r.startObject()
                        var org = ""
                        var itemName = ""
                        while (r.peek() != EndObject) {
                            let f = r.readName()
                            match (f) {
                                case "organization" => org = r.readValue<String>()
                                case "name" => itemName = r.readValue<String>()
                                case _ => r.skip()
                            }
                        }
                        r.endObject()
                        req.packages.add((org, itemName))
                    }
                    r.endArray()
                case _ => r.skip()
            }
        }
        r.endObject()
        return req
    }
}

// 团队关联的响应体：{"organizationIds":[..],"packages":[{"organization":"..","name":".."}]}
public class TeamLinksResp <: JsonSerializable {
    public let organizationIds: ArrayList<Int64>
    public let packages: ArrayList<TeamPkgLinkResp>

    public init(organizationIds: ArrayList<Int64>, packages: ArrayList<TeamPkgLinkResp>) {
        this.organizationIds = organizationIds
        this.packages = packages
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("organizationIds").writeValue(organizationIds)
        w.writeName("packages").writeValue(packages)
        w.endObject()
    }
}

public class TeamPkgLinkResp <: JsonSerializable {
    public let organization: String
    public let name: String

    public init(organization: String, name: String) {
        this.organization = organization
        this.name = name
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("organization").writeValue(organization)
        w.writeName("name").writeValue(name)
        w.endObject()
    }
}

public func teamLinksJson(ad: AdminDataStore, teamId: Int64): TeamLinksResp {
    let pkgs = ArrayList<TeamPkgLinkResp>()
    for (p in ad.listTeamPackages(teamId)) {
        pkgs.add(TeamPkgLinkResp(p.organization, p.packageName))
    }
    TeamLinksResp(ad.listTeamOrganizationIds(teamId), pkgs)
}
