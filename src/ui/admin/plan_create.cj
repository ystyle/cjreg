// 管理端创建发布计划（@Page /admin/new-publish-plan）
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

// ===== 创建向导 =====
//
// 路径为什么不在 `/admin/publish-plans/` 下面：详情页的路由是
// `/admin/publish-plans/[id]`，与该前缀下**任何同深度**的静态路径都长得一样
// （`/admin/publish-plans/create` 拆开是 4 段，`[id]` 也是 4 段，两者都"匹配"）。
// cjxt ≤ 1.1.0 的 `RouteRegistry.resolve` 按注册顺序取第一个匹配项，而 `@Page` 的
// 注册顺序由编译器决定 —— 实测参数路由先注册，创建页被详情页吃掉：点「创建发布计划」
// 打开的却是详情页（`[id]` 拿到 "create"、计划 id 留在 0，显示"计划不存在或已删除"）。
// 框架侧已改为字面路径优先（cjxt 1.1.2），但本仓当前依赖的 1.1.0 仍会踩；
// 放到 `/admin` 下 3 段路径就没有同深度的参数路由，不依赖框架升级也能正确解析。
// 等 cjxt 正式版带上该修复并升级后，可以改回 `/admin/publish-plans/create`。
@Page["/admin/new-publish-plan", "创建发布计划", requireAdmin]
class PublishPlanCreatePage <: Component {
    var state: Option<CjregState> = None
    var msg = Signal<String>("")
    var planName = Signal<String>("")
    var targetUpstream = Signal<String>("")
    var pollInterval = Signal<Int64>(60)   // 旧字段：索引等待已改固定阶梯，仅随计划落库保留
    var pollTimeout = Signal<Int64>(0)     // 索引等待上限（秒）：0 = 一直等，直到就绪或用户停止
    var pkgSearch = Signal<String>("")
    var selectedPkgs = Signal<ArrayList<Int64>>(ArrayList<Int64>())
    var nameError = Signal<String>("")
    var upstreamError = Signal<String>("")
    var planForm = Form([])
    // 候选包表：搜索 + 分页都是**信号派生**（见 list_binding.cj）；页面实例跨请求复用，
    // 所以绑定在 onMount 重建、onUnmount 释放。
    var pkgRows = Signal<ArrayList<PackageDoc>>(ArrayList<PackageDoc>())
    var pkgPage = Signal<Int64>(1)
    var pkgPageSize = Signal<Int64>(10)
    var pkgTotal = Signal<Int64>(0)
    // 已选包表（按选择顺序；移除后立刻重排）
    var selRows = Signal<ArrayList<PackageDoc>>(ArrayList<PackageDoc>())
    var selCount = Signal<Int64>(0)
    private var pkgBinding: Option<Effect> = None
    private var selBinding: Option<Effect> = None
    // 「本地版本 ↔ 目标仓版本」对照预览：每次改动选择都异步重跑一次与创建时**同一份**分析
    //（依赖展开 + 目标仓索引），所以预览与创建出来的计划必然一致。
    // 网络在后台线程，结果经 App.pushUpdate 回推（异步线程不能直接改前端信号）。
    var previewRows = Signal<ArrayList<PlanItem>>(ArrayList<PlanItem>())
    var previewBusy = Signal<Bool>(false)
    var previewNote = Signal<String>("")
    // 丢弃过期结果：连点「添加/移除」时，先发出的请求可能后到，
    // 不按序号过滤就会用旧结果覆盖新结果（界面看起来"点了没反应"）
    var previewSeq: Int64 = 0

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        this.rebind()
    }

    public func onUnmount(ctx: LifecycleContext): Unit {
        match (this.pkgBinding) {
            case Some(e) => e.dispose()
            case None => ()
        }
        match (this.selBinding) {
            case Some(e) => e.dispose()
            case None => ()
        }
        this.pkgBinding = None
        this.selBinding = None
    }

    private func rebind(): Unit {
        match (this.pkgBinding) {
            case Some(e) => e.dispose()
            case None => ()
        }
        match (this.selBinding) {
            case Some(e) => e.dispose()
            case None => ()
        }
        this.pkgBinding = Some(bindPaged(this.pkgRows, this.pkgTotal, { => this.candidatePkgs() },
            this.pkgPage, this.pkgPageSize))
        this.selBinding = Some(bindRows(this.selRows, this.selCount, { => this.selectedDocs() }))
    }

    func backToList(ctx: ActionContext): PatchResult {
        ctx.route.push("/admin/publish-plans")
        PatchResult.ReRender
    }

    // 目标上游变了 → 之前的对照结果作废，重跑一次（先选上游再选包是常见顺序，
    // 但不能只依赖选包**之后**才对照：用户可能先选包、后改上游）
    func onTargetChanged(ctx: ActionContext): PatchResult {
        this.refreshPreview(ctx)
        PatchResult.ReRender
    }

    func pkgLabel(d: PackageDoc): String {
        // `org::name@version`（无组织时就是 `name@version`）。
        // 早先写 `${org}/${name}`，无组织的包显示成 `/snappy@1.0.1`，看着像路径丢了前半截。
        packageLabel(d.organization, d.name, d.version)
    }

    func isSelected(ids: ArrayList<Int64>, id: Int64): Bool {
        for (x in ids) {
            if (x == id) {
                return true
            }
        }
        false
    }

    // ===== 包选择区（候选表 + 已选表）=====
    //
    // 只列**本站为源站**的包（upstreamId == 0）：回源镜像（upstreamId != 0）是上游的包，
    // 不能作为发布源推给别人；隐藏了多少个在提示里写明，免得看起来像"包丢了"。
    //
    // 候选表的数据走信号派生（search + 分页 → bindPaged），搜索框**只 bind**：
    // 旧实现把过滤挂在 on("input") 动作上，而前端对同一元素是"先 action 后 bind"，
    // 过滤拿到的是上一次的关键字 → 搜索看起来完全无效（详见 list_binding.cj 的根因说明）。
    func candidatePkgs(): ArrayList<PackageDoc> {
        let st = match (this.state) {
            case Some(x) => x
            case None => return ArrayList<PackageDoc>()
        }
        let kw = this.pkgSearch.get().trimAscii().toAsciiLower()
        let out = ArrayList<PackageDoc>()
        for (d in st.pkgStore.storm.all<PackageDoc>()) {
            if (d.deletedAt != 0) {
                continue
            }
            if (d.upstreamId != 0) {
                continue
            }
            if (kw != "" && !pkgLabel(d).toAsciiLower().contains(kw)) {
                continue
            }
            out.add(d)
        }
        // 包名升序；同名的多个版本**新版本在前**。
        //
        // 主键必须是「组织 + 包名」，不能拿 pkgLabel（含 `@version`）当主键：
        // 那样同名不同版本之间 ka != kb 恒成立，版本分支永远走不到，
        // 排序退化成整串字典序（`alpha@1.10.0 < alpha@1.9.0`），与「新版本在前」相悖。
        sort(out, lessThan: { a, b =>
            let ka = a.organization + "::" + a.name
            let kb = b.organization + "::" + b.name
            if (ka != kb) { ka < kb } else { compareVersions(a.version, b.version) > 0 }
        })
        out
    }

    // 本站为源站 / 回源镜像的计数（提示文案用）
    func sourceCounts(): (Int64, Int64) {
        let st = match (this.state) {
            case Some(x) => x
            case None => return (0, 0)
        }
        var local: Int64 = 0
        var mirror: Int64 = 0
        for (d in st.pkgStore.storm.all<PackageDoc>()) {
            if (d.deletedAt != 0) {
                continue
            }
            if (d.upstreamId != 0) { mirror++ } else { local++ }
        }
        (local, mirror)
    }

    // 已选包（按选择顺序解析成文档；包被删了就跳过，不显示 #id 这样的裸编号）
    func selectedDocs(): ArrayList<PackageDoc> {
        let st = match (this.state) {
            case Some(x) => x
            case None => return ArrayList<PackageDoc>()
        }
        let ids = this.selectedPkgs.get()
        let out = ArrayList<PackageDoc>()
        for (id in ids) {
            for (d in st.pkgStore.storm.all<PackageDoc>()) {
                if (d.id == id) {
                    out.add(d)
                    break
                }
            }
        }
        out
    }

    func pickerHint(): String {
        if (this.pkgTotal.get() > 0) {
            return ""
        }
        let (local, _) = this.sourceCounts()
        if (local == 0) {
            return "本站还没有自发布的包：回源镜像不作为发布源，请先发布到本仓"
        }
        "没有匹配的包"
    }

    // 候选包卡片：搜索 + 分页 + 表格（每行一个「添加 / 移除」）
    func renderCandidateCard(): IComponent {
        let (local, mirror) = this.sourceCounts()
        let toolbar = div([
            // 搜索框只 bind（输入即写信号 → 派生重算）；不挂 input 动作（见上面注释）
            div([Input().bind(this.pkgSearch).placeholder("搜索包名 / 组织")],
                attrs: Some(HashMap<String, String>([("style", "width:280px;display:inline-block;")]))),
            div([text("本站为源站 ${local} 个 · 已隐藏回源镜像 ${mirror} 个（回源包不作为发布源）")],
                attrs: Some(HashMap<String, String>([("class", cls("picker-hint"))]))),
        ], attrs: Some(HashMap<String, String>([("class", cls("toolbar"))])))
        let pager = Pagination()
            .currentPage(this.pkgPage)
            .pageSize(this.pkgPageSize)
            .pageSizes([10, 20, 50])
            .total(this.pkgTotal.get())
            .layout("total, prev, pager, next, sizes")
        let table = Table<PackageDoc>()
            .data(this.pkgRows)
            .emptyText("暂无数据")
            .stripe()
            .add(TableColumn<PackageDoc>().label("包").width(240).render({ d, i =>
                text(if (d.organization == "") { d.name } else { "${d.organization}::${d.name}" })
            }).showOverflowTooltip())
            .add(TableColumn<PackageDoc>().label("版本").width(110).accessor({ d => d.version }))
            .add(TableColumn<PackageDoc>().label("描述").accessor({ d => d.description }).minWidth(240).showOverflowTooltip())
            .add(TableColumn<PackageDoc>().label("操作").width(100).render({ d, i =>
                let id = d.id
                let act: ActionHandler = { c => this.togglePkg(c, id) }
                if (isSelected(this.selectedPkgs.get(), id)) {
                    Button([text("移除")]).size(ButtonSize.Small).kind(ButtonKind.Danger).onClick(act)
                } else {
                    Button([text("添加")]).size(ButtonSize.Small).kind(ButtonKind.Primary).onClick(act)
                }
            }))
        div([
            toolbar,
            listBody(this.pickerHint(), table),
            pager,
        ])
    }

    // 已选包卡片：列出已选（含被依赖自动补齐前的"手动选择"部分）+ 逐个移除
    func renderSelectedCard(): IComponent {
        let table = Table<PackageDoc>()
            .data(this.selRows)
            .emptyText("暂无数据")
            .stripe()
            .add(TableColumn<PackageDoc>().label("包").width(240).render({ d, i =>
                text(if (d.organization == "") { d.name } else { "${d.organization}::${d.name}" })
            }).showOverflowTooltip())
            .add(TableColumn<PackageDoc>().label("版本").width(110).accessor({ d => d.version }))
            .add(TableColumn<PackageDoc>().label("描述").accessor({ d => d.description }).minWidth(240).showOverflowTooltip())
            .add(TableColumn<PackageDoc>().label("操作").width(100).render({ d, i =>
                let id = d.id
                let act: ActionHandler = { c => this.togglePkg(c, id) }
                Button([text("移除")]).size(ButtonSize.Small).kind(ButtonKind.Danger).onClick(act)
            }))
        let hint = if (this.selCount.get() == 0) {
            "尚未选择：从上面的结果里点「添加」（依赖会自动补齐）"
        } else {
            ""
        }
        div([
            div([text("已选择 ${this.selCount.get()} 个（依赖会自动补齐）")],
                attrs: Some(HashMap<String, String>([("class", cls("picker-title"))]))),
            listBody(hint, table),
        ])
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
        // 选择变了 → 异步重跑「本地版本 ↔ 目标仓版本」对照
        this.refreshPreview(ctx)
        PatchResult.ReRender
    }

    // ===== 选择后的「版本对照」预览 =====

    // 选择一变就重跑一次对照（与创建时同一份 analyze：依赖展开 + 目标仓索引分类）
    func refreshPreview(ctx: ActionContext): Unit {
        let st = match (this.state) {
            case Some(x) => x
            case None => return
        }
        let selected = this.selectedPkgs.get()
        this.previewSeq++
        let seq = this.previewSeq
        if (selected.size == 0) {
            this.previewRows.set(ArrayList<PlanItem>())
            this.previewNote.set("")
            this.previewBusy.set(false)
            return
        }
        let roots = ArrayList<(String, String, String)>()
        for (d in st.pkgStore.storm.all<PackageDoc>()) {
            if (isSelected(selected, d.id)) {
                roots.add((d.organization, d.name, d.version))
            }
        }
        let targetId = match (Int64.tryParse(this.targetUpstream.get())) {
            case Some(n) => n
            case None => 0
        }
        this.previewBusy.set(true)
        this.previewNote.set("正在对比目标仓索引…")
        let sid = ctx.getSessionId()
        spawn { =>
            this.previewAsync(st, sid, seq, roots, targetId)
        }
    }

    // 组装一次对照（解析依赖 + 取目标仓索引）。**预览失败不阻断创建**，所以异常在这里
    // 就转成提示语返回；网络只能出现在这里（render 里不能有阻塞调用）。
    func computePreview(st: CjregState, roots: ArrayList<(String, String, String)>,
                        targetId: Int64): (ArrayList<PlanItem>, String) {
        let items = ArrayList<PlanItem>()
        var hasCycle = false
        var targetError = ""
        var targetChosen = false
        try {
            let planSvc = PublishPlanService(st.pkgStore)
            let target = if (targetId > 0) { st.upStore.getById(targetId) } else { Option<Upstream>.None }
            targetChosen = target.isSome()
            let proxy = st.proxySvc
            let analysis = planSvc.analyze(roots, targetUpstream: target, fetchIndex: { up, org, name =>
                match (proxy) {
                    case Some(p) => p.probeUpstreamIndex(up, org, name)
                    case None => IndexProbe(0, "", detail: "本实例未接入回源代理")
                }
            })
            for (it in analysis.items) {
                items.add(it)
            }
            hasCycle = analysis.hasCycle
            targetError = analysis.targetError
        } catch (e: Exception) {
            println("[cjreg] 发布计划创建页对照失败: " + e.toString())
            return (items, "对照失败：" + e.toString())
        }
        if (hasCycle) {
            return (items, "依赖存在环：创建会被拒绝，请先解开依赖环")
        }
        if (targetError != "") {
            return (items, targetError)
        }
        if (!targetChosen) {
            return (items, "未选择目标上游：只展开了依赖链，选好上游后才能对照目标仓版本")
        }
        var need: Int64 = 0
        var exists: Int64 = 0
        var conflict: Int64 = 0
        for (it in items) {
            match (it.category) {
                case PlanCategory.AlreadyExists => exists++
                case PlanCategory.Conflict => conflict++
                case _ => need++
            }
        }
        var note = "共 ${items.size} 项 · 需发布 ${need}"
        if (exists > 0) {
            note += " · 目标仓已有 ${exists}"
        }
        if (conflict > 0) {
            note += " · 冲突 ${conflict}"
        }
        (items, note)
    }

    func previewAsync(st: CjregState, sid: String, seq: Int64,
                      roots: ArrayList<(String, String, String)>, targetId: Int64): Unit {
        let (items, note) = this.computePreview(st, roots, targetId)
        let app = match (st.app) {
            case Some(a) => a
            case None =>
                this.previewBusy.set(false)
                return
        }
        try {
            let _ = app.pushUpdate(sid, { _ =>
                // 只有仍是最新的那一次才落到界面：连点时先发后到的响应必须丢掉
                if (this.previewSeq == seq) {
                    this.previewRows.set(items)
                    this.previewNote.set(note)
                }
                this.previewBusy.set(false)
                PatchResult.ReRender
            })
        } catch (e: Exception) {
            // 异步回调抛异常没人接：不接住界面会永远停在"对照中…"
            println("[cjreg] 发布计划创建页对照结果推送失败: " + e.toString())
            this.previewBusy.set(false)
        }
    }

    // 对照预览区：逐项列「本地版本 → 目标仓版本」+ 分类，创建前就看得出
    // 哪些其实已经发过、目标仓那边现在是哪个版本。数据直接用 previewRows（异步对照结果），
    // 表格自订阅这个信号，所以 pushUpdate 回来时行会自己更新。
    func previewSection(): IComponent {
        let table = Table<PlanItem>()
            .data(this.previewRows)
            .emptyText("暂无数据")
            .stripe()
            .add(TableColumn<PlanItem>().label("序").width(56).accessor({ it => it.order.toString() }))
            .add(TableColumn<PlanItem>().label("包").minWidth(240).render({ it, i =>
                text(packageLabel(it.org, it.name, it.version))
            }).showOverflowTooltip())
            .add(TableColumn<PlanItem>().label("目标仓").width(180).render({ it, i =>
                text(targetCompareText(it.name, it.targetVersion, it.targetCompared))
            }).showOverflowTooltip())
            .add(TableColumn<PlanItem>().label("分类").width(130).render({ it, i =>
                planCategoryTag(it.category, "")
            }))
            .add(TableColumn<PlanItem>().label("说明").minWidth(240).render({ it, i =>
                text(categoryHint(it.category, it.overwriteAllowed))
            }).showOverflowTooltip())
        // 注意区分两种提示：
        //  - **说明**（对照中 / 未选上游 / "共 N 项 · 需发布 M" 摘要）是信息，用普通提示行；
        //  - **空态**（还没选包）才用 emptyState（那张插图）。
        // 一开始两者都走 listBody（插图版），于是"有 5 行数据 + 一张大插图 + 一句摘要"叠在一起，
        // 看着像图裂了（实测反馈）。
        let busy = this.previewBusy.get()
        let note = this.previewNote.get()
        let rows = this.previewRows.get().size
        let infoSlot = if (note != "") {
            div([text(note)], attrs: Some(HashMap<String, String>([("class", cls("picker-hint"))])))
        } else if (busy) {
            div([text("对照中…（正在取目标仓索引）")],
                attrs: Some(HashMap<String, String>([("class", cls("picker-hint"))])))
        } else {
            div()
        }
        // 空态只在"确实没东西可看、也没别的说明"时出现
        let emptyHint = if (rows == 0 && note == "" && !busy) {
            "选择包以后，这里会列出每一包的本地版本与目标仓版本"
        } else {
            ""
        }
        div([
            infoSlot,
            listBody(emptyHint, table),
        ])
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
        // 依赖分析（以选中包为根，计算拓扑序）+ **按目标仓索引分类**：
        // 不做这一步的话，目标仓早已有同版本的包也会列成「待发布」，
        // 用户只能靠执行时换回 409 才知道"其实不用发"。
        let planSvc = PublishPlanService(st.pkgStore)
        let target = st.upStore.getById(targetId)
        let proxy = st.proxySvc
        let analysis = planSvc.analyze(roots, targetUpstream: target, fetchIndex: { up, org, name2 =>
            match (proxy) {
                case Some(p) => p.probeUpstreamIndex(up, org, name2)
                case None => IndexProbe(0, "", detail: "本实例未接入回源代理")
            }
        })
        if (analysis.hasCycle) {
            this.msg.set("依赖存在环")
            return PatchResult.ReRender
        }
        let uid = sessionUid(ctx)
        let uname = sessionUsername(ctx)
        let planId = st.adminData.createPlan(name, targetId, this.pollInterval.get(), this.pollTimeout.get(), nowMs())
        var order: Int64 = 0
        for (it in analysis.items) {
            // selected 由分类决定：目标仓已有同版本（同 sha / 不同 sha）默认不勾选
            st.adminData.addPlanItem(planId, it.pkgId, it.org, it.name, it.version, order,
                planCategoryName(it.category), it.selected,
                targetVersion: it.targetVersion, targetCompared: it.targetCompared)
            order++
        }
        // 进度的分母 = **需要发布的项数**，不是条目总数：
        // 目标仓已有同版本（already_exists）的项根本不用发，算进去会让「0/6」看着像 6 个都要发。
        st.adminData.setPlanTotal(planId, countRequired(analysis.items))
        if (analysis.targetError != "") {
            // 对比没做成必须留在计划上：否则「全部待发布」看起来像是真的比对过了
            st.adminData.setPlanError(planId, analysis.targetError, nowMs())
        }
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
            FormItem([Select(upstreamOptions.toArray()).bind(this.targetUpstream)
                .onChange({ c => this.onTargetChanged(c) })
                .placeholder("选择上游")]).label("目标上游")
                .bindValue({ => this.targetUpstream.get() })
                .rule(FormRule(required: true, message: "请选择目标上游"))
                .errorSignal(this.upstreamError),
            // 索引等待节奏是固定的（见 indexWaitRhythmText），不需要用户配；
            // 这里只留一个可选的**总等待上限**（0 = 一直等，默认）。
            FormItem([InputNumber().bind(this.pollTimeout).min(0)]).label("索引等待上限（秒，0 = 一直等）")
                .bindValue({ => this.pollTimeout.get().toString() }),
        ]).labelTop()
        this.planForm = form
        adminLayout("/admin/publish-plans", [
            div([text("创建发布计划")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            cardStack([
                adminCard("计划信息", [form]),
                adminCard("选择要发布的包", [
                    this.renderCandidateCard(),
                    div([text("已选择的包")],
                        attrs: Some(HashMap<String, String>([("class", cls("picker-title"))]))),
                    this.renderSelectedCard(),
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
                adminCard("版本对照（本地 → 目标仓）", [this.previewSection()]),
            ]),
        ])
    }
}
