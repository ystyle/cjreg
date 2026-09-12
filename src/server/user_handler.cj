// 用户门户只读 API（/api/user/*）：session token 鉴权（普通用户与管理员均可）
//
// 与管理 API（/api/admin/*，requireAdmin）分离：这里只暴露「我自己的」数据，
// 不提供任何跨用户读写能力（用户 id 一律取自会话，不接受客户端传入）。
package ystyle::cjreg.server

import tang.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*
import std.collection.*
import std.convert.*
import std.io.*

public class UserApi {
    public var auth: AuthService
    public var pkgStore: PackageStore
    public var adminData: AdminDataStore
    public var permissionMode: String

    public init(auth: AuthService, pkgStore: PackageStore, adminData: AdminDataStore, permissionMode: String) {
        this.auth = auth
        this.pkgStore = pkgStore
        this.adminData = adminData
        this.permissionMode = permissionMode
    }

    // ===== 守卫：session token（缺失/无效 → 401）=====

    func currentUser(ctx: TangHttpContext): ?User {
        let token = extractAuthToken(ctx)
        if (token.isEmpty()) {
            return None
        }
        this.auth.validateSessionToken(token)
    }

    // ===== GET /api/user/me =====
    // 当前用户信息 + 掩码 Token + 权限模式；mcp/cjpm 侧可用它确认「我是谁、能不能发」
    public func me(ctx: TangHttpContext): Unit {
        let user = match (this.currentUser(ctx)) {
            case Some(u) => u
            case None =>
                writeJson(ctx, 401u16, "{\"error\":\"not authenticated\"}")
                return
        }
        writeJson(ctx, 200u16,
            "{\"id\":${user.id},\"username\":\"${user.username}\",\"email\":\"${user.email}\"," +
            "\"isAdmin\":${user.isAdmin},\"publishTokenMasked\":\"${maskToken(user.publishToken)}\"," +
            "\"permissionMode\":\"${this.permissionMode}\"," +
            "\"permissionHint\":\"${permissionHint(this.permissionMode)}\"}")
    }

    // ===== POST /api/user/me/publish-token =====
    // 重置自己的发布 Token（旧 Token 立即失效）；响应返回新 Token（仅此一次由调用方保存）
    public func resetPublishToken(ctx: TangHttpContext): Unit {
        let user = match (this.currentUser(ctx)) {
            case Some(u) => u
            case None =>
                writeJson(ctx, 401u16, "{\"error\":\"not authenticated\"}")
                return
        }
        match (this.auth.resetPublishToken(user.id)) {
            case Some(t) =>
                this.adminData.addLog(LogKind.Auth, user.id, user.username, "reset publish token (portal)", "ok", nowMsUtc())
                writeJson(ctx, 200u16, "{\"publishToken\":\"${t}\"}")
            case None =>
                writeJson(ctx, 404u16, "{\"error\":\"user not found\"}")
        }
    }

    // ===== GET /api/user/me/packages?page=&size=&q= =====
    // 我发布过版本的包（服务端分页 + 名称/组织模糊搜索）
    public func myPackages(ctx: TangHttpContext): Unit {
        let user = match (this.currentUser(ctx)) {
            case Some(u) => u
            case None =>
                writeJson(ctx, 401u16, "{\"error\":\"not authenticated\"}")
                return
        }
        let page = parseQueryInt(ctx, "page", 1)
        let size = parseQueryInt(ctx, "size", 20)
        let q = ctx.query("q") ?? ""
        let all = myPackageRows(this.pkgStore, this.adminData, user.id)
        let hits = ArrayList<MyPackageRow>()
        for (r in all) {
            if (q.isEmpty() || r.name.contains(q) || r.org.contains(q)) {
                hits.add(r)
            }
        }
        let (start, end) = pageWindow(hits.size, page, size)
        let sb = StringBuilder()
        sb.append("{\"total\":${hits.size},\"page\":${page},\"size\":${size},\"items\":[")
        var i = start
        while (i < end) {
            if (i > start) {
                sb.append(",")
            }
            let r = hits[i]
            sb.append("{\"organization\":\"${r.org}\",\"name\":\"${r.name}\",")
            sb.append("\"versionCount\":${r.versionCount},\"latestVersion\":\"${r.latestVersion}\",")
            sb.append("\"isOwner\":${r.isOwner},\"updatedAt\":${r.updatedAt}}")
            i++
        }
        sb.append("]}")
        writeJson(ctx, 200u16, sb.toString())
    }

    // ===== GET /api/user/me/teams =====
    // 我所属团队 + 团队权限 + 关联组织/包（只读，供门户与外部工具展示）
    public func myTeams(ctx: TangHttpContext): Unit {
        let user = match (this.currentUser(ctx)) {
            case Some(u) => u
            case None =>
                writeJson(ctx, 401u16, "{\"error\":\"not authenticated\"}")
                return
        }
        let rows = myTeamRows(this.adminData, user.id)
        let sb = StringBuilder()
        sb.append("{\"permissionMode\":\"${this.permissionMode}\",\"items\":[")
        for (i in 0..rows.size) {
            if (i > 0) {
                sb.append(",")
            }
            let r = rows[i]
            sb.append("{\"id\":${r.teamId},\"name\":\"${r.name}\",\"displayName\":\"${r.displayName}\",")
            sb.append("\"permission\":\"${r.permission}\",\"organizations\":[")
            for (j in 0..r.orgNames.size) {
                if (j > 0) {
                    sb.append(",")
                }
                sb.append("\"${r.orgNames[j]}\"")
            }
            sb.append("],\"packages\":[")
            for (j in 0..r.packages.size) {
                if (j > 0) {
                    sb.append(",")
                }
                sb.append("\"${r.packages[j]}\"")
            }
            sb.append("]}")
        }
        sb.append("]}")
        writeJson(ctx, 200u16, sb.toString())
    }

    // ===== 工具 =====

    // 分页切片（与 UI 层 pageWindow 同语义：越界安全）
    func pageWindow(total: Int64, page: Int64, size: Int64): (Int64, Int64) {
        let safePage = if (page < 1) { 1 } else { page }
        let safeSize = if (size < 1) { 1 } else { if (size > 100) { 100 } else { size } }
        let start = (safePage - 1) * safeSize
        let end = if (start + safeSize > total) { total } else { start + safeSize }
        (start, end)
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
