// 代理回源（多仓核心）：本地未命中 → 按优先级回源上游 → 缓存
// 对齐 cjrepo FetchAndSavePackage / FetchIndex；多上游按 priority 遍历
package ystyle::cjreg.server

import ystyle::cjreg.protocol.*
import ystyle::cjreg.index.*
import ystyle::cjreg.config.*
import ystyle::cjreg.store.*
import stdx.net.http.*
import stdx.crypto.digest.SHA256
import stdx.encoding.hex.toHexString
import stdx.net.tls.*
import stdx.net.tls.common.*
import stdx.encoding.url.URL
import std.collection.*
import std.io.*
import std.fs.*

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
    // 删除制品（硬删除时联动清理）；返回是否真的删掉了
    func remove(sha256: String): Bool
    // 制品是否存在（恢复时校验「tarball 仍在」）
    // 注意：不能叫 exists——DiskBlobStore 内部要用 std.fs.exists(path)，
    // 同名成员会让方法体里的 exists(...) 解析成自身递归（实测触发 Out of memory）
    func has(sha256: String): Bool
    // 原子认领一个已写好的临时文件为制品：目标已存在（内容寻址去重）则丢弃临时文件，
    // 否则 rename 进位 —— 先落临时文件再 rename，读者不会看到半成品。
    // 供**流式发布**使用：制品不再整包驻留内存。
    func claimFile(sha256: String, tmpPath: String): Unit
    // 流式读取制品：下载路径用它把字节直接接到 HTTP 响应，**不整包驻留内存**。
    // 返回 None 表示制品不存在。
    func stream(sha256: String): ?InputStream
}

// 把内存中的制品包装成 InputStream（内存 blob 模式用；磁盘模式直接返回 File 流）
class BytesStream <: InputStream {
    let data: Array<Byte>
    var pos: Int64 = 0

    init(data: Array<Byte>) {
        this.data = data
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (this.pos >= this.data.size) {
            return 0
        }
        var n = buffer.size
        let remain = this.data.size - this.pos
        if (n > remain) {
            n = remain
        }
        var i: Int64 = 0
        while (i < n) {
            buffer[i] = this.data[this.pos + i]
            i++
        }
        this.pos += n
        return n
    }
}

public class MemoryBlobStore <: BlobStore {
    public var blobs: HashMap<String, Array<Byte>>

    public init() {
        this.blobs = HashMap<String, Array<Byte>>()
    }

    public func put(sha256: String, data: Array<Byte>): Unit {
        this.blobs.add(sha256, data)
    }

    public func stream(sha256: String): ?InputStream {
        match (this.blobs.get(sha256)) {
            case Some(d) => Some(BytesStream(d))
            case None => None
        }
    }

    public func claimFile(sha256: String, tmpPath: String): Unit {
        // 内存实现只能把临时文件读回来（生产流式路径走 DiskBlobStore，不经过这里）
        try {
            let f = File(tmpPath, Read)
            let bytes = readToEnd(f)
            f.close()
            this.blobs.add(sha256, bytes)
            removeIfExists(tmpPath, recursive: false)
        } catch (e: Exception) {
            println("[blob] claimFile failed ${sha256}: ${e.message}")
        }
    }

    public func get(sha256: String): ?Array<Byte> {
        if (this.blobs.contains(sha256)) {
            return Some(this.blobs.get(sha256).getOrThrow())
        }
        return None
    }

    public func remove(sha256: String): Bool {
        if (this.blobs.contains(sha256)) {
            this.blobs.remove(sha256)
            return true
        }
        return false
    }

    public func has(sha256: String): Bool {
        this.blobs.contains(sha256)
    }
}

// 代理服务：按优先级多上游回源
public class ProxyService {
    public var pkgStore: PackageStore
    public var blobStore: BlobStore
    public var upstreamSvc: UpstreamService
    // 可注入的出网 GET（单测离线注入 stub；默认走真实 httpGet）
    public var httpFetch: ?(String, String) -> ?Array<Byte> = None

    // 流式回源的临时文件目录（必须与 blob 同目录，rename 才能原子进位）。
    // 留空则回源保持"整包读入"的旧行为（内存 blob 模式与不需要流式的测试场景）。
    public var tmpDir: String = ""

    public init(pkgStore: PackageStore, blobStore: BlobStore, upstreamSvc: UpstreamService,
                tmpDir!: String = "") {
        this.pkgStore = pkgStore
        this.blobStore = blobStore
        this.upstreamSvc = upstreamSvc
        this.tmpDir = tmpDir
    }

    // 出网 GET 的唯一出口：测试注入点 + 后续打点都集中在这里
    public func fetchBytes(url: String, token: String): ?Array<Byte> {
        match (this.httpFetch) {
            case Some(f) => f(url, token)
            case None => httpGet(url, token)
        }
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
        let ups = this.upstreamSvc.proxySorted()
        for (up in ups) {
            let url = buildIndexURL(up.url, name, org)
            if (url.isEmpty()) {
                continue
            }
            let body = this.fetchBytes(url, up.authToken)
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
    // 纯取字节（展示字段补齐由调用方决定：下载路由 / admin sync-metadata 各做一次，避免重复解压）
    // 流式版：返回值里不再携带整包字节。本地命中直接给出 blob 流；
    // 回源路径仍需先把制品落成 blob（回源客户端本身是整体读取，见 fetchBytes），
    // 但**不再把字节交给调用方**，响应侧只拿流。
    // 回源下载一个制品并落成 blob：按 1 MiB 分块读，同时喂 SHA-256 与临时文件，
    // 读满后交给 BlobStore 原子认领（内容寻址去重）。任何失败都清理临时文件。
    // 返回 (sha256, 字节数)；失败返回 None。
    // 内存上限受 httpGetStream 的限制（见其注释）：中小制品峰值可控，超大制品仍可能触顶堆。
    public func fetchArtifactToBlob(url: String, token: String): ?(String, Int64) {
        let streamOpt = httpGetStream(url, token)
        if (streamOpt.isNone()) {
            return None
        }
        let stream = streamOpt.getOrThrow()
        let tmp = this.tmpDir + "/.tmp-fetch-" + nowMsUtc().toString()
        var out: ?File = None
        try {
            out = Some(File(tmp, Write))
        } catch (e: Exception) {
            println("[cjreg] 回源临时文件创建失败 ${tmp}: ${e.toString()}")
            return None
        }
        let f = out.getOrThrow()
        let sha = SHA256()
        let buf = Array<Byte>(1024 * 1024, repeat: 0)
        var size: Int64 = 0
        var failed = false
        try {
            while (true) {
                let n = stream.read(buf)
                if (n <= 0) {
                    break
                }
                size += n
                if (size > MAX_FILE_SIZE) {
                    failed = true
                    break
                }
                sha.write(buf[0..n])
                f.write(buf[0..n])
            }
        } catch (e: Exception) {
            println("[cjreg] 回源流式落盘失败 ${url}: ${e.toString()}")
            failed = true
        }
        try {
            f.close()
        } catch (e: Exception) {
            failed = true
        }
        if (failed || size <= 0) {
            try {
                removeIfExists(tmp, recursive: false)
            } catch (e: Exception) {
                ()
            }
            return None
        }
        let hex = toHexString(sha.finish())
        this.blobStore.claimFile(hex, tmp)
        return Some((hex, size))
    }

    public func fetchArtifactStream(org: String, name: String, version: String): (ProxyOutcome, ?InputStream, String) {
        let versions = this.pkgStore.listVersions(org, name)
        for (d in versions) {
            if (d.version == version && d.deletedAt == 0) {
                var sha = d.sha256
                if (sha.isEmpty()) {
                    sha = extractSha256(d.indexJson)
                }
                if (!sha.isEmpty()) {
                    match (this.blobStore.stream(sha)) {
                        case Some(st) => return (ProxyOutcome.HitLocal, Some(st), sha)
                        case None => ()
                    }
                }
            }
        }
        let ups = this.upstreamSvc.proxySorted()
        for (up in ups) {
            let url = buildPackageURL(up.url, name, version, org)
            if (!this.tmpDir.isEmpty()) {
                // 流式：边读边算 sha256 并落临时文件，内存与制品大小无关
                match (this.fetchArtifactToBlob(url, up.authToken)) {
                    case Some((sha, _)) =>
                        match (this.blobStore.stream(sha)) {
                            case Some(st) => return (ProxyOutcome.FetchedFromUpstream, Some(st), sha)
                            case None => return (ProxyOutcome.FetchedFromUpstream, None, sha)
                        }
                    case None => continue
                }
            }
            let body = this.fetchBytes(url, up.authToken)
            if (body.isNone()) {
                continue
            }
            let bytes = body.getOrThrow()
            let sha = sha256Hex(bytes)
            this.blobStore.put(sha, bytes)
            match (this.blobStore.stream(sha)) {
                case Some(st) => return (ProxyOutcome.FetchedFromUpstream, Some(st), sha)
                case None => return (ProxyOutcome.FetchedFromUpstream, None, sha)
            }
        }
        return (ProxyOutcome.NotFound, None, "")
    }

    public func fetchArtifact(org: String, name: String, version: String): (ProxyOutcome, ?Array<Byte>, String) {
        // 本地 blob 查询（通过本地包的 sha）
        let versions = this.pkgStore.listVersions(org, name)
        for (d in versions) {
            if (d.version == version && d.deletedAt == 0) {
                // sha256 是独立列（发布校验值 / 索引 sha256sum），优先用它；
                // 老文档可能只有 indexJson，退回从索引条目里取
                var sha = d.sha256
                if (sha.isEmpty()) {
                    sha = extractSha256(d.indexJson)
                }
                if (!sha.isEmpty()) {
                    let blob = this.blobStore.get(sha)
                    if (blob.isSome()) {
                        return (ProxyOutcome.HitLocal, blob, sha)
                    }
                }
            }
        }
        // 回源
        let ups = this.upstreamSvc.proxySorted()
        for (up in ups) {
            let url = buildPackageURL(up.url, name, version, org)
            let body = this.fetchBytes(url, up.authToken)
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

    // 直接从**指定上游**取索引（不查本地）：重拉需要上游的权威 sha256sum
    // （fetchIndex 本地有版本时会直接返回本地索引，拿不到上游口径）
    public func fetchUpstreamIndex(up: Upstream, org: String, name: String): ?String {
        let url = buildIndexURL(up.url, name, org)
        if (url.isEmpty()) {
            return None
        }
        match (this.fetchBytes(url, up.authToken)) {
            case Some(b) =>
                let ndjson = String.fromUtf8(b)
                if (ndjson.isEmpty()) {
                    None
                } else {
                    Some(ndjson)
                }
            case None => None
        }
    }

    // 探测上游索引（带状态码）——发布计划「等索引就绪」「检查索引」都走这里。
    //
    // 与 fetchUpstreamIndex 的区别：**不把失败折成一个 None**。
    //   200 + 正文      → 目标仓的索引（里面没有该版本 = 还没同步到）
    //   404             → 目标仓没有这个包（"查过了，确实没有"，与"没问到"不是一回事）
    //   401/403/429/5xx → 探测本身失败，再等也不会变好
    //   0               → 传输层失败（DNS/TLS/超时/连接被拒）
    public func probeUpstreamIndex(up: Upstream, org: String, name: String): IndexProbe {
        let url = buildIndexURL(up.url, name, org)
        if (url.isEmpty()) {
            return IndexProbe(400, "", detail: "索引 URL 构造失败（包名不合法）")
        }
        match (this.httpFetch) {
            case Some(f) =>
                // 离线注入点只给 body：有 body 视作 200、没有视作 404（单测用）
                match (f(url, up.authToken)) {
                    case Some(b) => IndexProbe(200, String.fromUtf8(b))
                    case None => IndexProbe(404, "")
                }
            case None =>
                let r = httpGetWithStatus(url, up.authToken)
                IndexProbe(r.status, String.fromUtf8(r.body), detail: r.error)
        }
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
            // index 条目含 cjc-version/sha256sum（展示字段不在索引协议内，保持空）
            doc.cjcVersion = e.cjcVersion
            doc.sha256 = e.sha256sum
            doc.upstreamId = up.id
            doc.upstreamName = up.name
            // 本仓收录时间：索引协议不含任何时间字段（上游发布时间拿不到），
            // 所以公开页只能显示「本仓收录于 …」；不写就是 0 → 页面全「未知」
            let now = nowMsUtc()
            doc.createdAt = now
            doc.updatedAt = now
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
            let resp = client.send(buildGetRequest(currentUrl, token))
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
            // 传输层失败（DNS/TLS/超时/连接被拒）此前被完全吞掉，调用方只看到 None，
            // 于是「上游不可达」被静默降级成「包不存在」（ProxyOutcome.UpstreamError 从未被返回）。
            println("[cjreg] 回源 GET 失败 " + currentUrl + ": " + e.toString())
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

// 带状态码的 GET 结果：`status = 0` 表示传输层失败（DNS/TLS/超时/连接被拒）。
public class HttpGetOutcome {
    public var status: Int64 = 0
    public var body: Array<Byte> = Array<Byte>()
    public var error: String = ""

    public init() {}
}

// 带状态码的 GET（索引探测专用）。
//
// 为什么不复用 httpGet：它把所有非 200 都折成 None，于是「404 目标仓还没有这个版本」与
// 「401/429/5xx 根本没问到」在调用方眼里一模一样 —— 前者要继续等，后者再等也不会变好。
// 正文也一并带出来：官方 400/401/429 的原因写在正文里。
// 把 HTTP 响应体包成"读完自动关连接"的流：调用方（下载 handler / 回源落盘）只看见 InputStream，
// 不必知道底下有个需要关闭的客户端。读尽或出错时关闭，避免连接泄漏。
class HttpBodyStream <: InputStream {
    let inner: InputStream
    let client: Client
    var closed: Bool = false

    init(inner: InputStream, client: Client) {
        this.inner = inner
        this.client = client
    }

    func closeOnce(): Unit {
        if (this.closed) {
            return
        }
        this.closed = true
        try {
            this.client.close()
        } catch (e: Exception) {
            ()  // 关闭失败不影响已读内容
        }
    }

    public func read(buffer: Array<Byte>): Int64 {
        try {
            let n = this.inner.read(buffer)
            if (n <= 0) {
                this.closeOnce()
            }
            return n
        } catch (e: Exception) {
            this.closeOnce()
            throw e
        }
    }
}

// 取响应体供调用方分块读取（重定向口径与 httpGetWithStatus 一致，最多 5 跳）。
// 调用方按需读取；读尽时底层客户端自动关闭。
//
// ⚠️ 限制：上游客户端在 `send` 阶段就会把响应体收下来，这里拿到的并不是真正的网络流，
// 因此**超大制品仍会顶到 GC 堆上限**（实测 64 MiB 以上回源 OOM，8–32 MiB 正常且线性）。
// 要让回源也做到内存 O(1)，需要客户端侧的流式读取能力，或改按 Range 分块回源。
// 本函数的价值在于：中小制品的峰值不再与制品大小线性相关，且把连接生命周期收进流里。
public func httpGetStream(url: String, token: String): ?InputStream {
    var currentUrl = url
    var hops: Int64 = 0
    while (hops < 5) {
        let client = buildHttpClient(currentUrl)
        try {
            let resp = client.send(buildGetRequest(currentUrl, token))
            let code = Int64(resp.status)
            if (code == 200) {
                return Some(HttpBodyStream(resp.body, client))
            }
            if (code == 301 || code == 302 || code == 307) {
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

public func httpGetWithStatus(url: String, token: String): HttpGetOutcome {
    let out = HttpGetOutcome()
    var currentUrl = url
    var hops: Int64 = 0
    while (hops < 5) {
        let client = buildHttpClient(currentUrl)
        try {
            let resp = client.send(buildGetRequest(currentUrl, token))
            let code = Int64(resp.status)
            if (code == 200) {
                out.status = 200
                out.body = readStreamToBytes(resp.body)
                client.close()
                return out
            }
            if (code == 301 || code == 302 || code == 307) {
                let loc = resp.headers.getFirst("location")
                client.close()
                if (loc.isSome() && !loc.getOrThrow().isEmpty()) {
                    currentUrl = loc.getOrThrow()
                    hops++
                    continue
                }
                out.status = code
                return out
            }
            out.status = code
            try {
                out.body = readStreamToBytes(resp.body)
            } catch (e2: Exception) {
                ()
            }
            client.close()
            return out
        } catch (e: Exception) {
            out.status = 0
            out.error = e.toString()
            println("[cjreg] 索引探测 GET 失败 " + currentUrl + ": " + e.toString())
            try {
                client.close()
            } catch (e2: Exception) {
                ()
            }
            return out
        }
    }
    out.status = 0
    out.error = "重定向次数过多"
    out
}

public func buildHttpClient(url: String): Client {
    let cb = ClientBuilder()
    cb.readTimeout(Duration.second * 15)
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

// HTTP POST 官方发布二进制（发布计划执行：推送包到目标上游）
// 返回 (是否成功, 状态码, 响应正文——截断 300 字符)
//
// 正文必须带出来：官方仓的失败原因写在正文里（429「每日请求频率超限」、
// 409「制品冲突」等），只回状态码的话上层只能写「HTTP 429」，排障看不到为什么。
public func httpPostBinary(url: String, body: Array<Byte>, token: String): (Bool, Int64, String) {
    let client = buildHttpClient(url)
    try {
        // 目标仓（官方中心仓 / 另一个私有仓）按官方规格校验 Authorization: {token}
        // ——此前这里漏带头，向需认证的目标仓推送必然 401
        let resp = client.send(buildPostRequest(url, body, token))
        let code = Int64(resp.status)
        var text = ""
        try {
            text = String.fromUtf8(readStreamToBytes(resp.body))
            if (text.size > 300) {
                text = text[..300] + "..."
            }
        } catch (e: Exception) {
            text = ""
        }
        client.close()
        return (code >= 200 && code < 300, code, text)
    } catch (e: Exception) {
        // 此前只回 (false, 0)，上层把它渲染成「推送失败 HTTP 0」——状态码 0 不是真实
        // HTTP 码，真正的失败原因（TLS/超时/连接被拒）全被吞掉，无法定位。
        println("[cjreg] 推送 POST 失败 " + url + ": " + e.toString())
        try {
            client.close()
        } catch (e2: Exception) {
            ()
        }
        return (false, 0, e.toString())
    }
}

// GET 请求构造：token 非空时带 Authorization（裸 token，对齐官方规格与 Go 先行版）
func buildGetRequest(url: String, token: String): HttpRequest {
    var b = HttpRequestBuilder().get().url(url)
    if (!token.isEmpty()) {
        b = b.header("Authorization", token)
    }
    b.build()
}

// POST 请求构造：同上
func buildPostRequest(url: String, body: Array<Byte>, token: String): HttpRequest {
    var b = HttpRequestBuilder().post().url(url)
    if (!token.isEmpty()) {
        b = b.header("Authorization", token)
    }
    b.body(body).build()
}

// 磁盘制品存储（持久化到 dataDir/blobs/{sha256}）
public class DiskBlobStore <: BlobStore {
    public var dir: String

    public init(dir: String) {
        this.dir = dir
        if (exists(dir)) {
            return
        }
        try {
            Directory.create(dir, recursive: true)
        } catch (e: Exception) {
            // 竞态下别的进程刚建好 → 不算失败；真建不出来（权限/磁盘满）才报 —— 这是持久化路径的
            // 起点，静默会让后续每次 put 各自报错、丢掉根因。
            if (!exists(dir)) {
                println("[cjreg] 制品目录创建失败 " + dir + ": " + e.toString())
            }
        }
    }

    public func put(sha256: String, data: Array<Byte>): Unit {
        try {
            let f = File(dir + "/" + sha256, Write)
            f.write(data)
            f.close()
        } catch (e: Exception) {
            println("[blob] put failed ${sha256}: ${e.message}")
        }
    }

    public func stream(sha256: String): ?InputStream {
        let path = dir + "/" + sha256
        if (!exists(path)) {
            return None
        }
        try {
            return Some(File(path, Read))
        } catch (e: Exception) {
            println("[cjreg] 制品流式打开失败 " + path + ": " + e.toString())
            return None
        }
    }

    public func claimFile(sha256: String, tmpPath: String): Unit {
        let target = dir + "/" + sha256
        try {
            if (exists(target)) {
                removeIfExists(tmpPath, recursive: false)  // 内容寻址天然幂等：同一制品已在盘上
                return
            }
            rename(tmpPath, to: target)  // 原子进位
        } catch (e: Exception) {
            println("[blob] claimFile failed ${sha256}: ${e.message}")
        }
    }

    public func get(sha256: String): ?Array<Byte> {
        let path = dir + "/" + sha256
        if (!exists(path)) {
            return None
        }
        try {
            let f = File(path, Read)
            let bytes = readToEnd(f)
            f.close()
            return Some(bytes)
        } catch (e: Exception) {
            // 制品在盘上但读失败（被截断/权限/IO 错）此前被当成「制品不存在」，
            // 上层据此报「制品缺失（sha=…）」——把 IO 故障误报成数据丢失。
            println("[cjreg] 制品读取失败 " + path + ": " + e.toString())
            return None
        }
    }

    public func remove(sha256: String): Bool {
        let path = dir + "/" + sha256
        if (!exists(path)) {
            return false
        }
        try {
            removeIfExists(path, recursive: false)
            return true
        } catch (e: Exception) {
            println("[blob] remove failed ${sha256}: ${e.message}")
            return false
        }
    }

    public func has(sha256: String): Bool {
        exists(dir + "/" + sha256)
    }
}
