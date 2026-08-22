// cjxt 管理界面：发布计划（列表 / 创建向导 / 详情）
package ystyle::cjreg.ui

import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import ystyle::cjreg.store.*
import ystyle::cjreg.server.*
import ystyle::cjreg.index.*
import std.collection.*
import std.convert.*

// ===== 发布计划列表 =====
@Page["/admin/publish-plans", "发布计划", requireAdmin]
class PublishPlansPage <: Component {
    var state: Option<CjregState> = None
    var msg = Signal<String>("")
    // 删除确认
    var confirmVisible = Signal<Bool>(false)
    var pendingDeleteId: Int64 = 0
    var pendingDeleteName: String = ""

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
    }

    func upstreamName(st: CjregState, id: Int64): String {
        match (st.upStore.getById(id)) {
            case Some(u) => u.name
            case None => "#${id}"
        }
    }

    func statusTag(s: String): IComponent {
        match (s) {
            case "running" => Tag([text("执行中")]).kind(ComponentKind.Warning)
            case "completed" => Tag([text("已完成")]).kind(ComponentKind.Success)
            case "failed" => Tag([text("失败")]).kind(ComponentKind.Danger)
            case "paused" => Tag([text("已暂停")]).kind(ComponentKind.Info)
            case _ => Tag([text("待执行")]).kind(ComponentKind.Primary)
        }
    }

    func gotoCreate(ctx: ActionContext): PatchResult {
        ctx.route.push("/admin/publish-plans/create")
        PatchResult.ReRender
    }

    func gotoDetail(ctx: ActionContext, id: Int64): PatchResult {
        ctx.route.push("/admin/publish-plans/${id}")
        PatchResult.ReRender
    }

    func askDelete(ctx: ActionContext, p: PlanDoc): PatchResult {
        this.pendingDeleteId = p.id
        this.pendingDeleteName = p.name
        this.confirmVisible.set(true)
        PatchResult.ReRender
    }

    func cancelDelete(ctx: ActionContext): PatchResult {
        this.confirmVisible.set(false)
        PatchResult.ReRender
    }

    func confirmDelete(ctx: ActionContext): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            this.msg.set("无权限：需要管理员登录")
            return PatchResult.ReRender
        }
        if (st.adminData.deletePlan(this.pendingDeleteId)) {
            this.msg.set("已删除计划 ${this.pendingDeleteName}")
            st.adminData.addLog(LogKind.Admin, sessionUid(ctx), sessionUsername(ctx), "delete plan ${this.pendingDeleteName}", "ok", nowMs())
        } else {
            this.msg.set("删除失败")
        }
        this.confirmVisible.set(false)
        this.pendingDeleteId = 0
        PatchResult.ReRender
    }

    func renderPlanRow(p: PlanDoc): IComponent {
        let st = match (this.state) {
            case Some(x) => x
            case None => return div()
        }
        let detailHandler: ActionHandler = { c => this.gotoDetail(c, p.id) }
        let deleteHandler: ActionHandler = { c => this.askDelete(c, p) }
        div([
            div([text(p.id.toString())], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text(p.name)], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([this.statusTag(p.status)], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text(this.upstreamName(st, p.targetUpstream))], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text("${p.completedCount}/${p.totalCount}")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([
                Button([text("详情")]).size(ButtonSize.Small).onClick(detailHandler),
                Button([text("删除")]).size(ButtonSize.Small).kind(ButtonKind.Danger).onClick(deleteHandler),
            ], attrs: Some(HashMap<String, String>([("class", cls("admin-td") + " " + cls("admin-actions"))]))),
        ], attrs: Some(HashMap<String, String>([("class", cls("admin-tr"))])))
    }

    func renderList(): IComponent {
        let plans = match (this.state) {
            case Some(st) => st.adminData.listPlans()
            case None => ArrayList<PlanDoc>()
        }
        if (plans.size == 0) {
            return emptyState("暂无发布计划，点击「创建计划」新建")
        }
        let rows = ArrayList<IComponent>()
        rows.add(div([
            div([text("ID")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text("计划名")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text("状态")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text("目标上游")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text("进度")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text("操作")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
        ], attrs: Some(HashMap<String, String>([("class", cls("admin-tr") + " " + cls("admin-th"))]))))
        for (p in plans) {
            rows.add(this.renderPlanRow(p))
        }
        div(rows.toArray(), attrs: Some(HashMap<String, String>([("class", cls("admin-table"))])))
    }

    func renderConfirmDialog(): IComponent {
        let dlg = Dialog([
            div([text("确定要删除计划「${this.pendingDeleteName}」吗？")]),
        ])
            .visible(this.confirmVisible)
            .title("删除确认")
            .width("400px")
            .closeOnClickModal(false)
            .footer([
                Button([text("取消")]).onClick(cancelDelete),
                Button([text("删除")]).kind(ButtonKind.Danger).onClick(confirmDelete),
            ])
        dlg
    }

    public func render(): IComponent {
        let toolbar = div([
            Button([text("创建计划")]).kind(ButtonKind.Primary).onClick(gotoCreate),
            if (this.msg.get() != "") {
                Tag([text(this.msg.get())]).kind(ComponentKind.Success)
            } else {
                div()
            },
        ], attrs: Some(HashMap<String, String>([("class", cls("toolbar"))])))
        adminLayout("/admin/publish-plans", [
            div([text("发布计划")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            adminCard("发布计划列表", [toolbar, this.renderList(), this.renderConfirmDialog()]),
        ])
    }
}

// ===== 创建向导 =====
@Page["/admin/publish-plans/create", "创建发布计划", requireAdmin]
class PublishPlanCreatePage <: Component {
    var state: Option<CjregState> = None
    var msg = Signal<String>("")
    var planName = Signal<String>("")
    var targetUpstream = Signal<String>("")
    var pollInterval = Signal<Int64>(60)
    var pollTimeout = Signal<Int64>(600)
    var pkgSearch = Signal<String>("")
    var selectedPkgs = Signal<ArrayList<Int64>>(ArrayList<Int64>())

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
    }

    func backToList(ctx: ActionContext): PatchResult {
        ctx.route.push("/admin/publish-plans")
        PatchResult.ReRender
    }

    func togglePkg(ctx: ActionContext, pkgId: Int64): PatchResult {
        let cur = this.selectedPkgs.get()
        var found = false
        let next = ArrayList<Int64>()
        for (id in cur) {
            if (id == pkgId) {
                found = true
            } else {
                next.add(id)
            }
        }
        if (!found) {
            next.add(pkgId)
        }
        this.selectedPkgs.set(next)
        PatchResult.ReRender
    }

    func submitCreate(ctx: ActionContext): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            this.msg.set("无权限：需要管理员登录")
            return PatchResult.ReRender
        }
        let name = this.planName.get()
        let targetId = match (Int64.tryParse(this.targetUpstream.get())) {
            case Some(n) => n
            case None => 0
        }
        let selected = this.selectedPkgs.get()
        if (name.isEmpty()) {
            this.msg.set("计划名必填")
            return PatchResult.ReRender
        }
        if (targetId == 0) {
            this.msg.set("请选择目标上游")
            return PatchResult.ReRender
        }
        if (selected.size == 0) {
            this.msg.set("请至少选择一个包")
            return PatchResult.ReRender
        }
        // 依赖分析（以选中包为根，计算拓扑序）
        let roots = ArrayList<(String, String, String)>()
        for (d in st.pkgStore.storm.all<PackageDoc>()) {
            var isSel = false
            for (id in selected) {
                if (d.id == id) {
                    isSel = true
                    break
                }
            }
            if (isSel) {
                roots.add((d.organization, d.name, d.version))
            }
        }
        let planSvc = PublishPlanService(st.pkgStore)
        let (items, hasCycle) = planSvc.analyze(roots)
        if (hasCycle) {
            this.msg.set("依赖存在环")
            return PatchResult.ReRender
        }
        let uid = sessionUid(ctx)
        let uname = sessionUsername(ctx)
        let planId = st.adminData.createPlan(name, targetId, this.pollInterval.get(), this.pollTimeout.get(), nowMs())
        var order: Int64 = 0
        for (it in items) {
            st.adminData.addPlanItem(planId, it.pkgId, it.org, it.name, it.version, order, categoryOf(it.category), true)
            order++
        }
        st.adminData.setPlanTotal(planId, items.size)
        st.adminData.addLog(LogKind.Admin, uid, uname, "create plan ${name}", "ok", nowMs())
        ctx.route.push("/admin/publish-plans/${planId}")
        PatchResult.ReRender
    }

    func renderPkgPicker(): IComponent {
        let st = match (this.state) {
            case Some(x) => x
            case None => return div()
        }
        let kw = this.pkgSearch.get()
        let selected = this.selectedPkgs.get()
        let rows = ArrayList<IComponent>()
        for (d in st.pkgStore.storm.all<PackageDoc>()) {
            if (d.deletedAt != 0) { continue }
            if (kw != "" && !d.name.contains(kw)) { continue }
            var isSel = false
            for (id in selected) {
                if (d.id == id) {
                    isSel = true
                    break
                }
            }
            let org = if (d.organization.isEmpty()) { "-" } else { d.organization }
            let toggleHandler: ActionHandler = { c => this.togglePkg(c, d.id) }
            rows.add(div([
                div([text("${org}/${d.name}@${d.version}")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
                Button([text(if (isSel) { "取消选择" } else { "选择" })]).size(ButtonSize.Small).kind(if (isSel) { ButtonKind.Danger } else { ButtonKind.Primary }).onClick(toggleHandler),
            ], attrs: Some(HashMap<String, String>([("class", cls("admin-tr"))]))))
        }
        div(rows.toArray(), attrs: Some(HashMap<String, String>([("class", cls("admin-table"))])))
    }

    public func render(): IComponent {
        let st = match (this.state) {
            case Some(x) => x
            case None => return div([text("加载中...")])
        }
        let upstreamOptions = ArrayList<IComponent>()
        for (u in st.upStore.listAll()) {
            upstreamOptions.add(SelectOption([text("${u.name}（${u.url}）")], u.id.toString()))
        }
        let backHandler: ActionHandler = { c => this.backToList(c) }
        adminLayout("/admin/publish-plans", [
            div([text("创建发布计划")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            adminCard("向导", [
                div([
                    div([text("计划名")], attrs: Some(HashMap<String, String>([("class", cls("dialog-form-label"))]))),
                    Input().bind(this.planName).placeholder("计划名称"),
                    div([text("目标上游")], attrs: Some(HashMap<String, String>([("class", cls("dialog-form-label"))]))),
                    Select(upstreamOptions.toArray()).bind(this.targetUpstream).placeholder("选择上游"),
                    div([text("轮询间隔（秒）")], attrs: Some(HashMap<String, String>([("class", cls("dialog-form-label"))]))),
                    InputNumber().bind(this.pollInterval).min(1),
                    div([text("轮询超时（秒）")], attrs: Some(HashMap<String, String>([("class", cls("dialog-form-label"))]))),
                    InputNumber().bind(this.pollTimeout).min(1),
                    div([text("选择要发布的包（依赖将自动纳入拓扑排序）")], attrs: Some(HashMap<String, String>([("class", cls("dialog-form-label"))]))),
                    Input().bind(this.pkgSearch).placeholder("搜索包名"),
                    this.renderPkgPicker(),
                    if (this.msg.get() != "") {
                        Tag([text(this.msg.get())]).kind(ComponentKind.Success)
                    } else {
                        div()
                    },
                    div([
                        Button([text("返回列表")]).onClick(backHandler),
                        Button([text("分析并创建")]).kind(ButtonKind.Primary).onClick(submitCreate),
                    ], attrs: Some(HashMap<String, String>([("class", cls("toolbar"))]))),
                ], attrs: Some(HashMap<String, String>([("class", cls("dialog-form"))]))),
            ]),
        ])
    }
}

// ===== 计划详情 =====
@Page["/admin/publish-plans/[id]", "发布计划详情", requireAdmin]
class PublishPlanDetailPage <: Component {
    var state: Option<CjregState> = None
    var planId: Int64 = 0
    var msg = Signal<String>("")

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
            case _ => Tag([text("待发布")]).kind(ComponentKind.Info)
        }
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
        if (st.planBusy.get()) {
            return PatchResult.ReRender
        }
        let sid = ctx.getSessionId()
        match (st.adminData.getPlan(this.planId)) {
            case Some(plan) =>
                match (st.upStore.getById(plan.targetUpstream)) {
                    case Some(up) =>
                        let docs = st.adminData.listPlanItems(this.planId)
                        let execItems = ArrayList<PlanItem>()
                        let docIds = ArrayList<Int64>()
                        for (d in docs) {
                            if (!d.selected) { continue }
                            execItems.add(PlanItem(d.packageId, d.packageName, d.packageOrg, d.packageVersion, toPlanCategory(d.category), d.order))
                            docIds.add(d.id)
                            let _ = st.adminData.updatePlanItem(d.id, "running", "", nowMs())
                        }
                        if (execItems.size == 0) {
                            this.msg.set("没有可执行的发布项")
                            return PatchResult.ReRender
                        }
                        st.adminData.updatePlanStatus(this.planId, "running", 0, nowMs())
                        st.planBusy.set(true)
                        st.planStatus.set("running")
                        st.planProgress.set("0/${execItems.size}")
                        st.adminData.addLog(LogKind.Publish, sessionUid(ctx), sessionUsername(ctx), "start plan ${plan.name}", "ok", nowMs())
                        // 异步执行（网络操作在线程内，DB 写在 pushUpdate 回调里串行化）
                        spawn { =>
                            this.runExecution(st, sid, execItems, docIds, up.url, up.authToken)
                        }
                    case None =>
                        this.msg.set("目标上游不存在")
                }
            case None =>
                this.msg.set("计划不存在")
        }
        PatchResult.ReRender
    }

    // 异步执行线程：逐项推送，每项完成通过 App.pushUpdate 推进度给前端
    func runExecution(st: CjregState, sid: String, items: ArrayList<PlanItem>, docIds: ArrayList<Int64>, url: String, token: String): Unit {
        let app = match (st.app) {
            case Some(a) => a
            case None => return
        }
        let executor = PublishExecutor(st.pkgStore, DiskBlobStore("${getDataDir()}/blobs"))
        let total = items.size
        let done = Box<Int64>(0)
        let (ok, _, _) = executor.execute(items, url, token, onItem: { it, ok, err =>
            // 服务端推送回调在 execMutex 内执行：DB 写与 WS handler 串行化
            let _ = app.pushUpdate(sid, { pctx =>
                let s = pctx.getState<CjregState>()
                if (done.value < docIds.size) {
                    let _ = s.adminData.updatePlanItem(docIds[done.value], if (ok) { "completed" } else { "failed" }, err, nowMs())
                }
                done.value++
                s.planProgress.set("${done.value}/${total}")
                PatchResult.ReRender
            })
        })
        let finalStatus = if (ok == total && total > 0) { "completed" } else { "failed" }
        let _ = app.pushUpdate(sid, { pctx =>
            let s = pctx.getState<CjregState>()
            let _ = s.adminData.updatePlanStatus(this.planId, finalStatus, ok, nowMs())
            s.planBusy.set(false)
            s.planStatus.set(finalStatus)
            PatchResult.ReRender
        })
    }

    func renderItemRow(d: PlanItemDoc): IComponent {
        div([
            div([text(d.order.toString())], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text("${d.packageOrg}/${d.packageName}@${d.packageVersion}")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text(d.category)], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([this.itemStatusTag(d.status)], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text(d.error)], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
        ], attrs: Some(HashMap<String, String>([("class", cls("admin-tr"))])))
    }

    func renderItems(): IComponent {
        let items = match (this.state) {
            case Some(st) => st.adminData.listPlanItems(this.planId)
            case None => ArrayList<PlanItemDoc>()
        }
        let rows = ArrayList<IComponent>()
        rows.add(div([
            div([text("序")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text("包")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text("分类")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text("状态")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
            div([text("错误")], attrs: Some(HashMap<String, String>([("class", cls("admin-td"))]))),
        ], attrs: Some(HashMap<String, String>([("class", cls("admin-tr") + " " + cls("admin-th"))]))))
        for (d in items) {
            rows.add(this.renderItemRow(d))
        }
        div(rows.toArray(), attrs: Some(HashMap<String, String>([("class", cls("admin-table"))])))
    }

    public func render(): IComponent {
        let st = match (this.state) {
            case Some(x) => x
            case None => return div([text("加载中...")])
        }
        let backHandler: ActionHandler = { c => this.backToList(c) }
        let executing = st.planBusy.get()
        match (st.adminData.getPlan(this.planId)) {
            case Some(plan) =>
                let canStart = !executing && (plan.status == "pending" || plan.status == "failed")
                let progressLine = if (executing) {
                    div([text("执行中: ${st.planProgress.get()}")])
                } else {
                    div()
                }
                adminLayout("/admin/publish-plans", [
                    div([text("发布计划详情")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
                    adminCard("计划信息", [
                        div([
                            div([text("名称: ${plan.name}")]),
                            div([this.statusTag(if (executing) { "running" } else { plan.status })]),
                            div([text("目标上游: ${this.upstreamName(st, plan.targetUpstream)}")]),
                            div([text("进度: ${plan.completedCount}/${plan.totalCount}")]),
                            div([text("轮询: ${plan.pollInterval}s / 超时 ${plan.pollTimeout}s")]),
                            progressLine,
                        ]),
                        div([
                            Button([text("返回列表")]).onClick(backHandler),
                            if (canStart) {
                                Button([text("开始执行")]).kind(ButtonKind.Primary).onClick(doStart)
                            } else {
                                div()
                            },
                            if (this.msg.get() != "") {
                                Tag([text(this.msg.get())]).kind(ComponentKind.Success)
                            } else {
                                div()
                            },
                        ], attrs: Some(HashMap<String, String>([("class", cls("toolbar"))]))),
                    ]),
                    adminCard("发布项", [this.renderItems()]),
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

// PlanItemDoc.category 字符串 → PlanCategory 枚举
func toPlanCategory(s: String): PlanCategory {
    match (s) {
        case "version_optional" => PlanCategory.VersionOptional
        case "already_exists" => PlanCategory.AlreadyExists
        case "conflict" => PlanCategory.Conflict
        case _ => PlanCategory.NeedPublish
    }
}

// 分类字符串（analyze 结果 → 存储）
func categoryOf(c: PlanCategory): String {
    match (c) {
        case PlanCategory.NeedPublish => "need_publish"
        case PlanCategory.VersionOptional => "version_optional"
        case PlanCategory.AlreadyExists => "already_exists"
        case PlanCategory.Conflict => "conflict"
    }
}

// 数据目录（从状态推断：blob 存储路径）
public func getDataDir(): String {
    "./data"
}

// ===== 日志页 =====
@Page["/admin/logs", "日志", requireAdmin]
class LogsPage <: Component {
    var state: Option<CjregState> = None
    var rows = Signal<ArrayList<HashMap<String, String>>>(ArrayList<HashMap<String, String>>())
    var kindFilter = Signal<String>("all")
    var statusFilter = Signal<String>("all")
    var msg = Signal<String>("")
    var confirmVisible = Signal<Bool>(false)

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        refresh()
    }

    func refresh(): Unit {
        match (this.state) {
            case Some(st) =>
                let kind = if (this.kindFilter.get() == "all") { Option<String>.None } else { Some(this.kindFilter.get()) }
                let logs = st.adminData.listLogs(kind, 300)
                let data = ArrayList<HashMap<String, String>>()
                for (l in logs) {
                    if (this.statusFilter.get() != "all" && l.status != this.statusFilter.get()) {
                        continue
                    }
                    let m = HashMap<String, String>()
                    m["id"] = l.id.toString()
                    m["kind"] = kindLabel(l.kind)
                    m["actor"] = l.actorName
                    m["action"] = l.action
                    m["target"] = l.target
                    m["status"] = l.status
                    data.add(m)
                }
                this.rows.set(data)
            case None => ()
        }
    }

    func kindLabel(k: String): String {
        match (k) {
            case "publish" => "发布"
            case "auth" => "认证"
            case _ => "管理"
        }
    }

    func doRefresh(ctx: ActionContext): PatchResult {
        this.refresh()
        PatchResult.ReRender
    }

    func askClear(ctx: ActionContext): PatchResult {
        this.confirmVisible.set(true)
        PatchResult.ReRender
    }

    func cancelClear(ctx: ActionContext): PatchResult {
        this.confirmVisible.set(false)
        PatchResult.ReRender
    }

    func confirmClear(ctx: ActionContext): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            this.msg.set("无权限：需要管理员登录")
            return PatchResult.ReRender
        }
        st.adminData.clearLogs()
        this.msg.set("已清空日志")
        st.adminData.addLog(LogKind.Admin, sessionUid(ctx), sessionUsername(ctx), "clear logs", "ok", nowMs())
        this.confirmVisible.set(false)
        this.refresh()
        PatchResult.ReRender
    }

    public func render(): IComponent {
        let kindOptions = ArrayList<IComponent>()
        kindOptions.add(SelectOption([text("全部类型")], "all"))
        kindOptions.add(SelectOption([text("发布")], "publish"))
        kindOptions.add(SelectOption([text("管理")], "admin"))
        kindOptions.add(SelectOption([text("认证")], "auth"))
        let statusOptions = ArrayList<IComponent>()
        statusOptions.add(SelectOption([text("全部结果")], "all"))
        statusOptions.add(SelectOption([text("成功")], "ok"))
        statusOptions.add(SelectOption([text("失败")], "failed"))
        let toolbar = div([
            Select(kindOptions.toArray()).bind(this.kindFilter).placeholder("类型"),
            Select(statusOptions.toArray()).bind(this.statusFilter).placeholder("结果"),
            Button([text("筛选")]).kind(ButtonKind.Primary).onClick(doRefresh),
            Button([text("清空日志")]).kind(ButtonKind.Danger).onClick(askClear),
            if (this.msg.get() != "") {
                Tag([text(this.msg.get())]).kind(ComponentKind.Success)
            } else {
                div()
            },
        ], attrs: Some(HashMap<String, String>([("class", cls("toolbar"))])))
        let table = Table()
            .data(this.rows)
            .stripe()
            .add(TableColumn().label("ID").colProp("id").width(60))
            .add(TableColumn().label("类型").colProp("kind").width(80))
            .add(TableColumn().label("操作者").colProp("actor").width(100))
            .add(TableColumn().label("操作").colProp("action"))
            .add(TableColumn().label("对象").colProp("target").width(120))
            .add(TableColumn().label("结果").colProp("status").width(80))
        let confirmDlg = Dialog([
            div([text("确定要清空全部日志吗？此操作不可恢复。")]),
        ])
            .visible(this.confirmVisible)
            .title("清空确认")
            .width("400px")
            .closeOnClickModal(false)
            .footer([
                Button([text("取消")]).onClick(cancelClear),
                Button([text("清空")]).kind(ButtonKind.Danger).onClick(confirmClear),
            ])
        adminLayout("/admin/logs", [
            div([text("日志")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            adminCard("操作日志", [toolbar, table, confirmDlg]),
        ])
    }
}
