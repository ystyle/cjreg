// 上游表（多仓核心）：Upstream 模型 + 存储接口 + 官方仓识别/保护
// 对齐 cjrepo upstreams 表；存储实现（Memory 供测试 / Bstorm M2 接入）
package ystyle::cjreg.config

import ystyle::cjreg.protocol.{isOfficialRegistry}
import std.collection.*

public let DEFAULT_CACHE_TTL: Int64 = 86400  // 默认缓存时间（秒），24h

// 上游
public class Upstream {
    public var id: Int64
    public var name: String        // 唯一
    public var url: String         // 上游地址（registry base）
    public var enabled: Bool
    public var cacheTtl: Int64
    public var authToken: String   // 回源认证 + 发布认证（向官方仓发布需要）
    public var isOfficial: Bool    // 官方中心仓（URL 识别或显式指定）
    public var priority: Int64     // 越小越优先；缺省按出现顺序
    public var lastSyncAt: Int64   // 最后同步时间戳

    public init(id: Int64, name: String, url: String, enabled: Bool,
                cacheTtl: Int64, authToken: String, isOfficial: Bool,
                priority: Int64, lastSyncAt: Int64) {
        this.id = id
        this.name = name
        this.url = url
        this.enabled = enabled
        this.cacheTtl = cacheTtl
        this.authToken = authToken
        this.isOfficial = isOfficial
        this.priority = priority
        this.lastSyncAt = lastSyncAt
    }
}

// 上游存储接口（可注入：Memory 供测试 / Bstorm 后续接入）
public interface UpstreamStore {
    func save(up: Upstream): Unit
    func getById(id: Int64): ?Upstream
    func getByName(name: String): ?Upstream
    func listAll(): ArrayList<Upstream>
    func remove(id: Int64): Bool
    func nextId(): Int64
}

public class MemoryUpstreamStore <: UpstreamStore {
    var items: ArrayList<Upstream>
    var next: Int64

    public init() {
        this.items = ArrayList<Upstream>()
        this.next = 1
    }

    public func save(up: Upstream): Unit {
        // 按 id 覆盖或追加
        var i: Int64 = 0
        while (i < this.items.size) {
            if (this.items[i].id == up.id) {
                this.items[i] = up
                return
            }
            i++
        }
        this.items.add(up)
    }

    public func getById(id: Int64): ?Upstream {
        for (u in this.items) {
            if (u.id == id) {
                return Some(u)
            }
        }
        return None
    }

    public func getByName(name: String): ?Upstream {
        for (u in this.items) {
            if (u.name == name) {
                return Some(u)
            }
        }
        return None
    }

    public func listAll(): ArrayList<Upstream> {
        this.items
    }

    public func remove(id: Int64): Bool {
        var i: Int64 = 0
        while (i < this.items.size) {
            if (this.items[i].id == id) {
                this.items.remove(i..i + 1)
                return true
            }
            i++
        }
        return false
    }

    public func nextId(): Int64 {
        let id = this.next
        this.next++
        return id
    }
}

// 上游服务：CRUD + 官方仓识别/保护 + 优先级排序
public class UpstreamService {
    public var store: UpstreamStore

    public init(store: UpstreamStore) {
        this.store = store
    }

    // 添加上游；官方仓由 URL 自动识别
    public func add(name: String, url: String, priority: Int64,
                    authToken: String, cacheTtl: Int64): ?Upstream {
        if (name.isEmpty() || url.isEmpty()) {
            return None
        }
        if (this.store.getByName(name).isSome()) {
            return None  // 重名
        }
        let up = Upstream(
            this.store.nextId(), name, url, true,
            if (cacheTtl <= 0) { DEFAULT_CACHE_TTL } else { cacheTtl },
            authToken, isOfficialRegistry(url), priority, 0
        )
        this.store.save(up)
        return Some(up)
    }

    public func getById(id: Int64): ?Upstream {
        this.store.getById(id)
    }

    public func getByName(name: String): ?Upstream {
        this.store.getByName(name)
    }

    // 更新（官方仓禁止删除，允许改 enabled/priority/cacheTtl/authToken）
    public func update(id: Int64, enabled: ?Bool, priority: ?Int64,
                       cacheTtl: ?Int64, authToken: ?String): Bool {
        match (this.store.getById(id)) {
            case Some(up) =>
                if (enabled.isSome()) {
                    up.enabled = enabled.getOrThrow()
                }
                if (priority.isSome()) {
                    up.priority = priority.getOrThrow()
                }
                if (cacheTtl.isSome() && cacheTtl.getOrThrow() > 0) {
                    up.cacheTtl = cacheTtl.getOrThrow()
                }
                if (authToken.isSome()) {
                    up.authToken = authToken.getOrThrow()
                }
                this.store.save(up)
                return true
            case None => return false
        }
    }

    // 删除：官方仓受保护（不可删除）；非官方仓可删
    public func remove(id: Int64): Bool {
        match (this.store.getById(id)) {
            case Some(up) =>
                if (up.isOfficial) {
                    return false  // 官方仓受保护
                }
                return this.store.remove(id)
            case None => return false
        }
    }

    // 按优先级排序的上游列表（priority asc，出现顺序 asc；仅 enabled）
    public func enabledSorted(): ArrayList<Upstream> {
        let list = ArrayList<Upstream>()
        for (u in this.store.listAll()) {
            if (u.enabled) {
                list.add(u)
            }
        }
        // 插入排序（稳定）：priority 升序
        var i: Int64 = 1
        while (i < list.size) {
            let key = list[i]
            var j = i - 1
            while (j >= 0 && list[j].priority > key.priority) {
                list[j + 1] = list[j]
                j--
            }
            list[j + 1] = key
            i++
        }
        return list
    }
}
