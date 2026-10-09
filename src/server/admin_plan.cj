// 管理 API · 发布计划与 resolve 诊断（analyze / execute / SSE 进度 / 跳过单项）——AdminService 的计划域扩展
package ystyle::cjreg.server

import tang.*
import ystyle::cjreg.config.*
import ystyle::cjreg.store.*
import stdx.encoding.json.stream.*
import std.collection.*
import std.io.*
import std.convert.*

extend AdminService {
    // ===== resolve 诊断端点 =====
    public func resolvePackage(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let name = ctx.query("name") ?? ""
        let org = ctx.query("organization") ?? ""
        let require = ctx.query("require") ?? ""
        if (name.isEmpty()) {
            writeDto(ctx, 400u16, ErrorResp("name required"))
            return
        }
        let fetchIndex: (String, String) -> ?String = { o: String, n: String =>
            match (this.proxySvc) {
                case Some(proxy) =>
                    let (outcome, ndjson) = proxy.fetchIndex(o, n)
                    if (ndjson.isEmpty()) {
                        None
                    } else {
                        Some(ndjson)
                    }
                case None => None
            }
        }
        let r = this.resolveSvc.resolve(name, org, require, fetchIndex)
        // selected 未命中时输出 null（不是省略字段）：消费方靠它区分「没有候选」与「字段缺失」
        let selected = match (r.selected) {
            case Some(c) => Some(resolveCandidateDto(c))
            case None => Option<ResolveCandidateDto>.None
        }
        let candidates = ArrayList<ResolveCandidateDto>()
        for (c in r.candidates) {
            candidates.add(resolveCandidateDto(c))
        }
        writeDto(ctx, 200u16, ResolveResp(r.name, r.org, r.require, r.found, r.replaced, r.replacedBy,
            selected, candidates, r.trace))
    }

    // ===== 发布计划 analyze =====
    // body: {packages:[{organization,name,version}], target_upstream?}
    // 给了 target_upstream 就按目标仓索引分类（need_publish/already_exists/conflict/version_optional）
// ── 发布计划进度（SSE 事件负载）─────────────────────────────────────────────
// 事件序列：`event: progress`（一次状态快照）；计划进入终态时再补 `event: done`。
//
// 为什么是「一次连接推一份快照」而不是长连接挂起：tang 跑在单线程事件循环上，
// 在 handler 里阻塞等待状态变化（sleep 心跳之类）会把整个服务卡住。EventSource 在
// 连接结束后会自动重连，因此「快照 + 自动重连」等价于由客户端驱动的高频轮询：
// 服务端零阻塞、不需要订阅表。管理页现有的定时轮询作为兜底保留，读的是同一份存储状态。

    public func analyzePlan(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let body = String.fromUtf8(ctx.bodyRaw())
        var roots = ArrayList<(String, String, String)>()
        parsePackagesBody(body, roots)
        if (roots.size == 0) {
            writeDto(ctx, 400u16, ErrorResp("packages required"))
            return
        }
        let targetId = parseTargetUpstream(body)
        let analysis = this.analyzeWithTarget(roots, targetId)
        let order = ArrayList<PlanItemAnalysisDto>()
        for (it in analysis.items) {
            // 目标仓对照：`target_version` 是目标仓该包最新版本；没做成对照时它为空，
            // 消费方必须连 `target_compared` 一起看才能区分「目标仓没有这个包」与「没查到」。
            order.add(PlanItemAnalysisDto(it.name, it.org, it.version, it.order, planCategoryName(it.category),
                it.selected, it.localSha256, it.remoteSha256, it.requirement, it.targetVersion, it.targetCompared))
        }
        writeDto(ctx, 200u16, PlanAnalyzeResp(analysis.targetChecked, analysis.targetError, order,
            analysis.hasCycle))
    }

    // 按目标上游做 analyze（targetId <= 0 或上游不存在 = 不做目标仓对比）
    public func analyzeWithTarget(roots: ArrayList<(String, String, String)>, targetId: Int64): PlanAnalysis {
        let target = if (targetId > 0) { this.upstreamStore.getById(targetId) } else { Option<Upstream>.None }
        let proxy = this.proxySvc
        this.planSvc.analyze(roots, targetUpstream: target, fetchIndex: { up, org, name =>
            match (proxy) {
                case Some(p) => p.probeUpstreamIndex(up, org, name)
                case None => IndexProbe(0, "", detail: "本实例未接入回源代理")
            }
        })
    }

    // 发布计划执行：POST /api/admin/publish-plans/execute
    // body: {packages:[{organization,name,version}], target_url, target_token?}
    // target_token 为空时按 target_url 匹配上游表取该上游的 authToken
    // （否则推送到需要认证的目标仓——如官方中心仓或另一个私有仓——会 401）
    // 手动跳过某个发布项：标记后执行器不再推送它（不计失败）。用于「这一项不想推」的场景，
    // 例如目标仓已有等价版本、或该依赖需要人工处理。计划详情页与脚本都可调用。
    public func skipPlanItem(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        var planId: Int64 = -1
        var itemId: Int64 = -1
        try {
            planId = Int64.parse(ctx.param("id"))
            itemId = Int64.parse(ctx.param("itemId"))
        } catch (e: Exception) {
            planId = -1
            itemId = -1
        }
        if (planId < 0 || itemId < 0) {
            writeDto(ctx, 400u16, ErrorResp("invalid plan or item id"))
            return
        }
        let (actorId, actorName) = this.actorOf(ctx)
        match (this.adminData) {
            case None => writeDto(ctx, 503u16, ErrorResp("admin store unavailable"))
            case Some(ad) =>
                let item = ad.getPlanItem(itemId)
                match (item) {
                    case None =>
                        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "skip_plan_item", "failed",
                            "plan=${planId} item=${itemId}", ctx, error: "item not found")
                        writeDto(ctx, 404u16, ErrorResp("plan item not found"))
                    case Some(it) =>
                        // 归属校验：不能拿 A 计划的 id 去改 B 计划的项
                        if (it.planId != planId) {
                            writeDto(ctx, 404u16, ErrorResp("plan item not found in this plan"))
                            return
                        }
                        ad.updatePlanItem(itemId, "skipped", "手动跳过", nowMsUtc())
                        let target = "${it.packageOrg}::${it.packageName}@${it.packageVersion}"
                        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, "skip_plan_item", "ok",
                            target, ctx, detail: "plan=${planId} item=${itemId}")
                        writeDto(ctx, 200u16, SkipItemResp(itemId))
                }
        }
    }

    // 发布计划进度流（SSE）。鉴权与其它管理端点一致；响应头走 stdx 的 HttpResponseBuilder。
    public func planEvents(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        var planId: Int64 = -1
        try {
            planId = Int64.parse(ctx.param("id"))
        } catch (e: Exception) {
            planId = -1
        }
        if (planId < 0) {
            writeDto(ctx, 400u16, ErrorResp("invalid plan id"))
            return
        }
        match (this.adminData) {
            case None => writeDto(ctx, 503u16, ErrorResp("admin store unavailable"))
            case Some(ad) =>
                match (ad.getPlan(planId)) {
                    case None => writeDto(ctx, 404u16, ErrorResp("plan not found"))
                    case Some(plan) =>
                        let payload = buildPlanEventsPayload(plan, ad.listPlanItems(planId))
                        ctx.responseBuilder
                            .header("Content-Type", "text/event-stream; charset=utf-8")
                            .header("Cache-Control", "no-cache")
                            .header("X-Accel-Buffering", "no")
                            .status(200u16)
                            .body(payload.toArray())
                }
        }
    }

    public func executePlan(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let body = String.fromUtf8(ctx.bodyRaw())
        var roots = ArrayList<(String, String, String)>()
        parsePackagesBody(body, roots)
        var targetUrl = ""
        var targetToken = ""
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
                            if (n == "target_url") {
                                targetUrl = r.readValue<String>()
                            } else if (n == "target_token") {
                                targetToken = r.readValue<String>()
                            } else {
                                r.skip()
                            }
                        }
                        r.endObject()
                        break
                    case _ => r.skip()
                }
            }
        } catch (e: Exception) {
            // 同新增上游：坏 JSON 只会回 400「packages and target_url required」，
            // 会把语法错说成字段缺失——留痕以免误诊（响应不变）
            eprintln("[cjreg] 执行发布计划请求体解析失败（按字段缺失处理）: " + e.toString())
        }
        let (planActorId, planActorName) = this.actorOf(ctx)
        if (roots.size == 0 || targetUrl.isEmpty()) {
            writeAudit(this.adminData, LogKind.Admin, planActorId, planActorName, "execute_publish_plan", "failed",
                targetUrl, ctx, error: "packages and target_url required")
            writeDto(ctx, 400u16, ErrorResp("packages and target_url required"))
            return
        }
        // 目标仓鉴权：显式 target_token 优先，否则按 URL 匹配上游表取该上游 authToken
        // （token 属敏感信息，审计只记「是否使用显式 token」，不落明文）
        let token = resolveTargetToken(targetToken, targetUrl, this.upstreamStore.listAll())
        // 先 analyze 得拓扑 items（legacy 接口不带目标仓，分类不参与执行）
        let analysis = this.planSvc.analyze(roots)
        let items = analysis.items
        if (items.size == 0) {
            writeAudit(this.adminData, LogKind.Admin, planActorId, planActorName, "execute_publish_plan", "failed",
                targetUrl, ctx, error: "no packages found locally")
            writeDto(ctx, 400u16, ErrorResp("no packages found locally"))
            return
        }
        let report = this.executor.execute(items, targetUrl, token)
        // 状态与审计按「是否中止」区分：429/401/403 是**暂停**（可续跑），不是失败
        let outcome = if (report.aborted) {
            "paused"
        } else if (report.failed > 0) {
            "failed"
        } else {
            "ok"
        }
        writeAudit(this.adminData, LogKind.Admin, planActorId, planActorName, "execute_publish_plan",
            outcome, targetUrl, ctx,
            error: if (report.aborted) {
                report.abortReason
            } else if (report.errors.size > 0) {
                report.errors[0]
            } else {
                ""
            },
            detail: "success=${report.success} skipped=${report.skipped} failed=${report.failed} " +
                "total=${report.total} aborted=${report.aborted} roots=${roots.size} " +
                "explicitToken=${!targetToken.isEmpty()}")
        writeDto(ctx, 200u16, PlanExecuteResp(report.success, report.skipped, report.failed, report.total,
            report.aborted, report.abortReason, report.errors))
    }
}

// 目标仓发布 token 解析：显式传入优先；否则按 URL 匹配上游表取其 authToken
// （发布计划推送到官方仓或另一个私有仓时都要带 token，否则目标仓 401）
public func resolveTargetToken(explicit: String, targetUrl: String, upstreams: ArrayList<Upstream>): String {
    if (!explicit.isEmpty()) {
        return explicit
    }
    let want = trimUrl(targetUrl)
    for (u in upstreams) {
        if (trimUrl(u.url) == want) {
            return u.authToken
        }
    }
    ""
}

// URL 归一（去尾部斜杠，便于比较）
func trimUrl(v: String): String {
    var s = v.trimAscii()
    while (s.size > 0 && s[s.size - 1] == 47u8) {
        s = s[0..s.size - 1]
    }
    s
}

// 解析候选项 → 响应 DTO（selected 与 candidates 同一形态）
func resolveCandidateDto(c: ResolveCandidate): ResolveCandidateDto {
    ResolveCandidateDto(c.repo, c.version, c.sha256sum, c.conflict)
}

public func buildPlanEventsPayload(plan: PlanDoc, items: ArrayList<PlanItemDoc>): String {
    let rows = ArrayList<PlanProgressItemDto>()
    for (it in items) {
        rows.add(PlanProgressItemDto(it.id, it.packageOrg, it.packageName, it.packageVersion,
            it.status, it.error))
    }
    // 帧结构（event/data/空行）与终态 done 语义不变；data 里的 JSON 由序列化器生成
    let sb = StringBuilder()
    sb.append("event: progress\n")
    sb.append("data: ")
    sb.append(jsonText(PlanProgressDto(plan.id, plan.status, plan.completedCount, plan.totalCount,
        plan.lastError, rows)))
    sb.append("\n\n")
    if (plan.status == "completed" || plan.status == "failed") {
        sb.append("event: done\n")
        sb.append("data: ")
        sb.append(jsonText(PlanDoneDto(plan.id, plan.status)))
        sb.append("\n\n")
    }
    return sb.toString()
}
