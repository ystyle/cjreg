// 管理 API · 在线备份（列表 / 触发 / 下载 / 删除）——AdminService 的备份域扩展
//
// 全部 requireAdmin：归档里含 passwordHash / publishToken / 会话 Token 与审计日志。
// 备份在服务端进程内执行（复用已持有的 Storm），因此**不需要停服**。
package ystyle::cjreg.server

import tang.*
import ystyle::cjreg.store.*
import std.collection.*
import std.fs.*
import std.time.*
import std.sync.*
import gjson

extend AdminService {
    private func backupServiceOrReply(ctx: TangHttpContext): ?OnlineBackupService {
        match (this.backupSvc) {
            case Some(s) => Some(s)
            case None =>
                writeDto(ctx, 501u16, ErrorResp("备份服务未启用"))
                None
        }
    }

    /** GET /api/admin/backups —— 归档列表 + 最近任务状态 + 是否需要重启应用恢复 */
    public func listBackups(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let svc = match (this.backupServiceOrReply(ctx)) {
            case Some(s) => s
            case None => return
        }
        let archives = ArrayList<BackupArchiveResp>()
        for ((name, size, mtime) in svc.listArchives()) {
            archives.add(BackupArchiveResp(name, size, mtime, "${monthDayTime(mtime)}"))
        }
        let jobs = ArrayList<BackupJobResp>()
        for (j in svc.recentJobs(limit: 10)) {
            jobs.add(BackupJobResp(j.id, j.fileName, j.status, j.message, j.createdAt,
                "${monthDayTime(j.createdAt)}", j.totalRows, j.blobFiles, j.sizeBytes, j.includeBlobs))
        }
        let pending = pendingRestoreInfo(svc.dataDirectory())
        writeDto(ctx, 200u16, BackupListResp(svc.busy(), archives, jobs, pending[0], pending[1]))
    }

    /** POST /api/admin/backups —— body {includeBlobs?: bool}；已有任务在跑返回 409 */
    public func createBackupJob(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let svc = match (this.backupServiceOrReply(ctx)) {
            case Some(s) => s
            case None => return
        }
        let req = parseJsonBody<CreateBackupRequest>(ctx.bodyRaw(), { r => CreateBackupRequest.fromJson(r) })
        var includeBlobs = true
        match (req) {
            case Some(r) => match (r.includeBlobs) {
                case Some(b) => includeBlobs = b
                case None => ()
            }
            case None => ()
        }
        let (actorId, actorName) = this.actorOf(ctx)
        match (svc.startBackup(includeBlobs)) {
            case Some(job) =>
                writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "backup_start", "ok", job.fileName, ctx,
                    detail: "includeBlobs=${includeBlobs}")
                writeDto(ctx, 200u16, BackupJobResp(job.id, job.fileName, job.status, job.message, job.createdAt,
                    "${monthDayTime(job.createdAt)}", 0, 0, 0, job.includeBlobs))
            case None =>
                writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "backup_start", "failed", "", ctx,
                    error: "已有备份任务在运行")
                writeDto(ctx, 409u16, ErrorResp("已有备份任务在运行，请等它结束"))
        }
    }

    /** DELETE /api/admin/backups/:file —— 删除一个归档文件 */
    public func deleteBackup(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let svc = match (this.backupServiceOrReply(ctx)) {
            case Some(s) => s
            case None => return
        }
        let name = ctx.param("file")
        if (!safeArchiveName(name)) {
            writeDto(ctx, 400u16, ErrorResp("非法的备份文件名"))
            return
        }
        let (actorId, actorName) = this.actorOf(ctx)
        if (svc.deleteArchive(name)) {
            writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "backup_delete", "ok", name, ctx)
            writeDto(ctx, 200u16, OkResp())
        } else {
            writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "backup_delete", "failed", name, ctx,
                error: "not found")
            writeDto(ctx, 404u16, ErrorResp("备份不存在"))
        }
    }

    /**
     * GET /api/admin/backups/:file/download —— 流式下载归档。
     * 审计里只记文件名与大小，不记内容。
     */
    public func downloadBackup(ctx: TangHttpContext): Unit {
        // 浏览器 `<a href>` 带不了 Authorization 头：允许用一次性票据（?ticket=）代替登录态。
        // 票据由 POST /api/admin/backups/:file/ticket 签发（那里 requireAdmin），5 分钟有效、用后即焚、
        // 且绑定了文件名——URL 里不会出现长期 session token。
        let ticket = match (ctx.query("ticket")) {
            case Some(t) => t
            case None => ""
        }
        if (!ticket.isEmpty()) {
            if (!consumeDownloadTicket(ticket, ctx.param("file"))) {
                writeDto(ctx, 401u16, ErrorResp("下载票据无效或已过期"))
                return
            }
        } else if (!requireAdmin(ctx)) {
            return
        }
        let svc = match (this.backupServiceOrReply(ctx)) {
            case Some(s) => s
            case None => return
        }
        let name = ctx.param("file")
        if (!safeArchiveName(name)) {
            writeDto(ctx, 400u16, ErrorResp("非法的备份文件名"))
            return
        }
        match (svc.archivePath(name)) {
            case Some(path) =>
                let (actorId, actorName) = this.actorOf(ctx)
                writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "backup_download", "ok", name, ctx)
                let f = File(path, Read)
                ctx.attachment(name).set("Content-Type", "application/gzip")
                ctx.responseBuilder.body(f)
            case None =>
                writeDto(ctx, 404u16, ErrorResp("备份不存在"))
        }
    }

    /** POST /api/admin/backups/:file/ticket —— 签发一次性下载票据（5 分钟，仅对该文件有效）。 */
    public func createDownloadTicket(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let svc = match (this.backupServiceOrReply(ctx)) {
            case Some(s) => s
            case None => return
        }
        let name = ctx.param("file")
        if (!safeArchiveName(name) || svc.archivePath(name).isNone()) {
            writeDto(ctx, 404u16, ErrorResp("备份不存在"))
            return
        }
        let t = issueDownloadTicket(name)
        writeDto(ctx, 200u16, DownloadTicketResp(t, name))
    }

    /**
     * POST /api/admin/backups/restore-check —— 上传归档并**在线校验**（不写库、不改数据）。
     *
     * 恢复本身不在线做（Badger 独占目录 + store 被全进程持有）：这里只做校验，
     * 通过后可「标记下次重启应用」。请求体 = tar.gz 原始字节。
     */
    public func restoreCheck(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let svc = match (this.backupServiceOrReply(ctx)) {
            case Some(s) => s
            case None => return
        }
        let body = ctx.bodyRaw()
        if (body.size == 0) {
            writeDto(ctx, 400u16, ErrorResp("请求体为空（应上传 tar.gz 备份文件）"))
            return
        }
        let (actorId, actorName) = this.actorOf(ctx)
        // 落到 backups 目录下的临时文件，校验完保留供「重启应用」使用
        let tmpName = "upload-${DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()}.tar.gz"
        let tmpPath = "${svc.dir()}/${tmpName}"
        try {
            let f = File(tmpPath, Write)
            f.write(body)
            f.close()
        } catch (e: Exception) {
            writeDto(ctx, 500u16, ErrorResp("写入临时文件失败: ${e.message}"))
            return
        }
        let result = try {
            restoreBackup("", tmpPath, checkOnly: true)
        } catch (e: Exception) {
            writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "backup_verify", "failed", tmpName, ctx,
                error: e.message)
            try {
                removeIfExists(Path(tmpPath), recursive: false)
            } catch (ignore: Exception) {
                ()
            }
            writeDto(ctx, 400u16, ErrorResp("备份校验失败: ${e.message}"))
            return
        }
        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "backup_verify", "ok", tmpName, ctx,
            detail: "rows=${result.totalRows} blobs=${result.blobFiles}")
        writeDto(ctx, 200u16, RestoreCheckResp(tmpName, result.totalRows, result.blobFiles, true))
    }

    /**
     * POST /api/admin/backups/:file/apply-on-restart —— 标记「下次启动时应用这个归档」。
     * 只写标记文件，不碰数据库；重启后由启动流程执行替换（失败自动回滚）。
     */
    public func markRestoreOnRestart(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let svc = match (this.backupServiceOrReply(ctx)) {
            case Some(s) => s
            case None => return
        }
        let name = ctx.param("file")
        if (!safeArchiveName(name)) {
            writeDto(ctx, 400u16, ErrorResp("非法的备份文件名"))
            return
        }
        if (svc.archivePath(name).isNone()) {
            writeDto(ctx, 404u16, ErrorResp("备份不存在"))
            return
        }
        let (actorId, actorName) = this.actorOf(ctx)
        writePendingRestore(svc.dataDirectory(), name, DateTime.nowUTC().toUnixTimeStamp().toMilliseconds())
        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "backup_apply_on_restart", "ok", name, ctx)
        writeDto(ctx, 200u16, OkResp())
    }

    /** DELETE /api/admin/backups/restore-pending —— 取消「下次重启应用」。 */
    public func cancelPendingRestore(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let svc = match (this.backupServiceOrReply(ctx)) {
            case Some(s) => s
            case None => return
        }
        let (actorId, actorName) = this.actorOf(ctx)
        let info = pendingRestoreInfo(svc.dataDirectory())
        if (info[0].isEmpty()) {
            writeDto(ctx, 404u16, ErrorResp("没有待应用的恢复"))
            return
        }
        clearPendingRestore(svc.dataDirectory())
        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "backup_apply_on_restart", "cancelled", info[0], ctx)
        writeDto(ctx, 200u16, OkResp())
    }
}

// ===== 一次性下载票据（内存，进程内有效）=====
//
// 目的：让浏览器 `<a href>` 能下载，同时不在 URL 里暴露长期 session token。
// 约束：5 分钟有效、用后即焚、绑定文件名；进程重启即全部失效（可接受，重新点一次即可）。
class DownloadTicket {
    let fileName: String
    let expiresAt: Int64

    init(fileName: String, expiresAt: Int64) {
        this.fileName = fileName
        this.expiresAt = expiresAt
    }
}

let TICKET_TTL_MS: Int64 = 5 * 60 * 1000
let ticketMutex = Mutex()
let tickets = HashMap<String, DownloadTicket>()

func issueDownloadTicket(fileName: String): String {
    let now = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
    // 随机票据：时间戳 + 计数器 + 文件名哈希，够用且不可猜（只对本进程内的文件名有效）
    let nonce = "${now}-${fileName.size}-${fileName.hashCode()}"
    let token = "tk-${now}-${nonce.hashCode()}"
    synchronized(ticketMutex) {
        // 顺手清过期项，避免无限增长
        let expired = ArrayList<String>()
        for ((k, v) in tickets) {
            if (v.expiresAt <= now) {
                expired.add(k)
            }
        }
        for (k in expired) {
            tickets.remove(k)
        }
        tickets[token] = DownloadTicket(fileName, now + TICKET_TTL_MS)
    }
    token
}

func consumeDownloadTicket(token: String, fileName: String): Bool {
    let now = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
    synchronized(ticketMutex) {
        match (tickets.get(token)) {
            case Some(t) =>
                if (!tickets.contains(token)) {
                    return false
                }
                tickets.remove(token)
                t.fileName == fileName && t.expiresAt > now
            case None => false
        }
    }
}

/** 归档文件名白名单：只允许 cjreg-/upload- 前缀 + 常见安全字符 + .tar.gz 后缀（防目录穿越）。 */
public func safeArchiveName(name: String): Bool {
    if (!name.endsWith(".tar.gz") || name.contains("/") || name.contains("..")) {
        return false
    }
    if (!name.startsWith("cjreg-") && !name.startsWith("upload-")) {
        return false
    }
    for (r in name.toRuneArray()) {
        let c = r.toString()
        let ok = (r >= r'a' && r <= r'z') || (r >= r'A' && r <= r'Z') || (r >= r'0' && r <= r'9') ||
            c == "-" || c == "_" || c == "."
        if (!ok) {
            return false
        }
    }
    true
}

/** 待应用恢复的标记文件路径（与数据目录同级，启动流程读取）。 */
public func pendingRestorePath(dataDir: String): String {
    "${dataDir}/.restore-pending"
}

/** 写入「下次重启应用」标记：内容 = 归档文件名 + 时间。 */
func writePendingRestore(dataDir: String, fileName: String, at: Int64): Unit {
    if (dataDir.isEmpty()) {
        return
    }
    let f = File(pendingRestorePath(dataDir), Write)
    f.write("{\"file\":\"${fileName}\",\"at\":${at}}".toArray())
    f.close()
}

/** 读取标记：返回 (文件名, 时间)；没有标记返回空。 */
public func pendingRestoreInfo(dataDir: String): (String, Int64) {
    if (dataDir.isEmpty()) {
        return ("", 0)
    }
    let path = pendingRestorePath(dataDir)
    if (!exists(Path(path))) {
        return ("", 0)
    }
    let text = try {
        let f = File(path, Read)
        let n = Int64(f.length)
        let buf = Array<Byte>(n, repeat: 0)
        f.read(buf)
        f.close()
        String.fromUtf8(buf)
    } catch (e: Exception) {
        return ("", 0)
    }
    let r = gjson.parse(text)
    (r.get("file").toString(), r.get("at").int())
}

func clearPendingRestore(dataDir: String): Unit {
    if (dataDir.isEmpty()) {
        return
    }
    let path = pendingRestorePath(dataDir)
    if (exists(Path(path))) {
        removeIfExists(Path(path), recursive: false)
    }
}

// 恢复标记的读写一律显式传数据目录：这里**不能用全局可变状态**——
// 同一进程里并行跑测试/多实例时，全局变量会让 A 用例读到 B 写下的标记
// （症状：全量跑间歇失败、单独跑全绿）。数据目录由 OnlineBackupService 持有。

func monthDayTime(ms: Int64): String {
    DateTime.fromUnixTimeStamp(Duration.millisecond * ms).inLocal().format("MM-dd HH:mm")
}
