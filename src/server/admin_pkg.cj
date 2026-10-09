// 管理 API · 包管理（版本列表 / 单版本详情 / 重拉 / 软删·恢复·硬删）——AdminService 的包域扩展
package ystyle::cjreg.server

import tang.*
import ystyle::cjreg.store.*
import std.collection.*
import std.convert.*
import std.sort.*

extend AdminService {
    // GET /api/admin/packages?organization=&name=&includeDeleted=1&page=&size=
    // 版本列表（管理端自动化用：拿到 id 才能调三级删除端点）
    public func listPackages(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let store = match (this.pkgStore) {
            case Some(s) => s
            case None =>
                writeDto(ctx, 500u16, ErrorResp("package store unavailable"))
                return
        }
        let org = ctx.query("organization") ?? ""
        let name = ctx.query("name") ?? ""
        let includeDeleted = (ctx.query("includeDeleted") ?? "") == "1"
        let hits = ArrayList<PackageDoc>()
        for (d in store.storm.all<PackageDoc>()) {
            if (!org.isEmpty() && d.organization != org) {
                continue
            }
            if (!name.isEmpty() && d.name != name) {
                continue
            }
            if (!includeDeleted && d.deletedAt != 0) {
                continue
            }
            hits.add(d)
        }
        sort(hits, by: adminPkgAsc)
        let page = parseI64(ctx.query("page"))
        let size = parseI64(ctx.query("size"))
        let (start, end) = pageWindow(hits.size, if (page <= 0) { 1 } else { page },
            if (size <= 0) { 50 } else { size })
        let items = ArrayList<AdminPackageDto>()
        var i = start
        while (i < end) {
            let d = hits[i]
            items.add(AdminPackageDto(d.id, d.organization, d.name, d.version, d.deletedAt, d.sha256,
                d.tarballSize, d.downloadCount, d.publisherId, d.upstreamId, d.createdAt, d.updatedAt))
            i++
        }
        writeDto(ctx, 200u16, AdminPackageListResp(hits.size, items))
    }

    // ===== 单版本详情 + 上游重拉 =====

    // GET /api/admin/packages/:id → 单版本详情（含 README 全文、来源上游、sha/大小/时间/发布者）
    public func getPackageVersion(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let store = match (this.pkgStore) {
            case Some(s) => s
            case None =>
                writeDto(ctx, 500u16, ErrorResp("package store unavailable"))
                return
        }
        let id = match (Int64.tryParse(ctx.param("id"))) {
            case Some(n) => n
            case None => 0
        }
        let doc = match (store.getById(id)) {
            case Some(d) => d
            case None =>
                writeDto(ctx, 404u16, ErrorResp("package version not found"))
                return
        }
        writeDto(ctx, 200u16, this.versionDetailJson(store, doc))
    }

    // POST /api/admin/packages/:id/refetch[?force=1] → 按上游内容重拉并覆盖本地缓存
    // 仅对回源镜像版本开放（upstreamId != 0）；上游 sha 变了需 force=1 二次确认
    public func refetchPackageVersion(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let id = match (Int64.tryParse(ctx.param("id"))) {
            case Some(n) => n
            case None => 0
        }
        if (id <= 0) {
            writeDto(ctx, 400u16, ErrorResp("invalid package id"))
            return
        }
        let store = match (this.pkgStore) {
            case Some(s) => s
            case None =>
                writeDto(ctx, 500u16, ErrorResp("package store unavailable"))
                return
        }
        let proxy = match (this.proxySvc) {
            case Some(p) => p
            case None =>
                writeDto(ctx, 503u16, ErrorResp("proxy service unavailable（未配置上游回源）"))
                return
        }
        let doc = match (store.getById(id)) {
            case Some(d) => d
            case None =>
                writeDto(ctx, 404u16, ErrorResp("package version not found"))
                return
        }
        let force = (ctx.query("force") ?? "") == "1"
        let r = refetchVersion(proxy, doc, force)
        let target = auditTarget(doc.organization, doc.name, doc.version)
        let (actorId, actorName) = this.actorOf(ctx)
        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "refetch_package",
            if (r.outcome == RefetchOutcome.Ok) { "ok" } else { "failed" }, target, ctx,
            error: if (r.outcome == RefetchOutcome.Ok) { "" } else { r.message },
            detail: "upstream=${r.upstreamName} old=${shortSha(r.oldSha)} new=${shortSha(r.newSha)} " +
                "changed=${r.changed} size=${r.size} force=${force} id=${id}")
        var code = 200u16
        match (r.outcome) {
            case RefetchOutcome.NotFound => code = 404u16
            case RefetchOutcome.LocalOwned => code = 409u16
            case RefetchOutcome.ShaChanged => code = 409u16
            case RefetchOutcome.Invalid => code = 409u16
            case RefetchOutcome.UpstreamMissing => code = 404u16
            case RefetchOutcome.Unavailable => code = 503u16
            case RefetchOutcome.Unreachable => code = 502u16
            case _ => code = 200u16
        }
        writeDto(ctx, code, refetchJson(r))
    }

    // 单版本详情（管理端用，含 README 全文；不走公开接口的脱敏口径）
    func versionDetailJson(store: PackageStore, doc: PackageDoc): PackageVersionDetailDto {
        let publisher = if (doc.publisherId > 0) {
            match (this.userStore.getUser(doc.publisherId)) {
                case Some(u) => u.username
                case None => ""
            }
        } else {
            ""
        }
        let upstream = if (doc.upstreamId > 0) {
            match (this.upstreamStore.getById(doc.upstreamId)) {
                case Some(u) => u.name
                case None => doc.upstreamName
            }
        } else {
            ""
        }
        let blobs: BlobStore = match (this.blobStore) {
            case Some(b) => b
            case None => MemoryBlobStore()
        }
        PackageVersionDetailDto(doc.id, doc.organization, doc.name, doc.version, doc.cjcVersion,
            doc.description, doc.artifactType, doc.executable, doc.authors, doc.repository, doc.homepage,
            doc.documentation, doc.tag, doc.category, doc.license, doc.sha256, doc.tarballSize,
            doc.downloadCount, doc.publisherId, publisher, doc.upstreamId, upstream, doc.deletedAt,
            doc.createdAt, doc.updatedAt, doc.readme, doc.readme.size, artifactAvailable(store, blobs, doc))
    }

    // ===== 包三级删除闭环 =====

    // DELETE /api/admin/packages/:id → 软删除（deletedAt；索引/下载/公开 API 立即不可见）
    public func deletePackage(ctx: TangHttpContext): Unit {
        this.lifecycleEntry(ctx, "soft")
    }

    // DELETE /api/admin/packages/:id/hard → 硬删除（需先软删；删记录 + 制品）
    public func hardDeletePackage(ctx: TangHttpContext): Unit {
        this.lifecycleEntry(ctx, "hard")
    }

    // PUT /api/admin/packages/:id/restore → 恢复（校验制品仍在）
    public func restorePackage(ctx: TangHttpContext): Unit {
        this.lifecycleEntry(ctx, "restore")
    }

    // 三种操作的公共入口：解析 id → 取版本 → 调用生命周期 → 审计 + JSON
    func lifecycleEntry(ctx: TangHttpContext, mode: String): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let id = match (Int64.tryParse(ctx.param("id"))) {
            case Some(n) => n
            case None => 0
        }
        if (id <= 0) {
            writeDto(ctx, 400u16, ErrorResp("invalid package id"))
            return
        }
        let store = match (this.pkgStore) {
            case Some(s) => s
            case None =>
                writeDto(ctx, 500u16, ErrorResp("package store unavailable"))
                return
        }
        let doc = match (store.getById(id)) {
            case Some(d) => d
            case None =>
                writeDto(ctx, 404u16, ErrorResp("package version not found"))
                return
        }
        let blobs: BlobStore = match (this.blobStore) {
            case Some(b) => b
            case None => MemoryBlobStore()
        }
        let now = auditNowMs()
        var action = "delete_package"
        var result: LifecycleResult
        match (mode) {
            case "hard" =>
                action = "hard_delete_package"
                result = hardDeleteVersion(store, blobs, this.adminData, doc, now)
            case "restore" =>
                action = "restore_package"
                result = restoreVersion(store, blobs, doc)
            case _ =>
                result = softDeleteVersion(store, this.adminData, doc, now)
        }
        let target = auditTarget(doc.organization, doc.name, doc.version)
        let status = match (result.outcome) {
            case LifecycleOutcome.Ok => "ok"
            case LifecycleOutcome.AlreadyDeleted => "ok"      // 幂等：语义上已是目标状态
            case _ => "failed"
        }
        let (actorId, actorName) = this.actorOf(ctx)
        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, action, status, target, ctx,
            error: if (status == "ok") { "" } else { result.message },
            detail: "skippedPlanItems=${result.skippedPlanItems} blobRemoved=${result.blobRemoved} " +
                "artifactPresent=${result.artifactPresent} id=${id}")
        // 结果码：NotDeleted/ArtifactMissing → 409（语义冲突，非参数错误）
        var code = 200u16
        match (result.outcome) {
            case LifecycleOutcome.NotFound => code = 404u16
            case LifecycleOutcome.NotDeleted => code = 409u16
            case LifecycleOutcome.ArtifactMissing => code = 409u16
            case LifecycleOutcome.Failed => code = 500u16
            case _ => code = 200u16
        }
        writeDto(ctx, code, lifecycleJson(result))
    }
}

// 管理端包列表排序：组织 → 包名 → 版本（升序）
func adminPkgAsc(a: PackageDoc, b: PackageDoc): Ordering {
    if (a.organization != b.organization) {
        return if (a.organization < b.organization) { Ordering.LT } else { Ordering.GT }
    }
    if (a.name != b.name) {
        return if (a.name < b.name) { Ordering.LT } else { Ordering.GT }
    }
    if (a.version == b.version) {
        return Ordering.EQ
    }
    return if (a.version < b.version) { Ordering.LT } else { Ordering.GT }
}
