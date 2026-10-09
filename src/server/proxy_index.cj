// 代理回源 · 索引域：本地命中判定 + 按优先级回源取索引（命中即缓存条目），
// 指定上游直取、带状态码的探测，以及 indexJson → sha256 提取
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
