// 上游表持久化（bstorm）：实现 config.UpstreamStore 接口
package ystyle::cjreg.store

import bstorm.*
import bstorm.macros.*
import stdx.encoding.json.stream.*
import ystyle::cjreg.config.*
import std.collection.*

// 上游文档
@Model
public class UpstreamDoc {
    @Id public var id: Int64 = 0
    public var name: String = ""
    public var url: String = ""
    public var enabled: Bool = true
    public var cacheTtl: Int64 = 86400
    public var authToken: String = ""
    public var isOfficial: Bool = false
    public var priority: Int64 = 0
    public var lastSyncAt: Int64 = 0
}

// bstorm 实现的 UpstreamStore（持久化）
public class BstormUpstreamStore <: UpstreamStore {
    public var storm: Storm
    public var next: Int64

    public init(storm: Storm) {
        this.storm = storm
        this.next = 1
        this.storm.reindex<UpstreamDoc>()
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
        for (d in this.storm.all<UpstreamDoc>()) {
            if (d.name == name) {
                return Some(toUpstream(d))
            }
        }
        return None
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
        Upstream(d.id, d.name, d.url, d.enabled, d.cacheTtl, d.authToken, d.isOfficial, d.priority, d.lastSyncAt)
    }
}
