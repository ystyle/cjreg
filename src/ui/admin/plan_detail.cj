// 管理端发布计划详情（@Page /admin/publish-plans/[id]）
package ystyle::cjreg.ui.admin

import ystyle::cjreg.ui.*
import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import ystyle::cjreg.store.*
import ystyle::cjreg.config.*
import ystyle::cjreg.server.{BlobStore, DiskBlobStore, ExecuteReport, IndexProbe, PlanCategory, PlanItem, PlanItemStatus, PublishExecutor, PublishPlanService, applyAnalysisToPlan, categoryHint, checkVersionsInIndex, countRequired, indexWaitRhythmText, packageLabel, planCategoryName, progressTextOf, targetCompareText, targetOverwritable}
import ystyle::cjreg.index.*
import ystyle::cjreg.semver_range.*
import std.collection.*
import std.sort.*
import std.convert.*
import std.time.*

// ===== 计划详情 =====
@Page["/admin/publish-plans/[id]", "发布计划详情", requireAdmin]
class PublishPlanDetailPage <: Component {
    var state: Option<CjregState> = None
    var planId: Int64 = 0
    var msg = Signal<String>("")
    // 「重新分析」在跑：要逐包取目标仓索引（真网络），界面必须有加载态
    var analyzing = Signal<Bool>(false)
    // **全量**发布项（pushUpdate 时经 refreshItems 更新）：计数、执行、按钮判据都读它
    var items = Signal<ArrayList<PlanItemDoc>>(ArrayList<PlanItemDoc>())
    // 表格**显示行**：由 items + 隐藏开关派生（见 plan_items_filter.cj 为什么要分成两份）
    var itemRows = Signal<ArrayList<PlanItemDoc>>(ArrayList<PlanItemDoc>())
    // 隐藏"不会推送"的项（没勾选 / 已被判未推送）
    var hideUnpublished = Signal<Bool>(false)
    // 派生绑定：页面实例是路由注册期创建、跨请求复用的，onMount 必须重建，否则订阅会累积
    private var binding: Option<Effect> = None

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        match (ctx.route.params.get("id")) {
            case Some(v) =>
                match (Int64.tryParse(v)) {
                    case Some(n) => this.planId = n
                    case None => ()
                }
            case None => ()
        }
        refreshItems()
        this.rebind()
    }

    public func onUnmount(ctx: LifecycleContext): Unit {
        match (this.binding) {
            case Some(e) => e.dispose()
            case None => ()
        }
        this.binding = None
    }

    // 显示行 = visibleItems(items, hideUnpublished)：开关一拨就自动重算
    private func rebind(): Unit {
        match (this.binding) {
            case Some(e) => e.dispose()
            case None => ()
        }
        this.binding = Some(bindVisible(this.itemRows, { =>
            visibleItems(this.items.get(), this.hideUnpublished.get())
        }))
    }

    func backToList(ctx: ActionContext): PatchResult {
        ctx.route.push("/admin/publish-plans")
        PatchResult.ReRender
    }

    func upstreamName(st: CjregState, id: Int64): String {
        match (st.upStore.getById(id)) {
            case Some(u) => u.name
            case None => "#${id}"
        }
    }

    func statusTag(s: String): IComponent {
        match (s) {
            case "interrupted" => Tag([text("上次未收口")]).kind(ComponentKind.Danger)
            case "running" => Tag([text("执行中")]).kind(ComponentKind.Warning)
            case "completed" => Tag([text("已完成")]).kind(ComponentKind.Success)
            case "failed" => Tag([text("失败")]).kind(ComponentKind.Danger)
            case "paused" => Tag([text("已暂停")]).kind(ComponentKind.Info)
            case _ => Tag([text("待执行")]).kind(ComponentKind.Primary)
        }
    }

    func itemStatusTag(s: String): IComponent {
        match (s) {
            case "completed" => Tag([text("成功")]).kind(ComponentKind.Success)
            case "failed" => Tag([text("失败")]).kind(ComponentKind.Danger)
            case "running" => Tag([text("推送中")]).kind(ComponentKind.Warning)
            case "waiting_index" => Tag([text("等待索引")]).kind(ComponentKind.Warning)
            case "skipped" => Tag([text("未推送")]).kind(ComponentKind.Info)
            // 默认（pending）用「未推送」而不是「待发布」：分类列已经有一档叫「待发布」，
            // 两列都写「待发布」会让人以为分类没生效
            case _ => Tag([text("未推送")]).kind(ComponentKind.Info)
        }
    }

    // 分类标签。注意：**分类是建计划（或上次重新分析）那一刻的目标仓比对结果**，
    // 一旦本次计划真的把它推成功了，再显示「待发布」就是自相矛盾（实测用户就会问
    // "tsdb 明明发出去了，怎么还回退成待发布"）。所以按执行状态分层显示：
    //   已推送成功、在等索引 → 「已推送·等索引」
    //   已完成             → 「已发布」
    // 文案只留这一处：详情页与创建页的对照预览共用同一个函数。
    func categoryTag(c: String, status: String): IComponent {
        planCategoryTag(toPlanCategory(c), status)
    }

    // 有没有"已推送成功、在等目标仓索引"的项。
    // 按**全量**判：隐藏开关只是显示筛选，不能把「检查索引」按钮一起藏没了
    func hasWaitingIndex(): Bool {
        for (d in this.items.get()) {
            if (d.status == "waiting_index") {
                return true
            }
        }
        false
    }

    // 分类说明（执行前就能看出「为什么不用发」/「发不出去该怎么办」）。
    // 文案与执行器的跳过原因共用服务端那一份，避免两处说法不一致。
    func itemHint(c: String, overwriteAllowed: Bool): String {
        categoryHint(toPlanCategory(c), overwriteAllowed)
    }

    // 开始执行：异步线程推送，逐项通过 App.pushUpdate 推送进度
    func doStart(ctx: ActionContext): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            this.msg.set("无权限：需要管理员登录")
            return PatchResult.ReRender
        }
        if (containsId(st.planRunIds.get(), this.planId)) {
            this.msg.set("该计划正在执行中")
            return PatchResult.ReRender
        }
        let sid = ctx.getSessionId()
        match (st.adminData.getPlan(this.planId)) {
            case Some(plan) =>
                match (st.upStore.getById(plan.targetUpstream)) {
                    case Some(up) =>
                        let docs = st.adminData.listPlanItems(this.planId)
                        let execItems = ArrayList<PlanItem>()
                        // pkgId → 计划项 docId：执行回调是按项来的（一个项可能回调多次），
                        // 用索引并行数组会错位，必须按 pkgId 映射
                        let docIds = HashMap<Int64, Int64>()
                        var pending: Int64 = 0
                        for (d in docs) {
                            if (!d.selected) { continue }
                            let it = PlanItem(d.packageId, d.packageName, d.packageOrg, d.packageVersion, toPlanCategory(d.category), d.order)
                            it.selected = d.selected
                            // 目标仓是否允许覆盖：决定跳过原因怎么说（中心仓只能升版重发）
                            it.overwriteAllowed = targetOverwritable(Some(up))
                            // 带上库里已有的状态：续跑时执行器据此跳过已完成的项
                            it.status = toPlanItemStatus(d.status)
                            if (!(it.status == PlanItemStatus.Completed)) {
                                pending++
                            }
                            // 这里**不再**把待执行项一律标成 running：running 在界面上是「推送中」，
                            // 而执行器是逐项推的——批量标成推送中会让排在后面的项看起来也在发
                            // （实测：tsdb 在等索引的十分钟里，还没轮到的 bstorm 一直显示「推送中」）。
                            // 真实状态由执行器每项开始时写。
                            execItems.add(it)
                            docIds[d.packageId] = d.id
                        }
                        if (execItems.size == 0) {
                            this.msg.set("没有可执行的发布项")
                            return PatchResult.ReRender
                        }
                        if (pending == 0) {
                            this.msg.set("所有项都已完成，无需重复推送")
                            return PatchResult.ReRender
                        }
                        st.adminData.updatePlanStatus(this.planId, "running", 0, nowMs())
                        // 清掉上一轮的停止请求，并登记本轮（进程级：界面据此判断"真的在跑"）
                        removePlanId(st, this.planId, true)
                        addPlanId(st, this.planId, false)
                        st.planBusy.set(true)
                        st.planStatus.set("running")
                        st.planProgress.set("0/${execItems.size}")
                        st.adminData.addLog(LogKind.Publish, sessionUid(ctx), sessionUsername(ctx), "start plan ${plan.name}", "ok", nowMs())
                        // 异步执行（网络操作在线程内，DB 写在 pushUpdate 回调里串行化）
                        spawn { =>
                            this.runExecution(st, sid, execItems, docIds, up, plan.pollTimeout)
                        }
                    case None =>
                        this.msg.set("目标上游不存在")
                }
            case None =>
                this.msg.set("计划不存在")
        }
        PatchResult.ReRender
    }

    // 异步执行线程：逐项推送，每项完成通过 App.pushUpdate 推进度给前端。
    // 计划级语义（对齐官方返回码规格）：
    //   429 / 401 / 403 → 目标仓直接告诉我们「继续下去也是白费」→ **暂停计划**并记下原因，
    //                     未执行的项保持未推送（下次点「继续执行」从这里接上）
    //   409            → 目标仓已有同版本不同制品 → 该项跳过（不是失败），继续下一项
    //   >=500 / 网络   → 执行器内部退避重试，仍失败才判该项失败
    // 执行线程入口：登记解除放在 finally —— 任何出口（提前 return、Exception、
    // 系统级 Error）都必须解登记。少解一次，这个计划在界面上就永远显示「执行中」，
    // 「重新分析/继续执行」这类按钮再也回不来（执行期间的按钮是受 planRunIds 控制的）。
    func runExecution(st: CjregState, sid: String, items: ArrayList<PlanItem>, docIds: HashMap<Int64, Int64>, up: Upstream, pollTimeoutSec: Int64): Unit {
        try {
            this.runExecutionInner(st, sid, items, docIds, up, pollTimeoutSec)
        } finally {
            removePlanId(st, this.planId, false)
            removePlanId(st, this.planId, true)
            st.planBusy.set(false)
        }
    }

    func runExecutionInner(st: CjregState, sid: String, items: ArrayList<PlanItem>, docIds: HashMap<Int64, Int64>, up: Upstream, pollTimeoutSec: Int64): Unit {
        // 执行期间登记在 planRunIds 里（界面据此判断"真的在跑"）。**所有出口都要注销**，
        // 否则计划会永远显示「执行中」——实测踩过：收口回调一抛就是这种下场。
        let app = match (st.app) {
            case Some(a) => a
            case None =>
                removePlanId(st, this.planId, false)
                st.planBusy.set(false)
                return
        }
        let executor = match (buildPlanExecutor(st.pkgStore, st.blobStore)) {
            case Some(e) => e
            case None =>
                this.msg.set("内部错误：制品库未注入，无法执行发布计划")
                removePlanId(st, this.planId, false)
                st.planBusy.set(false)
                return
        }
        let total = items.size
        let done = Box<Int64>(0)
        let okCount = Box<Int64>(0)
        var report = ExecuteReport()
        try {
        report = executor.execute(items, up.url, up.authToken, shouldCancel: { =>
            // 用户在详情页点了「停止执行」：每项开推前、以及等索引的每一轮都会问一次
            containsId(st.planCancelIds.get(), this.planId)
        }, onItem: { it, _, err =>
            // **先即时落盘**：单条状态与计划进度都必须进 DB，不能只留在执行线程的内存里、
            // 也不能只挂在 pushUpdate 上——页面一关（WS 会话没了）pushUpdate 就不再执行，
            // 结果是「计划永远 running、单条永远 Pending」，重启后分不清哪些已经发过。
            done.value++
            if (it.status == PlanItemStatus.Completed) {
                okCount.value++
            }
            match (docIds.get(it.pkgId)) {
                case Some(docId) =>
                    let _ = st.adminData.updatePlanItem(docId, planItemStatusName(it.status), err, nowMs())
                case None => ()
            }
            let _ = st.adminData.updatePlanStatus(this.planId, "running", okCount.value, nowMs())
            // 再推给前端刷新界面（纯 UI，失败也不影响已落盘的进度）。
            // 这一层必须自己吞异常：pushUpdate 抛出来会把整个执行线程带走——
            // 后面的项不再处理、计划级收口也不执行，计划就永远停在「执行中」。
            try {
                let _ = app.pushUpdate(sid, { pctx =>
                    let s = pctx.getState<CjregState>()
                    s.planProgress.set("${done.value}/${total}")
                    this.refreshItems()
                    PatchResult.ReRender
                })
            } catch (e: Exception) {
                println("[cjreg] 发布计划进度推送失败（plan ${this.planId}，进度已落盘）: " + e.toString())
            }
        }, indexProbe: { org, name =>
            // 拓扑序下一条依赖它：推完必须确认**目标仓索引里真的能查到该版本**再往下走。
            // 等待节奏固定（见 indexWaitRhythmText），默认不设总超时（中心仓同步慢是常态）；
            // 只有探测本身失败（401/403/429/5xx/网络）或用户点停止才收工。
            match (st.proxySvc) {
                case Some(p) => p.probeUpstreamIndex(up, org, name)
                case None => IndexProbe(0, "", detail: "本实例未接入回源代理")
            }
        }, pollTimeoutSec: pollTimeoutSec)
        } catch (e: Exception) {
            // 执行线程里没人接异常：以前抛出来就**连收口都不执行**，计划永远停在「执行中」
            // （实测：4 项全部已失败落盘，计划状态还是 running）。现在必须收口成 failed 并写明原因。
            println("[cjreg] 发布计划执行异常（plan ${this.planId}）: " + e.toString())
            report.failed++
            report.errors.add("执行线程异常：${e.toString()}")
        } catch (e: Error) {
            // 系统级错误（OOM 等）不是 Exception 子类，之前会直接逃逸：收口不执行、
            // 计划状态留在 running（登记由 runExecution 的 finally 兜住）。这里同样收口。
            println("[cjreg] 发布计划执行系统级错误（plan ${this.planId}）: " + e.toString())
            report.failed++
            report.errors.add("执行线程系统级错误：${e.toString()}")
        }
        // 收口：中止或"有项在等目标仓索引" → paused（可续跑）；否则按成败收。
        // 等索引不算失败：内容已经推上去了，只是目标仓还没同步出来（中心仓同步慢或审核没过）。
        let finalStatus = if (report.aborted || report.waitingIndex > 0) {
            "paused"
        } else if (report.failed == 0 && report.total > 0) {
            "completed"
        } else {
            "failed"
        }
        let summary = if (report.aborted) {
            report.abortReason
        } else if (report.waitingIndex > 0) {
            "已推送 ${report.success} 项，${report.waitingIndex} 项在等目标仓索引就绪" +
                "（超时未出现：同步慢或审核没过），依赖它们的项本次未推送；稍后点「继续执行」接着等"
        } else if (report.failed > 0) {
            "失败 ${report.failed} 项：${if (report.errors.size > 0) { report.errors[0] } else { "" }}"
        } else if (report.success == 0 && report.skipped > 0) {
            // 「全部跳过」不能悄悄收成「已完成」：那看起来像发过了，实际一个字节都没传
            "本次没有实际上传：${report.skipped} 项都已在目标仓存在（409）或未勾选，目标仓版本与本地一致"
        } else if (report.skipped > 0) {
            "成功 ${report.success} 项，跳过 ${report.skipped} 项（目标仓已有、未勾选或依赖未就绪）"
        } else {
            ""
        }
        // 计划级收口同样**先落盘**，再推界面
        let _ = st.adminData.updatePlanStatus(this.planId, finalStatus, report.success, nowMs())
        if (summary != "") {
            let _ = st.adminData.setPlanError(this.planId, summary, nowMs())
        }
        // 审计：以前只有"暂停"写一条，正常/失败收口什么都不留 —— 事后翻日志看不出
        // "这个计划跑完了吗、跑成什么样"。改成无论成败都记一条（发布态审计）。
        st.adminData.addLog(LogKind.Publish, 0, "",
            "plan ${this.planId} ${finalStatus}", if (report.failed > 0) { "failed" } else { "ok" }, nowMs())
        // **先直接复位执行登记**（不放在 pushUpdate 回调里）：回调可能因为会话在重连/
        // 已销毁而抛异常，那样登记就永远留在"执行中"，界面再无按钮可用。
        removePlanId(st, this.planId, false)
        removePlanId(st, this.planId, true)
        st.planBusy.set(false)
        if (report.aborted && report.abortReason == "用户已停止执行") {
            st.adminData.addLog(LogKind.Publish, 0, "", "plan ${this.planId} 用户停止", "ok", nowMs())
        }
        try {
            let _ = app.pushUpdate(sid, { pctx =>
                let s = pctx.getState<CjregState>()
                s.planBusy.set(false)
                s.planStatus.set(finalStatus)
                this.msg.set(summary)
                this.refreshItems()
                PatchResult.ReRender
            })
        } catch (e: Exception) {
            // 界面没刷到没关系（上面已落盘）；但不能把异常抛出去把线程搞死
            println("[cjreg] 发布计划收口推送失败（plan ${this.planId}，状态已落盘为 ${finalStatus}）: " + e.toString())
        }
    }

    // 「检查索引」：对"已推送成功、在等索引"的项各探测一次目标仓索引，
    // 命中的直接标成发布完成（内容早就在目标仓了，只是索引/审核没过）。
    // 同样走 analyzing 的加载态（真网络，逐包取索引）。
    func checkIndex(ctx: ActionContext): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            this.msg.set("无权限：需要管理员登录")
            return PatchResult.ReRender
        }
        if (this.analyzing.get()) {
            return PatchResult.ReRender
        }
        let sid = ctx.getSessionId()
        this.analyzing.set(true)
        st.planAnalyzeSince.set(nowMs())
        this.msg.set("正在检查目标仓索引…")
        spawn { =>
            this.checkIndexAsync(st, sid)
        }
        PatchResult.ReRender
    }

    func checkIndexAsync(st: CjregState, sid: String): Unit {
        var summary = ""
        try {
            let plan = match (st.adminData.getPlan(this.planId)) {
                case Some(p) => p
                case None =>
                    this.finishAnalyze(st, sid, "计划不存在")
                    return
            }
            let target = st.upStore.getById(plan.targetUpstream)
            if (target.isNone()) {
                this.finishAnalyze(st, sid, "目标上游不存在，无法检查")
                return
            }
            let docs = st.adminData.listPlanItems(this.planId)
            let waiting = ArrayList<PlanItemDoc>()
            let targets = ArrayList<(String, String, String)>()
            for (d in docs) {
                if (d.status == "waiting_index") {
                    waiting.add(d)
                    targets.add((d.packageOrg, d.packageName, d.packageVersion))
                }
            }
            if (waiting.size == 0) {
                this.finishAnalyze(st, sid, "没有在等索引的项")
                return
            }
            let proxy = st.proxySvc
            let up = target.getOrThrow()
            let r = checkVersionsInIndex(targets, { org, name =>
                match (proxy) {
                    case Some(p) => p.probeUpstreamIndex(up, org, name)
                    case None => IndexProbe(0, "", detail: "本实例未接入回源代理")
                }
            })
            var done: Int64 = 0
            for (i in r.ready) {
                let d = waiting[i]
                let _ = st.adminData.updatePlanItem(d.id, "completed",
                    "索引已就绪（检查索引确认），本项发布完成", nowMs())
                done++
            }
            // 重新数一遍进度：全部项都完成/跳过时，计划就是完成了
            var completed: Int64 = 0
            var pending: Int64 = 0
            for (d in st.adminData.listPlanItems(this.planId)) {
                if (d.status == "completed") {
                    completed++
                } else if (d.category != "already_exists") {
                    pending++
                }
            }
            if (pending == 0) {
                let _ = st.adminData.updatePlanStatus(this.planId, "completed", completed, nowMs())
                let _ = st.adminData.setPlanError(this.planId, "全部项已完成", nowMs())
            } else {
                let _ = st.adminData.updatePlanStatus(this.planId, "paused", completed, nowMs())
            }
            st.adminData.addLog(LogKind.Publish, 0, "", "plan ${this.planId} 检查索引", "ok", nowMs())
            summary = "检查索引：${done}/${waiting.size} 项已就绪并标记为已发布" +
                (if (r.unreachable > 0) {
                    // 探测失败与"还没同步到"不是一回事：401/429/5xx 得先解决那个问题，
                    // 否则用户会一直等一件不会发生的事
                    "（${r.unreachable} 项探测失败：${r.detail}）"
                } else {
                    ""
                }) +
                (if (pending == 0) { "；计划已全部完成" } else { "；其余项仍需发布，可点「继续执行」" })
        } catch (e: Exception) {
            println("[cjreg] 检查索引失败（plan ${this.planId}）: " + e.toString())
            summary = "检查索引失败：" + e.toString()
        }
        this.finishAnalyze(st, sid, summary)
    }

    // 请求停止执行：只置标志，执行器在"下一项开推前"和"等索引的每一轮"看到就收口。
    // 正在进行的 HTTP 推送没法中断（包已经在路上了），所以是"尽快停"而不是"立刻断"。
    func stopExecution(ctx: ActionContext): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            this.msg.set("无权限：需要管理员登录")
            return PatchResult.ReRender
        }
        if (!containsId(st.planRunIds.get(), this.planId)) {
            this.msg.set("该计划当前没有在执行")
            return PatchResult.ReRender
        }
        addPlanId(st, this.planId, true)
        this.msg.set("已请求停止：正在收尾（已推出去的项会保留）")
        PatchResult.ReRender
    }

    // 勾选/取消勾选某一项：目标仓已有同版本的项默认不勾选（执行器据此跳过），
    // 想强制覆盖/重发时必须能手工勾上，否则计划里那些项永远发不出去。
    func toggleItem(ctx: ActionContext, docId: Int64, selected: Bool): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            this.msg.set("无权限：需要管理员登录")
            return PatchResult.ReRender
        }
        let _ = st.adminData.setPlanItemSelected(docId, !selected)
        // 分母只数"需要发布"的项：这里用分类（不是勾选）算，与创建时同一口径，
        // 免得用户勾一下分母就变，看着像进度在跳
        this.syncPlanTotal(st)
        this.refreshItems()
        PatchResult.ReRender
    }

    // 把计划的"需要发布项数"重算落库（创建/勾选/重新分析后调用）
    func syncPlanTotal(st: CjregState): Unit {
        var n: Int64 = 0
        for (d in st.adminData.listPlanItems(this.planId)) {
            if (d.category == "already_exists") {
                continue
            }
            n++
        }
        let _ = st.adminData.setPlanTotal(this.planId, n)
    }

    // 重新分类：按当前目标仓索引重跑一遍 analyze（目标仓在这期间可能已经同步了，
    // 或者是计划早于"目标仓对比"功能创建的）。只改分类与默认勾选，不动执行状态。
    //
    // **必须异步**：对比要逐包去目标仓取索引（真网络，实测 6 个包数秒到十几秒），
    // 同步做完的话界面一直停在旧状态，用户以为点了没反应。所以这里只置"分析中"，
    // 把活儿丢给线程，干完 pushUpdate 回来。
    // 重新分析按钮（**执行中也显示**）。
    //
    // 以前写成 `if (!executing)` 包住，而 `executing` 是进程级执行登记（planRunIds）：
    // 「所有项都推完、只差最后一个在等索引」以及「执行线程没来得及收口」时它一直为真，
    // 按钮就永远不见了 —— 计划看着已经全部完成，却怎么都点不到重新分析。
    // 重新分析只写派生数据（order / 分类 / 补齐依赖），不动执行记录，与正在跑的线程
    // 不冲突：跑着的线程用的是它自己那份条目快照。
    func reanalyzeButton(): IComponent {
        let analyzing = this.analyzing.get()
        let btn = Button([text(if (analyzing) { "分析中…" } else { "重新分析" })])
        if (analyzing) {
            btn.loading()
        }
        btn.onClick(reanalyze)
    }

    func reanalyze(ctx: ActionContext): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            this.msg.set("无权限：需要管理员登录")
            return PatchResult.ReRender
        }
        // 卡死自愈：标志为真但已经跑了很久（上一轮线程死了/网络挂住），允许重来并留痕，
        // 不然用户点多少次都没反应、也不知道为什么
        if (this.analyzing.get()) {
            let since = st.planAnalyzeSince.get()
            let now = nowMs()
            if (since > 0 && now - since < 180000) {
                this.msg.set("正在对比目标仓索引…（已 ${(now - since) / 1000}s，请稍候）")
                return PatchResult.ReRender
            }
            println("[cjreg] 重新分析：上一轮疑似卡死（已 ${if (since > 0) { (now - since) / 1000 } else { -1 }}s），重新开始")
        }
        let sid = ctx.getSessionId()
        this.analyzing.set(true)
        st.planAnalyzeSince.set(nowMs())
        this.msg.set("正在对比目标仓索引…")
        println("[cjreg] 重新分析开始：plan=${this.planId}")
        spawn { =>
            this.reanalyzeAsync(st, sid)
        }
        PatchResult.ReRender
    }

    func reanalyzeAsync(st: CjregState, sid: String): Unit {
        var summary = ""
        try {
            let plan = match (st.adminData.getPlan(this.planId)) {
                case Some(p) => p
                case None =>
                    this.finishAnalyze(st, sid, "计划不存在")
                    return
            }
            let target = st.upStore.getById(plan.targetUpstream)
            if (target.isNone()) {
                this.finishAnalyze(st, sid, "目标上游不存在，无法对比")
                return
            }
            // 用计划里的条目（org/name/version）当根重跑：与创建时同一份输入
            let docs = st.adminData.listPlanItems(this.planId)
            let roots = ArrayList<(String, String, String)>()
            for (d in docs) {
                roots.add((d.packageOrg, d.packageName, d.packageVersion))
            }
            let planSvc = PublishPlanService(st.pkgStore)
            let proxy = st.proxySvc
            let analysis = planSvc.analyze(roots, targetUpstream: target, fetchIndex: { up, org, name =>
                match (proxy) {
                    case Some(p) => p.probeUpstreamIndex(up, org, name)
                    case None => IndexProbe(0, "", detail: "本实例未接入回源代理")
                }
            })
            // **整体写回**：顺序（依赖拓扑序）+ 分类 + 依赖补齐一起刷新。
            // 只刷分类的旧写法会让 order 永远停在建计划那一刻的快照 —— 顺序错了点
            // 「重新分析」也修不回来，按钮等于废的（实测：无组织依赖的边丢过一次，
            // holt 被排在 badgercj 前面，重新分析怎么点都是那个错顺序）。
            let refreshed = applyAnalysisToPlan(st.adminData, this.planId, analysis)
            this.syncPlanTotal(st)          // 条目/分类变了，分母跟着变
            if (analysis.targetError != "") {
                let _ = st.adminData.setPlanError(this.planId, analysis.targetError, nowMs())
                summary = analysis.targetError
            } else {
                // 文案带上计数：否则连续两次分析得到同一句话，看起来像"点了没反应"
                var need: Int64 = 0
                var exists: Int64 = 0
                var conflict: Int64 = 0
                for (it in analysis.items) {
                    match (it.category) {
                        case PlanCategory.AlreadyExists => exists++
                        case PlanCategory.Conflict => conflict++
                        case _ => need++
                    }
                }
                summary = "已重新分析：更新 ${refreshed.updated} 项" +
                    (if (refreshed.added > 0) { " · 新增依赖 ${refreshed.added} 项" } else { "" }) +
                    (if (refreshed.skipped > 0) { " · ${refreshed.skipped} 项同包已有其它版本未加入" } else { "" }) +
                    "（顺序与分类都已刷新；需发布 ${need} · 目标仓已有 ${exists}" +
                    (if (conflict > 0) { " · 冲突 ${conflict}" } else { "" }) + "）"
            }
        } catch (e: Exception) {
            // 异步线程里的异常没人接：不接住的话界面会永远停在"分析中…"
            println("[cjreg] 重新分析失败（plan ${this.planId}）: " + e.toString())
            summary = "重新分析失败：" + e.toString()
        }
        this.finishAnalyze(st, sid, summary)
    }

    // 收尾：清"分析中"、刷表格（必须在 pushUpdate 里做，否则到不了前端）
    func finishAnalyze(st: CjregState, sid: String, summary: String): Unit {
        // **先直接复位 analyzing**：原来只在 pushUpdate 回调里复位，回调一抛（会话重连/已销毁）
        // 这个标志就永远停在 true，之后每次点「重新分析」都在入口静默 return —— 用户看到的就是
        // 「点了没用、什么提示都没有」。实测踩过。
        this.analyzing.set(false)
        st.planAnalyzeSince.set(0)
        let app = match (st.app) {
            case Some(a) => a
            case None => return
        }
        try {
            let _ = app.pushUpdate(sid, { pctx =>
                this.msg.set(summary)
                this.refreshItems()
                PatchResult.ReRender
            })
        } catch (e: Exception) {
            println("[cjreg] 重新分析结果推送失败（plan ${this.planId}，分类已落盘）: " + e.toString())
        }
    }

    func refreshItems(): Unit {
        match (this.state) {
            case Some(st) =>
                let data = ArrayList<PlanItemDoc>()
                for (d in st.adminData.listPlanItems(this.planId)) {
                    data.add(d)
                }
                // 只写**全量**：显示行由 binding 的 Effect 从它派生（两边都写会让过滤被覆盖）
                this.items.set(data)
            case None => ()
        }
    }

    // 进度：分母是"需要发布的项数"，全都不需要发时直说，别显示 0/0
    func progressText(done: Int64, total: Int64): IComponent {
        text(progressTextOf(done, total))
    }

    // 明细：共几项、其中已存在/冲突/需发布各几个（不进分母也要让人看得见，不然像"项丢了"）。
    // 按**全量**算：隐藏开关只筛显示行，明细报的必须是计划的真实构成。
    func itemBreakdown(): String {
        var exists: Int64 = 0
        var conflict: Int64 = 0
        var need: Int64 = 0
        var compared: Int64 = 0
        let rows = this.items.get()
        for (d in rows) {
            match (d.category) {
                case "already_exists" => exists++
                case "conflict" => conflict++
                case _ => need++
            }
            if (d.targetCompared) {
                compared++
            }
        }
        var s = "共 ${rows.size} 项 · 需发布 ${need}"
        if (exists > 0) {
            s += " · 目标仓已有 ${exists}"
        }
        if (conflict > 0) {
            s += " · 冲突 ${conflict}"
        }
        // 整份计划都没有对照数据（老计划、或建计划时索引取不到）→ 明说怎么补齐，
        // 否则详情里一列「未对照」会让人以为是坏了
        if (rows.size > 0 && compared == 0) {
            s += " · 目标仓未对照（点「重新分析」补齐）"
        }
        s
    }

    // 索引等待策略文案：0 = 一直等（默认）；否则是总等待上限。
    // 节奏部分是服务端常量的投影（indexWaitRhythmText），别在这里再抄一遍数字。
    func waitPolicyText(pollTimeout: Int64): String {
        if (pollTimeout <= 0) {
            return "一直等（${indexWaitRhythmText()} 探测一次）"
        }
        "最长 ${pollTimeout}s（${indexWaitRhythmText()}）"
    }

    // 目标仓能不能覆盖已有同版本（官方中心仓不能 → 冲突条目只能升版重发）
    func targetOverwriteAllowed(): Bool {
        match (this.state) {
            case Some(st) =>
                match (st.adminData.getPlan(this.planId)) {
                    case Some(plan) => targetOverwritable(st.upStore.getById(plan.targetUpstream))
                    case None => false
                }
            case None => false
        }
    }

    // 显示行数文案：隐藏时给出「显示 N / 共 M」，否则只说总数。
    // 数字都从信号现读，所以拨开关时 render 会重算（不读信号的话文案不会变）。
    func itemCountText(): String {
        itemCountTextOf(this.itemRows.get().size, this.items.get().size, this.hideUnpublished.get())
    }

    // 「发布项」卡片头部：隐藏开关 + 行数。
    // 开关只影响显示，执行与计数仍按全量（见 plan_items_filter.cj）。
    func renderItemsToolbar(): IComponent {
        div([
            Switch().bind(this.hideUnpublished),
            text("隐藏不推送的项"),
            text(this.itemCountText()),
        ], attrs: Some(HashMap<String, String>([("class", cls("toolbar"))])))
    }

    // 全被隐藏时给一句话：否则只看到一张空表，像是项丢了。
    // 走 listBody 的固定槽位（见 layout.cj）——提示不能和表格换节点类型。
    func itemsHint(): String {
        if (this.itemRows.get().size == 0 && this.items.get().size > 0) {
            return "没有会推送的项（${this.items.get().size} 项都已勾掉或已判为未推送）—— 关掉「隐藏不推送的项」可以查看全部"
        }
        ""
    }

    func renderItems(): IComponent {
        let canOverwrite = this.targetOverwriteAllowed()
        Table<PlanItemDoc>()
            .data(this.itemRows)
            .emptyText("暂无数据")
            .stripe()
            .add(TableColumn<PlanItemDoc>().label("序").accessor({ d => d.order.toString() }).width(50))
            .add(TableColumn<PlanItemDoc>().label("包").accessor({ d =>
                packageLabel(d.packageOrg, d.packageName, d.packageVersion)
            }).minWidth(230))
            // 目标仓那一侧的版本，与「包」列并排看：`bstorm@1.4.9` 对 `bstorm@1.4.8`。
            // 三种取值（版本 / 无此包 / 未对照）由服务端 targetCompareText 统一给出，
            // 免得界面自己拼、和执行时的说法分叉。
            .add(TableColumn<PlanItemDoc>().label("目标仓").width(150).accessor({ d =>
                targetCompareText(d.packageName, d.targetVersion, d.targetCompared)
            }).showOverflowTooltip())
            // 时间线：推送（内容送进目标仓的时刻）与索引（目标仓索引里确认到该版本、
            // 消费者从此解析得到）。只报"我们能观测到的"事实——各客户端 cjpm 本地缓存
            // 什么时候刷新是客户端的事，服务端测不到，不猜。
            .add(TableColumn<PlanItemDoc>().label("时间").width(150).render({ d, i =>
                div([
                    div([text(itemTimeText("推送", d.pushedAt))]),
                    div([text(itemTimeText("索引", indexTimeOf(d)))]),
                ])
            }))
            .add(TableColumn<PlanItemDoc>().label("分类").width(120).render({ d, i =>
                this.categoryTag(d.category, d.status)
            }))
            .add(TableColumn<PlanItemDoc>().label("状态").width(90).render({ d, i =>
                this.itemStatusTag(d.status)
            }))
            .add(TableColumn<PlanItemDoc>().label("说明").accessor({ d =>
                // 有执行错误就显示错误，否则显示分类含义 —— 空着等于让人自己猜
                if (d.error != "") { d.error } else { this.itemHint(d.category, canOverwrite) }
            }).minWidth(280).showOverflowTooltip())
            .add(TableColumn<PlanItemDoc>().label("操作").width(100).render({ d, i =>
                // 目标仓不允许覆盖（官方中心仓）且条目已存在/冲突时，勾选也只会换回 409：
                // 直接告诉用户唯一出路是升版，不给一个注定失败的按钮
                let blocked = !canOverwrite &&
                    (d.category == "already_exists" || d.category == "conflict")
                if (blocked) {
                    // 冲突：唯一出路是升版；已存在：本来就不用发，只是"想重传也没门"
                    let why = if (d.category == "conflict") { "需升版" } else { "不可覆盖" }
                    Tag([text(why)]).kind(ComponentKind.Warning)
                } else {
                    let id = d.id
                    let sel = d.selected
                    let act: ActionHandler = { c => this.toggleItem(c, id, sel) }
                    let label = if (sel) { "取消勾选" } else { "勾选" }
                    Button([text(label)]).size(ButtonSize.Small).onClick(act)
                }
            }))
    }

    public func render(): IComponent {
        let st = match (this.state) {
            case Some(x) => x
            case None => return div([text("加载中...")])
        }
        let backHandler: ActionHandler = { c => this.backToList(c) }
        // "是否真的在执行"看进程级登记（planRunIds），不看会话级的 planBusy——
        // 后者可能因为收口回调抛异常而永远停在 true，把界面锁死（实测踩过）。
        let executing = containsId(st.planRunIds.get(), this.planId)
        let cancelling = containsId(st.planCancelIds.get(), this.planId)
        match (st.adminData.getPlan(this.planId)) {
            case Some(plan) =>
                // 这里**不再**要求 plan.status != "running"：库里状态可能是上一轮没收口留下的
                // "running"（进程被杀/回调抛异常），此时也该允许用户重新执行或停止。
                let canStart = !executing && plan.status != "completed"
                let resuming = plan.status == "paused" || plan.status == "failed"
                let progressLine = if (executing) {
                    div([text("执行中: ${st.planProgress.get()}")])
                } else {
                    div()
                }
                adminLayout("/admin/publish-plans", [
                    div([text("发布计划详情")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
                    cardStack([
                    adminCard("计划信息", [
                        Descriptions()
                            .border()
                            .column(2)
                            .labelWidth("100px")
                            .add(DescriptionsItem().label("名称").children([text(plan.name)]))
                            .add(DescriptionsItem().label("状态").children([this.statusTag(
                                // 库里写着 running、但进程里没有对应的执行线程 = 上一轮没收口
                                // （进程被杀/回调抛异常）。显示「上次未收口」而不是「执行中」，
                                // 免得用户以为还在跑、干等一个不存在的执行
                                if (executing) { "running" } else if (plan.status == "running") { "interrupted" } else { plan.status })]))
                            .add(DescriptionsItem().label("目标上游").children([text(this.upstreamName(st, plan.targetUpstream))]))
                            .add(DescriptionsItem().label("进度").children([this.progressText(plan.completedCount, plan.totalCount)]))
                            .add(DescriptionsItem().label("发布项").children([text(this.itemBreakdown())]))
                            .add(DescriptionsItem().label("索引等待").children([text(this.waitPolicyText(plan.pollTimeout))]))
                            .add(DescriptionsItem().label("执行").children([progressLine])),
                        // 计划级原因：中止/失败后刷新页面仍要看得到「为什么停了」
                        if (plan.lastError != "") {
                            div([Tag([text(plan.lastError)]).kind(ComponentKind.Warning)],
                                attrs: Some(HashMap<String, String>([("style", "margin: 8px 0")])))
                        } else {
                            div()
                        },
                        div([
                            Button([text("返回列表")]).onClick(backHandler),
                            this.reanalyzeButton(),
                            if (canStart) {
                                Button([text(if (resuming) { "继续执行（跳过已完成项）" } else { "开始执行" })])
                                    .kind(ButtonKind.Primary).onClick(doStart)
                            } else {
                                div()
                            },
                            // 「等索引」的项没必要逼用户再点一次执行、干等一个轮询周期（默认 60s、
                            // 超时 600s）：单独给一个"现在查一次"的入口，命中就直接标成已发布
                            if (!executing && this.hasWaitingIndex()) {
                                Button([text("检查索引")]).onClick(checkIndex)
                            } else {
                                div()
                            },
                            // 执行中（尤其"等目标仓索引"最长等于计划的 pollTimeout，默认 10 分钟）
                            // 必须给用户一个出口：不点它就只能干等
                            if (executing) {
                                if (cancelling) {
                                    Button([text("停止中…")]).disabled()
                                } else {
                                    Button([text("停止执行")]).kind(ButtonKind.Danger).onClick(stopExecution)
                                }
                            } else {
                                div()
                            },
                            if (this.msg.get() != "") {
                                Tag([text(this.msg.get())]).kind(ComponentKind.Success)
                            } else {
                                div()
                            },
                        ], attrs: Some(HashMap<String, String>([("class", cls("card-actions"))]))),
                    ]),
                        adminCard("发布项", [this.renderItemsToolbar(),
                            listBody(this.itemsHint(), this.renderItems())]),
                    ]),
                ])
            case None =>
                adminLayout("/admin/publish-plans", [
                    div([text("发布计划详情")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
                    div([text("计划不存在或已删除")]),
                    Button([text("返回列表")]).onClick(backHandler),
                ])
        }
    }
}
