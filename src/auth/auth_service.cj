// 认证服务：initAdmin（空库创建首个管理员）/ login / session 与发布 token 校验
package ystyle::cjreg.auth

import ystyle::cjreg.auth.model.*
import ystyle::cjreg.auth.util.*

public class AuthService {
    public var store: UserStore
    public var sessionTtlSeconds: Int64

    public init(store: UserStore, sessionTtlSeconds: Int64) {
        this.store = store
        this.sessionTtlSeconds = sessionTtlSeconds
    }

    // 部署期：空用户库上创建首个管理员（信任凭证 = 本地 CLI + 空数据目录）
    // 已初始化（存在用户）则拒绝
    public func initAdmin(username: String, password: String): ?User {
        if (!this.store.isEmpty()) {
            return None
        }
        if (username.isEmpty() || password.isEmpty()) {
            return None
        }
        if (this.store.getUserByUsername(username).isSome()) {
            return None
        }
        let user = User(
            this.store.nextUserId(),
            username,
            PasswordHash.hash(password),
            true,
            true,
            TokenGenerator.generatePublishToken()
        )
        this.store.saveUser(user)
        return Some(user)
    }

    // 用户名密码登录 → 签发 session token
    public func login(username: String, password: String): ?(User, UserToken) {
        match (this.store.getUserByUsername(username)) {
            case Some(user) =>
                if (!user.isActive) {
                    return None
                }
                if (!PasswordHash.verify(password, user.passwordHash)) {
                    return None
                }
                let token = UserToken(
                    TokenGenerator.generateSessionToken(),
                    user.id,
                    "session",
                    expiresAt(this.sessionTtlSeconds)
                )
                this.store.saveToken(token)
                return Some((user, token))
            case None => return None
        }
    }

    // 管理面会话 token 校验
    public func validateSessionToken(token: String): ?User {
        match (this.store.getToken(token)) {
            case Some(t) =>
                if (t.kind != "session") {
                    return None
                }
                if (!t.isValid()) {
                    return None
                }
                match (this.store.getUser(t.userId)) {
                    case Some(user) =>
                        if (!user.isActive) {
                            return None
                        }
                        return Some(user)
                    case None => return None
                }
            case None => return None
        }
    }

    // 发布 token 校验（POST /pkg 上传鉴权，兼容 cangjie-repo.toml token）
    public func validatePublishToken(token: String): ?User {
        for (u in this.store.listAllUsers()) {
            if (u.publishToken == token && u.isActive) {
                return Some(u)
            }
        }
        match (this.store.getToken(token)) {
            case Some(t) =>
                if (t.kind != "publish") {
                    return None
                }
                if (!t.isValid()) {
                    return None
                }
                return this.store.getUser(t.userId)
            case None => return None
        }
    }

    public func logout(token: String): Unit {
        this.store.removeToken(token)
    }

    // 创建用户（管理员调用）
    public func createUser(username: String, password: String, isAdmin: Bool, email!: String = ""): ?User {
        if (this.store.getUserByUsername(username).isSome()) {
            return None
        }
        let user = User(
            this.store.nextUserId(),
            username,
            PasswordHash.hash(password),
            isAdmin,
            true,
            TokenGenerator.generatePublishToken(),
            email: email
        )
        this.store.saveUser(user)
        return Some(user)
    }

    // ===== 管理员安全约束 =====

    // 启用状态的管理员数量（「最后一个管理员」保护的判定依据）
    public func countActiveAdmins(): Int64 {
        var n: Int64 = 0
        for (u in this.store.listAllUsers()) {
            if (u.isAdmin && u.isActive) {
                n++
            }
        }
        return n
    }

    // 该用户是否为「最后一个启用管理员」：禁用或降级他会使管理端无人可登录
    // （isAdminSession 要求 isAdmin && isActive；非启用管理员恒为 false）
    public func isLastActiveAdmin(userId: Int64): Bool {
        match (this.store.getUser(userId)) {
            case Some(user) =>
                if (!(user.isAdmin && user.isActive)) {
                    return false
                }
                return this.countActiveAdmins() <= 1
            case None => return false
        }
    }

    // 启用/禁用用户；拒绝禁用最后一个启用管理员（否则管理端彻底锁死）
    public func setUserActive(userId: Int64, active: Bool): Bool {
        match (this.store.getUser(userId)) {
            case Some(user) =>
                if (!active && this.isLastActiveAdmin(userId)) {
                    return false
                }
                user.isActive = active
                this.store.saveUser(user)
                return true
            case None => return false
        }
    }

    // 提升/取消管理员；拒绝取消最后一个启用管理员的身份
    // 幂等：目标状态与当前一致时直接返回 true（不写库）
    public func setUserAdmin(userId: Int64, isAdmin: Bool): Bool {
        match (this.store.getUser(userId)) {
            case Some(user) =>
                if (user.isAdmin == isAdmin) {
                    return true
                }
                if (!isAdmin && this.isLastActiveAdmin(userId)) {
                    return false
                }
                user.isAdmin = isAdmin
                this.store.saveUser(user)
                return true
            case None => return false
        }
    }

    // 删除用户（管理员受保护；其遗留 token 因查不到用户而自然失效）
    public func deleteUser(userId: Int64): Bool {
        match (this.store.getUser(userId)) {
            case Some(user) =>
                if (user.isAdmin) {
                    return false
                }
                return this.store.removeUser(userId)
            case None => return false
        }
    }

    // 修改密码
    public func changePassword(userId: Int64, newPassword: String): Bool {
        match (this.store.getUser(userId)) {
            case Some(user) =>
                user.passwordHash = PasswordHash.hash(newPassword)
                this.store.saveUser(user)
                return true
            case None => return false
        }
    }

    // 应急恢复（本地 CLI `cjreg admin reset-password`）：重置口令 + 强制管理员身份与启用状态
    // 用于管理端全部管理员被禁用/降级后的兜底；信任凭证 = 本地数据目录持有者
    public func recoverAdmin(username: String, newPassword: String): ?User {
        if (username.isEmpty() || newPassword.isEmpty()) {
            return None
        }
        match (this.store.getUserByUsername(username)) {
            case Some(user) =>
                user.passwordHash = PasswordHash.hash(newPassword)
                user.isAdmin = true
                user.isActive = true
                this.store.saveUser(user)
                return Some(user)
            case None => return None
        }
    }

    // 重置发布 token
    public func resetPublishToken(userId: Int64): ?String {
        match (this.store.getUser(userId)) {
            case Some(user) =>
                user.publishToken = TokenGenerator.generatePublishToken()
                this.store.saveUser(user)
                return Some(user.publishToken)
            case None => return None
        }
    }
}
