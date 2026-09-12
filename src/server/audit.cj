// 审计日志辅助：客户端 IP / User-Agent 提取 + 统一写入（发布、认证、管理 API 共用）
// 设计：真实 IP 优先取反向代理头 X-Forwarded-For 首个地址，其次 X-Real-IP，最后 TCP 对端
package ystyle::cjreg.server

import tang.*
import ystyle::cjreg.store.*
import std.time.*
import std.convert.*

// 日志种类常量（与 LogDoc.kind 存储值一致）
public let AUDIT_PUBLISH = "publish"
public let AUDIT_ADMIN = "admin"
public let AUDIT_AUTH = "auth"

// User-Agent 入库上限（防超长头撑大文档）
let AUDIT_UA_MAX: Int64 = 200
let AUDIT_IP_MAX: Int64 = 64

// 客户端 IP：X-Forwarded-For 首个 → X-Real-IP → TCP 对端地址
public func clientIp(ctx: TangHttpContext): String {
    let xff = ctx.ips()
    if (xff.size > 0) {
        for (part in xff[0].split(",")) {
            let ip = part.trimAscii()
            if (!ip.isEmpty()) {
                return truncateStr(stripPort(ip), AUDIT_IP_MAX)
            }
        }
    }
    match (ctx.getHeader("X-Real-IP")) {
        case Some(v) =>
            let ip = v.trimAscii()
            if (!ip.isEmpty()) {
                return truncateStr(stripPort(ip), AUDIT_IP_MAX)
            }
        case None => ()
    }
    // TCP 对端是 "ip:port"（如 127.0.0.1:38184），审计只记地址
    truncateStr(stripPort(ctx.ip()), AUDIT_IP_MAX)
}

// 去掉地址里的端口：127.0.0.1:38184 → 127.0.0.1；[::1]:38184 → ::1
// 裸 IPv6（2001:db8::1，多冒号）不截断
func stripPort(raw: String): String {
    let s = raw.trimAscii()
    if (s.startsWith("[")) {
        match (s.indexOf("]")) {
            case Some(i) => return s[1..i]
            case None => return s
        }
    }
    let last = s.lastIndexOf(":")
    match (last) {
        case Some(i) =>
            let tail = s[(i + 1)..s.size]
            if (!tail.isEmpty() && isAllDigits(tail)) {
                match (s.indexOf(":")) {
                    case Some(first) => if (first == i) {
                        return s[0..i]
                    }
                    case None => ()
                }
            }
        case None => ()
    }
    s
}

func isAllDigits(s: String): Bool {
    for (c in s.toRuneArray()) {
        if (c < r'0' || c > r'9') {
            return false
        }
    }
    return true
}

// 客户端 User-Agent（截断，缺失为空串）
public func clientUserAgent(ctx: TangHttpContext): String {
    match (ctx.getHeader("User-Agent")) {
        case Some(v) => truncateStr(v.trimAscii(), AUDIT_UA_MAX)
        case None => ""
    }
}

// 字符串截断（按字节；日志字段无需精确到字符边界）
func truncateStr(s: String, max: Int64): String {
    if (s.size <= max) {
        return s
    }
    s[0..max]
}

// 审计时间戳（毫秒，UTC）
public func auditNowMs(): Int64 {
    DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
}

// 审计目标串：org/name[@version]（org 为空时省略前缀）
public func auditTarget(org: String, name: String, version: String): String {
    var t = name
    if (!org.isEmpty()) {
        t = "${org}/${name}"
    }
    if (!version.isEmpty()) {
        t = "${t}@${version}"
    }
    t
}

// 统一审计写入：adminData 缺失（离线/单测未注入）时静默跳过
// action = 操作动词；status = ok/failed；detail = 补充说明；error = 失败原因
public func writeAudit(ad: ?AdminDataStore, kind: LogKind, actorId: Int64, actorName: String,
                       action: String, status: String, target: String, ctx: TangHttpContext,
                       error!: String = "", detail!: String = ""): Unit {
    match (ad) {
        case Some(store) =>
            let _ = store.addLog(kind, actorId, actorName, action, status, auditNowMs(),
                target: target, error: error, ipAddr: clientIp(ctx),
                userAgent: clientUserAgent(ctx), detail: detail)
        case None => ()
    }
}

// 日志种类解析（管理 API 路径参数 → ?String；"all"/空 → 不过滤）
public func parseAuditKind(raw: String): ?String {
    match (raw) {
        case "publish" => Some(AUDIT_PUBLISH)
        case "admin" => Some(AUDIT_ADMIN)
        case "auth" => Some(AUDIT_AUTH)
        case "all" => None
        case "" => None
        case _ => None
    }
}

// JSON 字符串转义（日志字段可能含引号/反斜杠/换行：UA、错误消息）
public func escapeJsonStr(s: String): String {
    let sb = StringBuilder()
    for (c in s.toRuneArray()) {
        match (c) {
            case r'"' => sb.append("\\\"")
            case r'\\' => sb.append("\\\\")
            case r'\n' => sb.append("\\n")
            case r'\r' => sb.append("\\r")
            case r'\t' => sb.append("\\t")
            case _ =>
                let n = UInt32(c)
                if (n < 0x20) {
                    sb.append("\\u${pad4(n)}")
                } else {
                    sb.append(c)
                }
        }
    }
    sb.toString()
}

func pad4(n: UInt32): String {
    let hex = n.toString(radix: 16)
    var pad = 4 - hex.size
    let sb = StringBuilder()
    while (pad > 0) {
        sb.append("0")
        pad--
    }
    sb.append(hex)
    sb.toString()
}
