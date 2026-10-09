// 代理回源 · 制品域：本地 blob 命中 → 回源抓取（流式落 blob / 整包两条路径），
// 以及 Range 分块取段与 Content-Range 总长解析
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
import std.convert.*

extend ProxyService {
    // 取制品：本地 blob 有 → 返回；否则回源
    // 纯取字节（展示字段补齐由调用方决定：下载路由 / admin sync-metadata 各做一次，避免重复解压）
    // 流式版：返回值里不再携带整包字节。本地命中直接给出 blob 流；
    // 回源路径仍需先把制品落成 blob（回源客户端本身是整体读取，见 fetchBytes），
    // 但**不再把字节交给调用方**，响应侧只拿流。
    // 回源下载一个制品并落成 blob：按 **Range 分块**取，边收边算 SHA-256 并写临时文件，
    // 最后交给 BlobStore 原子认领。上游忽略 Range（回 200 整包）时退化为一次性读取；
    // 任何失败都清理临时文件。返回 (sha256, 字节数)；失败返回 None。
    //
    // ⚠️ 实测结论（2026-10-08）：**分块并不能解决大制品回源的内存问题**。
    // 上游 HTTP/1.1 客户端对 206 响应同样按 `Content-Range` 里声明的**总长**分配缓冲，
    // 而非本块的实际长度 —— 实测 128 MiB 制品：桩上游只收到 1 个分块请求（预期 16 个）
    // 即触发 GC 堆上限。因此本函数目前对超大制品仍会失败。
    // 保留它的理由：分块逻辑本身是正确的（含重定向透传 Range、Content-Range 解析、
    // 忽略 Range 时退化），一旦客户端侧的缓冲行为改变或换成自实现的 HTTP 读取，
    // 这里就是可用的收口点；同时它对"上游本身按块响应"的场景是正确的实现。
    public func fetchArtifactToBlob(url: String, token: String): ?(String, Int64) {
        let blockSize: Int64 = 8 * 1024 * 1024
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
        var total: Int64 = -1
        var failed = false
        while (true) {
            var to = size + blockSize - 1
            if (total > 0 && to > total - 1) {
                to = total - 1
            }
            let segOpt = httpGetRangeWithStatus(url, token, size, to)
            if (segOpt.isNone()) {
                failed = true
                break
            }
            let (code, contentRange, stream) = segOpt.getOrThrow()
            var wholeBody = false
            if (code == 206) {
                if (total < 0) {
                    total = totalFromContentRange(contentRange)
                }
            } else {
                wholeBody = true  // 上游不支持 Range：这一份就是整包
            }
            var segSize: Int64 = 0
            try {
                while (true) {
                    let n = stream.read(buf)
                    if (n <= 0) {
                        break
                    }
                    segSize += n
                    size += n
                    if (size > MAX_FILE_SIZE) {
                        failed = true
                        break
                    }
                    sha.write(buf[0..n])
                    f.write(buf[0..n])
                }
            } catch (e: Exception) {
                println("[cjreg] 回源分块落盘失败 ${url}: ${e.toString()}")
                failed = true
            }
            if (failed) {
                break
            }
            if (wholeBody) {
                break  // 整包已读完
            }
            if (segSize == 0) {
                failed = true  // 没有进展：避免在异常上游上原地打转
                break
            }
            if (total > 0 && size >= total) {
                break
            }
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
}

// 带 Range 的 GET：分块回源用（每块响应很小，因此上游客户端"整包缓冲"不再是问题）
func buildGetRangeRequest(url: String, token: String, from: Int64, to: Int64): HttpRequest {
    var b = HttpRequestBuilder().get().url(url).header("Range", "bytes=${from}-${to}")
    if (!token.isEmpty()) {
        b = b.header("Authorization", token)
    }
    b.build()
}

// 取一段：返回 (状态码, Content-Range, 响应流)。重定向的每一跳都带 Range
// （302 后方法不变、Range 头同样适用，实测中心仓 → 华为云 mirror 的重定向链上有效）。
func httpGetRangeWithStatus(url: String, token: String, from: Int64, to: Int64): ?(Int64, String, InputStream) {
    var currentUrl = url
    var hops: Int64 = 0
    while (hops < 5) {
        let client = buildHttpClient(currentUrl)
        try {
            let resp = client.send(buildGetRangeRequest(currentUrl, token, from, to))
            let code = Int64(resp.status)
            if (code == 200 || code == 206) {
                let cr = resp.headers.getFirst("content-range") ?? ""
                return Some((code, cr, HttpBodyStream(resp.body, client)))
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

// 从 "bytes 0-8191/123456" 里取总长；拿不到返回 -1（分块仍可继续，只是不知道终点）
func totalFromContentRange(cr: String): Int64 {
    match (cr.lastIndexOf("/")) {
        case Some(i) =>
            let tail = cr[(i + 1)..]
            if (tail.isEmpty() || tail == "*") {
                return -1
            }
            try {
                return Int64.parse(tail.trimAscii())
            } catch (e: Exception) {
                return -1
            }
        case None => return -1
    }
}
