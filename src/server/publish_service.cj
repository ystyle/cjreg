// 发布核心业务：解析官方二进制 → 校验 meta 与 URL 一致 → sha256 校验制品 → 入库
// 纯逻辑（不依赖 HTTP），可单测；tang handler 为薄壳
package ystyle::cjreg.server

import ystyle::cjreg.protocol.*
import ystyle::cjreg.index.*
import ystyle::cjreg.store.*
import stdx.crypto.digest.SHA256
import stdx.encoding.hex.toHexString
import stdx.encoding.json.stream.*
import std.io.*
import std.collection.*

// 发布结果
public enum PublishOutcome {
    | Ok             // 入库成功（新包/新版本/覆盖成功）
    | InvalidFormat  // 二进制格式非法
    | MetaMismatch   // meta 与 URL 的 name/org/version 不一致
    | ShaMismatch    // 制品 sha256 与 meta 不一致
    | Conflict       // 同版本已存在且 sha 不同（需 overwrite）
    | BadRequest     // 参数错误

    public operator func ==(other: PublishOutcome): Bool {
        match (this) {
            case PublishOutcome.Ok => match (other) {
                case PublishOutcome.Ok => true
                case _ => false
            }
            case PublishOutcome.InvalidFormat => match (other) {
                case PublishOutcome.InvalidFormat => true
                case _ => false
            }
            case PublishOutcome.MetaMismatch => match (other) {
                case PublishOutcome.MetaMismatch => true
                case _ => false
            }
            case PublishOutcome.ShaMismatch => match (other) {
                case PublishOutcome.ShaMismatch => true
                case _ => false
            }
            case PublishOutcome.Conflict => match (other) {
                case PublishOutcome.Conflict => true
                case _ => false
            }
            case PublishOutcome.BadRequest => match (other) {
                case PublishOutcome.BadRequest => true
                case _ => false
            }
        }
    }
}

public class PublishResult {
    public var outcome: PublishOutcome
    public var pkgId: Int64
    public var message: String

    public init(outcome: PublishOutcome, pkgId: Int64, message: String) {
        this.outcome = outcome
        this.pkgId = pkgId
        this.message = message
    }
}

// 制品 SHA-256（hex）
public func sha256Hex(data: Array<Byte>): String {
    let sha = SHA256()
    sha.write(data)
    toHexString(sha.finish())
}

// 发布服务（校验 + 入库 + 制品字节存 blob 供发布计划执行）
public class PublishService {
    public var store: PackageStore
    public var blobStore: BlobStore

    public init(store: PackageStore, blobStore: BlobStore) {
        this.store = store
        this.blobStore = blobStore
    }

    // 发布；urlOrg 为 URL 里的 organization 参数（可空）
    public func publish(urlOrg: String, urlName: String, body: Array<Byte>): PublishResult {
        if (urlName.isEmpty()) {
            return PublishResult(PublishOutcome.BadRequest, 0, "package name required")
        }
        // 1. 解析官方二进制
        let data = parsePublishData(body)
        if (data.isNone()) {
            return PublishResult(PublishOutcome.InvalidFormat, 0, "invalid publish data format")
        }
        let pd = data.getOrThrow()

        // 2. 解析 meta-data.json（取 name/org/version）
        let meta = parseMetaJson(pd.metaData)
        if (meta.isNone()) {
            return PublishResult(PublishOutcome.InvalidFormat, 0, "invalid meta-data.json")
        }
        let metaInfo = meta.getOrThrow()

        // 3. 校验 meta 与 URL 一致
        if (metaInfo.name != urlName || metaInfo.org != urlOrg) {
            return PublishResult(PublishOutcome.MetaMismatch, 0,
                "metadata mismatch: url(${urlOrg}::${urlName}) vs meta(${metaInfo.org}::${metaInfo.name})")
        }

        // 4. sha256 校验制品与 meta.index.sha256sum 一致
        let actualSha = sha256Hex(pd.tarball)
        if (!metaInfo.sha256sum.isEmpty() && actualSha != metaInfo.sha256sum) {
            return PublishResult(PublishOutcome.ShaMismatch, 0,
                "sha256 mismatch: meta=${metaInfo.sha256sum} actual=${actualSha}")
        }

        // 5. 查同版本是否已存在（冲突/覆盖判定）
        let versions = this.store.listVersions(metaInfo.org, metaInfo.name)
        for (d in versions) {
            if (d.version == metaInfo.version && d.deletedAt == 0) {
                if (d.indexJson.contains(metaInfo.sha256sum)) {
                    // 同 sha → 幂等（视为已存在，仍可覆盖写入）
                    return PublishResult(PublishOutcome.Ok, d.id, "already exists (same sha)")
                }
                return PublishResult(PublishOutcome.Conflict, d.id,
                    "version exists with different sha, need overwrite")
            }
        }

        // 6. 制品字节存 blob（sha256 寻址，供发布计划执行推送到目标上游）
        this.blobStore.put(actualSha, pd.tarball)

        // 7. 入库
        let doc = PackageDoc()
        doc.organization = metaInfo.org
        doc.name = metaInfo.name
        doc.version = metaInfo.version
        doc.indexJson = String.fromUtf8(pd.metaData)
        this.store.save(doc)
        return PublishResult(PublishOutcome.Ok, doc.id, "published")
    }
}

// meta-data.json 关键字段（发布校验用）
public class MetaInfo {
    public var org: String
    public var name: String
    public var version: String
    public var sha256sum: String

    public init(org: String, name: String, version: String, sha256sum: String) {
        this.org = org
        this.name = name
        this.version = version
        this.sha256sum = sha256sum
    }
}

// 从 meta-data.json 解析 name/org/version 与 index.sha256sum
// meta 顶层含 organization/name/version；sha256sum 在嵌套 index 对象内
public func parseMetaJson(metaBytes: Array<Byte>): ?MetaInfo {
    let body = String.fromUtf8(metaBytes)
    let bb = ByteBuffer()
    bb.write(body.toArray())
    let r = JsonReader(bb)
    var org = ""
    var name = ""
    var version = ""
    var sha = ""
    try {
        while (let Some(v) <- r.peek()) {
            match (v) {
                case BeginObject =>
                    r.startObject()
                    while (r.peek() != EndObject) {
                        let n = r.readName()
                        match (n) {
                            case "organization" => org = r.readValue<String>()
                            case "name" => name = r.readValue<String>()
                            case "version" => version = r.readValue<String>()
                            case "index" =>
                                // 进入嵌套 index 对象取 sha256sum
                                r.startObject()
                                while (r.peek() != EndObject) {
                                    let innerName = r.readName()
                                    if (innerName == "sha256sum") {
                                        sha = r.readValue<String>()
                                    } else {
                                        r.skip()
                                    }
                                }
                                r.endObject()
                            case _ => r.skip()
                        }
                    }
                    r.endObject()
                    return Some(MetaInfo(org, name, version, sha))
                case _ => r.skip()
            }
        }
        return None
    } catch (e: Exception) {
        return None
    }
}
