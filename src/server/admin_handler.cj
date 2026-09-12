// 管理 API handler：认证（login/logout/me）+ 用户管理 + 上游管理 + resolve + 发布计划 analyze
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

// 管理服务：组装 auth + 上游 + resolve + 发布计划
public class AdminService {
    public var auth: AuthService
    public var upstreamSvc: UpstreamService
    public var userStore: UserStore
    public var upstreamStore: UpstreamStore
    public var resolveSvc: ResolveService
    public var proxySvc: ?ProxyService
    public var planSvc: PublishPlanService
    public var executor: PublishExecutor

    public init(auth: AuthService, upstreamSvc: UpstreamService,
                userStore: UserStore, upstreamStore: UpstreamStore,
                resolveSvc: ResolveService, proxySvc: ?ProxyService,
                planSvc: PublishPlanService, executor: PublishExecutor) {
        this.auth = auth
        this.upstreamSvc = upstreamSvc
        this.userStore = userStore
        this.upstreamStore = upstreamStore
        this.resolveSvc = resolveSvc
        this.proxySvc = proxySvc
        this.planSvc = planSvc
        this.executor = executor
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

    // 创建用户（普通/管理员）：body {username, password, isAdmin?, email?}
    // isAdmin 显式传入（与管理端 UI 的「管理员」开关口径一致，不再硬编码 false）
    public func createUser(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let req = parseJsonBody<CreateUserRequest>(ctx.bodyRaw(), { r => CreateUserRequest.fromJson(r) })
        match (req) {
            case Some(r) =>
                if (r.username.isEmpty() || r.password.isEmpty()) {
                    writeJson(ctx, 400u16, "{\"error\":\"username and password required\"}")
                    return
                }
                match (this.auth.createUser(r.username, r.password, r.isAdmin, email: r.email)) {
                    case Some(u) =>
                        writeJson(ctx, 200u16,
                            "{\"id\":${u.id},\"username\":\"${u.username}\",\"isAdmin\":${u.isAdmin}}")
                    case None =>
                        writeJson(ctx, 409u16, "{\"error\":\"user already exists\"}")
                }
            case None =>
                writeJson(ctx, 400u16, "{\"error\":\"invalid JSON body\"}")
        }
    }

    // 提升/取消管理员：PUT /api/admin/users/:id/admin  body {isAdmin: bool}
    // 「最后一个启用管理员」不可被取消身份（409）——与管理端 UI 同一约束
    public func setUserAdmin(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let uid = match (Int64.tryParse(ctx.param("id"))) {
            case Some(n) => n
            case None => 0
        }
        if (uid <= 0) {
            writeJson(ctx, 400u16, "{\"error\":\"invalid user id\"}")
            return
        }
        let req = parseJsonBody<SetUserAdminRequest>(ctx.bodyRaw(), { r => SetUserAdminRequest.fromJson(r) })
        // 字段缺失（None）与显式 false 必须区分：前者 400，后者是「降级」语义
        var hasFlag = false
        var target = false
        match (req) {
            case Some(r) => match (r.isAdmin) {
                case Some(b) =>
                    target = b
                    hasFlag = true
                case None => ()
            }
            case None => ()
        }
        if (!hasFlag) {
            writeJson(ctx, 400u16, "{\"error\":\"isAdmin (bool) required in JSON body\"}")
            return
        }
        match (this.userStore.getUser(uid)) {
            case None =>
                writeJson(ctx, 404u16, "{\"error\":\"user not found\"}")
                return
            case Some(_) => ()
        }
        if (!this.auth.setUserAdmin(uid, target)) {
            writeJson(ctx, 409u16, "{\"error\":\"cannot revoke the last active admin\"}")
            return
        }
        let u = this.userStore.getUser(uid).getOrThrow()
        writeJson(ctx, 200u16,
            "{\"id\":${u.id},\"username\":\"${u.username}\",\"isAdmin\":${u.isAdmin}}")
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

    // ===== resolve 诊断端点 =====
    public func resolvePackage(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let name = ctx.query("name") ?? ""
        let org = ctx.query("organization") ?? ""
        let require = ctx.query("require") ?? ""
        if (name.isEmpty()) {
            writeJson(ctx, 400u16, "{\"error\":\"name required\"}")
            return
        }
        let fetchIndex: (String, String) -> ?String = { o: String, n: String =>
            match (this.proxySvc) {
                case Some(proxy) =>
                    let (outcome, ndjson) = proxy.fetchIndex(o, n)
                    if (ndjson.isEmpty()) {
                        None
                    } else {
                        Some(ndjson)
                    }
                case None => None
            }
        }
        let r = this.resolveSvc.resolve(name, org, require, fetchIndex)
        let sb = StringBuilder()
        sb.append("{\"name\":\"${r.name}\",\"org\":\"${r.org}\",\"require\":\"${r.require}\",")
        sb.append("\"found\":${r.found},\"replaced\":${r.replaced},")
        sb.append("\"replacedBy\":\"${r.replacedBy}\",")
        sb.append("\"selected\":")
        match (r.selected) {
            case Some(c) =>
                sb.append("{\"repo\":\"${c.repo}\",\"version\":\"${c.version}\",\"sha256sum\":\"${c.sha256sum}\",\"conflict\":${c.conflict}}")
            case None => sb.append("null")
        }
        sb.append(",\"candidates\":[")
        for (i in 0..r.candidates.size) {
            let c = r.candidates[i]
            if (i > 0) {
                sb.append(",")
            }
            sb.append("{\"repo\":\"${c.repo}\",\"version\":\"${c.version}\",\"sha256sum\":\"${c.sha256sum}\",\"conflict\":${c.conflict}}")
        }
        sb.append("],\"trace\":[")
        for (i in 0..r.trace.size) {
            if (i > 0) {
                sb.append(",")
            }
            sb.append("\"${r.trace[i]}\"")
        }
        sb.append("]}")
        writeJson(ctx, 200u16, sb.toString())
    }

    // ===== 发布计划 analyze =====
    public func analyzePlan(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let body = String.fromUtf8(ctx.bodyRaw())
        var roots = ArrayList<(String, String, String)>()
        parsePackagesBody(body, roots)
        if (roots.size == 0) {
            writeJson(ctx, 400u16, "{\"error\":\"packages required\"}")
            return
        }
        let (items, cycle) = this.planSvc.analyze(roots)
        let sb = StringBuilder()
        sb.append("{\"publish_order\":[")
        for (i in 0..items.size) {
            if (i > 0) {
                sb.append(",")
            }
            let it = items[i]
            sb.append("{\"name\":\"${it.name}\",\"org\":\"${it.org}\",\"version\":\"${it.version}\",\"order\":${it.order}}")
        }
        sb.append("],\"hasCycle\":${cycle}}")
        writeJson(ctx, 200u16, sb.toString())
    }

    // 发布计划执行：POST /api/admin/publish-plans/execute
    // body: {packages:[{organization,name,version}], target_url, target_token?}
    // target_token 为空时按 target_url 匹配上游表取该上游的 authToken
    // （否则推送到需要认证的目标仓——如官方中心仓或另一个私有仓——会 401）
    public func executePlan(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let body = String.fromUtf8(ctx.bodyRaw())
        var roots = ArrayList<(String, String, String)>()
        parsePackagesBody(body, roots)
        var targetUrl = ""
        var targetToken = ""
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
                            if (n == "target_url") {
                                targetUrl = r.readValue<String>()
                            } else if (n == "target_token") {
                                targetToken = r.readValue<String>()
                            } else {
                                r.skip()
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
        if (roots.size == 0 || targetUrl.isEmpty()) {
            writeJson(ctx, 400u16, "{\"error\":\"packages and target_url required\"}")
            return
        }
        // 目标仓鉴权：显式 target_token 优先，否则按 URL 匹配上游表取该上游 authToken
        let token = resolveTargetToken(targetToken, targetUrl, this.upstreamStore.listAll())
        // 先 analyze 得拓扑 items
        let (items, _) = this.planSvc.analyze(roots)
        if (items.size == 0) {
            writeJson(ctx, 400u16, "{\"error\":\"no packages found locally\"}")
            return
        }
        let (ok, total, errors) = this.executor.execute(items, targetUrl, token)
        let sb = StringBuilder()
        sb.append("{\"success\":${ok},\"total\":${total},\"errors\":[")
        for (i in 0..errors.size) {
            if (i > 0) {
                sb.append(",")
            }
            sb.append("\"${errors[i]}\"")
        }
        sb.append("]}")
        writeJson(ctx, 200u16, sb.toString())
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

// 目标仓发布 token 解析：显式传入优先；否则按 URL 匹配上游表取其 authToken
// （发布计划推送到官方仓或另一个私有仓时都要带 token，否则目标仓 401）
public func resolveTargetToken(explicit: String, targetUrl: String, upstreams: ArrayList<Upstream>): String {
    if (!explicit.isEmpty()) {
        return explicit
    }
    let want = trimUrl(targetUrl)
    for (u in upstreams) {
        if (trimUrl(u.url) == want) {
            return u.authToken
        }
    }
    ""
}

// URL 归一（去尾部斜杠，便于比较）
func trimUrl(v: String): String {
    var s = v.trimAscii()
    while (s.size > 0 && s[s.size - 1] == 47u8) {
        s = s[0..s.size - 1]
    }
    s
}

// 写 JSON 响应
public func writeJson(ctx: TangHttpContext, code: UInt16, body: String): Unit {
    ctx.contentType("application/json").status(code).writeStringWithCode(code, body)
}

// 解析登录 JSON body（{username, password}）
public func parseLoginBody(body: Array<Byte>): ?LoginRequest {
    parseJsonBody<LoginRequest>(body, { r => LoginRequest.fromJson(r) })
}

// 解析 JSON body（空 body / 非 JSON / 字段类型不符均返回 None）
// 统一登录、创建用户、角色变更等端点的 body 解析入口
public func parseJsonBody<T>(body: Array<Byte>, f: (JsonReader) -> T): ?T {
    try {
        let text = String.fromUtf8(body)
        if (text.isEmpty()) {
            return None
        }
        let bb = ByteBuffer()
        bb.write(text.toArray())
        return Some(f(JsonReader(bb)))
    } catch (e: Exception) {
        return None
    }
}
