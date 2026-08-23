// 包存储（bstorm 集合）：包文档 = meta 字段 + 服务端附加字段
package ystyle::cjreg.store

import bstorm.*
import bstorm.macros.*
import stdx.encoding.json.stream.*
import std.collection.*

// 包文档模型（bstorm @Model 自动生成 tableName/getPrimaryKey/getIndexes/JSON 序列化）
@Model
public class PackageDoc {
    @Id public var id: Int64 = 0

    // meta-data.json 字段
    public var organization: String = ""
    public var name: String = ""
    public var version: String = ""
    public var cjcVersion: String = ""
    public var description: String = ""
    public var artifactType: String = "src"
    public var executable: Bool = false
    public var authors: ArrayList<String> = ArrayList<String>()
    public var repository: String = ""
    public var homepage: String = ""
    public var documentation: String = ""
    public var tag: ArrayList<String> = ArrayList<String>()
    public var category: ArrayList<String> = ArrayList<String>()
    public var license: ArrayList<String> = ArrayList<String>()
    public var metaVersion: Int64 = 1       // meta-data 规格版本号（meta-version）
    public var indexJson: String = ""   // 完整 meta-data.json 原文（含嵌套 index 条目，原样保存，展示/提取用）

    // 服务端附加字段
    public var publisherId: Int64 = 0        // 发布者用户 ID
    public var downloadCount: Int64 = 0      // 下载计数
    public var upstreamId: Int64 = 0         // 来源上游 ID（回源落库）
    public var upstreamName: String = ""     // 来源上游名
    public var readme: String = ""           // 提取的 README（可选）
    public var sha256: String = ""           // 制品 SHA-256（独立列，发布校验值 / 索引 sha256sum）
    public var tarballSize: Int64 = 0        // 制品字节数（回源缓存为 0，发布为实际大小）
    public var deletedAt: Int64 = 0          // 软删除时间戳（0 = 未删除）
    public var createdAt: Int64 = 0
    public var updatedAt: Int64 = 0
}

// 包存储服务（基于 bstorm Storm）
public class PackageStore {
    public var storm: Storm
    public var nextId: Int64

    public init(storm: Storm) {
        this.storm = storm
        this.nextId = 1
        this.storm.reindex<PackageDoc>()
        recoverNextId()
    }

    // 从已有包恢复最大 id（跨进程复用数据目录时避免 id 冲突）
    public func recoverNextId(): Unit {
        var maxId: Int64 = 0
        for (d in this.storm.all<PackageDoc>()) {
            if (d.id >= maxId) {
                maxId = d.id
            }
        }
        if (maxId >= this.nextId) {
            this.nextId = maxId + 1
        }
    }

    // 保存；id==0 时自动分配递增 id（bstorm @Id 不自动生成，需业务层分配）
    public func save(doc: PackageDoc): Unit {
        if (doc.id == 0) {
            doc.id = this.nextId
            this.nextId++
        }
        this.storm.save(doc)
    }

    public func getById(id: Int64): ?PackageDoc {
        this.storm.get<PackageDoc>(id)
    }

    public func delete(doc: PackageDoc): Unit {
        this.storm.delete(doc)
    }

    // 按名称找所有版本（含软删）
    public func listVersions(org: String, name: String): ArrayList<PackageDoc> {
        let result = ArrayList<PackageDoc>()
        for (d in this.storm.all<PackageDoc>()) {
            if (d.name == name && d.organization == org) {
                result.add(d)
            }
        }
        return result
    }

    // 下载计数 +1
    public func incrDownload(doc: PackageDoc): Unit {
        doc.downloadCount++
        this.storm.save(doc)
    }

    // 软删除（记录 deletedAt）
    public func softDelete(doc: PackageDoc, now: Int64): Unit {
        doc.deletedAt = now
        this.storm.save(doc)
    }

    public func restore(doc: PackageDoc): Unit {
        doc.deletedAt = 0
        this.storm.save(doc)
    }
}
