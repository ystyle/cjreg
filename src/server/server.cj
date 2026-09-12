// HTTP 服务端（tang）：发布/下载/索引 三端点 + 管理 API 挂载点
// 业务逻辑在 publish_service/index_service/download_service（纯逻辑已单测）
package ystyle::cjreg.server

import tang.*
import ystyle::cjreg.protocol.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*
import ystyle::cjreg.config.*
import std.collection.*
import stdx.encoding.json.stream.*
import std.io.*
import std.env.*

// 组装 HTTP 服务：官方协议三端点 + 健康检查 + 管理 API
public func buildServer(
    store: PackageStore,
    admin: ?AdminService,
    upstreamSvc: ?UpstreamService,
    blobStore: BlobStore
): Tang {
    let app = Tang().setHost("0.0.0.0")
    // 发布认证：管理服务存在时使用其 AuthService（规格 Authorization: publishToken）
    let publishAuth: ?AuthService = match (admin) {
        case Some(adm) => Some(adm.auth)
        case None => None
    }
    // 权限模式：CJREG_PERMISSION_MODE=team 启用团队严格校验；默认 open（内部先用着，有效 token 即发布）
    let permMode = permissionModeFromEnv()
    // 读鉴权开关（私有仓）：CJREG_REQUIRE_AUTH=1/true → 下载/索引需有效 token + 团队/个人 read 权限
    let requireReadAuth = match (getVariable("CJREG_REQUIRE_AUTH")) {
        case Some(v) => v == "1" || v == "true"
        case None => false
    }
    // 权限数据（团队/组织/包关联）：发布裁决与读裁决共用同一实例
    let permData = AdminDataStore(store.storm)
    let publishSvc = PublishService(store, blobStore, auth: publishAuth, adminData: Some(permData), permissionMode: permMode)
    let indexSvc = IndexService(store)
    let downloadSvc = DownloadService(store)
    // 代理回源服务（传入上游服务时启用；不可变，供 handler lambda 捕获）
    let proxySvc: ?ProxyService = match (upstreamSvc) {
        case Some(ups) => Some(ProxyService(store, blobStore, ups))
        case None => None
    }

    // 健康检查（自有端点，非官方协议）
    app.get("/api/health", { ctx =>
        ctx.writeString("{\"status\":\"ok\"}")
    })

    // 用户门户只读 API（/api/user/*）：session token 鉴权，普通用户与管理员均可
    // （管理 API /api/admin/* 走 requireAdmin，二者分离；见 user_handler.cj）
    match (publishAuth) {
        case Some(authSvc) =>
            let userApi = UserApi(authSvc, store, permData, permMode)
            app.get("/api/user/me", { ctx => userApi.me(ctx) })
            app.post("/api/user/me/publish-token", { ctx => userApi.resetPublishToken(ctx) })
            app.get("/api/user/me/packages", { ctx => userApi.myPackages(ctx) })
            app.get("/api/user/me/teams", { ctx => userApi.myTeams(ctx) })
        case None => ()
    }

    // 发布 POST /pkg/:name[?organization=]
    app.post("/pkg/:name", { ctx =>
        let name = ctx.param("name")
        let org = ctx.query("organization") ?? ""
        let body = ctx.bodyRaw()
        // 规格：Authorization: ${publishToken}（发布用户 token；兼容 "Bearer <token>" 写法）
        let token = extractAuthToken(ctx)
        let result = publishSvc.publish(org, name, body, token)
        match (result.outcome) {
            case PublishOutcome.Ok =>
                ctx.status(200u16).writeStringWithCode(200u16, "{\"status\":\"ok\",\"id\":${result.pkgId}}")
            case PublishOutcome.InvalidFormat =>
                ctx.status(400u16).writeStringWithCode(400u16, "{\"error\":\"invalid data format\"}")
            case PublishOutcome.MetaMismatch =>
                ctx.status(400u16).writeStringWithCode(400u16, "{\"error\":\"${result.message}\"}")
            case PublishOutcome.ShaMismatch =>
                ctx.status(400u16).writeStringWithCode(400u16, "{\"error\":\"${result.message}\"}")
            case PublishOutcome.Conflict =>
                ctx.status(409u16).writeStringWithCode(409u16, "{\"error\":\"conflict\",\"detail\":\"${result.message}\"}")
            case PublishOutcome.BadRequest =>
                ctx.status(400u16).writeStringWithCode(400u16, "{\"error\":\"${result.message}\"}")
            case PublishOutcome.Unauthorized =>
                ctx.status(401u16).writeStringWithCode(401u16, "{\"error\":\"${result.message}\"}")
            case PublishOutcome.Forbidden =>
                ctx.status(403u16).writeStringWithCode(403u16, "{\"error\":\"${result.message}\"}")
        }
    })

    // 下载 GET /pkg/:name/:version[?organization=]（统一走代理：blob 有则本地，否则回源）
    app.get("/pkg/:name/:version", { ctx =>
        let name = ctx.param("name")
        let version = ctx.param("version")
        let org = ctx.query("organization") ?? ""
        // 读鉴权（requireAuth=true）：token + read 权限
        if (requireReadAuth) {
            match (publishAuth) {
                case Some(authSvc) =>
                    if (!guardReadAccess(ctx, authSvc, permData, store, org, name)) {
                        return
                    }
                case None => ()
            }
        }
        // 计数（本地有该版本才计）
        downloadSvc.find(org, name, version)
        match (proxySvc) {
            case Some(proxy) =>
                let (outcome, blob, sha) = proxy.fetchArtifact(org, name, version)
                match (blob) {
                    case Some(bytes) =>
                        ctx.attachment("${name}-${version}.cjp")
                            .set("Content-Type", "application/x-gzip")
                        ctx.write(bytes)
                    case None =>
                        ctx.status(404u16).writeStringWithCode(404u16, "{\"error\":\"not found\"}")
                }
            case None =>
                ctx.status(404u16).writeStringWithCode(404u16, "{\"error\":\"not found\"}")
        }
    })

    // 索引 GET /index/:mo/:du/:name[?organization=]（本地无则回源上游）
    app.get("/index/:mo/:du/:name", { ctx =>
        let name = ctx.param("name")
        let org = ctx.query("organization") ?? ""
        if (name.size < 3) {
            ctx.status(400u16).writeStringWithCode(400u16, "{\"error\":\"invalid package name\"}")
            return
        }
        // 读鉴权（requireAuth=true）：token + read 权限
        if (requireReadAuth) {
            match (publishAuth) {
                case Some(authSvc) =>
                    if (!guardReadAccess(ctx, authSvc, permData, store, org, name)) {
                        return
                    }
                case None => ()
            }
        }
        let local = indexSvc.generate(org, name, false)
        if (!local.isEmpty()) {
            ctx.contentType("application/x-ndjson").writeString(local)
            return
        }
        match (proxySvc) {
            case Some(proxy) =>
                let (outcome, ndjson) = proxy.fetchIndex(org, name)
                if (ndjson.isEmpty()) {
                    ctx.status(404u16).writeStringWithCode(404u16, "{\"error\":\"not found\"}")
                } else {
                    ctx.contentType("application/x-ndjson").writeString(ndjson)
                }
            case None =>
                ctx.status(404u16).writeStringWithCode(404u16, "{\"error\":\"not found\"}")
        }
    })

    // 管理 API（可选：传入了 admin 服务才注册）
    match (admin) {
        case Some(adm) =>
            app.post("/api/admin/login", { ctx => adm.login(ctx) })
            app.post("/api/admin/logout", { ctx => adm.logout(ctx) })
            app.get("/api/admin/me", { ctx => adm.me(ctx) })
            app.get("/api/admin/users", { ctx => adm.listUsers(ctx) })
            app.post("/api/admin/users", { ctx => adm.createUser(ctx) })
            app.put("/api/admin/users/:id/admin", { ctx => adm.setUserAdmin(ctx) })
            app.get("/api/admin/upstreams", { ctx => adm.listUpstreams(ctx) })
            app.post("/api/admin/upstreams", { ctx => adm.addUpstream(ctx) })
            app.delete("/api/admin/upstreams/:id", { ctx => adm.deleteUpstream(ctx) })
            app.get("/api/admin/resolve", { ctx => adm.resolvePackage(ctx) })
            app.post("/api/admin/publish-plans/analyze", { ctx => adm.analyzePlan(ctx) })
            app.post("/api/admin/publish-plans/execute", { ctx => adm.executePlan(ctx) })
        case None => ()
    }

    return app
}

// 从 Authorization 头取 token：兼容官方规格的裸 token 与 HTTP 惯用的 "Bearer <token>"
func extractAuthToken(ctx: TangHttpContext): String {
    let raw = match (ctx.getHeader("Authorization")) {
        case Some(v) => v
        case None => ""
    }
    let trimmed = raw.trimAscii()
    if (trimmed.startsWith("Bearer ")) {
        return trimmed[7..trimmed.size].trimAscii()
    }
    trimmed
}

// 读路径鉴权（requireAuth=true 的下载/索引）：token 缺失/无效 → 401；无 read 权限 → 403
// 返回 true = 放行；false = 已写入拒绝响应（调用方直接 return）
func guardReadAccess(ctx: TangHttpContext, authSvc: AuthService, adminData: AdminDataStore,
                     store: PackageStore, org: String, name: String): Bool {
    let token = extractAuthToken(ctx)
    if (token.isEmpty()) {
        ctx.status(401u16).writeStringWithCode(401u16, "{\"error\":\"missing token\"}")
        return false
    }
    match (authSvc.validateAuthToken(token)) {
        case Some(user) =>
            if (!checkReadPermission(store, adminData, user, org, name)) {
                ctx.status(403u16).writeStringWithCode(403u16, "{\"error\":\"no permission to read\"}")
                return false
            }
            return true
        case None =>
            ctx.status(401u16).writeStringWithCode(401u16, "{\"error\":\"invalid token\"}")
            return false
    }
}

// 发布权限模式（环境变量 CJREG_PERMISSION_MODE）：team = 团队严格校验；默认 open
// 服务端（buildServer）与 UI 状态（main.cj 注入 CjregState）共用，避免两处口径漂移
public func permissionModeFromEnv(): String {
    match (getVariable("CJREG_PERMISSION_MODE")) {
        case Some(v) => if (v == "team") { "team" } else { "open" }
        case None => "open"
    }
}

// 兼容：无管理 API / 无上游的构建
public func buildServer(store: PackageStore): Tang {
    buildServer(store, None, None, MemoryBlobStore())
}

// 兼容：有管理 API 无上游
public func buildServer(store: PackageStore, admin: AdminService): Tang {
    buildServer(store, Some(admin), None, MemoryBlobStore())
}
