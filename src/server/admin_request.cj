// 管理 API · 请求体 DTO：登录 / 组织 upsert / 创建用户 / 角色变更
package ystyle::cjreg.server

import stdx.encoding.json.stream.*

// 登录请求
public class LoginRequest <: JsonDeserializable<LoginRequest> {
    public var username: String = ""
    public var password: String = ""

    public init() {}

    public static func fromJson(r: JsonReader): LoginRequest {
        let req = LoginRequest()
        r.startObject()
        while (r.peek() != EndObject) {
            let n = r.readName()
            match (n) {
                case "username" => req.username = r.readValue<String>()
                case "password" => req.password = r.readValue<String>()
                case _ => r.skip()
            }
        }
        r.endObject()
        return req
    }
}

// 组织创建/更新请求（body: {name?, displayName?, description?, isDefault?}）
// hasX 标记区分「字段未传」与「显式传空/假」——PUT 时未传字段保持原值
public class OrgUpsertRequest <: JsonDeserializable<OrgUpsertRequest> {
    public var name: String = ""
    public var displayName: String = ""
    public var description: String = ""
    public var isDefault: Bool = false
    public var hasDisplayName: Bool = false
    public var hasDescription: Bool = false
    public var hasIsDefault: Bool = false

    public init() {}

    public static func fromJson(r: JsonReader): OrgUpsertRequest {
        let req = OrgUpsertRequest()
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
                case "isDefault" =>
                    req.isDefault = r.readValue<Bool>()
                    req.hasIsDefault = true
                case _ => r.skip()
            }
        }
        r.endObject()
        return req
    }
}

// 创建用户请求（body: {username, password, isAdmin?, email?}）
public class CreateUserRequest <: JsonDeserializable<CreateUserRequest> {
    public var username: String = ""
    public var password: String = ""
    public var isAdmin: Bool = false
    public var email: String = ""

    public init() {}

    public static func fromJson(r: JsonReader): CreateUserRequest {
        let req = CreateUserRequest()
        r.startObject()
        while (r.peek() != EndObject) {
            let n = r.readName()
            match (n) {
                case "username" => req.username = r.readValue<String>()
                case "password" => req.password = r.readValue<String>()
                case "isAdmin" => req.isAdmin = r.readValue<Bool>()
                case "email" => req.email = r.readValue<String>()
                case _ => r.skip()
            }
        }
        r.endObject()
        return req
    }
}

// 用户角色变更请求（body: {isAdmin: true|false}）
public class SetUserAdminRequest <: JsonDeserializable<SetUserAdminRequest> {
    public var isAdmin: ?Bool = None

    public init() {}

    public static func fromJson(r: JsonReader): SetUserAdminRequest {
        let req = SetUserAdminRequest()
        r.startObject()
        while (r.peek() != EndObject) {
            let n = r.readName()
            match (n) {
                case "isAdmin" => req.isAdmin = Some(r.readValue<Bool>())
                case _ => r.skip()
            }
        }
        r.endObject()
        return req
    }
}
