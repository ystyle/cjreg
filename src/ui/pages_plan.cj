// cjxt 管理界面：发布计划（列表 / 创建向导 / 详情）
package ystyle::cjreg.ui

import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import ystyle::cjreg.store.*
import ystyle::cjreg.config.*
import ystyle::cjreg.server.*
import ystyle::cjreg.index.*
import std.collection.*
import std.convert.*

// ===== 列表行视图类型（泛型 Table<T> 行：实体 + 按需计算的次要字段） =====

/// 发布计划列表行：计划实体 + 目标上游名
public struct PlanRow {
    public let doc: PlanDoc
    public let upstream: String

    public init(doc: PlanDoc, upstream: String) {
        this.doc = doc
        this.upstream = upstream
    }
}

/// 创建向导包选择行：包实体 + 是否已选中
public struct PkgChoice {
    public let doc: PackageDoc
    public let selected: Bool

    public init(doc: PackageDoc, selected: Bool) {
        this.doc = doc
        this.selected = selected
    }
}

// ===== 发布计划列表 =====
@Page["/admin/publish-plans", "发布计划", requireAdmin]
class PublishPlansPage <: Component {
    var state: Option<CjregState> = None
    var msg = Signal<String>("")
    // 行数据 + 分页（泛型 Table<PlanRow>：计划实体 + 上游名）
    var rows = Signal<ArrayList<PlanRow>>(ArrayList<PlanRow>())
    var currentPage = Signal<Int64>(1)
    var pageSize = Signal<Int64>(20)
    var total = Signal<Int64>(0)
    // 删除确认
    var confirmVisible = Signal<Bool>(false)
    var pendingDeleteId: Int64 = 0
    var pendingDeleteName: String = ""

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        refresh()
    }

    // 分页切片（行数据为 PlanRow 视图）
    func refresh(): Unit {
        match (this.state) {
            case Some(st) =>
                let plans = st.adminData.listPlans()
                this.total.set(plans.size)
                let (start, end) = pageWindow(plans.size, this.currentPage.get(), this.pageSize.get())
                let data = ArrayList<PlanRow>()
                var i = start
                while (i < end) {
                    let p = plans[i]
                    data.add(PlanRow(p, this.upstreamName(st, p.targetUpstream)))
                    i++
                }
                this.rows.set(data)
            case None => ()
        }
    }

    func onPageChange(ctx: ActionContext): PatchResult {
        this.refresh()
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

    func gotoCreate(ctx: ActionContext): PatchResult {
        ctx.route.push("/admin/publish-plans/create")
        PatchResult.ReRender
    }

    func gotoDetail(ctx: ActionContext, id: Int64): PatchResult {
        ctx.route.push("/admin/publish-plans/${id}")
        PatchResult.ReRender
    }

    func askDelete(ctx: ActionContext, id: Int64): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        match (st.adminData.getPlan(id)) {
            case Some(p) =>
                this.pendingDeleteId = p.id
                this.pendingDeleteName = p.name
                this.confirmVisible.set(true)
            case None => ()
        }
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

    func renderList(): IComponent {
        if (this.rows.get().size == 0) {
            return emptyState("暂无发布计划，点击「创建计划」新建")
        }
        Table<PlanRow>()
            .data(this.rows)
            .stripe()
            .add(TableColumn<PlanRow>().label("ID").accessor({ r => r.doc.id.toString() }).width(50))
            .add(TableColumn<PlanRow>().label("计划名").accessor({ r => r.doc.name }).minWidth(140))
            .add(TableColumn<PlanRow>().label("状态").width(90).render({ r, i =>
                this.statusTag(r.doc.status)
            }))
            .add(TableColumn<PlanRow>().label("目标上游").accessor({ r => r.upstream }).minWidth(140))
            .add(TableColumn<PlanRow>().label("进度").accessor({ r => "${r.doc.completedCount}/${r.doc.totalCount}" }).width(90))
            .add(TableColumn<PlanRow>().label("操作").minWidth(180).render({ r, i =>
                let id = r.doc.id
                let detailH: ActionHandler = { c => this.gotoDetail(c, id) }
                let deleteH: ActionHandler = { c => this.askDelete(c, id) }
                div([
                    Button([text("详情")]).size(ButtonSize.Small).onClick(detailH),
                    Button([text("删除")]).size(ButtonSize.Small).kind(ButtonKind.Danger).onClick(deleteH),
                ])
            }))
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
        let pager = Pagination()
            .currentPage(this.currentPage)
            .pageSize(this.pageSize)
            .total(this.total.get())
            .layout("total, prev, pager, next, sizes")
            .onChange(onPageChange)
        adminLayout("/admin/publish-plans", [
            div([text("发布计划")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            adminCard("发布计划列表", [toolbar, this.renderList(), pager, this.renderConfirmDialog()]),
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
    var nameError = Signal<String>("")
    var upstreamError = Signal<String>("")
    var planForm = Form([])
    // 搜索结果一次最多渲染多少行（剩下的靠搜索缩小范围）
    let MaxPickerRows: Int64 = 30

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
    }

    func backToList(ctx: ActionContext): PatchResult {
        ctx.route.push("/admin/publish-plans")
        PatchResult.ReRender
    }

    func pkgLabel(d: PackageDoc): String {
        let prefix = if (d.organization.isEmpty()) { "" } else { d.organization + "/" }
        "${prefix}${d.name}@${d.version}"
    }

    func isSelected(ids: ArrayList<Int64>, id: Int64): Bool {
        for (x in ids) {
            if (x == id) {
                return true
            }
        }
        false
    }

    // 包选择区：搜索框 + 搜索结果（每条一个「添加」）+ 已选择列表（每条一个「移除」）。
    //
    // 两个关键点：
    // 1. **只列本站为源站的包**（upstreamId == 0）。回源镜像（upstreamId != 0）是上游的包，
    //    不能作为发布源推给别人；隐藏了多少个在提示里写明，免得看起来像"包丢了"。
    // 2. 结果**不缓存到另一个信号**，而是在 render 里直接由 pkgSearch 算出：搜索框只做 bind，
    //    输入即写信号 → 读它的 render 作用域自动重渲。旧实现用 Component.on("input", …) 触发
    //    过滤是错的——前端对同一元素的监听是「先 action 后 bind」，过滤拿到的是**上一次**的
    //    关键字，而 bind 之后没人再触发过滤 → 搜索看起来完全无效。
    func pickerSections(): Array<IComponent> {
        let st = match (this.state) {
            case Some(x) => x
            case None => return []
        }
        let kw = this.pkgSearch.get().trimAscii().toAsciiLower()
        let selected = this.selectedPkgs.get()
        var localTotal: Int64 = 0
        var mirrorTotal: Int64 = 0
        var matched: Int64 = 0
        let hits = ArrayList<PackageDoc>()
        for (d in st.pkgStore.storm.all<PackageDoc>()) {
            if (d.deletedAt != 0) {
                continue
            }
            if (d.upstreamId != 0) {
                mirrorTotal++
                continue
            }
            localTotal++
            if (kw != "" && !pkgLabel(d).toAsciiLower().contains(kw)) {
                continue
            }
            matched++
            if (hits.size < MaxPickerRows) {
                hits.add(d)
            }
        }
        let out = ArrayList<IComponent>()
        out.add(div([text("选择要发布的包（依赖将自动按拓扑序纳入）")],
            attrs: Some(HashMap<String, String>([("class", cls("dialog-form-label"))]))))
        out.add(Input().bind(this.pkgSearch).placeholder("搜索包名（只列本站为源站的包）"))
        out.add(div([text("本站为源站 ${localTotal} 个 · 已隐藏回源镜像 ${mirrorTotal} 个（回源包不作为发布源）")],
            attrs: Some(HashMap<String, String>([("class", cls("picker-hint"))]))))
        if (hits.size == 0) {
            let empty = if (localTotal == 0) {
                "本站还没有自发布的包：回源镜像不作为发布源，请先发布到本仓"
            } else {
                "没有匹配的包"
            }
            out.add(div([text(empty)], attrs: Some(HashMap<String, String>([("class", cls("picker-empty"))]))))
        } else {
            let rows = ArrayList<IComponent>()
            for (d in hits) {
                let id = d.id
                let sel = isSelected(selected, id)
                let act: ActionHandler = { c => this.togglePkg(c, id) }
                let btn = if (sel) {
                    Button([text("已添加")]).size(ButtonSize.Small).disabled()
                } else {
                    Button([text("添加")]).size(ButtonSize.Small).kind(ButtonKind.Primary).onClick(act)
                }
                rows.add(div([text(pkgLabel(d)), btn],
                    attrs: Some(HashMap<String, String>([("class", cls("picker-row"))]))))
            }
            out.add(div(rows.toArray(), attrs: Some(HashMap<String, String>([("class", cls("picker-list"))]))))
        }
        if (matched > hits.size) {
            out.add(div([text("仅显示前 ${hits.size} 个（共 ${matched} 个匹配），用搜索缩小范围")],
                attrs: Some(HashMap<String, String>([("class", cls("picker-hint"))]))))
        }
        out.add(div([text("已选择 ${selected.size} 个（依赖会自动补齐）")],
            attrs: Some(HashMap<String, String>([("class", cls("picker-title"))]))))
        if (selected.size == 0) {
            out.add(div([text("尚未选择：从上面的结果里点「添加」")],
                attrs: Some(HashMap<String, String>([("class", cls("picker-empty"))]))))
        } else {
            let rows = ArrayList<IComponent>()
            for (id in selected) {
                var label = "#${id}"
                for (d in st.pkgStore.storm.all<PackageDoc>()) {
                    if (d.id == id) {
                        label = pkgLabel(d)
                        break
                    }
                }
                let act: ActionHandler = { c => this.togglePkg(c, id) }
                rows.add(div([text(label),
                    Button([text("移除")]).size(ButtonSize.Small).kind(ButtonKind.Danger).onClick(act)],
                    attrs: Some(HashMap<String, String>([("class", cls("picker-row"))]))))
            }
            out.add(div(rows.toArray(), attrs: Some(HashMap<String, String>([("class", cls("picker-list"))]))))
        }
        out.toArray()
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
        // 只改信号：结果与已选择列表都在 render 里由信号算出
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
        if (!this.planForm.validate()) {
            return PatchResult.ReRender
        }
        let name = this.planName.get()
        let targetId = match (Int64.tryParse(this.targetUpstream.get())) {
            case Some(n) => n
            case None => 0
        }
        let selected = this.selectedPkgs.get()
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
        let form = Form([
            FormItem([Input().bind(this.planName).placeholder("计划名称")]).label("计划名")
                .bindValue({ => this.planName.get() })
                .rule(FormRule(required: true, message: "计划名必填"))
                .errorSignal(this.nameError),
            FormItem([Select(upstreamOptions.toArray()).bind(this.targetUpstream).placeholder("选择上游")]).label("目标上游")
                .bindValue({ => this.targetUpstream.get() })
                .rule(FormRule(required: true, message: "请选择目标上游"))
                .errorSignal(this.upstreamError),
            FormItem([InputNumber().bind(this.pollInterval).min(1)]).label("轮询间隔（秒）")
                .bindValue({ => this.pollInterval.get().toString() }),
            FormItem([InputNumber().bind(this.pollTimeout).min(1)]).label("轮询超时（秒）")
                .bindValue({ => this.pollTimeout.get().toString() }),
        ]).labelTop()
        this.planForm = form
        adminLayout("/admin/publish-plans", [
            div([text("创建发布计划")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            cardStack([
                adminCard("计划信息", [form]),
                adminCard("选择要发布的包", [
                    div(this.pickerSections()),
                    if (this.msg.get() != "") {
                        Tag([text(this.msg.get())]).kind(ComponentKind.Success)
                    } else {
                        div()
                    },
                    div([
                        Button([text("返回列表")]).onClick(backHandler),
                        Button([text("分析并创建")]).kind(ButtonKind.Primary).onClick(submitCreate),
                    ], attrs: Some(HashMap<String, String>([("class", cls("toolbar"))]))),
                ]),
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
    // 发布项行数据（pushUpdate 时经 refreshItems 更新）
    var itemRows = Signal<ArrayList<PlanItemDoc>>(ArrayList<PlanItemDoc>())

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
            case "skipped" => Tag([text("未推送")]).kind(ComponentKind.Info)
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
                        // pkgId → 计划项 docId：执行回调是按项来的（一个项可能回调多次），
                        // 用索引并行数组会错位，必须按 pkgId 映射
                        let docIds = HashMap<Int64, Int64>()
                        var pending: Int64 = 0
                        for (d in docs) {
                            if (!d.selected) { continue }
                            let it = PlanItem(d.packageId, d.packageName, d.packageOrg, d.packageVersion, toPlanCategory(d.category), d.order)
                            it.selected = d.selected
                            // 带上库里已有的状态：续跑时执行器据此跳过已完成的项
                            it.status = toPlanItemStatus(d.status)
                            if (!(it.status == PlanItemStatus.Completed)) {
                                pending++
                                let _ = st.adminData.updatePlanItem(d.id, "running", "", nowMs())
                            }
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
                        st.planBusy.set(true)
                        st.planStatus.set("running")
                        st.planProgress.set("0/${execItems.size}")
                        st.adminData.addLog(LogKind.Publish, sessionUid(ctx), sessionUsername(ctx), "start plan ${plan.name}", "ok", nowMs())
                        // 异步执行（网络操作在线程内，DB 写在 pushUpdate 回调里串行化）
                        spawn { =>
                            this.runExecution(st, sid, execItems, docIds, up, plan.pollInterval, plan.pollTimeout)
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
    func runExecution(st: CjregState, sid: String, items: ArrayList<PlanItem>, docIds: HashMap<Int64, Int64>, up: Upstream, pollIntervalSec: Int64, pollTimeoutSec: Int64): Unit {
        let app = match (st.app) {
            case Some(a) => a
            case None => return
        }
        let executor = PublishExecutor(st.pkgStore, DiskBlobStore("${getDataDir()}/blobs"))
        let total = items.size
        let done = Box<Int64>(0)
        let okCount = Box<Int64>(0)
        let report = executor.execute(items, up.url, up.authToken, onItem: { it, _, err =>
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
            // 再推给前端刷新界面（纯 UI，失败也不影响已落盘的进度）
            let _ = app.pushUpdate(sid, { pctx =>
                let s = pctx.getState<CjregState>()
                s.planProgress.set("${done.value}/${total}")
                this.refreshItems()
                PatchResult.ReRender
            })
        }, indexProbe: { org, name =>
            // 拓扑序下一条依赖它：推完必须确认**目标仓索引里真的能查到该版本**再往下走
            // （中心仓索引同步偶尔很慢，这里按计划的轮询间隔等，超时就暂停而不是判失败）
            match (st.proxySvc) {
                case Some(p) => p.fetchUpstreamIndex(up, org, name)
                case None => Option<String>.None
            }
        }, pollIntervalSec: pollIntervalSec, pollTimeoutSec: pollTimeoutSec)
        // 中止 → paused（可续跑）；否则按成败收口
        let finalStatus = if (report.aborted) {
            "paused"
        } else if (report.failed == 0 && report.total > 0) {
            "completed"
        } else {
            "failed"
        }
        let summary = if (report.aborted) {
            report.abortReason
        } else if (report.failed > 0) {
            "失败 ${report.failed} 项：${if (report.errors.size > 0) { report.errors[0] } else { "" }}"
        } else {
            ""
        }
        // 计划级收口同样**先落盘**，再推界面
        let _ = st.adminData.updatePlanStatus(this.planId, finalStatus, report.success, nowMs())
        if (summary != "") {
            let _ = st.adminData.setPlanError(this.planId, summary, nowMs())
        }
        if (report.aborted) {
            st.adminData.addLog(LogKind.Publish, 0, "", "plan ${this.planId} paused", "failed", nowMs())
        }
        let _ = app.pushUpdate(sid, { pctx =>
            let s = pctx.getState<CjregState>()
            s.planBusy.set(false)
            s.planStatus.set(finalStatus)
            this.msg.set(summary)
            this.refreshItems()
            PatchResult.ReRender
        })
    }

    func refreshItems(): Unit {
        match (this.state) {
            case Some(st) =>
                let items = st.adminData.listPlanItems(this.planId)
                let data = ArrayList<PlanItemDoc>()
                for (d in items) {
                    data.add(d)
                }
                this.itemRows.set(data)
            case None => ()
        }
    }

    func renderItems(): IComponent {
        Table<PlanItemDoc>()
            .data(this.itemRows)
            .stripe()
            .add(TableColumn<PlanItemDoc>().label("序").accessor({ d => d.order.toString() }).width(50))
            .add(TableColumn<PlanItemDoc>().label("包").accessor({ d => "${d.packageOrg}/${d.packageName}@${d.packageVersion}" }).minWidth(260))
            .add(TableColumn<PlanItemDoc>().label("分类").accessor({ d => d.category }).width(120))
            .add(TableColumn<PlanItemDoc>().label("状态").width(90).render({ d, i =>
                this.itemStatusTag(d.status)
            }))
            .add(TableColumn<PlanItemDoc>().label("错误").accessor({ d => d.error }).minWidth(160).showOverflowTooltip())
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
                let canStart = !executing && plan.status != "running" && plan.status != "completed"
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
                            .add(DescriptionsItem().label("状态").children([this.statusTag(if (executing) { "running" } else { plan.status })]))
                            .add(DescriptionsItem().label("目标上游").children([text(this.upstreamName(st, plan.targetUpstream))]))
                            .add(DescriptionsItem().label("进度").children([text("${plan.completedCount}/${plan.totalCount}")]))
                            .add(DescriptionsItem().label("轮询").children([text("${plan.pollInterval}s / 超时 ${plan.pollTimeout}s")]))
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
                            if (canStart) {
                                Button([text(if (resuming) { "继续执行（跳过已完成项）" } else { "开始执行" })])
                                    .kind(ButtonKind.Primary).onClick(doStart)
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

// PlanItemDoc.category 字符串 → PlanCategory 枚举
func toPlanCategory(s: String): PlanCategory {
    match (s) {
        case "version_optional" => PlanCategory.VersionOptional
        case "already_exists" => PlanCategory.AlreadyExists
        case "conflict" => PlanCategory.Conflict
        case _ => PlanCategory.NeedPublish
    }
}

// 计划项状态：字符串 ⇄ 枚举（续跑时要把库里的状态带回执行器，
// 否则已成功的项会被重复推送、换回 409）
func toPlanItemStatus(s: String): PlanItemStatus {
    match (s) {
        case "completed" => PlanItemStatus.Completed
        case "failed" => PlanItemStatus.Failed
        case "running" => PlanItemStatus.Pending
        case "skipped" => PlanItemStatus.Skipped
        case _ => PlanItemStatus.Pending
    }
}

func planItemStatusName(s: PlanItemStatus): String {
    match (s) {
        case PlanItemStatus.Completed => "completed"
        case PlanItemStatus.Failed => "failed"
        case PlanItemStatus.Skipped => "skipped"
        case PlanItemStatus.Publishing => "running"
        case PlanItemStatus.WaitingIndex => "pending"
        case PlanItemStatus.Pending => "pending"
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
// 审计日志：类型/结果筛选 + 关键字搜索 + 分页 + 按类型清理（清理动作自身入审计）
@Page["/admin/logs", "日志", requireAdmin]
class LogsPage <: Component {
    var state: Option<CjregState> = None
    var rows = Signal<ArrayList<LogDoc>>(ArrayList<LogDoc>())
    var kindFilter = Signal<String>("all")
    var statusFilter = Signal<String>("all")
    var keyword = Signal<String>("")
    var currentPage = Signal<Int64>(1)
    var pageSize = Signal<Int64>(20)
    var total = Signal<Int64>(0)
    var msg = Signal<String>("")
    var confirmVisible = Signal<Bool>(false)
    var cleanKind = Signal<String>("all")

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        refresh()
    }

    func refresh(): Unit {
        match (this.state) {
            case Some(st) =>
                let kind = if (this.kindFilter.get() == "all") { Option<String>.None } else { Some(this.kindFilter.get()) }
                let status = if (this.statusFilter.get() == "all") { "" } else { this.statusFilter.get() }
                var size = this.pageSize.get()
                if (size <= 0) {
                    size = 20
                }
                var page = this.currentPage.get()
                if (page < 1) {
                    page = 1
                }
                let (rows, total) = st.adminData.queryLogs(kind, this.keyword.get().trimAscii(), status,
                    0, 0, (page - 1) * size, size)
                this.rows.set(rows)
                this.total.set(total)
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
        this.currentPage.set(1)
        this.refresh()
        PatchResult.ReRender
    }

    // 分页绑定由框架回写 currentPage/pageSize 信号，这里只需按新条件重查
    func onPageChange(ctx: ActionContext): PatchResult {
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
        let scope = this.cleanKind.get()
        let kind = if (scope == "all") { Option<String>.None } else { Some(scope) }
        let deleted = st.adminData.removeLogs(kind, 0)
        // 清理动作自身入审计（管理类；UI 操作无 HTTP 上下文，IP/UA 记为管理端）
        let _ = st.adminData.addLog(LogKind.Admin, sessionUid(ctx), sessionUsername(ctx), "clean_logs", "ok", nowMs(),
            target: if (scope == "all") { "all" } else { scope },
            detail: "deleted=${deleted} via=admin-ui", ipAddr: "admin-ui", userAgent: "cjxt-admin-ui")
        this.msg.set("已清理 ${deleted} 条${if (scope == "all") { "全部" } else { this.kindLabel(scope) }}日志")
        this.confirmVisible.set(false)
        this.currentPage.set(1)
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
        let cleanOptions = ArrayList<IComponent>()
        cleanOptions.add(SelectOption([text("全部日志")], "all"))
        cleanOptions.add(SelectOption([text("仅发布日志")], "publish"))
        cleanOptions.add(SelectOption([text("仅管理日志")], "admin"))
        cleanOptions.add(SelectOption([text("仅认证日志")], "auth"))
        // 各控件固定宽度：日志页列多，工具栏需在一行内放下「筛选/清理」按钮
        let toolbar = div([
            div([Input().bind(this.keyword).placeholder("搜索操作者/操作/对象/错误")
                .on("input", { _ =>
                    this.currentPage.set(1)
                    this.refresh()
                    PatchResult.ReRender
                })], attrs: Some(HashMap<String, String>([("style", "width:230px;display:inline-block;")]))),
            div([Select(kindOptions.toArray()).bind(this.kindFilter)],
                attrs: Some(HashMap<String, String>([("style", "width:130px;display:inline-block;")]))),
            div([Select(statusOptions.toArray()).bind(this.statusFilter)],
                attrs: Some(HashMap<String, String>([("style", "width:130px;display:inline-block;")]))),
            Button([text("筛选")]).kind(ButtonKind.Primary).onClick(doRefresh),
            Button([text("清理日志")]).kind(ButtonKind.Danger).onClick(askClear),
            if (this.msg.get() != "") {
                Tag([text(this.msg.get())]).kind(ComponentKind.Success)
            } else {
                div()
            },
        ], attrs: Some(HashMap<String, String>([("class", cls("toolbar"))])))
        let table = Table<LogDoc>()
            .data(this.rows)
            .stripe()
            .add(TableColumn<LogDoc>().label("时间").width(120).render({ l, i =>
                text(formatTimeMs(l.createdAt))
            }))
            .add(TableColumn<LogDoc>().label("类型").width(70).render({ l, i =>
                text(this.kindLabel(l.kind))
            }))
            .add(TableColumn<LogDoc>().label("操作者").accessor({ l => l.actorName }).width(100))
            .add(TableColumn<LogDoc>().label("操作").accessor({ l => l.action }).minWidth(140).showOverflowTooltip())
            .add(TableColumn<LogDoc>().label("对象").accessor({ l => l.target }).minWidth(150).showOverflowTooltip())
            .add(TableColumn<LogDoc>().label("结果").width(80).render({ l, i =>
                if (l.status == "ok") {
                    Tag([text("成功")]).kind(ComponentKind.Success)
                } else {
                    Tag([text("失败")]).kind(ComponentKind.Danger)
                }
            }))
            .add(TableColumn<LogDoc>().label("IP").accessor({ l => l.ipAddr }).width(120))
            .add(TableColumn<LogDoc>().label("User-Agent").accessor({ l => l.userAgent }).minWidth(130).showOverflowTooltip())
            .add(TableColumn<LogDoc>().label("错误信息").accessor({ l => l.error }).minWidth(160).showOverflowTooltip())
        let pager = Pagination()
            .currentPage(this.currentPage)
            .pageSize(this.pageSize)
            .total(this.total.get())
            .layout("total, prev, pager, next, sizes")
            .onChange(onPageChange)
        let confirmDlg = Dialog([
            div([text("清理范围：")]),
            Select(cleanOptions.toArray()).bind(this.cleanKind),
            div([text("清理后不可恢复；清理动作本身会记入审计日志。")]),
        ])
            .visible(this.confirmVisible)
            .title("清理审计日志")
            .width("420px")
            .closeOnClickModal(false)
            .footer([
                Button([text("取消")]).onClick(cancelClear),
                Button([text("确认清理")]).kind(ButtonKind.Danger).onClick(confirmClear),
            ])
        adminLayout("/admin/logs", [
            div([text("审计日志")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            adminCard("操作日志", [toolbar, table, pager, confirmDlg]),
        ])
    }
}
