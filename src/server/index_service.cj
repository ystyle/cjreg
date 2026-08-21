// 索引/下载核心业务（纯逻辑可单测）
package ystyle::cjreg.server

import ystyle::cjreg.index.*
import ystyle::cjreg.store.*
import std.collection.*

// 索引生成服务：从包存储生成 NDJSON 索引
public class IndexService {
    public var store: PackageStore

    public init(store: PackageStore) {
        this.store = store
    }

    // 生成指定包的全部版本索引（含软删？默认不含；org 为空=无组织包）
    public func generate(org: String, name: String, includeDeleted: Bool): String {
        let indexes = ArrayList<PackageIndex>()
        for (d in this.store.listVersions(org, name)) {
            if (!includeDeleted && d.deletedAt != 0) {
                continue
            }
            let idx = packageDocToIndex(d)
            if (idx.isSome()) {
                indexes.add(idx.getOrThrow())
            }
        }
        return generateNDJSON(indexes)
    }

    // 从包文档还原索引条目（indexJson 已保存 meta 的 index 内容）
    public func packageDocToIndex(d: PackageDoc): ?PackageIndex {
        let indexes = parseNDJSON(d.indexJson)
        if (indexes.size == 0) {
            return None
        }
        return Some(indexes[0])
    }
}

// 下载服务：查版本 + 计数
public class DownloadService {
    public var store: PackageStore

    public init(store: PackageStore) {
        this.store = store
    }

    // 返回 (包文档, 制品字节)；制品字节由 blob 存储提供（M2 先用占位，M3 接内容寻址）
    public func find(org: String, name: String, version: String): ?PackageDoc {
        for (d in this.store.listVersions(org, name)) {
            if (d.version == version && d.deletedAt == 0) {
                this.store.incrDownload(d)
                return Some(d)
            }
        }
        return None
    }
}
