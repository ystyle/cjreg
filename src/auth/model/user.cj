// 用户模型与存储接口（Memory 实现供测试；Bstorm 实现 M2 接入）
package ystyle::cjreg.auth.model

import ystyle::cjreg.auth.util.{currentTimestamp}
import std.collection.*

// 用户
public class User {
    public var id: Int64
    public var username: String
    public var passwordHash: String
    public var email: String
    public var isAdmin: Bool
    public var isActive: Bool
    public var publishToken: String

    public init(id: Int64, username: String, passwordHash: String,
                isAdmin: Bool, isActive: Bool, publishToken: String, email!: String = "") {
        this.id = id
        this.username = username
        this.passwordHash = passwordHash
        this.email = email
        this.isAdmin = isAdmin
        this.isActive = isActive
        this.publishToken = publishToken
    }
}

// 会话/发布 token
public class UserToken {
    public var token: String
    public var userId: Int64
    public var kind: String   // "session" / "publish"
    public var expiresAt: Int64

    public init(token: String, userId: Int64, kind: String, expiresAt: Int64) {
        this.token = token
        this.userId = userId
        this.kind = kind
        this.expiresAt = expiresAt
    }

    public func isValid(): Bool {
        this.expiresAt > currentTimestamp()
    }
}

// 用户/token 存储接口
public interface UserStore {
    func saveUser(user: User): Unit
    func getUserByUsername(username: String): ?User
    func getUser(id: Int64): ?User
    func removeUser(id: Int64): Bool
    func getToken(token: String): ?UserToken
    func saveToken(t: UserToken): Unit
    func removeToken(token: String): Unit
    func nextUserId(): Int64
    func listAllUsers(): ArrayList<User>
    func isEmpty(): Bool
}

// 内存实现（测试/单机小规模）
public class MemoryUserStore <: UserStore {
    var users: ArrayList<User>
    var tokens: ArrayList<UserToken>
    var nextId: Int64

    public init() {
        this.users = ArrayList<User>()
        this.tokens = ArrayList<UserToken>()
        this.nextId = 1
    }

    public func saveUser(user: User): Unit {
        // upsert 语义：同 id 替换，避免重复添加
        var i: Int64 = 0
        while (i < this.users.size) {
            if (this.users[i].id == user.id) {
                this.users[i] = user
                return
            }
            i++
        }
        this.users.add(user)
    }

    public func getUserByUsername(username: String): ?User {
        for (u in this.users) {
            if (u.username == username) {
                return Some(u)
            }
        }
        return None
    }

    public func getUser(id: Int64): ?User {
        for (u in this.users) {
            if (u.id == id) {
                return Some(u)
            }
        }
        return None
    }

    public func removeUser(id: Int64): Bool {
        var i: Int64 = 0
        while (i < this.users.size) {
            if (this.users[i].id == id) {
                this.users.remove(i..i + 1)
                return true
            }
            i++
        }
        return false
    }

    public func getToken(token: String): ?UserToken {
        for (t in this.tokens) {
            if (t.token == token) {
                return Some(t)
            }
        }
        return None
    }

    public func saveToken(t: UserToken): Unit {
        this.tokens.add(t)
    }

    public func removeToken(token: String): Unit {
        var i: Int64 = 0
        while (i < this.tokens.size) {
            if (this.tokens[i].token == token) {
                this.tokens.remove(i..i + 1)
                return
            }
            i++
        }
    }

    public func nextUserId(): Int64 {
        let id = this.nextId
        this.nextId++
        return id
    }

    public func listAllUsers(): ArrayList<User> {
        this.users
    }

    public func isEmpty(): Bool {
        this.users.size == 0
    }
}
