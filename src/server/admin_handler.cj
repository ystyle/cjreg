// 管理 API handler：AdminService 的字段/构造 + 会话与鉴权底座 + JSON body 解析入口
// 各域端点在同包 admin_*.cj 里以 extend AdminService 展开：admin_auth / admin_users /
// admin_org / admin_pkg / admin_upstream / admin_plan / admin_logs；请求体 DTO 见 admin_request.cj
package ystyle::cjreg.server

import tang.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*
import ystyle::cjreg.auth.util.*
import ystyle::cjreg.config.*
import ystyle::cjreg.store.*
import stdx.encoding.json.stream.*
import std.io.*
import std.convert.*

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
    // 在线备份服务（None = 未注入，备份页不可用）
    public var backupSvc: ?OnlineBackupService

    public init(auth: AuthService, upstreamSvc: UpstreamService,
                userStore: UserStore, upstreamStore: UpstreamStore,
                resolveSvc: ResolveService, proxySvc: ?ProxyService,
                planSvc: PublishPlanService, executor: PublishExecutor,
                adminData!: ?AdminDataStore = None,
                pkgStore!: ?PackageStore = None,
                blobStore!: ?BlobStore = None,
                backupSvc!: ?OnlineBackupService = None) {
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
        this.backupSvc = backupSvc
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

    // 当前操作者（requireAdmin 通过后必然存在；解析失败按匿名记）
    func actorOf(ctx: TangHttpContext): (Int64, String) {
        match (this.currentUser(ctx)) {
            case Some(u) => (u.id, u.username)
            case None => (0, "")
        }
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
