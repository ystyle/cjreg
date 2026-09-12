// 上游连通性测试（POST /api/admin/upstreams/:id/test）
//
// 设计：
//   - 指定 `name`（≥3 字符）→ 请求该上游的 NDJSON 索引端点 `/index/{mo}/{du}/{name}`：
//     200 且正文非空 = 连通且能取到索引；404 = 连通但该包不存在（仍算连通，error 记说明）
//   - 未指定 `name` → 请求上游基地址（只要拿到 HTTP 响应即连通）
//   - 目标上游 enabled=false 时照测（诊断用），但结果里标注 enabled
// 纯逻辑函数（probeUpstream）不依赖 HTTP handler → 可直接单测；网络细节在 httpProbe 里。
package ystyle::cjreg.server

import ystyle::cjreg.protocol.*
import ystyle::cjreg.config.*
import ystyle::cjreg.store.*
import stdx.net.http.*
import std.collection.*
import std.time.*

// 探测结果（JSON 由 upstreamProbeJson 输出）
public struct UpstreamProbeResult {
    public let upstreamId: Int64
    public let upstreamName: String
    public let baseUrl: String          // 上游登记的地址
    public let testedUrl: String        // 实际请求地址
    public let enabled: Bool
    public let reachable: Bool          // 拿到 HTTP 响应（含 4xx/5xx）
    public let healthy: Bool            // 200 且（未指定包 || 正文非空）
    public let status: Int64            // HTTP 状态码（0 = 未拿到响应）
    public let latencyMs: Int64
    public let bodyBytes: Int64
    public let authUsed: Bool
    public let packages: ArrayList<String>  // 索引正文里扫到的包名样本（最多 5 个）
    public let error: String

    public init(upstreamId: Int64, upstreamName: String, baseUrl: String, testedUrl: String, enabled: Bool,
                reachable: Bool, healthy: Bool, status: Int64, latencyMs: Int64, bodyBytes: Int64,
                authUsed: Bool, packages: ArrayList<String>, error: String) {
        this.upstreamId = upstreamId
        this.upstreamName = upstreamName
        this.baseUrl = baseUrl
        this.testedUrl = testedUrl
        this.enabled = enabled
        this.reachable = reachable
        this.healthy = healthy
        this.status = status
        this.latencyMs = latencyMs
        this.bodyBytes = bodyBytes
        this.authUsed = authUsed
        this.packages = packages
        this.error = error
    }
}

/// 探测摘要文案（管理端/CLI 展示：连通 / 不通 + 耗时 + 状态码）
public func probeSummary(r: UpstreamProbeResult): String {
    if (!r.reachable) {
        return "不可达：${r.error}"
    }
    if (r.healthy) {
        return "连通（${r.status}，${r.latencyMs}ms，${r.bodyBytes} 字节）"
    }
    let tail = if (r.error.isEmpty()) { "" } else { "：${r.error}" }
    "已连通但不可用（${r.status}，${r.latencyMs}ms）${tail}"
}

public func upstreamProbeJson(r: UpstreamProbeResult): String {
    let sb = StringBuilder()
    sb.append("{\"upstreamId\":${r.upstreamId},\"upstreamName\":\"${escapeJsonStr(r.upstreamName)}\",")
    sb.append("\"baseUrl\":\"${escapeJsonStr(r.baseUrl)}\",\"testedUrl\":\"${escapeJsonStr(r.testedUrl)}\",")
    sb.append("\"enabled\":${r.enabled},\"reachable\":${r.reachable},\"healthy\":${r.healthy},")
    sb.append("\"status\":${r.status},\"latencyMs\":${r.latencyMs},\"bodyBytes\":${r.bodyBytes},")
    sb.append("\"authUsed\":${r.authUsed},\"packages\":${jsonStringArray(r.packages)},")
    sb.append("\"error\":\"${escapeJsonStr(r.error)}\",")
    sb.append("\"summary\":\"${escapeJsonStr(probeSummary(r))}\"}")
    sb.toString()
}

/// 索引正文（NDJSON）里扫出包名样本：取 `"name":"xxx"` 的前几个（诊断用，不解析整体结构）
/// 容错：`"name" : "x"`（冒号/引号间有空格）同样识别；不匹配则跳过该处继续向后扫
public func scanPackageNames(ndjson: String, limit: Int64): ArrayList<String> {
    let names = ArrayList<String>()
    var rest = ndjson
    while (names.size < limit) {
        let idx = rest.indexOf("\"name\"")
        if (idx.isNone()) {
            break
        }
        let after = rest[(idx.getOrThrow() + 6)..rest.size]
        rest = after   // 每次前移，保证有限次迭代（避免匹配失败时死循环）
        let colon = after.indexOf(":")
        if (colon.isNone()) {
            continue
        }
        let tail = after[(colon.getOrThrow() + 1)..after.size].trimAscii()
        if (!tail.startsWith("\"")) {
            continue
        }
        let body = tail[1..tail.size]
        match (body.indexOf("\"")) {
            case Some(e) =>
                let name = body[0..e]
                if (!name.isEmpty()) {
                    var dup = false
                    for (n in names) {
                        if (n == name) {
                            dup = true
                            break
                        }
                    }
                    if (!dup) {
                        names.add(name)
                    }
                }
                rest = body[(e + 1)..body.size]
            case None => continue
        }
    }
    names
}

/// 纯逻辑：把「HTTP 结果」翻译成探测结论（可单测；不参与网络）
public func classifyProbe(up: Upstream, testedUrl: String, withName: Bool, status: Int64, latencyMs: Int64,
                          bodyBytes: Int64, body: String, transportError: String): UpstreamProbeResult {
    let names = if (status == 200 && withName) { scanPackageNames(body, 5) } else { ArrayList<String>() }
    if (status <= 0) {
        return UpstreamProbeResult(up.id, up.name, up.url, testedUrl, up.enabled, false, false, 0, latencyMs,
            bodyBytes, !up.authToken.isEmpty(), names, if (transportError.isEmpty()) { "无响应" } else { transportError })
    }
    if (status == 404) {
        // 有响应即连通；指定包不存在不算故障（上游没有该包是正常状态）
        let err = if (withName) { "该上游未收录此包（404）" } else { "上游返回 404" }
        return UpstreamProbeResult(up.id, up.name, up.url, testedUrl, up.enabled, true, false, status, latencyMs,
            bodyBytes, !up.authToken.isEmpty(), names, err)
    }
    if (status != 200) {
        let err = if (status == 401 || status == 403) { "认证失败（${status}）" } else { "上游返回 ${status}" }
        return UpstreamProbeResult(up.id, up.name, up.url, testedUrl, up.enabled, true, false, status, latencyMs,
            bodyBytes, !up.authToken.isEmpty(), names, err)
    }
    if (withName && bodyBytes == 0) {
        return UpstreamProbeResult(up.id, up.name, up.url, testedUrl, up.enabled, true, false, status, latencyMs,
            bodyBytes, !up.authToken.isEmpty(), names, "索引为空")
    }
    UpstreamProbeResult(up.id, up.name, up.url, testedUrl, up.enabled, true, true, status, latencyMs, bodyBytes,
        !up.authToken.isEmpty(), names, "")
}

/// 网络探测：按 name 决定请求索引端点还是基地址；返回分类后的结果
public func probeUpstream(up: Upstream, name: String, org: String): UpstreamProbeResult {
    var testedUrl = trimTrailing(up.url)
    var withName = false
    if (!name.isEmpty() && name.size >= 3) {
        let idxUrl = buildIndexURL(up.url, name, org)
        if (!idxUrl.isEmpty()) {
            testedUrl = idxUrl
            withName = true
        }
    }
    let start = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
    let (status, body, err) = httpProbe(testedUrl, up.authToken, withName)
    let latency = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() - start
    classifyProbe(up, testedUrl, withName, status, latency, body.size, String.fromUtf8(body), err)
}

// 单次 GET：返回 (状态码, 正文, 传输错误)；4xx/5xx 也算拿到响应（状态码非 0）
func httpProbe(url: String, token: String, readBody: Bool): (Int64, Array<Byte>, String) {
    let client = buildHttpClient(url)
    try {
        let resp = client.send(buildGetRequest(url, token))
        let code = Int64(resp.status)
        var body = Array<Byte>()
        if (readBody && code == 200) {
            body = readStreamToBytes(resp.body)
        } else {
            // 诊断只需状态码时也把正文读掉，避免连接复用异常
            let _ = readStreamToBytes(resp.body)
        }
        client.close()
        return (code, body, "")
    } catch (e: Exception) {
        try {
            client.close()
        } catch (_: Exception) {
            ()
        }
        return (0, Array<Byte>(), e.message)
    }
}

// 上游地址归一（去尾部斜杠）
func trimTrailing(v: String): String {
    var s = v.trimAscii()
    while (s.size > 0 && s[s.size - 1] == 47u8) {
        s = s[0..s.size - 1]
    }
    s
}
