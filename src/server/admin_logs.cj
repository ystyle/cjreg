// 管理 API · 审计日志（查询 / 清理）——AdminService 的日志域扩展
package ystyle::cjreg.server

import tang.*
import ystyle::cjreg.store.*
import stdx.encoding.json.stream.*
import std.collection.*
import std.io.*

extend AdminService {
    // ===== 审计日志查询/清理 =====
    // GET /api/admin/logs/:kind?keyword=&status=&from=&to=&offset=&limit=
    // kind: publish|admin|auth|all（未知值按 all）；from/to 为毫秒时间戳（0 = 不限）
    public func queryLogs(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let kind = parseAuditKind(ctx.param("kind"))
        let keyword = ctx.query("keyword") ?? ""
        let status = ctx.query("status") ?? ""
        let from = parseI64(ctx.query("from"))
        let to = parseI64(ctx.query("to"))
        var offset = parseI64(ctx.query("offset"))
        if (offset < 0) {
            offset = 0
        }
        var limit = parseI64(ctx.query("limit"))
        if (limit <= 0) {
            limit = 50
        }
        if (limit > 500) {
            limit = 500
        }
        let (rows, total) = match (this.adminData) {
            case Some(ad) => ad.queryLogs(kind, keyword, status, from, to, offset, limit)
            case None => (ArrayList<LogDoc>(), 0)
        }
        let items = ArrayList<LogRowDto>()
        for (d in rows) {
            items.add(LogRowDto(d.id, d.kind, d.actorId, d.actorName, d.action, d.status, d.target,
                d.detail, d.error, d.ipAddr, d.userAgent, d.createdAt))
        }
        writeDto(ctx, 200u16, LogQueryResp(total, offset, limit, items))
    }

    // POST /api/admin/logs/clean  body {kind?: publish|admin|auth|all, before?: 毫秒}
    // 无 body 时清空全部；返回 {"deleted":N}
    public func cleanLogs(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let body = String.fromUtf8(ctx.bodyRaw())
        var kindRaw = ""
        var before: Int64 = 0
        if (!body.trimAscii().isEmpty()) {
            let bb = ByteBuffer()
            bb.write(body.toArray())
            let r = JsonReader(bb)
            try {
                r.startObject()
                while (r.peek() != EndObject) {
                    let n = r.readName()
                    match (n) {
                        case "kind" => kindRaw = r.readValue<String>()
                        case "before" => before = r.readValue<Int64>()
                        case _ => r.skip()
                    }
                }
                r.endObject()
            } catch (e: Exception) {
                writeDto(ctx, 400u16, ErrorResp("invalid JSON body"))
                return
            }
        }
        let kind = parseAuditKind(kindRaw)
        let (actorId, actorName) = this.actorOf(ctx)
        let deleted = match (this.adminData) {
            case Some(ad) => ad.removeLogs(kind, before)
            case None => 0
        }
        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "clean_logs", "ok",
            if (kindRaw.isEmpty()) { "all" } else { kindRaw }, ctx,
            detail: "deleted=${deleted} before=${before}")
        writeDto(ctx, 200u16, DeletedResp(deleted))
    }
}
