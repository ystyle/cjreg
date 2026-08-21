// 代理回源（多仓核心）：本地未命中 → 按优先级回源上游 → 缓存
// 对齐 cjrepo FetchAndSavePackage / FetchIndex；多上游按 priority 遍历
package ystyle::cjreg.server

import ystyle::cjreg.protocol.*
import ystyle::cjreg.index.*
import ystyle::cjreg.config.*
import ystyle::cjreg.store.*
import stdx.net.http.*
import stdx.net.tls.*
import stdx.net.tls.common.*
import stdx.encoding.url.URL
import std.collection.*
import std.io.*

// 回源结果
public enum ProxyOutcome {
    | HitLocal       // 本地命中
    | FetchedFromUpstream  // 上游回源成功
    | NotFound       // 本地与所有上游都未命中
    | UpstreamError  // 上游全部失败

    public operator func ==(other: ProxyOutcome): Bool {
        match (this) {
            case ProxyOutcome.HitLocal => match (other) {
                case ProxyOutcome.HitLocal => true
                case _ => false
            }
            case ProxyOutcome.FetchedFromUpstream => match (other) {
                case ProxyOutcome.FetchedFromUpstream => true
                case _ => false
            }
            case ProxyOutcome.NotFound => match (other) {
                case ProxyOutcome.NotFound => true
                case _ => false
            }
            case ProxyOutcome.UpstreamError => match (other) {
                case ProxyOutcome.UpstreamError => true
                case _ => false
            }
        }
    }
}

// 制品字节存储接口（blob 内容寻址；M4 先内存/后续落盘）
public interface BlobStore {
    func put(sha256: String, data: Array<Byte>): Unit
    func get(sha256: String): ?Array<Byte>
}

public class MemoryBlobStore <: BlobStore {
    public var blobs: HashMap<String, Array<Byte>>

    public init() {
        this.blobs = HashMap<String, Array<Byte>>()
    }

    public func put(sha256: String, data: Array<Byte>): Unit {
        this.blobs.add(sha256, data)
    }

    public func get(sha256: String): ?Array<Byte> {
        if (this.blobs.contains(sha256)) {
            return Some(this.blobs.get(sha256).getOrThrow())
        }
        return None
    }
}

// 代理服务：按优先级多上游回源
public class ProxyService {
    public var pkgStore: PackageStore
    public var blobStore: BlobStore
    public var upstreamSvc: UpstreamService

    public init(pkgStore: PackageStore, blobStore: BlobStore, upstreamSvc: UpstreamService) {
        this.pkgStore = pkgStore
        this.blobStore = blobStore
        this.upstreamSvc = upstreamSvc
    }

    // 取索引：本地有版本 → 返回；否则按优先级回源上游，命中即缓存索引条目到本地
    // 返回 (outcome, ndjson)
    public func fetchIndex(org: String, name: String): (ProxyOutcome, String) {
        // 1. 本地
        let local = this.pkgStore.listVersions(org, name)
        if (local.size > 0) {
            // 有未删除版本即认为本地有
            var hasLive = false
            for (d in local) {
                if (d.deletedAt == 0) {
                    hasLive = true
                    break
                }
            }
            if (hasLive) {
                return (ProxyOutcome.HitLocal, generateLocalIndex(org, name))
            }
        }
        // 2. 回源上游（priority 顺序）
        let ups = this.upstreamSvc.enabledSorted()
        for (up in ups) {
            let url = buildIndexURL(up.url, name, org)
            if (url.isEmpty()) {
                continue
            }
            let body = httpGet(url, up.authToken)
            if (body.isNone()) {
                continue
            }
            let ndjson = String.fromUtf8(body.getOrThrow())
            if (ndjson.isEmpty()) {
                continue
            }
            // 回源命中 → 缓存索引条目到本地 pkg 集合（后续发布计划/本地命中用）
            cacheIndexEntries(org, name, ndjson, up)
            return (ProxyOutcome.FetchedFromUpstream, ndjson)
        }
        return (ProxyOutcome.NotFound, "")
    }

    // 取制品：本地 blob 有 → 返回；否则回源
    public func fetchArtifact(org: String, name: String, version: String): (ProxyOutcome, ?Array<Byte>, String) {
        // 本地 blob 查询（通过本地包的 sha）
        let versions = this.pkgStore.listVersions(org, name)
        for (d in versions) {
            if (d.version == version && d.deletedAt == 0) {
                let sha = extractSha256(d.indexJson)
                if (!sha.isEmpty()) {
                    let blob = this.blobStore.get(sha)
                    if (blob.isSome()) {
                        return (ProxyOutcome.HitLocal, blob, sha)
                    }
                }
            }
        }
        // 回源
        let ups = this.upstreamSvc.enabledSorted()
        for (up in ups) {
            let url = buildPackageURL(up.url, name, version, org)
            let body = httpGet(url, up.authToken)
            if (body.isNone()) {
                continue
            }
            let bytes = body.getOrThrow()
            let sha = sha256Hex(bytes)
            this.blobStore.put(sha, bytes)
            return (ProxyOutcome.FetchedFromUpstream, Some(bytes), sha)
        }
        return (ProxyOutcome.NotFound, None, "")
    }

    // 本地索引生成（复用 index_service 逻辑）
    public func generateLocalIndex(org: String, name: String): String {
        let svc = IndexService(this.pkgStore)
        return svc.generate(org, name, false)
    }

    // 把上游 NDJSON 索引条目缓存到本地 pkg 集合（记录 upstream 来源）
    public func cacheIndexEntries(org: String, name: String, ndjson: String, up: Upstream): Unit {
        let entries = parseNDJSON(ndjson)
        for (e in entries) {
            // 已存在的版本跳过（不覆盖本地发布）
            let existing = this.pkgStore.listVersions(e.organization, e.name)
            var dup = false
            for (d in existing) {
                if (d.version == e.version) {
                    dup = true
                    break
                }
            }
            if (dup) {
                continue
            }
            let doc = PackageDoc()
            doc.organization = e.organization
            doc.name = e.name
            doc.version = e.version
            doc.upstreamId = up.id
            doc.upstreamName = up.name
            // 每个 doc 只存对应版本的单行索引（避免多行取 [0] 导致重复）
            doc.indexJson = generateNDJSON(ArrayList<PackageIndex>([e]))
            this.pkgStore.save(doc)
        }
    }
}

// 从 indexJson 提取 sha256sum（发布时存的完整 meta 里有）
public func extractSha256(indexJson: String): String {
    let entries = parseNDJSON(indexJson)
    if (entries.size == 0) {
        return ""
    }
    return entries[0].sha256sum
}

// HTTP GET（stdx.net.http，对齐 cjdep registry.cj 验证过的模式）
// 手动跟随重定向（官方制品 URL 会 302 到存储）
public func httpGet(url: String, token: String): ?Array<Byte> {
    var currentUrl = url
    var hops: Int64 = 0
    while (hops < 5) {
        let client = buildHttpClient(currentUrl)
        try {
            let resp = client.get(currentUrl)
            if (resp.status == HttpStatusCode.STATUS_OK) {
                // 循环读 InputStream（制品是二进制，不能用 StringReader）
                let bytes = readStreamToBytes(resp.body)
                client.close()
                return Some(bytes)
            }
            if (resp.status == HttpStatusCode.STATUS_MOVED_PERMANENTLY ||
                resp.status == HttpStatusCode.STATUS_FOUND ||
                resp.status == HttpStatusCode.STATUS_TEMPORARY_REDIRECT) {
                // 跟随重定向
                let loc = resp.headers.getFirst("location")
                client.close()
                if (loc.isSome() && !loc.getOrThrow().isEmpty()) {
                    currentUrl = loc.getOrThrow()
                    hops++
                    continue
                }
                return None
            }
            client.close()
            return None
        } catch (e: Exception) {
            try {
                client.close()
            } catch (e2: Exception) {
                ()
            }
            return None
        }
    }
    return None
}

public func buildHttpClient(url: String): Client {
    let cb = ClientBuilder()
    cb.readTimeout(Duration.minute)
    if (url.startsWith("https")) {
        var tls = TlsClientConfig()
        tls.verifyMode = CertificateVerifyMode.TrustAll
        cb.tlsConfig(tls)
    }
    return cb.build()
}

// 循环读 InputStream 到字节数组（InputStream 非 Seekable，不能用 readToEnd）
public func readStreamToBytes(stream: InputStream): Array<Byte> {
    let buf = ByteBuffer()
    var chunk = Array<Byte>(8192, repeat: 0)
    while (true) {
        let n = stream.read(chunk)
        if (n <= 0) {
            break
        }
        buf.write(chunk[0..n])
    }
    readToEnd(buf)
}
