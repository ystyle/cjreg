// 上游表持久化（bstorm）：实现 config.UpstreamStore 接口
package ystyle::cjreg.store

import bstorm.*
import bstorm.macros.*
import stdx.encoding.json.stream.*
import ystyle::cjreg.config.*
import std.collection.*

// 上游文档
//
// ⚠️ proxyEnabled / asTarget 的**字段默认值必须是 true**：bstorm 的 fromJson 先按字段
// 默认值构造对象、再按 JSON 键赋值，旧文档里没有这两个键 → 读出来就是这里的默认值。
// 若把它们写成 false，升级后存量上游会立刻停止回源 / 从发布计划下拉里消失。
// 「新加的上游默认不允许作为目标仓」由 UpstreamService.add 的默认参数负责，不在这里。
@Model
public class UpstreamDoc {
    @Id public var id: Int64 = 0
    @Index public var name: String = ""
    public var url: String = ""
    public var enabled: Bool = true
    public var cacheTtl: Int64 = 86400
    public var authToken: String = ""
    public var isOfficial: Bool = false
    public var priority: Int64 = 0
    public var lastSyncAt: Int64 = 0
    public var proxyEnabled: Bool = true
    public var asTarget: Bool = true
}

// bstorm 实现的 UpstreamStore（持久化）
public class BstormUpstreamStore <: UpstreamStore {
    public var storm: Storm
    public var next: Int64

    public init(storm: Storm) {
        this.storm = storm
        this.next = 1
        recoverNextId()
    }

    // 从已有记录恢复最大 id（跨进程复用同一数据目录时避免 id 冲突）
    public func recoverNextId(): Unit {
        var maxId: Int64 = 0
        for (d in this.storm.all<UpstreamDoc>()) {
            if (d.id >= maxId) {
                maxId = d.id
            }
        }
        if (maxId >= this.next) {
            this.next = maxId + 1
        }
    }

    public func save(up: Upstream): Unit {
        let doc = UpstreamDoc()
        doc.id = up.id
        doc.name = up.name
        doc.url = up.url
        doc.enabled = up.enabled
        doc.cacheTtl = up.cacheTtl
        doc.authToken = up.authToken
        doc.isOfficial = up.isOfficial
        doc.priority = up.priority
        doc.lastSyncAt = up.lastSyncAt
        doc.proxyEnabled = up.proxyEnabled
        doc.asTarget = up.asTarget
        this.storm.save(doc)
    }

    public func getById(id: Int64): ?Upstream {
        let doc = this.storm.get<UpstreamDoc>(id)
        if (doc.isNone()) {
            return None
        }
        return Some(toUpstream(doc.getOrThrow()))
    }

    public func getByName(name: String): ?Upstream {
        match (this.storm.one<UpstreamDoc>("name", name)) {
            case Some(d) => Some(toUpstream(d))
            case None => None
        }
    }

    public func listAll(): ArrayList<Upstream> {
        let result = ArrayList<Upstream>()
        for (d in this.storm.all<UpstreamDoc>()) {
            result.add(toUpstream(d))
        }
        return result
    }

    public func remove(id: Int64): Bool {
        match (this.storm.get<UpstreamDoc>(id)) {
            case Some(doc) =>
                this.storm.delete(doc)
                return true
            case None => return false
        }
    }

    public func nextId(): Int64 {
        let id = this.next
        this.next++
        return id
    }

    private func toUpstream(d: UpstreamDoc): Upstream {
        Upstream(d.id, d.name, d.url, d.enabled, d.cacheTtl, d.authToken, d.isOfficial, d.priority, d.lastSyncAt,
            proxyEnabled: d.proxyEnabled, asTarget: d.asTarget)
    }
}
