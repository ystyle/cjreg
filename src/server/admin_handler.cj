// 管理 API handler：认证（login/logout/me）+ 用户管理 + 上游管理 + resolve + 发布计划 analyze
package ystyle::cjreg.server

import tang.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*
import ystyle::cjreg.auth.util.*
import ystyle::cjreg.config.*
import ystyle::cjreg.store.*
import stdx.encoding.json.stream.*
import std.collection.*
import std.io.*
import std.convert.*
import std.sort.*

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
    // 审计日志存储（None = 不记审计；与 buildServer 注入同一实例，避免 id 撞车）
    public var adminData: ?AdminDataStore
    // 包库与制品库（三级删除闭环用：软删/恢复/硬删 + 制品清理）
    public var pkgStore: ?PackageStore
    public var blobStore: ?BlobStore

    public init(auth: AuthService, upstreamSvc: UpstreamService,
                userStore: UserStore, upstreamStore: UpstreamStore,
                resolveSvc: ResolveService, proxySvc: ?ProxyService,
                planSvc: PublishPlanService, executor: PublishExecutor,
                adminData!: ?AdminDataStore = None,
                pkgStore!: ?PackageStore = None,
                blobStore!: ?BlobStore = None) {
        this.auth = auth
        this.upstreamSvc = upstreamSvc
        this.userStore = userStore
        this.upstreamStore = upstreamStore
        this.resolveSvc = resolveSvc
        this.proxySvc = proxySvc
        this.planSvc = planSvc
        this.executor = executor
        this.adminData = adminData
        this.pkgStore = pkgStore
        this.blobStore = blobStore
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
                    writeAudit(this.adminData, LogKind.Auth, 0, lr.username, "login", "failed", lr.username, ctx,
                        error: "username and password required")
                    writeJson(ctx, 400u16, "{\"error\":\"username and password required\"}")
                    return
                }
                match (this.auth.login(lr.username, lr.password)) {
                    case Some((user, token)) =>
                        writeAudit(this.adminData, LogKind.Auth, user.id, user.username, "login", "ok", user.username, ctx,
                            detail: "isAdmin=${user.isAdmin}")
                        writeJson(ctx, 200u16,
                            "{\"id\":${user.id},\"username\":\"${user.username}\"," +
                            "\"isAdmin\":${user.isAdmin},\"token\":\"${token.token}\"," +
                            "\"expiresAt\":${token.expiresAt}}")
                    case None =>
                        writeAudit(this.adminData, LogKind.Auth, 0, lr.username, "login", "failed", lr.username, ctx,
                            error: "invalid username or password")
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
        let actor = this.currentUser(ctx)
        let token = this.extractToken(ctx)
        if (token.isSome()) {
            this.auth.logout(token.getOrThrow())
        }
        match (actor) {
            case Some(u) =>
                writeAudit(this.adminData, LogKind.Auth, u.id, u.username, "logout", "ok", u.username, ctx)
            case None => ()
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
                let (actorId, actorName) = this.actorOf(ctx)
                match (this.auth.createUser(r.username, r.password, r.isAdmin, email: r.email)) {
                    case Some(u) =>
                        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "create_user", "ok", u.username, ctx,
                            detail: "isAdmin=${u.isAdmin} email=${r.email}")
                        writeJson(ctx, 200u16,
                            "{\"id\":${u.id},\"username\":\"${u.username}\",\"isAdmin\":${u.isAdmin}}")
                    case None =>
                        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "create_user", "failed", r.username, ctx,
                            error: "user already exists")
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
        let (actorId, actorName) = this.actorOf(ctx)
        let action = if (target) { "grant_admin" } else { "revoke_admin" }
        if (!this.auth.setUserAdmin(uid, target)) {
            let name = match (this.userStore.getUser(uid)) {
                case Some(x) => x.username
                case None => "#${uid}"
            }
            writeAudit(this.adminData, LogKind.Admin, actorId, actorName, action, "failed", name, ctx,
                error: "cannot revoke the last active admin")
            writeJson(ctx, 409u16, "{\"error\":\"cannot revoke the last active admin\"}")
            return
        }
        let u = this.userStore.getUser(uid).getOrThrow()
        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, action, "ok", u.username, ctx,
            detail: "isAdmin=${u.isAdmin}")
        writeJson(ctx, 200u16,
            "{\"id\":${u.id},\"username\":\"${u.username}\",\"isAdmin\":${u.isAdmin}}")
    }

    // 当前操作者（requireAdmin 通过后必然存在；解析失败按匿名记）
    func actorOf(ctx: TangHttpContext): (Int64, String) {
        match (this.currentUser(ctx)) {
            case Some(u) => (u.id, u.username)
            case None => (0, "")
        }
    }

    // ===== 审计日志查询/清理 =====
    // GET /api/admin/logs/:kind?keyword=&status=&from=&to=&offset=&limit=
    // kind: publish|admin|auth|all（未知值按 all）；from/to 为毫秒时间戳（0 = 不限）
    public func queryLogs(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let kind = parseAuditKind(ctx.param("kind"))
        let keyword = ctx.query("keyword") ?? ""
        let status = ctx.query("status") ?? ""
        let from = parseI64(ctx.query("from"))
        let to = parseI64(ctx.query("to"))
        var offset = parseI64(ctx.query("offset"))
        if (offset < 0) {
            offset = 0
        }
        var limit = parseI64(ctx.query("limit"))
        if (limit <= 0) {
            limit = 50
        }
        if (limit > 500) {
            limit = 500
        }
        let (rows, total) = match (this.adminData) {
            case Some(ad) => ad.queryLogs(kind, keyword, status, from, to, offset, limit)
            case None => (ArrayList<LogDoc>(), 0)
        }
        let sb = StringBuilder()
        sb.append("{\"total\":${total},\"offset\":${offset},\"limit\":${limit},\"items\":[")
        for (i in 0..rows.size) {
            if (i > 0) {
                sb.append(",")
            }
            let d = rows[i]
            sb.append("{\"id\":${d.id},\"kind\":\"${d.kind}\",\"actorId\":${d.actorId}," +
                "\"actorName\":\"${escapeJsonStr(d.actorName)}\",\"action\":\"${escapeJsonStr(d.action)}\"," +
                "\"status\":\"${escapeJsonStr(d.status)}\",\"target\":\"${escapeJsonStr(d.target)}\"," +
                "\"detail\":\"${escapeJsonStr(d.detail)}\",\"error\":\"${escapeJsonStr(d.error)}\"," +
                "\"ipAddr\":\"${escapeJsonStr(d.ipAddr)}\",\"userAgent\":\"${escapeJsonStr(d.userAgent)}\"," +
                "\"createdAt\":${d.createdAt}}")
        }
        sb.append("]}")
        writeJson(ctx, 200u16, sb.toString())
    }

    // POST /api/admin/logs/clean  body {kind?: publish|admin|auth|all, before?: 毫秒}
    // 无 body 时清空全部；返回 {"deleted":N}
    public func cleanLogs(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let body = String.fromUtf8(ctx.bodyRaw())
        var kindRaw = ""
        var before: Int64 = 0
        if (!body.trimAscii().isEmpty()) {
            let bb = ByteBuffer()
            bb.write(body.toArray())
            let r = JsonReader(bb)
            try {
                r.startObject()
                while (r.peek() != EndObject) {
                    let n = r.readName()
                    match (n) {
                        case "kind" => kindRaw = r.readValue<String>()
                        case "before" => before = r.readValue<Int64>()
                        case _ => r.skip()
                    }
                }
                r.endObject()
            } catch (e: Exception) {
                writeJson(ctx, 400u16, "{\"error\":\"invalid JSON body\"}")
                return
            }
        }
        let kind = parseAuditKind(kindRaw)
        let (actorId, actorName) = this.actorOf(ctx)
        let deleted = match (this.adminData) {
            case Some(ad) => ad.removeLogs(kind, before)
            case None => 0
        }
        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "clean_logs", "ok",
            if (kindRaw.isEmpty()) { "all" } else { kindRaw }, ctx,
            detail: "deleted=${deleted} before=${before}")
        writeJson(ctx, 200u16, "{\"deleted\":${deleted}}")
    }

    // 查询参数转 Int64（缺失/非法 → 0）
    func parseI64(v: ?String): Int64 {
        match (v) {
            case Some(s) => match (Int64.tryParse(s.trimAscii())) {
                case Some(n) => n
                case None => 0
            }
            case None => 0
        }
    }

    // GET /api/admin/packages?organization=&name=&includeDeleted=1&page=&size=
    // 版本列表（管理端自动化用：拿到 id 才能调三级删除端点）
    public func listPackages(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let store = match (this.pkgStore) {
            case Some(s) => s
            case None =>
                writeJson(ctx, 500u16, "{\"error\":\"package store unavailable\"}")
                return
        }
        let org = ctx.query("organization") ?? ""
        let name = ctx.query("name") ?? ""
        let includeDeleted = (ctx.query("includeDeleted") ?? "") == "1"
        let hits = ArrayList<PackageDoc>()
        for (d in store.storm.all<PackageDoc>()) {
            if (!org.isEmpty() && d.organization != org) {
                continue
            }
            if (!name.isEmpty() && d.name != name) {
                continue
            }
            if (!includeDeleted && d.deletedAt != 0) {
                continue
            }
            hits.add(d)
        }
        sort(hits, by: adminPkgAsc)
        let page = parseI64(ctx.query("page"))
        let size = parseI64(ctx.query("size"))
        let (start, end) = pageWindow(hits.size, if (page <= 0) { 1 } else { page },
            if (size <= 0) { 50 } else { size })
        let sb = StringBuilder()
        sb.append("{\"total\":${hits.size},\"items\":[")
        var i = start
        while (i < end) {
            if (i > start) {
                sb.append(",")
            }
            let d = hits[i]
            sb.append("{\"id\":${d.id},\"organization\":\"${escapeJsonStr(d.organization)}\",")
            sb.append("\"name\":\"${escapeJsonStr(d.name)}\",\"version\":\"${escapeJsonStr(d.version)}\",")
            sb.append("\"deletedAt\":${d.deletedAt},\"sha256\":\"${escapeJsonStr(d.sha256)}\",")
            sb.append("\"tarballSize\":${d.tarballSize},\"downloads\":${d.downloadCount},")
            sb.append("\"publisherId\":${d.publisherId},\"upstreamId\":${d.upstreamId},")
            sb.append("\"createdAt\":${d.createdAt},\"updatedAt\":${d.updatedAt}}")
            i++
        }
        sb.append("]}")
        writeJson(ctx, 200u16, sb.toString())
    }

    // ===== 包三级删除闭环 =====
    // DELETE /api/admin/packages/:id → 软删除（deletedAt；索引/下载/公开 API 立即不可见）
    public func deletePackage(ctx: TangHttpContext): Unit {
        this.lifecycleEntry(ctx, "soft")
    }

    // DELETE /api/admin/packages/:id/hard → 硬删除（需先软删；删记录 + 制品）
    public func hardDeletePackage(ctx: TangHttpContext): Unit {
        this.lifecycleEntry(ctx, "hard")
    }

    // PUT /api/admin/packages/:id/restore → 恢复（校验制品仍在）
    public func restorePackage(ctx: TangHttpContext): Unit {
        this.lifecycleEntry(ctx, "restore")
    }

    // 三种操作的公共入口：解析 id → 取版本 → 调用生命周期 → 审计 + JSON
    func lifecycleEntry(ctx: TangHttpContext, mode: String): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let id = match (Int64.tryParse(ctx.param("id"))) {
            case Some(n) => n
            case None => 0
        }
        if (id <= 0) {
            writeJson(ctx, 400u16, "{\"error\":\"invalid package id\"}")
            return
        }
        let store = match (this.pkgStore) {
            case Some(s) => s
            case None =>
                writeJson(ctx, 500u16, "{\"error\":\"package store unavailable\"}")
                return
        }
        let doc = match (store.getById(id)) {
            case Some(d) => d
            case None =>
                writeJson(ctx, 404u16, "{\"error\":\"package version not found\"}")
                return
        }
        let blobs: BlobStore = match (this.blobStore) {
            case Some(b) => b
            case None => MemoryBlobStore()
        }
        let now = auditNowMs()
        var action = "delete_package"
        var result: LifecycleResult
        match (mode) {
            case "hard" =>
                action = "hard_delete_package"
                result = hardDeleteVersion(store, blobs, this.adminData, doc, now)
            case "restore" =>
                action = "restore_package"
                result = restoreVersion(store, blobs, doc)
            case _ =>
                result = softDeleteVersion(store, this.adminData, doc, now)
        }
        let target = auditTarget(doc.organization, doc.name, doc.version)
        let status = match (result.outcome) {
            case LifecycleOutcome.Ok => "ok"
            case LifecycleOutcome.AlreadyDeleted => "ok"      // 幂等：语义上已是目标状态
            case _ => "failed"
        }
        let (actorId, actorName) = this.actorOf(ctx)
        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, action, status, target, ctx,
            error: if (status == "ok") { "" } else { result.message },
            detail: "skippedPlanItems=${result.skippedPlanItems} blobRemoved=${result.blobRemoved} " +
                "artifactPresent=${result.artifactPresent} id=${id}")
        // 结果码：NotDeleted/ArtifactMissing → 409（语义冲突，非参数错误）
        var code = 200u16
        match (result.outcome) {
            case LifecycleOutcome.NotFound => code = 404u16
            case LifecycleOutcome.NotDeleted => code = 409u16
            case LifecycleOutcome.ArtifactMissing => code = 409u16
            case LifecycleOutcome.Failed => code = 500u16
            case _ => code = 200u16
        }
        writeJson(ctx, code, lifecycleJson(result))
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
        let (upActorId, upActorName) = this.actorOf(ctx)
        match (this.upstreamSvc.add(name, url, priority, "", 0)) {
            case Some(u) =>
                writeAudit(this.adminData, LogKind.Admin, upActorId, upActorName, "add_upstream", "ok", name, ctx,
                    detail: "url=${url} priority=${priority}")
                writeJson(ctx, 200u16, "{\"id\":${u.id},\"name\":\"${u.name}\",\"isOfficial\":${u.isOfficial}}")
            case None =>
                writeAudit(this.adminData, LogKind.Admin, upActorId, upActorName, "add_upstream", "failed", name, ctx,
                    error: "upstream name exists or invalid")
                writeJson(ctx, 409u16, "{\"error\":\"upstream name exists or invalid\"}")
        }
    }

    public func deleteUpstream(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let idStr = ctx.param("id")
        let id = Int64.parse(idStr)
        let (delActorId, delActorName) = this.actorOf(ctx)
        // 目标名尽量取真实上游名（删除后查不到，故先查）
        var upName = "#${id}"
        for (u in this.upstreamStore.listAll()) {
            if (u.id == id) {
                upName = u.name
            }
        }
        if (this.upstreamSvc.remove(id)) {
            writeAudit(this.adminData, LogKind.Admin, delActorId, delActorName, "delete_upstream", "ok", upName, ctx)
            writeJson(ctx, 200u16, "{\"status\":\"ok\"}")
        } else {
            writeAudit(this.adminData, LogKind.Admin, delActorId, delActorName, "delete_upstream", "failed", upName, ctx,
                error: "not found or official protected")
            writeJson(ctx, 409u16, "{\"error\":\"cannot delete (not found or official protected)\"}")
        }
    }

    // POST /api/admin/upstreams/:id/test?name=&organization=
    // 连通性测试：指定 name（≥3 字符）测索引端点，否则测基地址；结果含状态码/耗时/正文大小/包名样本
    public func testUpstream(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let id = match (Int64.tryParse(ctx.param("id"))) {
            case Some(n) => n
            case None => 0
        }
        let up = match (this.upstreamStore.getById(id)) {
            case Some(u) => u
            case None =>
                writeJson(ctx, 404u16, "{\"error\":\"upstream not found\"}")
                return
        }
        let name = ctx.query("name") ?? ""
        let org = ctx.query("organization") ?? ""
        let result = probeUpstream(up, name, org)
        let (actorId, actorName) = this.actorOf(ctx)
        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "test_upstream",
            if (result.reachable) { "ok" } else { "failed" }, up.name, ctx,
            error: result.error,
            detail: "status=${result.status} latency=${result.latencyMs}ms healthy=${result.healthy} url=${result.testedUrl}")
        writeJson(ctx, 200u16, upstreamProbeJson(result))
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
        let (planActorId, planActorName) = this.actorOf(ctx)
        if (roots.size == 0 || targetUrl.isEmpty()) {
            writeAudit(this.adminData, LogKind.Admin, planActorId, planActorName, "execute_publish_plan", "failed",
                targetUrl, ctx, error: "packages and target_url required")
            writeJson(ctx, 400u16, "{\"error\":\"packages and target_url required\"}")
            return
        }
        // 目标仓鉴权：显式 target_token 优先，否则按 URL 匹配上游表取该上游 authToken
        // （token 属敏感信息，审计只记「是否使用显式 token」，不落明文）
        let token = resolveTargetToken(targetToken, targetUrl, this.upstreamStore.listAll())
        // 先 analyze 得拓扑 items
        let (items, _) = this.planSvc.analyze(roots)
        if (items.size == 0) {
            writeAudit(this.adminData, LogKind.Admin, planActorId, planActorName, "execute_publish_plan", "failed",
                targetUrl, ctx, error: "no packages found locally")
            writeJson(ctx, 400u16, "{\"error\":\"no packages found locally\"}")
            return
        }
        let (ok, total, errors) = this.executor.execute(items, targetUrl, token)
        writeAudit(this.adminData, LogKind.Admin, planActorId, planActorName, "execute_publish_plan",
            if (ok == total && total > 0) { "ok" } else { "failed" }, targetUrl, ctx,
            error: if (errors.size > 0) { errors[0] } else { "" },
            detail: "success=${ok}/${total} roots=${roots.size} explicitToken=${!targetToken.isEmpty()}")
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

// 管理端包列表排序：组织 → 包名 → 版本（升序）
func adminPkgAsc(a: PackageDoc, b: PackageDoc): Ordering {
    if (a.organization != b.organization) {
        return if (a.organization < b.organization) { Ordering.LT } else { Ordering.GT }
    }
    if (a.name != b.name) {
        return if (a.name < b.name) { Ordering.LT } else { Ordering.GT }
    }
    if (a.version == b.version) {
        return Ordering.EQ
    }
    return if (a.version < b.version) { Ordering.LT } else { Ordering.GT }
}
