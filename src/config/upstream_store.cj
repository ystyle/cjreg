// 上游表（多仓核心）：Upstream 模型 + 存储接口 + 官方仓识别/保护
// 对齐 cjrepo upstreams 表；存储实现（Memory 供测试 / Bstorm M2 接入）
package ystyle::cjreg.config

import ystyle::cjreg.protocol.{isOfficialRegistry}
import std.collection.*

public let DEFAULT_CACHE_TTL: Int64 = 86400  // 默认缓存时间（秒），24h

// 上游
//
// 两个正交开关（都建立在 enabled 这个总闸之上）：
//   proxyEnabled  读路径：本地没有的包是否去它那里取、并缓存落库（回源 / 镜像同步）
//   asTarget      写路径：是否出现在发布计划的「目标上游」下拉里（可被推送）
// 默认值分两层，别混：
//   · **字段默认 true/true**：bstorm 反序列化旧文档时缺失键就落到字段默认值，
//     存量上游读出来必须与升级前逐字一致（否则升级即断回源 / 下拉全空）；
//   · **新建时由调用方给**（`UpstreamService.add` 默认 proxyEnabled=true、asTarget=false）：
//     推送是不可逆操作，新加的上游默认不允许当目标仓，要显式打开。
public class Upstream {
    public var id: Int64
    public var name: String        // 唯一
    public var url: String         // 上游地址（registry base）
    public var enabled: Bool       // 总闸：关 = 不回源、也不可选作目标仓
    public var cacheTtl: Int64
    public var authToken: String   // 回源认证 + 发布认证（向官方仓发布需要）
    public var isOfficial: Bool    // 官方中心仓（URL 识别或显式指定）
    public var priority: Int64     // 越小越优先；缺省按出现顺序
    public var lastSyncAt: Int64   // 最后同步时间戳
    public var proxyEnabled: Bool  // 是否参与回源（镜像同步）
    public var asTarget: Bool      // 是否可作为发布计划的目标仓

    public init(id: Int64, name: String, url: String, enabled: Bool,
                cacheTtl: Int64, authToken: String, isOfficial: Bool,
                priority: Int64, lastSyncAt: Int64,
                proxyEnabled!: Bool = true, asTarget!: Bool = true) {
        this.id = id
        this.name = name
        this.url = url
        this.enabled = enabled
        this.cacheTtl = cacheTtl
        this.authToken = authToken
        this.isOfficial = isOfficial
        this.priority = priority
        this.lastSyncAt = lastSyncAt
        this.proxyEnabled = proxyEnabled
        this.asTarget = asTarget
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

    // 添加上游；官方仓由 URL 自动识别。
    // 新加的上游：默认参与回源（proxyEnabled=true）、**默认不允许作为发布计划目标**
    // （asTarget=false）—— 推送不可逆，目标仓要显式授权。
    public func add(name: String, url: String, priority: Int64,
                    authToken: String, cacheTtl: Int64,
                    proxyEnabled!: Bool = true, asTarget!: Bool = false): ?Upstream {
        if (name.isEmpty() || url.isEmpty()) {
            return None
        }
        if (this.store.getByName(name).isSome()) {
            return None  // 重名
        }
        let up = Upstream(
            this.store.nextId(), name, url, true,
            if (cacheTtl <= 0) { DEFAULT_CACHE_TTL } else { cacheTtl },
            authToken, isOfficialRegistry(url), priority, 0,
            proxyEnabled: proxyEnabled, asTarget: asTarget
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

    // 更新（官方仓禁止删除，允许改 enabled/proxyEnabled/asTarget/priority/cacheTtl/authToken）
    public func update(id: Int64, enabled: ?Bool, priority: ?Int64,
                       cacheTtl: ?Int64, authToken: ?String,
                       proxyEnabled!: ?Bool = None, asTarget!: ?Bool = None): Bool {
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
                if (proxyEnabled.isSome()) {
                    up.proxyEnabled = proxyEnabled.getOrThrow()
                }
                if (asTarget.isSome()) {
                    up.asTarget = asTarget.getOrThrow()
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

    // 参与回源的上游（enabled 且 proxyEnabled），按优先级排序（priority asc，出现顺序 asc）。
    // 回源 / 解析诊断 / 重拉都走这里——**关掉回源开关的上游不出现在这条链上**。
    public func proxySorted(): ArrayList<Upstream> {
        let list = ArrayList<Upstream>()
        for (u in this.store.listAll()) {
            if (u.enabled && u.proxyEnabled) {
                list.add(u)
            }
        }
        sortByPriority(list)
        return list
    }

    // 发布计划可选的目标仓（enabled 且 asTarget），顺序同上。
    // 「不可作为目标仓」的上游连下拉都不出现——推送到官方中心仓这类不可逆操作要显式授权。
    public func planTargets(): ArrayList<Upstream> {
        let list = ArrayList<Upstream>()
        for (u in this.store.listAll()) {
            if (u.enabled && u.asTarget) {
                list.add(u)
            }
        }
        sortByPriority(list)
        return list
    }

    // 插入排序（稳定）：priority 升序
    private func sortByPriority(list: ArrayList<Upstream>): Unit {
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
    }
}
