// 用户门户只读 API（/api/user/*）响应 DTO
//
// 响应体一律交给 JsonWriter 序列化：字段名与转义由序列化器负责，不再手工拼 JSON 字符串。
// 字段名、字段顺序即客户端契约（前端与测试按 JSON 文本断言）：新增字段只能追加在末尾。
package ystyle::cjreg.server

import std.collection.*
import stdx.encoding.json.stream.*

// 门户「我是谁」：{"id":N,"username":"..","email":"..","isAdmin":bool,"publishTokenMasked":"..",
//                 "permissionMode":"..","permissionHint":".."}
// publishToken 只给掩码形态（明文只在重置那一次由 PublishTokenResp 返回）
public class PortalMeResp <: JsonSerializable {
    public let id: Int64
    public let username: String
    public let email: String
    public let isAdmin: Bool
    public let publishTokenMasked: String
    public let permissionMode: String
    public let permissionHint: String

    public init(id: Int64, username: String, email: String, isAdmin: Bool, publishTokenMasked: String,
                permissionMode: String, permissionHint: String) {
        this.id = id
        this.username = username
        this.email = email
        this.isAdmin = isAdmin
        this.publishTokenMasked = publishTokenMasked
        this.permissionMode = permissionMode
        this.permissionHint = permissionHint
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(id)
        w.writeName("username").writeValue(username)
        w.writeName("email").writeValue(email)
        w.writeName("isAdmin").writeValue(isAdmin)
        w.writeName("publishTokenMasked").writeValue(publishTokenMasked)
        w.writeName("permissionMode").writeValue(permissionMode)
        w.writeName("permissionHint").writeValue(permissionHint)
        w.endObject()
    }
}

// 重置发布 Token 的回执：{"publishToken":".."}（明文只此一次）
public class PublishTokenResp <: JsonSerializable {
    public let publishToken: String

    public init(publishToken: String) {
        this.publishToken = publishToken
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("publishToken").writeValue(publishToken)
        w.endObject()
    }
}

// 我的包列表行：{"organization":"..","name":"..","versionCount":N,"latestVersion":"..",
//                "isOwner":bool,"updatedAt":N}
public class MyPackageRowDto <: JsonSerializable {
    public let organization: String
    public let name: String
    public let versionCount: Int64
    public let latestVersion: String
    public let isOwner: Bool
    public let updatedAt: Int64

    public init(organization: String, name: String, versionCount: Int64, latestVersion: String, isOwner: Bool,
                updatedAt: Int64) {
        this.organization = organization
        this.name = name
        this.versionCount = versionCount
        this.latestVersion = latestVersion
        this.isOwner = isOwner
        this.updatedAt = updatedAt
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("organization").writeValue(organization)
        w.writeName("name").writeValue(name)
        w.writeName("versionCount").writeValue(versionCount)
        w.writeName("latestVersion").writeValue(latestVersion)
        w.writeName("isOwner").writeValue(isOwner)
        w.writeName("updatedAt").writeValue(updatedAt)
        w.endObject()
    }
}

// 我的包（服务端分页）：{"total":N,"page":N,"size":N,"items":[<MyPackageRowDto>..]}
public class MyPackageListResp <: JsonSerializable {
    public let total: Int64
    public let page: Int64
    public let size: Int64
    public let items: ArrayList<MyPackageRowDto>

    public init(total: Int64, page: Int64, size: Int64, items: ArrayList<MyPackageRowDto>) {
        this.total = total
        this.page = page
        this.size = size
        this.items = items
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("total").writeValue(total)
        w.writeName("page").writeValue(page)
        w.writeName("size").writeValue(size)
        w.writeName("items").writeValue(items)
        w.endObject()
    }
}

// 我的团队行：{"id":N,"name":"..","displayName":"..","permission":"..","organizations":[..],
//              "packages":[..]}
public class MyTeamRowDto <: JsonSerializable {
    public let id: Int64
    public let name: String
    public let displayName: String
    public let permission: String
    public let organizations: ArrayList<String>
    public let packages: ArrayList<String>

    public init(id: Int64, name: String, displayName: String, permission: String,
                organizations: ArrayList<String>, packages: ArrayList<String>) {
        this.id = id
        this.name = name
        this.displayName = displayName
        this.permission = permission
        this.organizations = organizations
        this.packages = packages
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(id)
        w.writeName("name").writeValue(name)
        w.writeName("displayName").writeValue(displayName)
        w.writeName("permission").writeValue(permission)
        w.writeName("organizations").writeValue(organizations)
        w.writeName("packages").writeValue(packages)
        w.endObject()
    }
}

// 我的团队：{"permissionMode":"..","items":[<MyTeamRowDto>..]}
public class MyTeamsResp <: JsonSerializable {
    public let permissionMode: String
    public let items: ArrayList<MyTeamRowDto>

    public init(permissionMode: String, items: ArrayList<MyTeamRowDto>) {
        this.permissionMode = permissionMode
        this.items = items
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("permissionMode").writeValue(permissionMode)
        w.writeName("items").writeValue(items)
        w.endObject()
    }
}
