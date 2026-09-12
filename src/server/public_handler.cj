// 公开只读 API handler（C1–C5）：/api/stats、/api/packages[*]、/api/organizations
//
// 鉴权：`require_auth=false`（默认）时全部公开；`require_auth=true`（私有仓）时要求有效 Token，
// 并按 read 权限过滤（与下载/索引同一裁决）。逻辑在读模型层（public_service.cj），本层只做参数解析与响应。
package ystyle::cjreg.server

import tang.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*
import std.collection.*
import std.convert.*

public class PublicApi {
    public var pkgStore: PackageStore
    public var adminData: AdminDataStore
    // 私有仓鉴权（require_auth=true 时使用；None = 无认证服务，视为开放）
    public var auth: ?AuthService
    // 用户库（发布者名解析 + 用户数统计；None = 无认证服务，按匿名处理）
    public var userStore: ?UserStore
    public var requireAuth: Bool
    public var startedAt: Int64

    public init(pkgStore: PackageStore, adminData: AdminDataStore, auth: ?AuthService,
                userStore: ?UserStore, requireAuth: Bool, startedAt: Int64) {
        this.pkgStore = pkgStore
        this.adminData = adminData
        this.auth = auth
        this.userStore = userStore
        this.requireAuth = requireAuth
        this.startedAt = startedAt
    }

    // ===== GET /api/stats =====
    public func stats(ctx: TangHttpContext): Unit {
        if (!this.guard(ctx)) {
            return
        }
        let userCount = match (this.userStore) {
            case Some(us) => us.listAllUsers().size
            case None => 0
        }
        let s = publicStatsModel(this.pkgStore, this.adminData, userCount, this.startedAt, auditNowMs())
        writeJson(ctx, 200u16, publicStatsJson(s))
    }

    // ===== GET /api/packages =====
    // 参数：q（名称/描述/组织；支持 `org::name` 语法）、organization、category（逗号分隔 OR）、
    //       sort（updated|downloads|name）、page（1 起）、size（默认 20，上限 100）
    public func listPackages(ctx: TangHttpContext): Unit {
        let user = this.currentUser(ctx)
        if (!this.guardWith(ctx, user)) {
            return
        }
        let rows = collectPublicPackages(this.pkgStore, this.adminData, user, this.requireAuth)
        let q = ctx.query("q") ?? ""
        let org = ctx.query("organization") ?? ""
        let cats = splitCommaList(ctx.query("category") ?? "")
        let sortKey = ctx.query("sort") ?? "updated"
        let hits = filterPublicPackages(rows, q, org, cats, sortKey)
        let page = parseQueryInt(ctx, "page", 1)
        let size = parseQueryInt(ctx, "size", 20)
        writeJson(ctx, 200u16, publicPackageListJson(hits, hits.size, page, size))
    }

    // ===== GET /api/packages/:name =====
    public func packageDetail(ctx: TangHttpContext): Unit {
        let user = this.currentUser(ctx)
        if (!this.guardWith(ctx, user)) {
            return
        }
        let name = ctx.param("name")
        let org = ctx.query("organization") ?? ""
        if (!this.allowed(ctx, user, org, name)) {
            return
        }
        let versions = publicVersions(this.pkgStore, org, name, this.publisherResolver())
        if (versions.size == 0) {
            writeJson(ctx, 404u16, "{\"error\":\"package not found\"}")
            return
        }
        // README：取最新未软删版本的 README
        var readme = ""
        for (d in this.pkgStore.listVersions(org, name)) {
            if (d.deletedAt == 0 && d.version == versions[0].version) {
                readme = d.readme
            }
        }
        writeJson(ctx, 200u16, publicPackageDetailJson(org, name, versions, readme))
    }

    // ===== GET /api/packages/:name/:version =====
    public func versionDetail(ctx: TangHttpContext): Unit {
        let user = this.currentUser(ctx)
        if (!this.guardWith(ctx, user)) {
            return
        }
        let name = ctx.param("name")
        let version = ctx.param("version")
        let org = ctx.query("organization") ?? ""
        if (!this.allowed(ctx, user, org, name)) {
            return
        }
        match (publicVersion(this.pkgStore, org, name, version, this.publisherResolver())) {
            case Some(v) => writeJson(ctx, 200u16, publicVersionJsonRow(v))
            case None => writeJson(ctx, 404u16, "{\"error\":\"version not found\"}")
        }
    }

    // ===== GET /api/organizations =====
    public func organizations(ctx: TangHttpContext): Unit {
        let user = this.currentUser(ctx)
        if (!this.guardWith(ctx, user)) {
            return
        }
        let rows = publicOrgRows(this.pkgStore, this.adminData, user, this.requireAuth)
        writeJson(ctx, 200u16, publicOrgListJson(rows))
    }

    // ===== 鉴权辅助 =====

    // 开放模式：直接放行；私有仓：无有效 Token → 401
    func guard(ctx: TangHttpContext): Bool {
        return this.guardWith(ctx, this.currentUser(ctx))
    }

    func guardWith(ctx: TangHttpContext, user: ?User): Bool {
        if (!this.requireAuth) {
            return true
        }
        match (user) {
            case Some(_) => return true
            case None =>
                writeJson(ctx, 401u16, "{\"error\":\"missing or invalid token\"}")
                return false
        }
    }

    // 包级读权限（私有仓）：无权限 → 403
    func allowed(ctx: TangHttpContext, user: ?User, org: String, name: String): Bool {
        if (!this.requireAuth) {
            return true
        }
        if (canReadPackage(this.pkgStore, this.adminData, user, org, name)) {
            return true
        }
        writeJson(ctx, 403u16, "{\"error\":\"no permission to read\"}")
        return false
    }

    func currentUser(ctx: TangHttpContext): ?User {
        match (this.auth) {
            case Some(a) =>
                let token = extractAuthToken(ctx)
                if (token.isEmpty()) {
                    return None
                }
                return a.validateAuthToken(token)
            case None => None
        }
    }

    // 发布者 id → 用户名（请求内缓存，避免逐版本查库）
    func publisherResolver(): (Int64) -> String {
        let cache = HashMap<Int64, String>()
        return { id: Int64 =>
            if (id <= 0) {
                return ""
            }
            match (cache.get(id)) {
                case Some(v) => return v
                case None => ()
            }
            let name = match (this.userStore) {
                case Some(us) => match (us.getUser(id)) {
                    case Some(u) => u.username
                    case None => ""
                }
                case None => ""
            }
            cache[id] = name
            name
        }
    }

    func parseQueryInt(ctx: TangHttpContext, key: String, fallback: Int64): Int64 {
        let raw = ctx.query(key) ?? ""
        if (raw.isEmpty()) {
            return fallback
        }
        match (Int64.tryParse(raw)) {
            case Some(n) => n
            case None => fallback
        }
    }
}
