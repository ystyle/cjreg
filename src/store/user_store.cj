// 用户存储（bstorm 持久化）：实现 auth.UserStore 接口
// 用户与会话 token 落 bstorm 集合，支持跨重启
package ystyle::cjreg.store

import bstorm.*
import bstorm.macros.*
import stdx.encoding.json.stream.*
import ystyle::cjreg.auth.model.*
import std.collection.*

// 用户文档（bstorm 持久化）
@Model
public class UserDoc {
    @Id public var id: Int64 = 0
    public var username: String = ""
    public var passwordHash: String = ""
    public var isAdmin: Bool = false
    public var isActive: Bool = true
    public var publishToken: String = ""
}

// 会话/发布 token 文档
@Model
public class UserTokenDoc {
    @Id public var token: String = ""
    public var userId: Int64 = 0
    public var kind: String = ""
    public var expiresAt: Int64 = 0
}

// bstorm 实现的 UserStore（持久化）
public class BstormUserStore <: UserStore {
    public var storm: Storm
    public var nextId: Int64

    public init(storm: Storm) {
        this.storm = storm
        this.nextId = 1
        // 持久存储重新打开后需重建索引，否则 all/find 返回空
        this.storm.reindex<UserDoc>()
        this.storm.reindex<UserTokenDoc>()
        recoverNextId()
    }

    // 从已有用户恢复最大 id（跨进程复用数据目录时避免 id 冲突）
    public func recoverNextId(): Unit {
        var maxId: Int64 = 0
        for (d in this.storm.all<UserDoc>()) {
            if (d.id >= maxId) {
                maxId = d.id
            }
        }
        if (maxId >= this.nextId) {
            this.nextId = maxId + 1
        }
    }

    // ===== 用户 =====
    public func saveUser(user: User): Unit {
        let doc = UserDoc()
        if (user.id == 0) {
            doc.id = this.nextId
            user.id = doc.id
            this.nextId++
        } else {
            doc.id = user.id
        }
        doc.username = user.username
        doc.passwordHash = user.passwordHash
        doc.isAdmin = user.isAdmin
        doc.isActive = user.isActive
        doc.publishToken = user.publishToken
        this.storm.save(doc)
    }

    public func getUserByUsername(username: String): ?User {
        for (d in this.storm.all<UserDoc>()) {
            if (d.username == username) {
                return Some(toUser(d))
            }
        }
        return None
    }

    public func getUser(id: Int64): ?User {
        let doc = this.storm.get<UserDoc>(id)
        if (doc.isNone()) {
            return None
        }
        return Some(toUser(doc.getOrThrow()))
    }

    // ===== token =====
    public func getToken(token: String): ?UserToken {
        let doc = this.storm.get<UserTokenDoc>(token)
        if (doc.isNone()) {
            return None
        }
        let d = doc.getOrThrow()
        return Some(UserToken(d.token, d.userId, d.kind, d.expiresAt))
    }

    public func saveToken(t: UserToken): Unit {
        let doc = UserTokenDoc()
        doc.token = t.token
        doc.userId = t.userId
        doc.kind = t.kind
        doc.expiresAt = t.expiresAt
        this.storm.save(doc)
    }

    public func removeToken(token: String): Unit {
        match (this.storm.get<UserTokenDoc>(token)) {
            case Some(doc) => this.storm.delete(doc)
            case None => ()
        }
    }

    // ===== 工具 =====
    public func nextUserId(): Int64 {
        let id = this.nextId
        this.nextId++
        return id
    }

    public func listAllUsers(): ArrayList<User> {
        let result = ArrayList<User>()
        for (d in this.storm.all<UserDoc>()) {
            result.add(toUser(d))
        }
        return result
    }

    public func isEmpty(): Bool {
        this.storm.all<UserDoc>().size == 0
    }

    private func toUser(d: UserDoc): User {
        User(d.id, d.username, d.passwordHash, d.isAdmin, d.isActive, d.publishToken)
    }
}
