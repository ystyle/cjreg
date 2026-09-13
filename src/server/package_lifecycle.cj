// 包三级删除闭环（设计见 docs/design.md §5.6 / 管理 API 表）
//
//   1) 软删除 softDeleteVersion：deletedAt 置时间戳；索引/下载/公开 API 立即不可见，
//      已完成的发布计划项保留（历史），未完成的引用项标记 skipped（联动标记）
//   2) 恢复 restoreVersion：**校验制品仍在**（本地 blob 存在，或该版本来自上游可重新回源）；
//      制品丢失时拒绝恢复（409），避免恢复出一个下载 404 的版本
//   3) 硬删除 hardDeleteVersion：仅允许对**已软删**的版本执行；删除记录 + 制品文件（blob），
//      并再次联动计划项；写审计（由 handler 负责），不可恢复
//
// 纯逻辑（不依赖 HTTP）→ 可直接单测；blob/计划项通过参数注入。
package ystyle::cjreg.server

import ystyle::cjreg.store.*
import std.collection.*

// 删除/恢复结果
public enum LifecycleOutcome {
    | Ok
    | NotFound          // 版本记录不存在
    | NotDeleted        // 硬删前置条件不满足（需先软删）
    | AlreadyDeleted    // 软删幂等提示
    | ArtifactMissing   // 恢复时制品已丢失（blob 不存在且无上游可回源）
    | Failed

    public operator func ==(other: LifecycleOutcome): Bool {
        match (this) {
            case LifecycleOutcome.Ok => match (other) {
                case LifecycleOutcome.Ok => true
                case _ => false
            }
            case LifecycleOutcome.NotFound => match (other) {
                case LifecycleOutcome.NotFound => true
                case _ => false
            }
            case LifecycleOutcome.NotDeleted => match (other) {
                case LifecycleOutcome.NotDeleted => true
                case _ => false
            }
            case LifecycleOutcome.AlreadyDeleted => match (other) {
                case LifecycleOutcome.AlreadyDeleted => true
                case _ => false
            }
            case LifecycleOutcome.ArtifactMissing => match (other) {
                case LifecycleOutcome.ArtifactMissing => true
                case _ => false
            }
            case LifecycleOutcome.Failed => match (other) {
                case LifecycleOutcome.Failed => true
                case _ => false
            }
        }
    }
}

public struct LifecycleResult {
    public let outcome: LifecycleOutcome
    public let message: String
    public let skippedPlanItems: Int64      // 联动标记为 skipped 的计划项数
    public let blobRemoved: Bool            // 硬删是否删掉了制品文件
    public let artifactPresent: Bool        // 恢复前制品是否存在（诊断）

    public init(outcome: LifecycleOutcome, message: String, skippedPlanItems: Int64,
                blobRemoved: Bool, artifactPresent: Bool) {
        this.outcome = outcome
        this.message = message
        this.skippedPlanItems = skippedPlanItems
        this.blobRemoved = blobRemoved
        this.artifactPresent = artifactPresent
    }
}

public func lifecycleJson(r: LifecycleResult): String {
    let status = match (r.outcome) {
        case LifecycleOutcome.Ok => "ok"
        case LifecycleOutcome.NotFound => "not_found"
        case LifecycleOutcome.NotDeleted => "not_deleted"
        case LifecycleOutcome.AlreadyDeleted => "already_deleted"
        case LifecycleOutcome.ArtifactMissing => "artifact_missing"
        case LifecycleOutcome.Failed => "failed"
    }
    let sb = StringBuilder()
    sb.append("{\"status\":\"${status}\",\"message\":\"${escapeJsonStr(r.message)}\",")
    sb.append("\"skippedPlanItems\":${r.skippedPlanItems},\"blobRemoved\":${r.blobRemoved},")
    sb.append("\"artifactPresent\":${r.artifactPresent}}")
    sb.toString()
}

/// 制品是否可用：blob 存在 → true；该版本来自上游（upstreamId != 0）→ 可重新回源，视为可用；
/// 本地发布且 blob 丢失 → false（不可恢复）
public func artifactAvailable(pkgStore: PackageStore, blobStore: BlobStore, doc: PackageDoc): Bool {
    if (doc.sha256.isEmpty()) {
        // 无 sha 记录的老数据：按上游可回源判断
        return doc.upstreamId != 0
    }
    if (blobStore.has(doc.sha256)) {
        return true
    }
    return doc.upstreamId != 0
}

/// 软删除版本：幂等（已软删返回 AlreadyDeleted）；联动把未完成的计划项标记 skipped
public func softDeleteVersion(pkgStore: PackageStore, adminData: ?AdminDataStore, doc: PackageDoc,
                              now: Int64): LifecycleResult {
    if (doc.deletedAt != 0) {
        return LifecycleResult(LifecycleOutcome.AlreadyDeleted, "该版本已是删除状态", 0, false, false)
    }
    let steps = skipPlanItemsForVersion(adminData, doc.organization, doc.name, doc.version, now)
    pkgStore.softDelete(doc, now)
    LifecycleResult(LifecycleOutcome.Ok, "已软删除（可恢复）", steps, false, false)
}

/// 恢复软删版本：先校验制品仍在（blob 或上游可回源），否则拒绝
public func restoreVersion(pkgStore: PackageStore, blobStore: BlobStore, doc: PackageDoc): LifecycleResult {
    if (doc.deletedAt == 0) {
        return LifecycleResult(LifecycleOutcome.Ok, "该版本未被删除", 0, false, true)
    }
    let present = artifactAvailable(pkgStore, blobStore, doc)
    if (!present) {
        return LifecycleResult(LifecycleOutcome.ArtifactMissing,
            "制品已丢失（本地无该制品且无上游来源），恢复后会造成下载 404，已拒绝", 0, false, false)
    }
    pkgStore.restore(doc)
    LifecycleResult(LifecycleOutcome.Ok, "已恢复", 0, false, true)
}

/// 硬删除：仅允许已软删的版本；删除 blob（未被其它版本引用时）+ 记录 + 联动计划项
public func hardDeleteVersion(pkgStore: PackageStore, blobStore: BlobStore, adminData: ?AdminDataStore,
                              doc: PackageDoc, now: Int64): LifecycleResult {
    if (doc.deletedAt == 0) {
        return LifecycleResult(LifecycleOutcome.NotDeleted,
            "硬删除前需先软删除（避免误操作直接丢失制品）", 0, false, true)
    }
    var removed = false
    var shared = 0
    if (!doc.sha256.isEmpty()) {
        // blob 是内容寻址的：同一个制品可能被多个版本共享（跨组织镜像同一个包等），
        // 删之前必须确认没人再用 —— 否则会静默搞坏另一个版本的下载（它只能靠回源救，本地发布的可救不回来）
        shared = shaReferencedByOthers(pkgStore, doc.sha256, doc.id)
        if (shared == 0) {
            removed = blobStore.remove(doc.sha256)
        }
    }
    let steps = skipPlanItemsForVersion(adminData, doc.organization, doc.name, doc.version, now)
    pkgStore.hardDelete(doc)
    let msg = if (shared > 0) {
        "已硬删除记录；制品仍被 ${shared} 个其它版本引用，保留未删"
    } else {
        "已硬删除（记录 + 制品，不可恢复）"
    }
    LifecycleResult(LifecycleOutcome.Ok, msg, steps, removed, false)
}

/// 同一 sha 还被多少个**其它**未删文档引用（内容寻址的 blob 可能被多版本共享）
public func shaReferencedByOthers(pkgStore: PackageStore, sha: String, excludeId: Int64): Int64 {
    if (sha.isEmpty()) {
        return 0
    }
    var n: Int64 = 0
    for (d in pkgStore.storm.all<PackageDoc>()) {
        if (d.id == excludeId || d.deletedAt != 0) {
            continue
        }
        if (d.sha256 == sha) {
            n++
        }
    }
    return n
}

/// 计划项联动：把引用该版本且未完成的计划项标记为 skipped
/// （completed/failed 保留历史；skipped 是六态模型中的「已跳过」状态）
public func skipPlanItemsForVersion(adminData: ?AdminDataStore, org: String, name: String,
                                    version: String, now: Int64): Int64 {
    let ad = match (adminData) {
        case Some(x) => x
        case None => return 0
    }
    var n: Int64 = 0
    for (item in ad.listPlanItems()) {
        if (item.packageOrg != org || item.packageName != name || item.packageVersion != version) {
            continue
        }
        if (item.status == "completed" || item.status == "failed" || item.status == "skipped") {
            continue
        }
        if (ad.updatePlanItem(item.id, "skipped", "目标版本已删除（软删/硬删联动跳过）", now)) {
            n++
        }
    }
    n
}
