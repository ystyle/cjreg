// 管理 API handler：认证（login/logout/me）+ 用户管理 + 上游管理
// 基于 tang 路由；业务逻辑复用 auth/upstream 模块
package ystyle::cjreg.server

import tang.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*
import ystyle::cjreg.auth.util.*
import ystyle::cjreg.config.*
import stdx.encoding.json.stream.*
import std.collection.*
import std.io.*
import std.convert.*

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

// 管理服务：组装 auth + 上游，注册管理路由
public class AdminService {
    public var auth: AuthService
    public var upstreamSvc: UpstreamService
    public var userStore: UserStore
    public var upstreamStore: UpstreamStore

    public init(auth: AuthService, upstreamSvc: UpstreamService,
                userStore: UserStore, upstreamStore: UpstreamStore) {
        this.auth = auth
        this.upstreamSvc = upstreamSvc
        this.userStore = userStore
        this.upstreamStore = upstreamStore
    }

    // 从 Authorization 头取 token
    public func extractToken(ctx: TangHttpContext): ?String {
        let header = ctx.getHeader("Authorization")
        match (header) {
            case Some(h) =>
                if (h.startsWith("Bearer ")) {
                    return Some(h[7..h.size])
                }
                return None
            case None => return None
        }
    }

    // 当前用户（未认证返回 None）
    public func currentUser(ctx: TangHttpContext): ?User {
        let token = this.extractToken(ctx)
        if (token.isNone()) {
            return None
        }
        return this.auth.validateSessionToken(token.getOrThrow())
    }

    public func login(ctx: TangHttpContext): Unit {
        // 手动解析 JSON body（bindJson 对流位置敏感，这里用 bodyRaw 更稳）
        let req = parseLoginBody(ctx.bodyRaw())
        match (req) {
            case Some(lr) =>
                if (lr.username.isEmpty() || lr.password.isEmpty()) {
                    writeJson(ctx, 400u16, "{\"error\":\"username and password required\"}")
                    return
                }
                match (this.auth.login(lr.username, lr.password)) {
                    case Some((user, token)) =>
                        writeJson(ctx, 200u16,
                            "{\"id\":${user.id},\"username\":\"${user.username}\"," +
                            "\"isAdmin\":${user.isAdmin},\"token\":\"${token.token}\"," +
                            "\"expiresAt\":${token.expiresAt}}")
                    case None =>
                        // 诊断：区分用户不存在与密码错误
                        match (this.userStore.getUserByUsername(lr.username)) {
                            case Some(u) =>
                                println("[login] user ${lr.username} exists, password verify failed")
                            case None =>
                                println("[login] user ${lr.username} NOT FOUND (users=${this.userStore.listAllUsers().size})")
                        }
                        writeJson(ctx, 401u16, "{\"error\":\"invalid username or password\"}")
                }
            case None =>
                writeJson(ctx, 400u16, "{\"error\":\"invalid JSON body\"}")
        }
    }

    public func me(ctx: TangHttpContext): Unit {
        match (this.currentUser(ctx)) {
            case Some(user) =>
                writeJson(ctx, 200u16,
                    "{\"id\":${user.id},\"username\":\"${user.username}\"," +
                    "\"isAdmin\":${user.isAdmin},\"isActive\":${user.isActive}," +
                    "\"publishToken\":\"${user.publishToken}\"}")
            case None =>
                writeJson(ctx, 401u16, "{\"error\":\"not authenticated\"}")
        }
    }

    public func logout(ctx: TangHttpContext): Unit {
        let token = this.extractToken(ctx)
        if (token.isSome()) {
            this.auth.logout(token.getOrThrow())
        }
        writeJson(ctx, 200u16, "{\"status\":\"ok\"}")
    }

    public func listUsers(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let users = this.userStore.listAllUsers()
        let sb = StringBuilder()
        sb.append("[")
        for (i in 0..users.size) {
            let u = users[i]
            if (i > 0) {
                sb.append(",")
            }
            sb.append("{\"id\":${u.id},\"username\":\"${u.username}\"," +
                "\"isAdmin\":${u.isAdmin},\"isActive\":${u.isActive}}")
        }
        sb.append("]")
        writeJson(ctx, 200u16, sb.toString())
    }

    public func createUser(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        // 从 body 解析 username/password（表单字段）
        let username = ctx.fromValue("username") ?? ""
        let password = ctx.fromValue("password") ?? ""
        if (username.isEmpty() || password.isEmpty()) {
            writeJson(ctx, 400u16, "{\"error\":\"username and password required\"}")
            return
        }
        match (this.auth.createUser(username, password, false)) {
            case Some(u) =>
                writeJson(ctx, 200u16, "{\"id\":${u.id},\"username\":\"${u.username}\"}")
            case None =>
                writeJson(ctx, 409u16, "{\"error\":\"user already exists\"}")
        }
    }

    // ===== 上游管理 =====
    public func listUpstreams(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let list = this.upstreamStore.listAll()
        let sb = StringBuilder()
        sb.append("[")
        for (i in 0..list.size) {
            let u = list[i]
            if (i > 0) {
                sb.append(",")
            }
            sb.append("{\"id\":${u.id},\"name\":\"${u.name}\",\"url\":\"${u.url}\"," +
                "\"enabled\":${u.enabled},\"isOfficial\":${u.isOfficial}," +
                "\"priority\":${u.priority},\"cacheTtl\":${u.cacheTtl}}")
        }
        sb.append("]")
        writeJson(ctx, 200u16, sb.toString())
    }

    public func addUpstream(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        // 手动解析 JSON body {name, url, priority}
        let body = String.fromUtf8(ctx.bodyRaw())
        var name = ""
        var url = ""
        var priorityStr = ""
        let bb = ByteBuffer()
        bb.write(body.toArray())
        let r = JsonReader(bb)
        try {
            while (let Some(v) <- r.peek()) {
                match (v) {
                    case BeginObject =>
                        r.startObject()
                        while (r.peek() != EndObject) {
                            let n = r.readName()
                            match (n) {
                                case "name" => name = r.readValue<String>()
                                case "url" => url = r.readValue<String>()
                                case "priority" => priorityStr = r.readValue<String>()
                                case _ => r.skip()
                            }
                        }
                        r.endObject()
                        break
                    case _ => r.skip()
                }
            }
        } catch (e: Exception) {
            ()
        }
        let priority = parsePriority(priorityStr)
        if (name.isEmpty() || url.isEmpty()) {
            writeJson(ctx, 400u16, "{\"error\":\"name and url required\"}")
            return
        }
        match (this.upstreamSvc.add(name, url, priority, "", 0)) {
            case Some(u) =>
                writeJson(ctx, 200u16, "{\"id\":${u.id},\"name\":\"${u.name}\",\"isOfficial\":${u.isOfficial}}")
            case None =>
                writeJson(ctx, 409u16, "{\"error\":\"upstream name exists or invalid\"}")
        }
    }

    public func deleteUpstream(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let idStr = ctx.param("id")
        let id = Int64.parse(idStr)
        if (this.upstreamSvc.remove(id)) {
            writeJson(ctx, 200u16, "{\"status\":\"ok\"}")
        } else {
            writeJson(ctx, 409u16, "{\"error\":\"cannot delete (not found or official protected)\"}")
        }
    }

    func requireAdmin(ctx: TangHttpContext): Bool {
        match (this.currentUser(ctx)) {
            case Some(user) =>
                if (user.isAdmin) {
                    return true
                }
                writeJson(ctx, 403u16, "{\"error\":\"admin required\"}")
                return false
            case None =>
                writeJson(ctx, 401u16, "{\"error\":\"not authenticated\"}")
                return false
        }
    }

    func parsePriority(v: String): Int64 {
        let n = Int64.tryParse(v)
        match (n) {
            case Some(p) => return p
            case None => return 0
        }
    }
}

// 写 JSON 响应
public func writeJson(ctx: TangHttpContext, code: UInt16, body: String): Unit {
    ctx.contentType("application/json").status(code).writeStringWithCode(code, body)
}

// 手动解析登录 JSON body（{username, password}）
public func parseLoginBody(body: Array<Byte>): ?LoginRequest {
    let text = String.fromUtf8(body)
    let bb = ByteBuffer()
    bb.write(text.toArray())
    let r = JsonReader(bb)
    let req = LoginRequest()
    try {
        while (let Some(v) <- r.peek()) {
            match (v) {
                case BeginObject =>
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
                    return Some(req)
                case _ => r.skip()
            }
        }
        return None
    } catch (e: Exception) {
        return None
    }
}
