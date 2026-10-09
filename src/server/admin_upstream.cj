// 管理 API · 上游管理（列表 / 新增 / 更新 / 删除 / 连通性测试）——AdminService 的上游域扩展
package ystyle::cjreg.server

import tang.*
import ystyle::cjreg.store.*
import stdx.encoding.json.stream.*
import std.collection.*
import std.io.*
import std.convert.*

extend AdminService {
    // ===== 上游管理 =====
    public func listUpstreams(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let list = this.upstreamStore.listAll()
        let rows = ArrayList<UpstreamDto>()
        for (u in list) {
            rows.add(UpstreamDto(u.id, u.name, u.url, u.enabled, u.isOfficial, u.priority, u.cacheTtl,
                u.proxyEnabled, u.asTarget))
        }
        // 契约是**裸数组**（不是 {total,items} 包装）：外部脚本按 Array 解析
        writeDto(ctx, 200u16, rows)
    }

    public func addUpstream(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let body = String.fromUtf8(ctx.bodyRaw())
        var name = ""
        var url = ""
        var priorityStr = ""
        // 两个正交开关的缺省：参与回源、**不**允许作为发布计划目标
        // （推送不可逆，目标仓要显式授权；与 UpstreamService.add 的默认值一致）
        var proxyEnabled = true
        var asTarget = false
        let bb = ByteBuffer()
        bb.write(body.toArray())
        let r = JsonReader(bb)
        try {
            while (let Some(v) <- r.peek()) {
                match (v) {
                    case BeginObject =>
                        r.startObject()
                        while (r.peek() != EndObject) {
                            let n = r.readName()
                            match (n) {
                                case "name" => name = r.readValue<String>()
                                case "url" => url = r.readValue<String>()
                                case "priority" => priorityStr = r.readValue<String>()
                                case "proxy_enabled" => proxyEnabled = r.readValue<Bool>()
                                case "as_target" => asTarget = r.readValue<Bool>()
                                case _ => r.skip()
                            }
                        }
                        r.endObject()
                        break
                    case _ => r.skip()
                }
            }
        } catch (e: Exception) {
            // 请求体不是合法 JSON：下面只会回 400「name and url required」，
            // 那会把「JSON 语法错」说成「字段没填」——留痕以免误诊（响应不变）
            eprintln("[cjreg] 新增上游请求体解析失败（按字段缺失处理）: " + e.toString())
        }
        let priority = parsePriority(priorityStr)
        if (name.isEmpty() || url.isEmpty()) {
            writeDto(ctx, 400u16, ErrorResp("name and url required"))
            return
        }
        let (upActorId, upActorName) = this.actorOf(ctx)
        match (this.upstreamSvc.add(name, url, priority, "", 0, proxyEnabled: proxyEnabled, asTarget: asTarget)) {
            case Some(u) =>
                writeAudit(this.adminData, LogKind.Admin, upActorId, upActorName, "add_upstream", "ok", name, ctx,
                    detail: "url=${url} priority=${priority} proxyEnabled=${proxyEnabled} asTarget=${asTarget}")
                writeDto(ctx, 200u16, UpstreamAddedResp(u.id, u.name, u.isOfficial, u.proxyEnabled,
                    u.asTarget))
            case None =>
                writeAudit(this.adminData, LogKind.Admin, upActorId, upActorName, "add_upstream", "failed", name, ctx,
                    error: "upstream name exists or invalid")
                writeDto(ctx, 409u16, ErrorResp("upstream name exists or invalid"))
        }
    }

    // PUT /api/admin/upstreams/:id —— 局部更新：body 里出现哪个字段就改哪个
    // 支持 enabled / proxyEnabled / asTarget / priority / cacheTtl / authToken
    // （启用开关与两个正交能力开关都走这里，脚本/CI 可自动配置）
    public func updateUpstream(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let id = match (Int64.tryParse(ctx.param("id").trimAscii())) {
            case Some(n) => n
            case None =>
                writeDto(ctx, 400u16, ErrorResp("invalid upstream id (expect numeric id)"))
                return
        }
        let body = String.fromUtf8(ctx.bodyRaw())
        var enabled: ?Bool = None
        var proxyEnabled: ?Bool = None
        var asTarget: ?Bool = None
        var priority: ?Int64 = None
        var cacheTtl: ?Int64 = None
        var authToken: ?String = None
        let bb = ByteBuffer()
        bb.write(body.toArray())
        let r = JsonReader(bb)
        try {
            while (let Some(v) <- r.peek()) {
                match (v) {
                    case BeginObject =>
                        r.startObject()
                        while (r.peek() != EndObject) {
                            let n = r.readName()
                            match (n) {
                                case "enabled" => enabled = Some(r.readValue<Bool>())
                                case "proxyEnabled" => proxyEnabled = Some(r.readValue<Bool>())
                                case "asTarget" => asTarget = Some(r.readValue<Bool>())
                                case "priority" => priority = Some(r.readValue<Int64>())
                                case "cacheTtl" => cacheTtl = Some(r.readValue<Int64>())
                                case "authToken" => authToken = Some(r.readValue<String>())
                                case _ => r.skip()
                            }
                        }
                        r.endObject()
                        break
                    case _ => r.skip()
                }
            }
        } catch (e: Exception) {
            eprintln("[cjreg] 更新上游请求体解析失败: " + e.toString())
            writeDto(ctx, 400u16, ErrorResp("invalid json body"))
            return
        }
        let (actorId, actorName) = this.actorOf(ctx)
        if (this.upstreamSvc.update(id, enabled, priority, cacheTtl, authToken, proxyEnabled: proxyEnabled, asTarget: asTarget)) {
            writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "update_upstream", "ok", "#${id}", ctx,
                detail: "enabled=${enabled.isSome()} proxyEnabled=${proxyEnabled.isSome()} asTarget=${asTarget.isSome()}")
            writeDto(ctx, 200u16, OkResp())
        } else {
            writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "update_upstream", "failed", "#${id}", ctx,
                error: "not found")
            writeDto(ctx, 404u16, ErrorResp("upstream not found"))
        }
    }

    public func deleteUpstream(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        // 路径参数可能是任意串（例如误传上游名）：解析失败要回 400，
        // 不能让 Int64.parse 的异常冒到框架层变成 500
        let id = match (Int64.tryParse(ctx.param("id").trimAscii())) {
            case Some(n) => n
            case None =>
                writeDto(ctx, 400u16, ErrorResp("invalid upstream id (expect numeric id)"))
                return
        }
        let (delActorId, delActorName) = this.actorOf(ctx)
        // 目标名尽量取真实上游名（删除后查不到，故先查）
        var upName = "#${id}"
        for (u in this.upstreamStore.listAll()) {
            if (u.id == id) {
                upName = u.name
            }
        }
        if (this.upstreamSvc.remove(id)) {
            writeAudit(this.adminData, LogKind.Admin, delActorId, delActorName, "delete_upstream", "ok", upName, ctx)
            writeDto(ctx, 200u16, OkResp())
        } else {
            writeAudit(this.adminData, LogKind.Admin, delActorId, delActorName, "delete_upstream", "failed", upName, ctx,
                error: "not found or official protected")
            writeDto(ctx, 409u16, ErrorResp("cannot delete (not found or official protected)"))
        }
    }

    // POST /api/admin/upstreams/:id/test?name=&organization=
    // 连通性测试：指定 name（≥3 字符）测索引端点，否则测基地址；结果含状态码/耗时/正文大小/包名样本
    public func testUpstream(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let id = match (Int64.tryParse(ctx.param("id"))) {
            case Some(n) => n
            case None => 0
        }
        let up = match (this.upstreamStore.getById(id)) {
            case Some(u) => u
            case None =>
                writeDto(ctx, 404u16, ErrorResp("upstream not found"))
                return
        }
        let name = ctx.query("name") ?? ""
        let org = ctx.query("organization") ?? ""
        let result = probeUpstream(up, name, org)
        let (actorId, actorName) = this.actorOf(ctx)
        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "test_upstream",
            if (result.reachable) { "ok" } else { "failed" }, up.name, ctx,
            error: result.error,
            detail: "status=${result.status} latency=${result.latencyMs}ms healthy=${result.healthy} url=${result.testedUrl}")
        writeDto(ctx, 200u16, upstreamProbeJson(result))
    }

    func parsePriority(v: String): Int64 {
        let n = Int64.tryParse(v)
        match (n) {
            case Some(p) => return p
            case None => return 0
        }
    }
}
