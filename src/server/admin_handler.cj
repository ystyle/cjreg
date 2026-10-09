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
                    writeDto(ctx, 400u16, ErrorResp("username and password required"))
                    return
                }
                match (this.auth.login(lr.username, lr.password)) {
                    case Some((user, token)) =>
                        writeAudit(this.adminData, LogKind.Auth, user.id, user.username, "login", "ok", user.username, ctx,
                            detail: "isAdmin=${user.isAdmin}")
                        writeDto(ctx, 200u16, LoginResp(user.id, user.username, user.isAdmin,
                            token.token, token.expiresAt))
                    case None =>
                        writeAudit(this.adminData, LogKind.Auth, 0, lr.username, "login", "failed", lr.username, ctx,
                            error: "invalid username or password")
                        writeDto(ctx, 401u16, ErrorResp("invalid username or password"))
                }
            case None =>
                writeDto(ctx, 400u16, ErrorResp("invalid JSON body"))
        }
    }

    public func me(ctx: TangHttpContext): Unit {
        match (this.currentUser(ctx)) {
            case Some(user) =>
                writeDto(ctx, 200u16, AdminMeResp(user.id, user.username, user.isAdmin,
                    user.isActive, user.publishToken))
            case None =>
                writeDto(ctx, 401u16, ErrorResp("not authenticated"))
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
        writeDto(ctx, 200u16, OkResp())
    }

    public func listUsers(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let users = this.userStore.listAllUsers()
        let rows = ArrayList<UserRowResp>()
        for (u in users) {
            rows.add(UserRowResp(u.id, u.username, u.isAdmin, u.isActive))
        }
        // 契约是**裸数组**（不是 {total,items} 包装）：外部脚本按 Array 解析
        writeDto(ctx, 200u16, rows)
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
                    writeDto(ctx, 400u16, ErrorResp("username and password required"))
                    return
                }
                let (actorId, actorName) = this.actorOf(ctx)
                match (this.auth.createUser(r.username, r.password, r.isAdmin, email: r.email)) {
                    case Some(u) =>
                        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "create_user", "ok", u.username, ctx,
                            detail: "isAdmin=${u.isAdmin} email=${r.email}")
                        writeDto(ctx, 200u16, UserAdminResp(u.id, u.username, u.isAdmin))
                    case None =>
                        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "create_user", "failed", r.username, ctx,
                            error: "user already exists")
                        writeDto(ctx, 409u16, ErrorResp("user already exists"))
                }
            case None =>
                writeDto(ctx, 400u16, ErrorResp("invalid JSON body"))
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
            writeDto(ctx, 400u16, ErrorResp("invalid user id"))
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
            writeDto(ctx, 400u16, ErrorResp("isAdmin (bool) required in JSON body"))
            return
        }
        match (this.userStore.getUser(uid)) {
            case None =>
                writeDto(ctx, 404u16, ErrorResp("user not found"))
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
            writeDto(ctx, 409u16, ErrorResp("cannot revoke the last active admin"))
            return
        }
        let u = this.userStore.getUser(uid).getOrThrow()
        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, action, "ok", u.username, ctx,
            detail: "isAdmin=${u.isAdmin}")
        writeDto(ctx, 200u16, UserAdminResp(u.id, u.username, u.isAdmin))
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
        let items = ArrayList<LogRowDto>()
        for (d in rows) {
            items.add(LogRowDto(d.id, d.kind, d.actorId, d.actorName, d.action, d.status, d.target,
                d.detail, d.error, d.ipAddr, d.userAgent, d.createdAt))
        }
        writeDto(ctx, 200u16, LogQueryResp(total, offset, limit, items))
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
                writeDto(ctx, 400u16, ErrorResp("invalid JSON body"))
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
        writeDto(ctx, 200u16, DeletedResp(deleted))
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
                writeDto(ctx, 500u16, ErrorResp("package store unavailable"))
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
        let items = ArrayList<AdminPackageDto>()
        var i = start
        while (i < end) {
            let d = hits[i]
            items.add(AdminPackageDto(d.id, d.organization, d.name, d.version, d.deletedAt, d.sha256,
                d.tarballSize, d.downloadCount, d.publisherId, d.upstreamId, d.createdAt, d.updatedAt))
            i++
        }
        writeDto(ctx, 200u16, AdminPackageListResp(hits.size, items))
    }

    // ===== 组织 CRUD（REST）=====
    // 组织端点需要的两个 store：缺失时写 500 并返回 None
    func orgStores(ctx: TangHttpContext): ?(AdminDataStore, PackageStore) {
        let ad = match (this.adminData) {
            case Some(x) => x
            case None =>
                writeDto(ctx, 500u16, ErrorResp("admin data store unavailable"))
                return None
        }
        let ps = match (this.pkgStore) {
            case Some(x) => x
            case None =>
                writeDto(ctx, 500u16, ErrorResp("package store unavailable"))
                return None
        }
        Some((ad, ps))
    }

    // GET /api/admin/organizations → 列表（含包/版本/团队计数）
    public func listOrganizations(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let (ad, ps) = match (this.orgStores(ctx)) {
            case Some(v) => v
            case None => return
        }
        let items = ArrayList<OrgDto>()
        for (o in ad.listOrgs()) {
            let (pkgs, versions) = orgPackageStats(ps, o.name)
            items.add(orgJson(o, pkgs, versions, orgReferencingTeams(ad, o.id).size))
        }
        writeDto(ctx, 200u16, orgListJson(items, items.size))
    }

    // GET /api/admin/organizations/:id → 详情
    public func getOrganization(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let (ad, ps) = match (this.orgStores(ctx)) {
            case Some(v) => v
            case None => return
        }
        let id = match (Int64.tryParse(ctx.param("id"))) {
            case Some(n) => n
            case None => 0
        }
        let org = match (ad.getOrg(id)) {
            case Some(o) => if (o.deletedAt == 0) { o } else {
                writeDto(ctx, 404u16, ErrorResp("organization not found"))
                return
            }
            case None =>
                writeDto(ctx, 404u16, ErrorResp("organization not found"))
                return
        }
        let (pkgs, versions) = orgPackageStats(ps, org.name)
        writeDto(ctx, 200u16, orgJson(org, pkgs, versions, orgReferencingTeams(ad, org.id).size))
    }

    // POST /api/admin/organizations  body {name, displayName?, description?, isDefault?}
    public func createOrganization(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let (ad, _) = match (this.orgStores(ctx)) {
            case Some(v) => v
            case None => return
        }
        let body = match (parseJsonBody<OrgUpsertRequest>(ctx.bodyRaw(), { r => OrgUpsertRequest.fromJson(r) })) {
            case Some(b) => b
            case None =>
                writeDto(ctx, 400u16, ErrorResp("invalid JSON body"))
                return
        }
        let (actorId, _) = this.actorOf(ctx)
        let r = createOrgChecked(ad, body.name.trimAscii(), body.displayName, body.description,
            body.isDefault, actorId, auditNowMs())
        this.auditOrg(ctx, "create_org", body.name.trimAscii(), r)
        writeDto(ctx, orgResultCode(r), orgResultJson(r))
    }

    // PUT /api/admin/organizations/:id  body {name?, displayName?, description?, isDefault?}
    // 未传的字段保持原值；name 非空且与原值不同时视为改名（有包则 409）
    public func updateOrganization(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let (ad, ps) = match (this.orgStores(ctx)) {
            case Some(v) => v
            case None => return
        }
        let id = match (Int64.tryParse(ctx.param("id"))) {
            case Some(n) => n
            case None => 0
        }
        let body = match (parseJsonBody<OrgUpsertRequest>(ctx.bodyRaw(), { r => OrgUpsertRequest.fromJson(r) })) {
            case Some(b) => b
            case None =>
                writeDto(ctx, 400u16, ErrorResp("invalid JSON body"))
                return
        }
        let cur = match (ad.getOrg(id)) {
            case Some(o) => o
            case None =>
                writeDto(ctx, 404u16, ErrorResp("organization not found"))
                return
        }
        let displayName = if (body.hasDisplayName) { body.displayName } else { cur.displayName }
        let description = if (body.hasDescription) { body.description } else { cur.description }
        let isDefault = if (body.hasIsDefault) { body.isDefault } else { cur.isDefault }
        let wantedName = body.name.trimAscii()
        let r = updateOrgChecked(ps, ad, id, wantedName, displayName, description, isDefault, auditNowMs())
        let target = if (wantedName.isEmpty() || wantedName == cur.name) { cur.name } else { "${cur.name}→${wantedName}" }
        this.auditOrg(ctx, "update_org", target, r)
        writeDto(ctx, orgResultCode(r), orgResultJson(r))
    }

    // DELETE /api/admin/organizations/:id → 软删（有包或仍被团队关联时 409）
    public func deleteOrganization(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let (ad, ps) = match (this.orgStores(ctx)) {
            case Some(v) => v
            case None => return
        }
        let id = match (Int64.tryParse(ctx.param("id"))) {
            case Some(n) => n
            case None => 0
        }
        let name = match (ad.getOrg(id)) {
            case Some(o) => o.name
            case None => "#${id}"
        }
        let r = deleteOrgChecked(ps, ad, id, auditNowMs())
        this.auditOrg(ctx, "delete_org", name, r)
        writeDto(ctx, orgResultCode(r), orgResultJson(r))
    }

    // 组织操作审计（与 UI 侧 uiAudit 的动作名保持一致）
    func auditOrg(ctx: TangHttpContext, action: String, target: String, r: OrgResult): Unit {
        let (actorId, actorName) = this.actorOf(ctx)
        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, action,
            if (r.outcome == OrgOutcome.Ok) { "ok" } else { "failed" }, target, ctx,
            error: if (r.outcome == OrgOutcome.Ok) { "" } else { r.message },
            detail: "id=${r.orgId} affected=${r.affected}")
    }

    // ===== 单版本详情 + 上游重拉 =====

    // GET /api/admin/packages/:id → 单版本详情（含 README 全文、来源上游、sha/大小/时间/发布者）
    public func getPackageVersion(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let store = match (this.pkgStore) {
            case Some(s) => s
            case None =>
                writeDto(ctx, 500u16, ErrorResp("package store unavailable"))
                return
        }
        let id = match (Int64.tryParse(ctx.param("id"))) {
            case Some(n) => n
            case None => 0
        }
        let doc = match (store.getById(id)) {
            case Some(d) => d
            case None =>
                writeDto(ctx, 404u16, ErrorResp("package version not found"))
                return
        }
        writeDto(ctx, 200u16, this.versionDetailJson(store, doc))
    }

    // POST /api/admin/packages/:id/refetch[?force=1] → 按上游内容重拉并覆盖本地缓存
    // 仅对回源镜像版本开放（upstreamId != 0）；上游 sha 变了需 force=1 二次确认
    public func refetchPackageVersion(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let id = match (Int64.tryParse(ctx.param("id"))) {
            case Some(n) => n
            case None => 0
        }
        if (id <= 0) {
            writeDto(ctx, 400u16, ErrorResp("invalid package id"))
            return
        }
        let store = match (this.pkgStore) {
            case Some(s) => s
            case None =>
                writeDto(ctx, 500u16, ErrorResp("package store unavailable"))
                return
        }
        let proxy = match (this.proxySvc) {
            case Some(p) => p
            case None =>
                writeDto(ctx, 503u16, ErrorResp("proxy service unavailable（未配置上游回源）"))
                return
        }
        let doc = match (store.getById(id)) {
            case Some(d) => d
            case None =>
                writeDto(ctx, 404u16, ErrorResp("package version not found"))
                return
        }
        let force = (ctx.query("force") ?? "") == "1"
        let r = refetchVersion(proxy, doc, force)
        let target = auditTarget(doc.organization, doc.name, doc.version)
        let (actorId, actorName) = this.actorOf(ctx)
        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "refetch_package",
            if (r.outcome == RefetchOutcome.Ok) { "ok" } else { "failed" }, target, ctx,
            error: if (r.outcome == RefetchOutcome.Ok) { "" } else { r.message },
            detail: "upstream=${r.upstreamName} old=${shortSha(r.oldSha)} new=${shortSha(r.newSha)} " +
                "changed=${r.changed} size=${r.size} force=${force} id=${id}")
        var code = 200u16
        match (r.outcome) {
            case RefetchOutcome.NotFound => code = 404u16
            case RefetchOutcome.LocalOwned => code = 409u16
            case RefetchOutcome.ShaChanged => code = 409u16
            case RefetchOutcome.Invalid => code = 409u16
            case RefetchOutcome.UpstreamMissing => code = 404u16
            case RefetchOutcome.Unavailable => code = 503u16
            case RefetchOutcome.Unreachable => code = 502u16
            case _ => code = 200u16
        }
        writeDto(ctx, code, refetchJson(r))
    }

    // 单版本详情（管理端用，含 README 全文；不走公开接口的脱敏口径）
    func versionDetailJson(store: PackageStore, doc: PackageDoc): PackageVersionDetailDto {
        let publisher = if (doc.publisherId > 0) {
            match (this.userStore.getUser(doc.publisherId)) {
                case Some(u) => u.username
                case None => ""
            }
        } else {
            ""
        }
        let upstream = if (doc.upstreamId > 0) {
            match (this.upstreamStore.getById(doc.upstreamId)) {
                case Some(u) => u.name
                case None => doc.upstreamName
            }
        } else {
            ""
        }
        let blobs: BlobStore = match (this.blobStore) {
            case Some(b) => b
            case None => MemoryBlobStore()
        }
        PackageVersionDetailDto(doc.id, doc.organization, doc.name, doc.version, doc.cjcVersion,
            doc.description, doc.artifactType, doc.executable, doc.authors, doc.repository, doc.homepage,
            doc.documentation, doc.tag, doc.category, doc.license, doc.sha256, doc.tarballSize,
            doc.downloadCount, doc.publisherId, publisher, doc.upstreamId, upstream, doc.deletedAt,
            doc.createdAt, doc.updatedAt, doc.readme, doc.readme.size, artifactAvailable(store, blobs, doc))
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
            writeDto(ctx, 400u16, ErrorResp("invalid package id"))
            return
        }
        let store = match (this.pkgStore) {
            case Some(s) => s
            case None =>
                writeDto(ctx, 500u16, ErrorResp("package store unavailable"))
                return
        }
        let doc = match (store.getById(id)) {
            case Some(d) => d
            case None =>
                writeDto(ctx, 404u16, ErrorResp("package version not found"))
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
        writeDto(ctx, code, lifecycleJson(result))
    }

    // ===== 上游管理 =====
    public func listUpstreams(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let list = this.upstreamStore.listAll()
        let rows = ArrayList<UpstreamDto>()
        for (u in list) {
            rows.add(UpstreamDto(u.id, u.name, u.url, u.enabled, u.isOfficial, u.priority, u.cacheTtl,
                u.proxyEnabled, u.asTarget))
        }
        // 契约是**裸数组**（不是 {total,items} 包装）：外部脚本按 Array 解析
        writeDto(ctx, 200u16, rows)
    }

    public func addUpstream(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let body = String.fromUtf8(ctx.bodyRaw())
        var name = ""
        var url = ""
        var priorityStr = ""
        // 两个正交开关的缺省：参与回源、**不**允许作为发布计划目标
        // （推送不可逆，目标仓要显式授权；与 UpstreamService.add 的默认值一致）
        var proxyEnabled = true
        var asTarget = false
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
                                case "proxy_enabled" => proxyEnabled = r.readValue<Bool>()
                                case "as_target" => asTarget = r.readValue<Bool>()
                                case _ => r.skip()
                            }
                        }
                        r.endObject()
                        break
                    case _ => r.skip()
                }
            }
        } catch (e: Exception) {
            // 请求体不是合法 JSON：下面只会回 400「name and url required」，
            // 那会把「JSON 语法错」说成「字段没填」——留痕以免误诊（响应不变）
            eprintln("[cjreg] 新增上游请求体解析失败（按字段缺失处理）: " + e.toString())
        }
        let priority = parsePriority(priorityStr)
        if (name.isEmpty() || url.isEmpty()) {
            writeDto(ctx, 400u16, ErrorResp("name and url required"))
            return
        }
        let (upActorId, upActorName) = this.actorOf(ctx)
        match (this.upstreamSvc.add(name, url, priority, "", 0, proxyEnabled: proxyEnabled, asTarget: asTarget)) {
            case Some(u) =>
                writeAudit(this.adminData, LogKind.Admin, upActorId, upActorName, "add_upstream", "ok", name, ctx,
                    detail: "url=${url} priority=${priority} proxyEnabled=${proxyEnabled} asTarget=${asTarget}")
                writeDto(ctx, 200u16, UpstreamAddedResp(u.id, u.name, u.isOfficial, u.proxyEnabled,
                    u.asTarget))
            case None =>
                writeAudit(this.adminData, LogKind.Admin, upActorId, upActorName, "add_upstream", "failed", name, ctx,
                    error: "upstream name exists or invalid")
                writeDto(ctx, 409u16, ErrorResp("upstream name exists or invalid"))
        }
    }

    // PUT /api/admin/upstreams/:id —— 局部更新：body 里出现哪个字段就改哪个
    // 支持 enabled / proxyEnabled / asTarget / priority / cacheTtl / authToken
    // （启用开关与两个正交能力开关都走这里，脚本/CI 可自动配置）
    public func updateUpstream(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let id = match (Int64.tryParse(ctx.param("id").trimAscii())) {
            case Some(n) => n
            case None =>
                writeDto(ctx, 400u16, ErrorResp("invalid upstream id (expect numeric id)"))
                return
        }
        let body = String.fromUtf8(ctx.bodyRaw())
        var enabled: ?Bool = None
        var proxyEnabled: ?Bool = None
        var asTarget: ?Bool = None
        var priority: ?Int64 = None
        var cacheTtl: ?Int64 = None
        var authToken: ?String = None
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
                                case "enabled" => enabled = Some(r.readValue<Bool>())
                                case "proxyEnabled" => proxyEnabled = Some(r.readValue<Bool>())
                                case "asTarget" => asTarget = Some(r.readValue<Bool>())
                                case "priority" => priority = Some(r.readValue<Int64>())
                                case "cacheTtl" => cacheTtl = Some(r.readValue<Int64>())
                                case "authToken" => authToken = Some(r.readValue<String>())
                                case _ => r.skip()
                            }
                        }
                        r.endObject()
                        break
                    case _ => r.skip()
                }
            }
        } catch (e: Exception) {
            eprintln("[cjreg] 更新上游请求体解析失败: " + e.toString())
            writeDto(ctx, 400u16, ErrorResp("invalid json body"))
            return
        }
        let (actorId, actorName) = this.actorOf(ctx)
        if (this.upstreamSvc.update(id, enabled, priority, cacheTtl, authToken, proxyEnabled: proxyEnabled, asTarget: asTarget)) {
            writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "update_upstream", "ok", "#${id}", ctx,
                detail: "enabled=${enabled.isSome()} proxyEnabled=${proxyEnabled.isSome()} asTarget=${asTarget.isSome()}")
            writeDto(ctx, 200u16, OkResp())
        } else {
            writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "update_upstream", "failed", "#${id}", ctx,
                error: "not found")
            writeDto(ctx, 404u16, ErrorResp("upstream not found"))
        }
    }

    public func deleteUpstream(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        // 路径参数可能是任意串（例如误传上游名）：解析失败要回 400，
        // 不能让 Int64.parse 的异常冒到框架层变成 500
        let id = match (Int64.tryParse(ctx.param("id").trimAscii())) {
            case Some(n) => n
            case None =>
                writeDto(ctx, 400u16, ErrorResp("invalid upstream id (expect numeric id)"))
                return
        }
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
            writeDto(ctx, 200u16, OkResp())
        } else {
            writeAudit(this.adminData, LogKind.Admin, delActorId, delActorName, "delete_upstream", "failed", upName, ctx,
                error: "not found or official protected")
            writeDto(ctx, 409u16, ErrorResp("cannot delete (not found or official protected)"))
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
                writeDto(ctx, 404u16, ErrorResp("upstream not found"))
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
        writeDto(ctx, 200u16, upstreamProbeJson(result))
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
            writeDto(ctx, 400u16, ErrorResp("name required"))
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
        // selected 未命中时输出 null（不是省略字段）：消费方靠它区分「没有候选」与「字段缺失」
        let selected = match (r.selected) {
            case Some(c) => Some(resolveCandidateDto(c))
            case None => Option<ResolveCandidateDto>.None
        }
        let candidates = ArrayList<ResolveCandidateDto>()
        for (c in r.candidates) {
            candidates.add(resolveCandidateDto(c))
        }
        writeDto(ctx, 200u16, ResolveResp(r.name, r.org, r.require, r.found, r.replaced, r.replacedBy,
            selected, candidates, r.trace))
    }

    // ===== 发布计划 analyze =====
    // body: {packages:[{organization,name,version}], target_upstream?}
    // 给了 target_upstream 就按目标仓索引分类（need_publish/already_exists/conflict/version_optional）
// ── 发布计划进度（SSE 事件负载）─────────────────────────────────────────────
// 事件序列：`event: progress`（一次状态快照）；计划进入终态时再补 `event: done`。
//
// 为什么是「一次连接推一份快照」而不是长连接挂起：tang 跑在单线程事件循环上，
// 在 handler 里阻塞等待状态变化（sleep 心跳之类）会把整个服务卡住。EventSource 在
// 连接结束后会自动重连，因此「快照 + 自动重连」等价于由客户端驱动的高频轮询：
// 服务端零阻塞、不需要订阅表。管理页现有的定时轮询作为兜底保留，读的是同一份存储状态。

    public func analyzePlan(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let body = String.fromUtf8(ctx.bodyRaw())
        var roots = ArrayList<(String, String, String)>()
        parsePackagesBody(body, roots)
        if (roots.size == 0) {
            writeDto(ctx, 400u16, ErrorResp("packages required"))
            return
        }
        let targetId = parseTargetUpstream(body)
        let analysis = this.analyzeWithTarget(roots, targetId)
        let order = ArrayList<PlanItemAnalysisDto>()
        for (it in analysis.items) {
            // 目标仓对照：`target_version` 是目标仓该包最新版本；没做成对照时它为空，
            // 消费方必须连 `target_compared` 一起看才能区分「目标仓没有这个包」与「没查到」。
            order.add(PlanItemAnalysisDto(it.name, it.org, it.version, it.order, planCategoryName(it.category),
                it.selected, it.localSha256, it.remoteSha256, it.requirement, it.targetVersion, it.targetCompared))
        }
        writeDto(ctx, 200u16, PlanAnalyzeResp(analysis.targetChecked, analysis.targetError, order,
            analysis.hasCycle))
    }

    // 按目标上游做 analyze（targetId <= 0 或上游不存在 = 不做目标仓对比）
    public func analyzeWithTarget(roots: ArrayList<(String, String, String)>, targetId: Int64): PlanAnalysis {
        let target = if (targetId > 0) { this.upstreamStore.getById(targetId) } else { Option<Upstream>.None }
        let proxy = this.proxySvc
        this.planSvc.analyze(roots, targetUpstream: target, fetchIndex: { up, org, name =>
            match (proxy) {
                case Some(p) => p.probeUpstreamIndex(up, org, name)
                case None => IndexProbe(0, "", detail: "本实例未接入回源代理")
            }
        })
    }

    // 发布计划执行：POST /api/admin/publish-plans/execute
    // body: {packages:[{organization,name,version}], target_url, target_token?}
    // target_token 为空时按 target_url 匹配上游表取该上游的 authToken
    // （否则推送到需要认证的目标仓——如官方中心仓或另一个私有仓——会 401）
    // 手动跳过某个发布项：标记后执行器不再推送它（不计失败）。用于「这一项不想推」的场景，
    // 例如目标仓已有等价版本、或该依赖需要人工处理。计划详情页与脚本都可调用。
    public func skipPlanItem(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        var planId: Int64 = -1
        var itemId: Int64 = -1
        try {
            planId = Int64.parse(ctx.param("id"))
            itemId = Int64.parse(ctx.param("itemId"))
        } catch (e: Exception) {
            planId = -1
            itemId = -1
        }
        if (planId < 0 || itemId < 0) {
            writeDto(ctx, 400u16, ErrorResp("invalid plan or item id"))
            return
        }
        let (actorId, actorName) = this.actorOf(ctx)
        match (this.adminData) {
            case None => writeDto(ctx, 503u16, ErrorResp("admin store unavailable"))
            case Some(ad) =>
                let item = ad.getPlanItem(itemId)
                match (item) {
                    case None =>
                        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "skip_plan_item", "failed",
                            "plan=${planId} item=${itemId}", ctx, error: "item not found")
                        writeDto(ctx, 404u16, ErrorResp("plan item not found"))
                    case Some(it) =>
                        // 归属校验：不能拿 A 计划的 id 去改 B 计划的项
                        if (it.planId != planId) {
                            writeDto(ctx, 404u16, ErrorResp("plan item not found in this plan"))
                            return
                        }
                        ad.updatePlanItem(itemId, "skipped", "手动跳过", nowMsUtc())
                        let target = "${it.packageOrg}::${it.packageName}@${it.packageVersion}"
                        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "skip_plan_item", "ok",
                            target, ctx, detail: "plan=${planId} item=${itemId}")
                        writeDto(ctx, 200u16, SkipItemResp(itemId))
                }
        }
    }

    // 发布计划进度流（SSE）。鉴权与其它管理端点一致；响应头走 stdx 的 HttpResponseBuilder。
    public func planEvents(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        var planId: Int64 = -1
        try {
            planId = Int64.parse(ctx.param("id"))
        } catch (e: Exception) {
            planId = -1
        }
        if (planId < 0) {
            writeDto(ctx, 400u16, ErrorResp("invalid plan id"))
            return
        }
        match (this.adminData) {
            case None => writeDto(ctx, 503u16, ErrorResp("admin store unavailable"))
            case Some(ad) =>
                match (ad.getPlan(planId)) {
                    case None => writeDto(ctx, 404u16, ErrorResp("plan not found"))
                    case Some(plan) =>
                        let payload = buildPlanEventsPayload(plan, ad.listPlanItems(planId))
                        ctx.responseBuilder
                            .header("Content-Type", "text/event-stream; charset=utf-8")
                            .header("Cache-Control", "no-cache")
                            .header("X-Accel-Buffering", "no")
                            .status(200u16)
                            .body(payload.toArray())
                }
        }
    }

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
            // 同新增上游：坏 JSON 只会回 400「packages and target_url required」，
            // 会把语法错说成字段缺失——留痕以免误诊（响应不变）
            eprintln("[cjreg] 执行发布计划请求体解析失败（按字段缺失处理）: " + e.toString())
        }
        let (planActorId, planActorName) = this.actorOf(ctx)
        if (roots.size == 0 || targetUrl.isEmpty()) {
            writeAudit(this.adminData, LogKind.Admin, planActorId, planActorName, "execute_publish_plan", "failed",
                targetUrl, ctx, error: "packages and target_url required")
            writeDto(ctx, 400u16, ErrorResp("packages and target_url required"))
            return
        }
        // 目标仓鉴权：显式 target_token 优先，否则按 URL 匹配上游表取该上游 authToken
        // （token 属敏感信息，审计只记「是否使用显式 token」，不落明文）
        let token = resolveTargetToken(targetToken, targetUrl, this.upstreamStore.listAll())
        // 先 analyze 得拓扑 items（legacy 接口不带目标仓，分类不参与执行）
        let analysis = this.planSvc.analyze(roots)
        let items = analysis.items
        if (items.size == 0) {
            writeAudit(this.adminData, LogKind.Admin, planActorId, planActorName, "execute_publish_plan", "failed",
                targetUrl, ctx, error: "no packages found locally")
            writeDto(ctx, 400u16, ErrorResp("no packages found locally"))
            return
        }
        let report = this.executor.execute(items, targetUrl, token)
        // 状态与审计按「是否中止」区分：429/401/403 是**暂停**（可续跑），不是失败
        let outcome = if (report.aborted) {
            "paused"
        } else if (report.failed > 0) {
            "failed"
        } else {
            "ok"
        }
        writeAudit(this.adminData, LogKind.Admin, planActorId, planActorName, "execute_publish_plan",
            outcome, targetUrl, ctx,
            error: if (report.aborted) {
                report.abortReason
            } else if (report.errors.size > 0) {
                report.errors[0]
            } else {
                ""
            },
            detail: "success=${report.success} skipped=${report.skipped} failed=${report.failed} " +
                "total=${report.total} aborted=${report.aborted} roots=${roots.size} " +
                "explicitToken=${!targetToken.isEmpty()}")
        writeDto(ctx, 200u16, PlanExecuteResp(report.success, report.skipped, report.failed, report.total,
            report.aborted, report.abortReason, report.errors))
    }

    func requireAdmin(ctx: TangHttpContext): Bool {
        match (this.currentUser(ctx)) {
            case Some(user) =>
                if (user.isAdmin) {
                    return true
                }
                writeDto(ctx, 403u16, ErrorResp("admin required"))
                return false
            case None =>
                writeDto(ctx, 401u16, ErrorResp("not authenticated"))
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

// 解析候选项 → 响应 DTO（selected 与 candidates 同一形态）
func resolveCandidateDto(c: ResolveCandidate): ResolveCandidateDto {
    ResolveCandidateDto(c.repo, c.version, c.sha256sum, c.conflict)
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

public func buildPlanEventsPayload(plan: PlanDoc, items: ArrayList<PlanItemDoc>): String {
    let rows = ArrayList<PlanProgressItemDto>()
    for (it in items) {
        rows.add(PlanProgressItemDto(it.id, it.packageOrg, it.packageName, it.packageVersion,
            it.status, it.error))
    }
    // 帧结构（event/data/空行）与终态 done 语义不变；data 里的 JSON 由序列化器生成
    let sb = StringBuilder()
    sb.append("event: progress\n")
    sb.append("data: ")
    sb.append(jsonText(PlanProgressDto(plan.id, plan.status, plan.completedCount, plan.totalCount,
        plan.lastError, rows)))
    sb.append("\n\n")
    if (plan.status == "completed" || plan.status == "failed") {
        sb.append("event: done\n")
        sb.append("data: ")
        sb.append(jsonText(PlanDoneDto(plan.id, plan.status)))
        sb.append("\n\n")
    }
    return sb.toString()
}
