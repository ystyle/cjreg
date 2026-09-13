// 上游重拉（把某个「回源镜像版本」按上游内容重新拉一遍并覆盖本地缓存）
//
// 为什么需要：本地落库后本地就是权威，没有入口从上游重新拉。管理员真会遇到：
// blob 被清理/损坏、早期回源漏了展示字段（sync-metadata 只能从**本地 blob** 补，blob 没了就补不了）、
// 上游该版本的索引元数据变了。今天的土办法是「硬删 → 再有人请求一次」，但硬删不可恢复、
// 丢下载数、还有「包凭空消失」的窗口。
//
// 语义与护栏：
//   - 只对**回源镜像**版本开放（upstreamId != 0）：本地发布的版本本地才是权威，重拉会把你自己的
//     内容换成上游同版本的（同版本内容未必一致）→ 直接拒绝，需要替换请先硬删再触发回源；
//   - 以上游**索引声明的 sha256sum** 为准校验下载内容（防半截包/内容与索引不符）；
//   - 上游同版本 sha 变了（上游重新发布了同版本）→ 默认拒绝，要 force 才接受覆盖；
//   - 不改 doc.id / downloadCount / createdAt / updatedAt（重拉是刷新缓存，不是发版，不搅乱「最近更新」）；
//   - 旧 blob 仍被其它版本引用时不清理（内容寻址，blob 可能共享）。
package ystyle::cjreg.server

import ystyle::cjreg.store.*
import ystyle::cjreg.config.*
import ystyle::cjreg.index.*
import ystyle::cjreg.protocol.*
import std.collection.*

// 重拉结果
public enum RefetchOutcome {
    | Ok              // 成功（changed 表示内容是否真的变了）
    | NotFound        // 版本不存在
    | LocalOwned      // 本地发布的版本，不受上游管辖
    | UpstreamMissing // 上游索引里没有该版本（可能已下架）
    | ShaChanged      // 上游同版本 sha 变了，需 force
    | Unreachable     // 上游不可达 / 下载失败
    | Invalid         // 下载内容与上游索引 sha 不符（半截包）
    | Unavailable     // 上游被禁用/已删除

    public operator func ==(other: RefetchOutcome): Bool {
        match (this) {
            case RefetchOutcome.Ok => match (other) {
                case RefetchOutcome.Ok => true
                case _ => false
            }
            case RefetchOutcome.NotFound => match (other) {
                case RefetchOutcome.NotFound => true
                case _ => false
            }
            case RefetchOutcome.LocalOwned => match (other) {
                case RefetchOutcome.LocalOwned => true
                case _ => false
            }
            case RefetchOutcome.UpstreamMissing => match (other) {
                case RefetchOutcome.UpstreamMissing => true
                case _ => false
            }
            case RefetchOutcome.ShaChanged => match (other) {
                case RefetchOutcome.ShaChanged => true
                case _ => false
            }
            case RefetchOutcome.Unreachable => match (other) {
                case RefetchOutcome.Unreachable => true
                case _ => false
            }
            case RefetchOutcome.Invalid => match (other) {
                case RefetchOutcome.Invalid => true
                case _ => false
            }
            case RefetchOutcome.Unavailable => match (other) {
                case RefetchOutcome.Unavailable => true
                case _ => false
            }
        }
    }
}

public class RefetchResult {
    public var outcome: RefetchOutcome
    public var message: String
    public var oldSha: String = ""
    public var newSha: String = ""
    public var size: Int64 = 0
    public var changed: Bool = false      // 内容与本地原来那份不同
    public var upstreamName: String = ""
    public var readmeLen: Int64 = 0

    public init(outcome: RefetchOutcome, message: String) {
        this.outcome = outcome
        this.message = message
    }
}

// 重拉一个版本：拉上游索引 → 校验 sha → 下载制品 → 覆盖本地 doc 与 blob
public func refetchVersion(proxy: ProxyService, doc: PackageDoc, force: Bool): RefetchResult {
    if (doc.upstreamId == 0) {
        return RefetchResult(RefetchOutcome.LocalOwned,
            "本地发布的版本不受上游管辖（重拉会覆盖你自己的内容）；如需换成上游同版本，请先硬删除该版本再请求一次回源")
    }
    // 来源上游：优先记录里的那个；记录没了（被删/改名）就按优先级逐个试
    let candidates = ArrayList<Upstream>()
    match (proxy.upstreamSvc.getById(doc.upstreamId)) {
        case Some(u) => if (u.enabled) {
            candidates.add(u)
        }
        case None => ()
    }
    if (candidates.size == 0) {
        for (u in proxy.upstreamSvc.enabledSorted()) {
            candidates.add(u)
        }
    }
    if (candidates.size == 0) {
        return RefetchResult(RefetchOutcome.Unavailable, "没有可用的上游（来源上游已删除/禁用）")
    }

    var lastErr = ""
    var sawMissingVersion = false
    for (up in candidates) {
        // 1. 上游索引：拿到该版本的权威 sha256sum
        let ndjson = match (proxy.fetchUpstreamIndex(up, doc.organization, doc.name)) {
            case Some(s) => s
            case None =>
                lastErr = "上游「${up.name}」索引取不到"
                continue
        }
        var entry: ?PackageIndex = None
        for (e in parseNDJSON(ndjson)) {
            if (e.version == doc.version) {
                entry = Some(e)
                break
            }
        }
        let idx = match (entry) {
            case Some(e) => e
            case None =>
                // 索引取到了但没这个版本：与「上游不可达」是两回事，要分开报
                sawMissingVersion = true
                lastErr = "上游「${up.name}」索引里已无 ${doc.version} 这个版本"
                continue
        }
        // 2. sha 变化裁决：上游重新发布了同版本 → 需显式 force
        if (!doc.sha256.isEmpty() && !idx.sha256sum.isEmpty() && idx.sha256sum != doc.sha256 && !force) {
            let r = RefetchResult(RefetchOutcome.ShaChanged,
                "上游同版本内容已变（本地 ${shortSha(doc.sha256)} → 上游 ${shortSha(idx.sha256sum)}）——确认要用上游内容覆盖本地吗？")
            r.oldSha = doc.sha256
            r.newSha = idx.sha256sum
            r.upstreamName = up.name
            return r
        }
        // 3. 下载制品
        let url = buildPackageURL(up.url, doc.name, doc.version, doc.organization)
        let bytes = match (proxy.fetchBytes(url, up.authToken)) {
            case Some(b) => b
            case None =>
                lastErr = "上游「${up.name}」制品下载失败"
                continue
        }
        // 4. 校验：内容必须与上游索引声明的 sha 一致（防半截包/索引与内容不一致）
        let actual = sha256Hex(bytes)
        if (!idx.sha256sum.isEmpty() && actual != idx.sha256sum) {
            let r = RefetchResult(RefetchOutcome.Invalid,
                "下载内容与上游索引 sha 不符（索引 ${shortSha(idx.sha256sum)}，实际 ${shortSha(actual)}）——已丢弃，未覆盖本地")
            r.oldSha = doc.sha256
            r.newSha = idx.sha256sum
            r.upstreamName = up.name
            return r
        }

        // 5. 覆盖：旧 blob 若仍被别的版本引用则不清理
        let oldSha = doc.sha256
        let changed = oldSha != actual
        if (changed && !oldSha.isEmpty() && shaReferencedByOthers(proxy.pkgStore, oldSha, doc.id) == 0) {
            let _ = proxy.blobStore.remove(oldSha)
        }
        proxy.blobStore.put(actual, bytes)
        doc.sha256 = actual
        doc.tarballSize = bytes.size
        doc.indexJson = generateNDJSON(ArrayList<PackageIndex>([idx]))
        if (!idx.cjcVersion.isEmpty()) {
            doc.cjcVersion = idx.cjcVersion
        }
        doc.upstreamId = up.id
        doc.upstreamName = up.name
        // 展示字段与 README 用新制品刷新（上游元数据可能也变了）
        let _ = enrichDocFromArtifact(doc, bytes, overwrite: true)
        proxy.pkgStore.save(doc)

        let r = RefetchResult(RefetchOutcome.Ok,
            if (changed) { "已重拉并覆盖（${shortSha(oldSha)} → ${shortSha(actual)}）" } else { "已重拉（内容与本地一致，仅刷新元数据）" })
        r.oldSha = oldSha
        r.newSha = actual
        r.size = bytes.size
        r.changed = changed
        r.upstreamName = up.name
        r.readmeLen = doc.readme.size
        return r
    }
    if (sawMissingVersion) {
        return RefetchResult(RefetchOutcome.UpstreamMissing,
            "上游索引里已没有这个版本（可能已下架）：${lastErr}")
    }
    return RefetchResult(RefetchOutcome.Unreachable, "上游不可达：${lastErr}")
}

// sha 缩写（日志/提示用）
public func shortSha(sha: String): String {
    if (sha.size <= 12) {
        return sha
    }
    return sha[0..12]
}

// 重拉结果 JSON（管理 API 用）
public func refetchJson(r: RefetchResult): String {
    let status = match (r.outcome) {
        case RefetchOutcome.Ok => "ok"
        case RefetchOutcome.NotFound => "not_found"
        case RefetchOutcome.LocalOwned => "local_owned"
        case RefetchOutcome.UpstreamMissing => "upstream_missing"
        case RefetchOutcome.ShaChanged => "sha_changed"
        case RefetchOutcome.Unreachable => "unreachable"
        case RefetchOutcome.Invalid => "invalid"
        case RefetchOutcome.Unavailable => "unavailable"
    }
    let sb = StringBuilder()
    sb.append("{\"status\":\"${status}\",\"message\":\"${escapeJsonStr(r.message)}\",")
    sb.append("\"oldSha\":\"${r.oldSha}\",\"newSha\":\"${r.newSha}\",")
    sb.append("\"changed\":${r.changed},\"size\":${r.size},\"readmeLength\":${r.readmeLen},")
    sb.append("\"upstream\":\"${escapeJsonStr(r.upstreamName)}\"}")
    sb.toString()
}
