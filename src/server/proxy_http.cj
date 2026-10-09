// 代理回源 · HTTP 传输层：GET / 带状态码 GET / 流式 GET / POST 与请求构造、
// 响应体流包装（读完自动关连接）、客户端与字节读取工具
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
// ⚠️ 限制（依据上游实现）：`resp.body` 虽是 `InputStream`，但 HTTP/1.1 客户端把它包成
// `HttpNormalBody`，其构造函数就按 `contentLength` 分配数组并把连接读满 —— 之后 `read()`
// 只是从内存数组拷贝，因此拿不到"边收边给"。
// 实测：带 Content-Length 与 chunked（无长度）两种响应下，128 MiB 制品回源都触顶 GC 堆；
// 8 / 16 / 32 MiB 正常且线性。
// 本函数的价值：中小制品的峰值不再随制品线性增长，且把连接生命周期收进了流里。
// 要让回源也做到内存 O(1)，需要客户端侧的真流式读取，或改按 Range 分块回源。

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
