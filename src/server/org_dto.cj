// 组织 CRUD（/api/admin/organizations*）响应 DTO
//
// 响应体一律交给 JsonWriter 序列化：字段名与转义由序列化器负责，不再手工拼 JSON 字符串。
// 字段名、字段顺序即客户端契约（前端与测试按 JSON 文本断言）：新增字段只能追加在末尾。
package ystyle::cjreg.server

import std.collection.*
import stdx.encoding.json.stream.*

// 组织行：{"id":N,"name":"..","displayName":"..","description":"..","isDefault":bool,"ownerId":N,
//          "packageCount":N,"versionCount":N,"teamCount":N,"createdAt":N,"updatedAt":N}
// packageCount/versionCount/teamCount 是列表页的聚合计数（不落在 OrgDoc 里）
public class OrgDto <: JsonSerializable {
    public let id: Int64
    public let name: String
    public let displayName: String
    public let description: String
    public let isDefault: Bool
    public let ownerId: Int64
    public let packageCount: Int64
    public let versionCount: Int64
    public let teamCount: Int64
    public let createdAt: Int64
    public let updatedAt: Int64

    public init(id: Int64, name: String, displayName: String, description: String, isDefault: Bool,
                ownerId: Int64, packageCount: Int64, versionCount: Int64, teamCount: Int64,
                createdAt: Int64, updatedAt: Int64) {
        this.id = id
        this.name = name
        this.displayName = displayName
        this.description = description
        this.isDefault = isDefault
        this.ownerId = ownerId
        this.packageCount = packageCount
        this.versionCount = versionCount
        this.teamCount = teamCount
        this.createdAt = createdAt
        this.updatedAt = updatedAt
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(id)
        w.writeName("name").writeValue(name)
        w.writeName("displayName").writeValue(displayName)
        w.writeName("description").writeValue(description)
        w.writeName("isDefault").writeValue(isDefault)
        w.writeName("ownerId").writeValue(ownerId)
        w.writeName("packageCount").writeValue(packageCount)
        w.writeName("versionCount").writeValue(versionCount)
        w.writeName("teamCount").writeValue(teamCount)
        w.writeName("createdAt").writeValue(createdAt)
        w.writeName("updatedAt").writeValue(updatedAt)
        w.endObject()
    }
}

// 组织列表：{"total":N,"items":[<OrgDto>..]}
public class OrgListResp <: JsonSerializable {
    public let total: Int64
    public let items: ArrayList<OrgDto>

    public init(total: Int64, items: ArrayList<OrgDto>) {
        this.total = total
        this.items = items
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("total").writeValue(total)
        w.writeName("items").writeValue(items)
        w.endObject()
    }
}

// 组织写操作结果：{"status":"..","message":"..","id":N,"affected":N}
// status 是 OrgOutcome 的稳定别名（ok/not_found/duplicate_name/invalid_name/has_packages/
// referenced_by_teams/rename_with_packages/failed），HTTP 状态码由 orgResultCode 单独映射
public class OrgResultResp <: JsonSerializable {
    public let status: String
    public let message: String
    public let id: Int64
    public let affected: Int64

    public init(status: String, message: String, id: Int64, affected: Int64) {
        this.status = status
        this.message = message
        this.id = id
        this.affected = affected
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("status").writeValue(status)
        w.writeName("message").writeValue(message)
        w.writeName("id").writeValue(id)
        w.writeName("affected").writeValue(affected)
        w.endObject()
    }
}
