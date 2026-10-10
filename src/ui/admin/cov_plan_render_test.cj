// 发布计划（列表 / 创建向导 / 详情）与共用辅助的渲染 + 交互回归。
//
// 三个页面里 detail 的分支最多（执行、索引确认、重新分析、勾选、停止），原先只有
// 「按钮可见性」的用例；这里补全：
//   * plan_shared 的纯函数（分类/状态字符串⇄枚举、索引时间、时间文案、登记/注销）；
//   * plan_list：状态 Tag 六档、目标上游名兜底、计划不存在时的提示、删除三态、跳转；
//   * plan_create：候选包过滤（软删/回源镜像/关键字）、已选表、对照预览的四条提示出口、
//     提交（未选包 / 依赖成环 / 成功建计划并入条目 / targetError 落库）；
//   * plan_detail：执行前的三条早退（非管理员/已在执行/计划不存在/目标上游不存在）、
//     无可执行项、全部已完成、勾选 toggle、停止执行、检查索引四条出口、
//     重新分析（卡死自愈、正常、目标上游缺失、计划不存在）、明细/行数/索引等待文案、
//     最后一列「不可覆盖/需升版」的只读态。
package ystyle::cjreg.ui.admin

import ystyle::cjreg.ui.*
import cjxt.*
import ystyle::cjreg.store.*
import ystyle::cjreg.config.*
import ystyle::cjreg.index.*
import ystyle::cjreg.server.{IndexProbe, PlanCategory, PlanItem, PlanItemStatus, PublishPlanService,
    PublishExecutor, checkVersionsInIndex, indexWaitRhythmText, ProxyService, MemoryBlobStore}
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*
import std.collection.*
import std.reflect.*
import std.unittest.*
import std.unittest.testmacro.*

func mountPlanListCov(state: CjregState): PublishPlansPage {
    let page = PublishPlansPage()
    page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
    page
}

func mountPlanCreateCov(state: CjregState): PublishPlanCreatePage {
    let page = PublishPlanCreatePage()
    page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
    page
}

func mountPlanDetailCov(state: CjregState, planId: Int64, isAdmin!: Bool = true): PublishPlanDetailPage {
    let page = PublishPlanDetailPage()
    page.onMount(covPlanDetailCtx(state, planId, isAdmin))
    page
}

// 详情页上下文：带路由参数 id（onMount 从 route.params 取计划 id）
func covPlanDetailCtx(state: CjregState, planId: Int64, isAdmin: Bool): LifecycleContext {
    let states = HashMap<String, AppState>()
    states.add(TypeInfo.of<CjregState>().qualifiedName, state)
    let params = HashMap<String, String>()
    params.add("id", planId.toString())
    let sctx: SessionContext = SessionContextState(userCtxMap(1, "admin", isAdmin))
    LifecycleContext("sid-plan-detail", params, Option<String>.None, Option<String>.None,
        states: states, sessionContext: Some(sctx))
}

func covSeedPlan(state: CjregState, name: String, status!: String = "pending",
                 targetUpstream!: Int64 = 0, pollTimeout!: Int64 = 600,
                 lastError!: String = ""): Int64 {
    let id = state.adminData.createPlan(name, targetUpstream, 60, pollTimeout, 1000)
    let _ = state.adminData.updatePlanStatus(id, status, 0, 1000)
    if (lastError != "") {
        let _ = state.adminData.setPlanError(id, lastError, 1000)
    }
    id
}

// 计划项：默认「需发布 + 勾选 + 未推送」
func covSeedPlanItem(state: CjregState, planId: Int64, name: String, order: Int64,
                     category!: String = "need_publish", selected!: Bool = true,
                     status!: String = "pending", error!: String = "",
                     targetVersion!: String = "", targetCompared!: Bool = false,
                     org!: String = "ystyle"): Int64 {
    let id = state.adminData.addPlanItem(planId, order + 100, org, name, "1.0.0", order,
        category, selected, targetVersion: targetVersion, targetCompared: targetCompared)
    if (status != "pending") {
        let _ = state.adminData.updatePlanItem(id, status, error, 2000)
    }
    return id
}

// 给发布计划页造一个「有制品」的包（执行路径要靠它）
func covSeedPublishable(state: CjregState, org: String, name: String, version: String): PackageDoc {
    let entry = PackageIndex()
    entry.organization = org
    entry.name = name
    entry.version = version
    entry.sha256sum = "sha-${name}-${version}"
    let d = PackageDoc()
    d.organization = org
    d.name = name
    d.version = version
    d.sha256 = entry.sha256sum
    d.indexJson = generateNDJSON(ArrayList<PackageIndex>([entry]))
    d.createdAt = 1000
    d.updatedAt = 2000
    state.pkgStore.save(d)
    d
}

@Test
public class CovPlanSharedTest {
    // 分类字符串 ⇄ 枚举：四档 + 未知值落 NeedPublish
    @TestCase
    public func covPlanShared_categoryMapping(): Unit {
        @Expect(toPlanCategory("version_optional") == PlanCategory.VersionOptional, true)
        @Expect(toPlanCategory("already_exists") == PlanCategory.AlreadyExists, true)
        @Expect(toPlanCategory("conflict") == PlanCategory.Conflict, true)
        @Expect(toPlanCategory("need_publish") == PlanCategory.NeedPublish, true)
        @Expect(toPlanCategory("bogus") == PlanCategory.NeedPublish, true)
    }

    // 索引时间：优先显式 indexAt；否则已完成的退回 completedAt；其余 0
    @TestCase
    public func covPlanShared_indexTimeOf(): Unit {
        let d = PlanItemDoc()
        @Expect(indexTimeOf(d), 0)                 // 都没有 → 0
        d.completedAt = 777
        @Expect(indexTimeOf(d), 0)                 // 未完成时不退回 completedAt
        d.status = "completed"
        @Expect(indexTimeOf(d), 777)
        d.indexAt = 999
        @Expect(indexTimeOf(d), 999)               // indexAt 优先
    }

    // 时间文案：0 → 「label —」，正数 → 「label HH:mm:ss」
    @TestCase
    public func covPlanShared_itemTimeText(): Unit {
        @Expect(itemTimeText("推送", 0), "推送 —")
        @Expect(itemTimeText("索引", -5), "索引 —")
        let t = 1700000000000
        let s = itemTimeText("推送", t)
        @Expect(s.startsWith("推送 "), true)
        @Expect(s.size, "推送 HH:mm:ss".size)
        @Expect(s.contains(":"), true)
    }

    // 分类 Tag：status 优先（completed / waiting_index），否则按分类四档
    @TestCase
    public func covPlanShared_categoryTagAllBranches(): Unit {
        @Expect(covRender(planCategoryTag(PlanCategory.NeedPublish, "completed")).contains("已发布"), true)
        @Expect(covRender(planCategoryTag(PlanCategory.NeedPublish, "waiting_index")).contains("已推送·等索引"), true)
        @Expect(covRender(planCategoryTag(PlanCategory.AlreadyExists, "pending")).contains("已存在"), true)
        @Expect(covRender(planCategoryTag(PlanCategory.Conflict, "pending")).contains("冲突"), true)
        @Expect(covRender(planCategoryTag(PlanCategory.VersionOptional, "pending")).contains("可升版"), true)
        @Expect(covRender(planCategoryTag(PlanCategory.NeedPublish, "pending")).contains("待发布"), true)
    }

    // 计划项状态字符串 ⇄ 枚举：六档 + 未知值
    @TestCase
    public func covPlanShared_itemStatusMapping(): Unit {
        @Expect(toPlanItemStatus("completed") == PlanItemStatus.Completed, true)
        @Expect(toPlanItemStatus("failed") == PlanItemStatus.Failed, true)
        @Expect(toPlanItemStatus("running") == PlanItemStatus.Pending, true)
        @Expect(toPlanItemStatus("waiting_index") == PlanItemStatus.WaitingIndex, true)
        @Expect(toPlanItemStatus("skipped") == PlanItemStatus.Skipped, true)
        @Expect(toPlanItemStatus("pending") == PlanItemStatus.Pending, true)
        @Expect(toPlanItemStatus("bogus") == PlanItemStatus.Pending, true)

        @Expect(planItemStatusName(PlanItemStatus.Completed), "completed")
        @Expect(planItemStatusName(PlanItemStatus.Failed), "failed")
        @Expect(planItemStatusName(PlanItemStatus.Skipped), "skipped")
        @Expect(planItemStatusName(PlanItemStatus.Publishing), "running")
        @Expect(planItemStatusName(PlanItemStatus.WaitingIndex), "waiting_index")
        @Expect(planItemStatusName(PlanItemStatus.Pending), "pending")
    }

    // 登记 / 注销：幂等（重复登记不重复加），cancel 决定写哪条信号
    @TestCase
    public func covPlanShared_addRemovePlanId(): Unit {
        let state = makePortalState("team")
        addPlanId(state, 7, false)
        addPlanId(state, 7, false)          // 幂等
        @Expect(state.planRunIds.get().size, 1)
        addPlanId(state, 8, false)
        @Expect(state.planRunIds.get().size, 2)

        addPlanId(state, 7, true)
        addPlanId(state, 7, true)           // 幂等
        @Expect(state.planCancelIds.get().size, 1)
        @Expect(containsId(state.planCancelIds.get(), 7), true)

        removePlanId(state, 7, false)
        @Expect(state.planRunIds.get().size, 1)
        @Expect(state.planRunIds.get()[0], 8)
        removePlanId(state, 7, true)
        @Expect(state.planCancelIds.get().size, 0)
        // 注销一个不存在的 id：不动列表
        removePlanId(state, 999, false)
        @Expect(state.planRunIds.get().size, 1)
    }
}

@Test
public class CovPlanListRenderTest {
    // 空态与提示
    @TestCase
    public func covPlanList_emptyState(): Unit {
        let state = makePortalState("team")
        let page = mountPlanListCov(state)
        @Expect(page.rows.get().size, 0)
        let json = covRenderExpanded(page.render())
        @Expect(json.contains("暂无发布计划，点击「创建计划」新建"), true)
        @Expect(json.contains("el-table"), true)
        @Expect(json.contains("发布计划列表"), true)
        @Expect(json.contains("创建计划"), true)
    }

    // 状态 Tag 六档：interrupted 由「库里 running 但进程没登记」推出来
    @TestCase
    public func covPlanList_statusTagAllBranches(): Unit {
        let state = makePortalState("team")
        let page = mountPlanListCov(state)
        for ((s, label) in [("running", "执行中"), ("completed", "已完成"), ("failed", "失败"),
                            ("paused", "已暂停"), ("pending", "待执行")]) {
            @Expect(covRender(page.statusTag(s)).contains(label), true)
        }
        @Expect(covRender(page.statusTag("interrupted")).contains("上次未收口"), true)
        @Expect(covRender(page.statusTag("bogus")).contains("待执行"), true)

        // 渲染层：running 但没登记 → 显示「上次未收口」
        let pid = covSeedPlan(state, "stale-running", status: "running")
        page.refresh()
        let json = covRender(page.render())
        @Expect(json.contains("上次未收口"), true)
        @Expect(json.contains("执行中"), false)

        // 登记之后 → 显示「执行中」
        addPlanId(state, pid, false)
        page.refresh()
        @Expect(covRender(page.render()).contains("执行中"), true)
    }

    // 目标上游名：存在给名字，不存在给 #id
    @TestCase
    public func covPlanList_upstreamNameFallback(): Unit {
        let state = makePortalState("team")
        let upId = covSeedUpstream(state, "mirror-x")
        let page = mountPlanListCov(state)
        @Expect(page.upstreamName(state, upId), "mirror-x")
        @Expect(page.upstreamName(state, 999999), "#999999")

        let _ = covSeedPlan(state, "with-up", targetUpstream: upId)
        let _ = covSeedPlan(state, "without-up", targetUpstream: 424242)
        page.refresh()
        let json = covRender(page.render())
        @Expect(json.contains("mirror-x"), true)
        @Expect(json.contains("#424242"), true)
    }

    // 进度列：totalCount 为 0 时「无需发布」，否则 done/total
    @TestCase
    public func covPlanList_progressColumn(): Unit {
        let state = makePortalState("team")
        let a = covSeedPlan(state, "no-work")
        let b = covSeedPlan(state, "half-done")
        let _ = state.adminData.setPlanTotal(b, 4)
        let _ = state.adminData.updatePlanStatus(b, "running", 2, 1000)
        let page = mountPlanListCov(state)
        page.refresh()
        let json = covRender(page.render())
        @Expect(json.contains("无需发布"), true)
        @Expect(json.contains("2/4"), true)
        @Expect(a != b, true)
    }

    // 新建在前（listPlans 按 id 降序）
    @TestCase
    public func covPlanList_newestFirst(): Unit {
        let state = makePortalState("team")
        let old = covSeedPlan(state, "旧")
        let fresh = covSeedPlan(state, "新")
        let page = mountPlanListCov(state)
        @Expect(page.rows.get().size, 2)
        @Expect(page.rows.get()[0].doc.id, fresh)
        @Expect(page.rows.get()[1].doc.id, old)
    }

    // 分页：切片 + 越界页钳制
    @TestCase
    public func covPlanList_pagination(): Unit {
        let state = makePortalState("team")
        for (i in 0..5) {
            let _ = covSeedPlan(state, "p${i}")
        }
        let page = mountPlanListCov(state)
        let (actx, _) = covActx(state)
        @Expect(page.total.get(), 5)

        page.pageSize.set(2)
        let _ = page.onPageChange(actx)
        @Expect(page.rows.get().size, 2)

        page.currentPage.set(50)
        let _ = page.onPageChange(actx)
        @Expect(page.rows.get().size, 0)
        @Expect(page.total.get(), 5)
    }

    // 跳转：创建计划与详情
    @TestCase
    public func covPlanList_navigation(): Unit {
        let state = makePortalState("team")
        let pid = covSeedPlan(state, "nav")
        let page = mountPlanListCov(state)
        let (actx, nav) = covActx(state)
        let _ = page.gotoCreate(actx)
        @Expect(nav[0], "/admin/publish-plans/create")
        let _ = page.gotoDetail(actx, pid)
        @Expect(nav[1], "/admin/publish-plans/${pid}")
    }

    // 删除确认：正文走 SignalView，换对象后内容跟着变；不存在的 id 给提示（不是静默）
    @TestCase
    public func covPlanList_deleteConfirmFlow(): Unit {
        let state = makePortalState("team")
        let a = covSeedPlan(state, "plan-a")
        let b = covSeedPlan(state, "plan-b")
        let page = mountPlanListCov(state)
        let (actx, _) = covActx(state)

        let _ = page.askDelete(actx, a)
        @Expect(page.confirmVisible.get(), true)
        @Expect(page.pendingDeleteName.get(), "plan-a")
        @Expect(covRender(page.render()).contains("确定要删除计划「plan-a」吗？"), true)

        let _ = page.askDelete(actx, b)
        @Expect(page.pendingDeleteName.get(), "plan-b")
        @Expect(covRender(page.render()).contains("确定要删除计划「plan-b」吗？"), true)

        // 不存在 → 明确提示（静默会像按钮坏了）
        page.confirmVisible.set(false)
        let _ = page.askDelete(actx, 999999)
        @Expect(page.confirmVisible.get(), false)
        @Expect(page.msg.get(), "计划 #999999 不存在（可能已被删除），请刷新列表")
        @Expect(covRender(page.render()).contains("计划 #999999 不存在"), true)
    }

    @TestCase
    public func covPlanList_cancelDelete(): Unit {
        let state = makePortalState("team")
        let pid = covSeedPlan(state, "keep-plan")
        let page = mountPlanListCov(state)
        let (actx, _) = covActx(state)
        let _ = page.askDelete(actx, pid)
        let _ = page.cancelDelete(actx)
        @Expect(page.confirmVisible.get(), false)
        @Expect(state.adminData.getPlan(pid).isSome(), true)
    }

    // 确认删除：真删（含条目）+ 审计 + 列表刷新；再删一次同 id → 「删除失败」
    @TestCase
    public func covPlanList_confirmDelete(): Unit {
        let state = makePortalState("team")
        let pid = covSeedPlan(state, "doomed-plan")
        let _ = covSeedPlanItem(state, pid, "alpha", 1)
        let page = mountPlanListCov(state)
        let (actx, _) = covActx(state)
        @Expect(page.rows.get().size, 1)

        let _ = page.askDelete(actx, pid)
        let _ = page.confirmDelete(actx)
        @Expect(page.msg.get(), "已删除计划 doomed-plan")
        @Expect(page.confirmVisible.get(), false)
        @Expect(page.pendingDeleteId, 0)
        @Expect(state.adminData.getPlan(pid).isNone(), true)
        @Expect(state.adminData.listPlanItems(pid).size, 0)   // 条目一并删掉
        @Expect(page.rows.get().size, 0)                       // 列表已刷新
        let (_, total) = state.adminData.queryLogs(Some("admin"), "delete plan", "", 0, 0, 0, 10)
        @Expect(total, 1)

        // 记录已被删 → 再删一次：askDelete 会提示不存在，不会再进确认
        let _ = page.askDelete(actx, pid)
        @Expect(page.confirmVisible.get(), false)
        // 直接调 confirmDelete（模拟 pendingDeleteId 已被清成 0 的边角）→ deletePlan 返回 false
        let _ = page.confirmDelete(actx)
        @Expect(page.msg.get(), "删除失败")
    }

    // 鉴权：库里降级 / 未登录
    @TestCase
    public func covPlanList_confirmDeleteRequiresAdmin(): Unit {
        let state = makePortalState("team")
        let pid = covSeedPlan(state, "safe-plan")
        let page = mountPlanListCov(state)
        let (plain, _) = covActx(state, dbIsAdmin: false, ctxIsAdmin: true, username: "covplain")
        let _ = page.askDelete(plain, pid)
        let _ = page.confirmDelete(plain)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(state.adminData.getPlan(pid).isSome(), true)

        let anon = covAnonActx(state)
        let _ = page.confirmDelete(anon)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(state.adminData.queryLogs(Option<String>.None, "", "", 0, 0, 0, 10)[1], 0)
    }

    // 未挂载 state：全部动作走 None 分支
    @TestCase
    public func covPlanList_withoutState(): Unit {
        let state = makePortalState("team")
        let page = PublishPlansPage()
        @Expect(covRender(page.render()).contains("发布计划"), true)
        page.refresh()
        @Expect(page.rows.get().size, 0)
        let (actx, _) = covActx(state)
        let _ = page.onPageChange(actx)
        let _ = page.askDelete(actx, 1)
        @Expect(page.confirmVisible.get(), false)
        let _ = page.confirmDelete(actx)
        @Expect(page.msg.get(), "")
    }

    // msg 提示槽位：空时不渲染 Tag
    @TestCase
    public func covPlanList_msgTag(): Unit {
        let state = makePortalState("team")
        let page = mountPlanListCov(state)
        @Expect(covRender(page.render()).contains("已删除计划"), false)
        page.msg.set("已删除计划 x")
        @Expect(covRender(page.render()).contains("已删除计划 x"), true)
    }
}

@Test
public class CovPlanCreateRenderTest {
    // 候选包：跳过软删与回源镜像（并在提示里报数），关键字过滤
    @TestCase
    public func covPlanCreate_candidateFiltering(): Unit {
        let state = makePortalState("team")
        let _ = covSeedPkg(state, "ystyle", "alpha", "1.0.0", desc: "第一个")
        let _ = covSeedPkg(state, "acme", "beta", "2.0.0")
        let _ = covSeedPkg(state, "ystyle", "gone", "1.0.0", deleted: true)
        let _ = covSeedPkg(state, "ystyle", "mirrored", "1.0.0", upstreamId: 9, upstreamName: "up")
        let page = mountPlanCreateCov(state)

        @Expect(page.pkgRows.get().size, 2)     // gone 与 mirrored 都被跳过
        @Expect(page.pkgTotal.get(), 2)
        let json = covRender(page.render())
        @Expect(json.contains("本站为源站 2 个 · 已隐藏回源镜像 1 个（回源包不作为发布源）"), true)
        @Expect(json.contains("ystyle::alpha"), true)
        @Expect(json.contains("acme::beta"), true)
        @Expect(json.contains("gone"), false)
        @Expect(json.contains("mirrored"), false)

        // 关键字（大小写不敏感 + trim）
        page.pkgSearch.set("  BETA ")
        @Expect(page.pkgRows.get().size, 1)
        @Expect(page.pkgRows.get()[0].name, "beta")
        page.pkgSearch.set("nothing")
        @Expect(page.pkgRows.get().size, 0)
        @Expect(page.pickerHint(), "没有匹配的包")
        @Expect(covRender(page.render()).contains("没有匹配的包"), true)
    }

    // 一个自发布包都没有：提示引导先发布（与"没有匹配"区分）
    @TestCase
    public func covPlanCreate_pickerHintWhenNoLocalPackages(): Unit {
        let state = makePortalState("team")
        let _ = covSeedPkg(state, "ystyle", "mirror-only", "1.0.0", upstreamId: 1, upstreamName: "up")
        let page = mountPlanCreateCov(state)
        @Expect(page.pkgTotal.get(), 0)
        @Expect(page.pickerHint(), "本站还没有自发布的包：回源镜像不作为发布源，请先发布到本仓")
    }

    // 候选表排序：包名升序；同名多版本按**版本号字符串**升序。
    //
    // 这里断言的是**实际行为**：比较器用完整标签 `org::name@version` 做主键（`ka != kb`），
    // 而标签里已经含版本号，所以版本分支（`ka == kb` 时才比版本）实际上永远走不到 →
    // 得到的是字典序升序，而不是源码注释里写的"新版本在前"。先在测试里钉住现状，
    // 待确认这是有意为之还是缺陷后再决定是否改生产代码。
    @TestCase
    public func covPlanCreate_candidateOrdering(): Unit {
        let state = makePortalState("team")
        let _ = covSeedPkg(state, "ystyle", "beta", "1.0.0")
        let _ = covSeedPkg(state, "ystyle", "alpha", "1.0.0")
        let _ = covSeedPkg(state, "ystyle", "alpha", "1.2.0")
        let _ = covSeedPkg(state, "ystyle", "alpha", "1.1.0")
        let page = mountPlanCreateCov(state)
        let rows = page.pkgRows.get()
        @Expect(rows.size, 4)
        @Expect(rows[0].name, "alpha")
        @Expect(rows[0].version, "1.0.0")
        @Expect(rows[1].version, "1.1.0")
        @Expect(rows[2].version, "1.2.0")
        @Expect(rows[3].name, "beta")
    }

    // 已选表的行数与计数：选中/移除都走信号
    @TestCase
    public func covPlanCreate_selectedCardCounts(): Unit {
        let state = makePortalState("team")
        let a = covSeedPkg(state, "ystyle", "alpha", "1.0.0")
        let b = covSeedPkg(state, "ystyle", "beta", "1.0.0")
        let page = mountPlanCreateCov(state)
        let (actx, _) = covActx(state)

        @Expect(page.selCount.get(), 0)
        @Expect(covRender(page.render()).contains("尚未选择：从上面的结果里点「添加」（依赖会自动补齐）"), true)

        let _ = page.togglePkg(actx, a.id)
        @Expect(page.selectedPkgs.get().size, 1)
        @Expect(page.selRows.get().size, 1)
        @Expect(page.selRows.get()[0].name, "alpha")
        let json = covRender(page.render())
        @Expect(json.contains("已选择 1 个（依赖会自动补齐）"), true)
        @Expect(json.contains("尚未选择"), false)

        let _ = page.togglePkg(actx, b.id)
        @Expect(page.selCount.get(), 2)

        // 再点一次 → 移除（保留另一个：next 列表构造的 else 分支）
        let _ = page.togglePkg(actx, a.id)
        @Expect(page.selectedPkgs.get().size, 1)
        @Expect(page.selRows.get()[0].name, "beta")
        @Expect(page.isSelected(page.selectedPkgs.get(), a.id), false)
        @Expect(page.isSelected(page.selectedPkgs.get(), b.id), true)

        // 全移除 → 回到空态
        let _ = page.togglePkg(actx, b.id)
        @Expect(page.selCount.get(), 0)
        @Expect(covRender(page.render()).contains("尚未选择"), true)
    }

    // 候选表操作列的按钮文案：未选「添加」/ 已选「移除」
    @TestCase
    public func covPlanCreate_candidateButtonLabel(): Unit {
        let state = makePortalState("team")
        let a = covSeedPkg(state, "ystyle", "alpha", "1.0.0")
        let page = mountPlanCreateCov(state)
        let (actx, _) = covActx(state)
        @Expect(covRender(page.render()).contains("\"text\":\"添加\""), true)
        @Expect(covRender(page.render()).contains("\"text\":\"移除\""), false)

        let _ = page.togglePkg(actx, a.id)
        let json = covRender(page.render())
        @Expect(json.contains("\"text\":\"移除\""), true)
        @Expect(json.contains("\"text\":\"添加\""), false)
    }

    // 候选表分页：10 条/页 + 越界钳制
    @TestCase
    public func covPlanCreate_candidatePagination(): Unit {
        let state = makePortalState("team")
        for (i in 0..12) {
            let _ = covSeedPkg(state, "ystyle", "pkg${i}", "1.0.0")
        }
        let page = mountPlanCreateCov(state)
        @Expect(page.pkgTotal.get(), 12)
        @Expect(page.pkgRows.get().size, 10)
        page.pkgPage.set(2)
        @Expect(page.pkgRows.get().size, 2)
        page.pkgPage.set(99)
        @Expect(page.pkgRows.get().size, 2)     // 本地钳制到最后一页
        page.pkgPageSize.set(0)
        @Expect(page.pkgRows.get().size, 1)
    }

    // 无组织包的包标签：不出现 "::"
    @TestCase
    public func covPlanCreate_pkgLabelWithoutOrg(): Unit {
        let state = makePortalState("team")
        let d = covSeedPkg(state, "", "snappy", "1.0.1")
        let page = mountPlanCreateCov(state)
        @Expect(page.pkgLabel(d), "snappy@1.0.1")
        let json = covRender(page.render())
        @Expect(json.contains("snappy"), true)
        @Expect(json.contains("::snappy"), false)
    }

    // 对照预览：四条提示出口（未选上游 / 成环 / 目标仓索引取不到 / 正常摘要）
    @TestCase
    public func covPlanCreate_previewNotes(): Unit {
        let state = makePortalState("team")
        let a = covSeedPublishable(state, "ystyle", "alpha", "1.0.0")
        let page = mountPlanCreateCov(state)

        // 1) 未选目标上游：只展开依赖链
        let roots = ArrayList<(String, String, String)>()
        roots.add(("ystyle", "alpha", "1.0.0"))
        let (items1, note1) = page.computePreview(state, roots, 0)
        @Expect(items1.size, 1)
        @Expect(note1, "未选择目标上游：只展开了依赖链，选好上游后才能对照目标仓版本")

        // 2) 选了上游但取不到索引 → targetError 原文
        let upId = covSeedUpstream(state, "mirror")
        state.proxySvc = Option<ProxyService>.None   // 没接回源代理 → 探测失败
        let (_, note2) = page.computePreview(state, roots, upId)
        @Expect(note2.contains("目标仓索引取不到"), true)

        // 3) 目标仓返回 404（确实没有该包）→ 只展开 + 摘要
        let (_, note3) = page.computePreview(state, roots, upId)
        @Expect(note3.contains("目标仓索引取不到") || note3.contains("共 1 项"), true)

        // 4) 空 roots：items 为空
        let (items4, _) = page.computePreview(state, ArrayList<(String, String, String)>(), 0)
        @Expect(items4.size, 0)
        @Expect(a.id > 0, true)
    }

    // 对照预览：目标仓已有同版本同制品 → already_exists 计数进摘要
    @TestCase
    public func covPlanCreate_previewCountsAlreadyExists(): Unit {
        let state = makePortalState("team")
        let doc = covSeedPublishable(state, "ystyle", "alpha", "1.0.0")
        let upId = covSeedUpstream(state, "mirror")
        // 目标仓索引里同版本同 sha → already_exists（默认不勾选）
        let entry = PackageIndex()
        entry.organization = "ystyle"
        entry.name = "alpha"
        entry.version = "1.0.0"
        entry.sha256sum = doc.sha256
        let ndjson = generateNDJSON(ArrayList<PackageIndex>([entry]))
        let blob = MemoryBlobStore()
        let ups = UpstreamService(state.upStore)
        let proxy = ProxyService(state.pkgStore, blob, ups)
        proxy.httpFetch = { u, t =>
            if (u.contains("/index/")) { Some(ndjson.toArray()) } else { None }
        }
        state.proxySvc = Some(proxy)

        let page = mountPlanCreateCov(state)
        let roots = ArrayList<(String, String, String)>()
        roots.add(("ystyle", "alpha", "1.0.0"))
        let (items, note) = page.computePreview(state, roots, upId)
        @Expect(items.size, 1)
        @Expect(items[0].category == PlanCategory.AlreadyExists, true)
        @Expect(items[0].selected, false)
        @Expect(note.contains("共 1 项 · 需发布 0"), true)
        @Expect(note.contains("目标仓已有 1"), true)
    }

    // 对照预览：目标仓有同版本但 sha 不同 → conflict 计数进摘要
    @TestCase
    public func covPlanCreate_previewCountsConflict(): Unit {
        let state = makePortalState("team")
        let _ = covSeedPublishable(state, "ystyle", "alpha", "1.0.0")
        let upId = covSeedUpstream(state, "mirror")
        let entry = PackageIndex()
        entry.organization = "ystyle"
        entry.name = "alpha"
        entry.version = "1.0.0"
        entry.sha256sum = "totally-different-sha"
        let ndjson = generateNDJSON(ArrayList<PackageIndex>([entry]))
        let proxy = ProxyService(state.pkgStore, MemoryBlobStore(), UpstreamService(state.upStore))
        proxy.httpFetch = { u, t =>
            if (u.contains("/index/")) { Some(ndjson.toArray()) } else { None }
        }
        state.proxySvc = Some(proxy)

        let page = mountPlanCreateCov(state)
        let roots = ArrayList<(String, String, String)>()
        roots.add(("ystyle", "alpha", "1.0.0"))
        let (items, note) = page.computePreview(state, roots, upId)
        @Expect(items[0].category == PlanCategory.Conflict, true)
        @Expect(note.contains("冲突 1"), true)
    }

    // 刷新预览：selected 为空时清空预览并复位 busy（不发起网络）
    @TestCase
    public func covPlanCreate_refreshPreviewWithNoSelection(): Unit {
        let state = makePortalState("team")
        let page = mountPlanCreateCov(state)
        let (actx, _) = covActx(state)
        page.previewRows.set(ArrayList<PlanItem>())
        page.previewBusy.set(true)
        page.previewNote.set("旧提示")
        let _ = page.refreshPreview(actx)
        @Expect(page.previewRows.get().size, 0)
        @Expect(page.previewNote.get(), "")
        @Expect(page.previewBusy.get(), false)
    }

    // 目标上游变更触发重跑对照（onTargetChanged 的入口）
    @TestCase
    public func covPlanCreate_targetChangedTriggersPreview(): Unit {
        let state = makePortalState("team")
        let _ = covSeedPublishable(state, "ystyle", "alpha", "1.0.0")
        let upId = covSeedUpstream(state, "mirror")
        let page = mountPlanCreateCov(state)
        let (actx, _) = covActx(state)
        let one = ArrayList<Int64>()
        one.add(state.pkgStore.storm.all<PackageDoc>()[0].id)
        page.selectedPkgs.set(one)
        page.targetUpstream.set(upId.toString())
        let _ = page.onTargetChanged(actx)
        @Expect(page.previewNote.get(), "正在对比目标仓索引…")
        @Expect(page.previewBusy.get(), true)
    }

    // 预览断言的 infoSlot 三态：note 优先 / busy 次之 / 都没有时给空态
    @TestCase
    public func covPlanCreate_previewInfoSlots(): Unit {
        let state = makePortalState("team")
        let _ = covSeedPkg(state, "ystyle", "alpha", "1.0.0")
        let page = mountPlanCreateCov(state)
        // 无 note 无 busy 无行 → 空态提示
        @Expect(covRender(page.render()).contains("选择包以后，这里会列出每一包的本地版本与目标仓版本"), true)

        // busy → 「对照中…」
        page.previewBusy.set(true)
        @Expect(covRender(page.render()).contains("对照中…（正在取目标仓索引）"), true)
        @Expect(covRender(page.render()).contains("选择包以后"), false)

        // note 优先于 busy
        page.previewNote.set("共 3 项 · 需发布 2")
        let json = covRender(page.render())
        @Expect(json.contains("共 3 项 · 需发布 2"), true)
        @Expect(json.contains("对照中…"), false)
    }

    // 提交：未选包 → 明确提示
    @TestCase
    public func covPlanCreate_submitWithoutSelection(): Unit {
        let state = makePortalState("team")
        let upId = covSeedUpstream(state, "mirror")
        let _ = covSeedPublishable(state, "ystyle", "alpha", "1.0.0")
        let page = mountPlanCreateCov(state)
        let _ = covRender(page.render())   // 建出 planForm
        let (actx, _) = covActx(state)
        page.planName.set("新计划")
        page.targetUpstream.set(upId.toString())
        let _ = page.submitCreate(actx)
        @Expect(page.msg.get(), "请至少选择一个包")
        @Expect(state.adminData.listPlans().size, 0)
    }

    // 提交：必填校验（计划名/目标上游）
    @TestCase
    public func covPlanCreate_submitValidation(): Unit {
        let state = makePortalState("team")
        let _ = covSeedPublishable(state, "ystyle", "alpha", "1.0.0")
        let page = mountPlanCreateCov(state)
        let _ = covRender(page.render())
        let (actx, _) = covActx(state)

        page.planName.set("")
        let _ = page.submitCreate(actx)
        @Expect(page.nameError.get(), "计划名必填")
        @Expect(state.adminData.listPlans().size, 0)

        page.planName.set("ok-name")
        page.targetUpstream.set("")
        let _ = page.submitCreate(actx)
        @Expect(page.upstreamError.get(), "请选择目标上游")
        @Expect(state.adminData.listPlans().size, 0)
        @Expect(covRender(page.render()).contains("请选择目标上游"), true)
    }

    // 提交成功：建计划 + 写入条目（分类/对照/勾选）+ 分母按 countRequired + 跳详情
    @TestCase
    public func covPlanCreate_submitCreatesPlan(): Unit {
        let state = makePortalState("team")
        let doc = covSeedPublishable(state, "ystyle", "alpha", "1.0.0")
        let upId = covSeedUpstream(state, "mirror")
        // 目标仓已有同版本同 sha → 该条 already_exists（不勾选、不进分母）
        let entry = PackageIndex()
        entry.organization = "ystyle"
        entry.name = "alpha"
        entry.version = "1.0.0"
        entry.sha256sum = doc.sha256
        let ndjson = generateNDJSON(ArrayList<PackageIndex>([entry]))
        let proxy = ProxyService(state.pkgStore, MemoryBlobStore(), UpstreamService(state.upStore))
        proxy.httpFetch = { u, t =>
            if (u.contains("/index/")) { Some(ndjson.toArray()) } else { None }
        }
        state.proxySvc = Some(proxy)

        let page = mountPlanCreateCov(state)
        let _ = covRender(page.render())
        let (actx, nav) = covActx(state)
        page.planName.set("建计划成功")
        page.targetUpstream.set(upId.toString())
        page.pollTimeout.set(0)
        let picked = ArrayList<Int64>()
        picked.add(doc.id)
        page.selectedPkgs.set(picked)
        let _ = page.submitCreate(actx)

        @Expect(state.adminData.listPlans().size, 1)
        let plan = state.adminData.listPlans()[0]
        @Expect(plan.name, "建计划成功")
        @Expect(plan.targetUpstream, upId)
        @Expect(plan.pollTimeout, 0)
        @Expect(plan.pollInterval, 60)          // 旧字段随计划落库保留
        let items = state.adminData.listPlanItems(plan.id)
        @Expect(items.size, 1)
        @Expect(items[0].packageName, "alpha")
        @Expect(items[0].category, "already_exists")
        @Expect(items[0].selected, false)
        @Expect(items[0].targetCompared, true)
        @Expect(items[0].targetVersion, "1.0.0")
        @Expect(plan.totalCount, 0)              // countRequired 不含 already_exists
        @Expect(nav[nav.size - 1], "/admin/publish-plans/${plan.id}")
        let (_, total) = state.adminData.queryLogs(Some("admin"), "create plan", "", 0, 0, 0, 10)
        @Expect(total, 1)
    }

    // 提交：目标仓索引取不到 → targetError 落到计划上（不是静默）
    @TestCase
    public func covPlanCreate_submitRecordsTargetError(): Unit {
        let state = makePortalState("team")
        let doc = covSeedPublishable(state, "ystyle", "alpha", "1.0.0")
        let upId = covSeedUpstream(state, "mirror")
        // 不接回源代理 → 探测全失败 → targetError 非空
        let page = mountPlanCreateCov(state)
        let _ = covRender(page.render())
        let (actx, _) = covActx(state)
        page.planName.set("对照失败的计划")
        page.targetUpstream.set(upId.toString())
        let picked = ArrayList<Int64>()
        picked.add(doc.id)
        page.selectedPkgs.set(picked)
        let _ = page.submitCreate(actx)

        let plan = state.adminData.listPlans()[0]
        @Expect(plan.lastError.contains("目标仓索引取不到"), true)
        let items = state.adminData.listPlanItems(plan.id)
        @Expect(items[0].targetCompared, false)
        @Expect(items[0].category, "need_publish")
    }

    // 提交：非管理员被拒
    @TestCase
    public func covPlanCreate_submitRequiresAdmin(): Unit {
        let state = makePortalState("team")
        let doc = covSeedPublishable(state, "ystyle", "alpha", "1.0.0")
        let upId = covSeedUpstream(state, "mirror")
        let page = mountPlanCreateCov(state)
        let _ = covRender(page.render())
        let (plain, _) = covActx(state, dbIsAdmin: false, ctxIsAdmin: true, username: "covplain")
        page.planName.set("nope")
        page.targetUpstream.set(upId.toString())
        let picked = ArrayList<Int64>()
        picked.add(doc.id)
        page.selectedPkgs.set(picked)
        let _ = page.submitCreate(plain)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(state.adminData.listPlans().size, 0)
    }

    // 返回列表：跳转
    @TestCase
    public func covPlanCreate_backToList(): Unit {
        let state = makePortalState("team")
        let page = mountPlanCreateCov(state)
        let (actx, nav) = covActx(state)
        let _ = page.backToList(actx)
        @Expect(nav[0], "/admin/publish-plans")
    }

    // 目标上游下拉：选项文案是 `名字（URL）`。
    // Select **收起时只渲染当前选中项的标签**（面板展开才有全部选项），所以这里先把
    // 信号置成该上游的 id，再断言选中的标签文案 —— 顺带守住 findLabel 走的是同一条拼接。
    @TestCase
    public func covPlanCreate_upstreamOptionLabel(): Unit {
        let state = makePortalState("team")
        let upId = covSeedUpstream(state, "mirror-z", url: "https://z.test/registry")
        let page = mountPlanCreateCov(state)
        @Expect(covRender(page.render()).contains("选择上游"), true)   // 未选 → placeholder
        page.targetUpstream.set(upId.toString())
        @Expect(covRender(page.render()).contains("mirror-z（https://z.test/registry）"), true)
        @Expect(covRender(page.render()).contains("选择上游"), false)
    }

    // 未挂载 state：render 给加载中，各入口走 None 分支
    @TestCase
    public func covPlanCreate_withoutState(): Unit {
        let state = makePortalState("team")
        let page = PublishPlanCreatePage()
        @Expect(covRender(page.render()).contains("加载中..."), true)
        @Expect(page.candidatePkgs().size, 0)
        let (l, m) = page.sourceCounts()
        @Expect(l, 0)
        @Expect(m, 0)
        @Expect(page.selectedDocs().size, 0)
        let (actx, nav) = covActx(state)
        let _ = page.submitCreate(actx)
        @Expect(page.msg.get(), "")
        page.refreshPreview(actx)   // state 为 None → 直接 return
        let _ = page.onTargetChanged(actx)
        let _ = page.backToList(actx)
        @Expect(nav[0], "/admin/publish-plans")
    }

    // onUnmount：两个 binding 都释放；之后再改搜索不再重算
    @TestCase
    public func covPlanCreate_unmountAndRemount(): Unit {
        let state = makePortalState("team")
        let _ = covSeedPkg(state, "ystyle", "alpha", "1.0.0")
        let _ = covSeedPkg(state, "ystyle", "beta", "1.0.0")
        let page = mountPlanCreateCov(state)
        @Expect(page.pkgRows.get().size, 2)

        page.onUnmount(mountCtx(state, userCtxMap(1, "admin", true)))
        page.pkgSearch.set("alpha")
        @Expect(page.pkgRows.get().size, 2)      // 已 dispose，不再重算

        // 重新挂载：binding 重建（Some 分支先 dispose 旧的）
        page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
        @Expect(page.pkgRows.get().size, 1)      // 关键字仍是 alpha
        page.pkgSearch.set("")
        @Expect(page.pkgRows.get().size, 2)
    }
}

@Test
public class CovPlanDetailRenderTest {
    // 未挂载 state：render 给「加载中...」
    @TestCase
    public func covPlanDetail_withoutState(): Unit {
        let page = PublishPlanDetailPage()
        @Expect(covRender(page.render()).contains("加载中..."), true)
    }

    // 计划不存在：空态 + 返回按钮
    @TestCase
    public func covPlanDetail_missingPlan(): Unit {
        let state = makePortalState("team")
        let page = mountPlanDetailCov(state, 999999)
        let json = covRender(page.render())
        @Expect(json.contains("计划不存在或已删除"), true)
        @Expect(json.contains("返回列表"), true)
        @Expect(json.contains("重新分析"), false)
    }

    // 计划信息卡：名称/状态/目标上游/进度/发布项明细/索引等待/执行 + 计划级原因
    @TestCase
    public func covPlanDetail_infoCard(): Unit {
        let state = makePortalState("team")
        let upId = covSeedUpstream(state, "mirror-info")
        let pid = covSeedPlan(state, "info-plan", status: "paused", targetUpstream: upId,
            pollTimeout: 0, lastError: "429 已暂停")
        let _ = covSeedPlanItem(state, pid, "alpha", 1)
        let _ = covSeedPlanItem(state, pid, "beta", 2, category: "already_exists")
        let _ = covSeedPlanItem(state, pid, "gamma", 3, category: "conflict")
        let _ = state.adminData.setPlanTotal(pid, 2)
        let _ = state.adminData.updatePlanStatus(pid, "paused", 1, 1000)

        let page = mountPlanDetailCov(state, pid)
        let json = covRender(page.render())
        @Expect(json.contains("info-plan"), true)
        @Expect(json.contains("mirror-info"), true)
        @Expect(json.contains("已暂停"), true)
        @Expect(json.contains("1/2"), true)
        // 明细口径：already_exists / conflict 各自单列，其余算「需发布」
        @Expect(json.contains("共 3 项 · 需发布 1"), true)
        @Expect(json.contains("目标仓已有 1"), true)
        @Expect(json.contains("冲突 1"), true)
        // pollTimeout=0 → 「一直等（…探测一次）」
        @Expect(json.contains("一直等（${indexWaitRhythmText()} 探测一次）"), true)
        // lastError 渲染成 Warning Tag
        @Expect(json.contains("429 已暂停"), true)
        @Expect(json.contains("el-tag--warning"), true)
    }

    // 索引等待文案：0 与正数两档
    @TestCase
    public func covPlanDetail_waitPolicyText(): Unit {
        let state = makePortalState("team")
        let pid = covSeedPlan(state, "wait")
        let page = mountPlanDetailCov(state, pid)
        @Expect(page.waitPolicyText(0), "一直等（${indexWaitRhythmText()} 探测一次）")
        @Expect(page.waitPolicyText(-1), "一直等（${indexWaitRhythmText()} 探测一次）")
        @Expect(page.waitPolicyText(600), "最长 600s（${indexWaitRhythmText()}）")
    }

    // 明细文案：老计划（一条都没对照）要明说怎么补齐
    @TestCase
    public func covPlanDetail_itemBreakdownUncompared(): Unit {
        let state = makePortalState("team")
        let pid = covSeedPlan(state, "old-plan")
        let _ = covSeedPlanItem(state, pid, "alpha", 1)              // targetCompared=false
        let page = mountPlanDetailCov(state, pid)
        @Expect(page.itemBreakdown(), "共 1 项 · 需发布 1 · 目标仓未对照（点「重新分析」补齐）")

        // 有对照数据的项 → 不再提示未对照
        let pid2 = covSeedPlan(state, "new-plan")
        let _ = covSeedPlanItem(state, pid2, "beta", 1, targetCompared: true, targetVersion: "9.9.9")
        let page2 = mountPlanDetailCov(state, pid2)
        @Expect(page2.itemBreakdown().contains("目标仓未对照"), false)
        @Expect(page2.itemBreakdown(), "共 1 项 · 需发布 1")

        // 空计划：0 项、也不提未对照
        let pid3 = covSeedPlan(state, "empty-plan")
        let page3 = mountPlanDetailCov(state, pid3)
        @Expect(page3.itemBreakdown(), "共 0 项 · 需发布 0")
    }

    // 发布项表：状态 Tag 六档 + 分类列 + 目标仓三态 + 说明列（有 error 优先）
    @TestCase
    public func covPlanDetail_itemTagsAndColumns(): Unit {
        let state = makePortalState("team")
        let pid = covSeedPlan(state, "tags-plan")
        let page = mountPlanDetailCov(state, pid)
        for ((s, label) in [("completed", "成功"), ("failed", "失败"), ("running", "推送中"),
                            ("waiting_index", "等待索引"), ("skipped", "未推送"), ("pending", "未推送")]) {
            @Expect(covRender(page.itemStatusTag(s)).contains(label), true)
        }

        let _ = covSeedPlanItem(state, pid, "done", 1, status: "completed", targetCompared: true, targetVersion: "1.0.0")
        let _ = covSeedPlanItem(state, pid, "failed-item", 2, status: "failed", error: "目标仓 500")
        let _ = covSeedPlanItem(state, pid, "no-compare", 3)
        let _ = covSeedPlanItem(state, pid, "no-remote-pkg", 4, targetCompared: true)
        page.refreshItems()
        let json = covRender(page.render())
        @Expect(json.contains("完成") || json.contains("成功"), true)
        @Expect(json.contains("目标仓 500"), true)          // 说明列优先显示 error
        @Expect(json.contains("未对照"), true)
        @Expect(json.contains("无此包"), true)               // 对照了但目标仓没有
        @Expect(json.contains("1.0.0"), true)
    }

    // 「不可覆盖」只读态：官方目标仓 + already_exists/conflict → 给提示 Tag 而不是勾选按钮
    @TestCase
    public func covPlanDetail_blockedItemsShowReason(): Unit {
        let state = makePortalState("team")
        let upId = covSeedUpstream(state, "official-up",
            url: "https://pkg.cangjie-lang.cn/registry", isOfficial: true)
        let pid = covSeedPlan(state, "official-plan", targetUpstream: upId)
        let _ = covSeedPlanItem(state, pid, "exists", 1, category: "already_exists", selected: false,
            targetCompared: true, targetVersion: "1.0.0")
        let _ = covSeedPlanItem(state, pid, "conflict", 2, category: "conflict", selected: false,
            targetCompared: true, targetVersion: "1.0.1")
        let _ = covSeedPlanItem(state, pid, "need", 3)
        let page = mountPlanDetailCov(state, pid)
        @Expect(page.targetOverwriteAllowed(), false)
        let json = covRender(page.render())
        @Expect(json.contains("不可覆盖"), true)
        @Expect(json.contains("需升版"), true)
        // 需要发布的那一项仍可勾选/取消勾选
        @Expect(json.contains("取消勾选"), true)
    }

    // 自建仓（可覆盖）：三条都走勾选按钮
    @TestCase
    public func covPlanDetail_overwritableItemsHaveToggle(): Unit {
        let state = makePortalState("team")
        let upId = covSeedUpstream(state, "self-up")
        let pid = covSeedPlan(state, "self-plan", targetUpstream: upId)
        let _ = covSeedPlanItem(state, pid, "exists", 1, category: "already_exists", selected: false,
            targetCompared: true, targetVersion: "1.0.0")
        let page = mountPlanDetailCov(state, pid)
        @Expect(page.targetOverwriteAllowed(), true)
        let json = covRender(page.render())
        @Expect(json.contains("勾选"), true)
        @Expect(json.contains("不可覆盖"), false)
        // 说明列给出「可勾选强制重传」的说法（already_exists 且允许覆盖那一档）
        @Expect(json.contains("要重传就勾选强制覆盖"), true)
    }

    // 勾选 toggle：两次调用来回切，分母按分类重算（already_exists 不进分母）
    @TestCase
    public func covPlanDetail_toggleItem(): Unit {
        let state = makePortalState("team")
        let upId = covSeedUpstream(state, "self-up2")
        let pid = covSeedPlan(state, "toggle-plan", targetUpstream: upId)
        let a = covSeedPlanItem(state, pid, "alpha", 1, selected: true)
        let _ = covSeedPlanItem(state, pid, "exists", 2, category: "already_exists", selected: false)
        // 先由 toggleItem 自己算一次分母（只有 alpha 是 need_publish）
        let page = mountPlanDetailCov(state, pid)
        let (actx, _) = covActx(state)
        let _ = page.toggleItem(actx, a, true)     // 取消勾选（顺带 syncPlanTotal）
        @Expect(state.adminData.getPlanItem(a).getOrThrow().selected, false)
        @Expect(state.adminData.getPlan(pid).getOrThrow().totalCount, 1)   // 分母按分类算，不随勾选变

        let _ = page.toggleItem(actx, a, false)    // 重新勾上
        @Expect(state.adminData.getPlanItem(a).getOrThrow().selected, true)
        @Expect(state.adminData.getPlan(pid).getOrThrow().totalCount, 1)
        @Expect(page.items.get().size, 2)
    }

    // 勾选：非管理员被拒
    @TestCase
    public func covPlanDetail_toggleItemRequiresAdmin(): Unit {
        let state = makePortalState("team")
        let pid = covSeedPlan(state, "perm-plan")
        let a = covSeedPlanItem(state, pid, "alpha", 1)
        let page = mountPlanDetailCov(state, pid)
        let (plain, _) = covActx(state, dbIsAdmin: false, ctxIsAdmin: true, username: "covplain")
        let _ = page.toggleItem(plain, a, true)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(state.adminData.getPlanItem(a).getOrThrow().selected, true)
    }

    // 重新分析按钮：analyzing 时换文案 + loading 且禁用
    @TestCase
    public func covPlanDetail_reanalyzeButtonStates(): Unit {
        let state = makePortalState("team")
        let pid = covSeedPlan(state, "btn-plan")
        let page = mountPlanDetailCov(state, pid)
        @Expect(covRender(page.reanalyzeButton()).contains("重新分析"), true)
        @Expect(covRender(page.reanalyzeButton()).contains("is-loading"), false)

        page.analyzing.set(true)
        let json = covRender(page.reanalyzeButton())
        @Expect(json.contains("分析中…"), true)
        @Expect(json.contains("is-loading"), true)
    }

    // 重新分析：非管理员 / 计划不存在 / 目标上游不存在 三条早退。
    //
    // 收尾提示（page.msg）只在 finishAnalyze 的 **pushUpdate 回调**里写，而没有真实 WS 会话时
    // pushUpdate 直接返回 false（cjxt 的守卫）→ 回调不执行。所以这里断言的是收尾的**可观测副作用**：
    // analyzing 被复位、planAnalyzeSince 归零（这两条正是"卡死自愈"依赖的状态）。
    @TestCase
    public func covPlanDetail_reanalyzeEarlyExits(): Unit {
        let state = makePortalState("team")
        let pid = covSeedPlan(state, "ra-plan")     // targetUpstream = 0 → 不存在
        let page = mountPlanDetailCov(state, pid)

        let (plain, _) = covActx(state, dbIsAdmin: false, ctxIsAdmin: true, username: "covplain")
        let _ = page.reanalyze(plain)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(page.analyzing.get(), false)

        // 目标上游不存在：analyzing 先置真，收尾再复位
        let (actx, _) = covActx(state)
        page.analyzing.set(false)
        page.reanalyzeAsync(state, "sid-test")
        @Expect(page.analyzing.get(), false)
        @Expect(state.planAnalyzeSince.get(), 0)

        // 计划不存在：同样只走收尾复位（不落库）
        page.planId = 999999
        page.analyzing.set(true)
        page.reanalyzeAsync(state, "sid-test")
        @Expect(page.analyzing.get(), false)
        @Expect(state.planAnalyzeSince.get(), 0)
    }

    // 重新分析正常路径：分类写回 + 分母重算（syncPlanTotal）
    @TestCase
    public func covPlanDetail_reanalyzeUpdatesPlan(): Unit {
        let state = makePortalState("team")
        let doc = covSeedPublishable(state, "ystyle", "alpha", "1.0.0")
        let upId = covSeedUpstream(state, "ra-ok-up")
        let pid = covSeedPlan(state, "ra-ok", targetUpstream: upId)
        // 先放一条 already_exists 的旧条目：重新分析应把它刷成 need_publish
        let _ = covSeedPlanItem(state, pid, "alpha", 1, category: "already_exists", selected: false,
            targetCompared: true, targetVersion: "1.0.0")
        let _ = state.adminData.setPlanTotal(pid, 0)

        // 目标仓索引空 → 全部 need_publish
        let proxy = ProxyService(state.pkgStore, MemoryBlobStore(), UpstreamService(state.upStore))
        proxy.httpFetch = { u, t =>
            if (u.contains("/index/")) { Some("".toArray()) } else { None }
        }
        state.proxySvc = Some(proxy)

        let page = mountPlanDetailCov(state, pid)
        page.analyzing.set(true)
        state.planAnalyzeSince.set(12345)
        page.reanalyzeAsync(state, "sid-test")

        @Expect(page.analyzing.get(), false)
        @Expect(state.planAnalyzeSince.get(), 0)
        let items = state.adminData.listPlanItems(pid)
        @Expect(items[0].category, "need_publish")
        @Expect(state.adminData.getPlan(pid).getOrThrow().totalCount, 1)
        @Expect(doc.id > 0, true)
    }

    // 重新分析：目标仓索引取不到 → targetError 落到计划上
    @TestCase
    public func covPlanDetail_reanalyzeRecordsTargetError(): Unit {
        let state = makePortalState("team")
        let _ = covSeedPublishable(state, "ystyle", "alpha", "1.0.0")
        let upId = covSeedUpstream(state, "ra-err-up")
        let pid = covSeedPlan(state, "ra-err", targetUpstream: upId)
        let _ = covSeedPlanItem(state, pid, "alpha", 1)
        // 不接回源代理 → 探测全失败
        let page = mountPlanDetailCov(state, pid)
        page.reanalyzeAsync(state, "sid-test")
        @Expect(state.adminData.getPlan(pid).getOrThrow().lastError.contains("目标仓索引取不到"), true)
        @Expect(page.analyzing.get(), false)
    }

    // 检查索引：非管理员 / 正在分析中 / 没有等索引项 / 计划不存在 / 目标上游不存在。
    // 同 reanalyze：收尾文案要 pushUpdate 才写，这里断言状态复位与库内不动。
    @TestCase
    public func covPlanDetail_checkIndexEarlyExits(): Unit {
        let state = makePortalState("team")
        let pid = covSeedPlan(state, "ci-plan")
        let _ = covSeedPlanItem(state, pid, "alpha", 1)
        let page = mountPlanDetailCov(state, pid)

        let (plain, _) = covActx(state, dbIsAdmin: false, ctxIsAdmin: true, username: "covplain")
        let _ = page.checkIndex(plain)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(page.analyzing.get(), false)

        // analyzing 已为真：直接返回（不清标志、不置 planAnalyzeSince）
        page.analyzing.set(true)
        state.planAnalyzeSince.set(777)
        let (actx, _) = covActx(state)
        let _ = page.checkIndex(actx)
        @Expect(page.analyzing.get(), true)
        @Expect(state.planAnalyzeSince.get(), 777)

        // 没有等索引的项
        page.analyzing.set(false)
        page.checkIndexAsync(state, "sid-test")
        @Expect(page.analyzing.get(), false)

        // 计划不存在
        page.planId = 999999
        page.checkIndexAsync(state, "sid-test")
        @Expect(page.analyzing.get(), false)

        // 目标上游不存在（targetUpstream = 0）
        page.planId = pid
        page.checkIndexAsync(state, "sid-test")
        @Expect(page.analyzing.get(), false)
        @Expect(state.adminData.listPlanItems(pid)[0].status, "pending")
    }

    // 检查索引：命中 → 条目标 completed，计划收口 completed，索引时间落库
    @TestCase
    public func covPlanDetail_checkIndexMarksReady(): Unit {
        let state = makePortalState("team")
        let doc = covSeedPublishable(state, "ystyle", "alpha", "1.0.0")
        let upId = covSeedUpstream(state, "ci-up")
        let pid = covSeedPlan(state, "ci-ok", targetUpstream: upId)
        let _ = covSeedPlanItem(state, pid, "alpha", 1, status: "waiting_index",
            targetCompared: true, targetVersion: "1.0.0")
        let entry = PackageIndex()
        entry.organization = "ystyle"
        entry.name = "alpha"
        entry.version = "1.0.0"
        entry.sha256sum = doc.sha256
        let ndjson = generateNDJSON(ArrayList<PackageIndex>([entry]))
        let proxy = ProxyService(state.pkgStore, MemoryBlobStore(), UpstreamService(state.upStore))
        proxy.httpFetch = { u, t =>
            if (u.contains("/index/")) { Some(ndjson.toArray()) } else { None }
        }
        state.proxySvc = Some(proxy)

        let page = mountPlanDetailCov(state, pid)
        page.checkIndexAsync(state, "sid-test")
        @Expect(state.adminData.getPlan(pid).getOrThrow().status, "completed")
        @Expect(state.adminData.getPlan(pid).getOrThrow().lastError, "全部项已完成")
        let item = state.adminData.listPlanItems(pid)[0]
        @Expect(item.status, "completed")
        @Expect(item.error.contains("索引已就绪"), true)
        @Expect(item.indexAt > 0, true)          // 「索引」时刻落库（消费者从此解析得到）
        @Expect(page.analyzing.get(), false)
        let (_, total) = state.adminData.queryLogs(Some("publish"), "检查索引", "", 0, 0, 0, 10)
        @Expect(total, 1)
    }

    // 检查索引：未命中（目标仓还没有）→ 计划收口 paused，条目仍是 waiting_index
    @TestCase
    public func covPlanDetail_checkIndexNotReadyYet(): Unit {
        let state = makePortalState("team")
        let _ = covSeedPublishable(state, "ystyle", "alpha", "1.0.0")
        let upId = covSeedUpstream(state, "ci-up2")
        let pid = covSeedPlan(state, "ci-wait", targetUpstream: upId)
        let _ = covSeedPlanItem(state, pid, "alpha", 1, status: "waiting_index")
        let proxy = ProxyService(state.pkgStore, MemoryBlobStore(), UpstreamService(state.upStore))
        proxy.httpFetch = { u, t =>
            if (u.contains("/index/")) { Some("".toArray()) } else { None }
        }
        state.proxySvc = Some(proxy)

        let page = mountPlanDetailCov(state, pid)
        page.checkIndexAsync(state, "sid-test")
        @Expect(state.adminData.getPlan(pid).getOrThrow().status, "paused")
        @Expect(state.adminData.listPlanItems(pid)[0].status, "waiting_index")
    }

    // 检查索引：探测本身失败（未接回源代理）→ 计划仍是 paused（不是 completed）
    @TestCase
    public func covPlanDetail_checkIndexProbeFailure(): Unit {
        let state = makePortalState("team")
        let upId = covSeedUpstream(state, "ci-up3")
        let pid = covSeedPlan(state, "ci-fail", targetUpstream: upId)
        let _ = covSeedPlanItem(state, pid, "alpha", 1, status: "waiting_index")
        // proxySvc 未注入 → IndexProbe(0, "") → unreachable++
        let page = mountPlanDetailCov(state, pid)
        page.checkIndexAsync(state, "sid-test")
        @Expect(state.adminData.getPlan(pid).getOrThrow().status, "paused")
        @Expect(page.analyzing.get(), false)
    }

    // 执行：四条早退（非管理员 / 已在执行 / 计划不存在 / 目标上游不存在）
    @TestCase
    public func covPlanDetail_doStartEarlyExits(): Unit {
        let state = makePortalState("team")
        let pid = covSeedPlan(state, "start-plan")     // targetUpstream = 0
        let _ = covSeedPlanItem(state, pid, "alpha", 1)
        let page = mountPlanDetailCov(state, pid)

        let (plain, _) = covActx(state, dbIsAdmin: false, ctxIsAdmin: true, username: "covplain")
        let _ = page.doStart(plain)
        @Expect(page.msg.get(), "无权限：需要管理员登录")

        let (actx, _) = covActx(state)
        addPlanId(state, pid, false)
        let _ = page.doStart(actx)
        @Expect(page.msg.get(), "该计划正在执行中")
        removePlanId(state, pid, false)

        // 目标上游不存在
        let _ = page.doStart(actx)
        @Expect(page.msg.get(), "目标上游不存在")

        // 计划不存在
        page.planId = 999999
        let _ = page.doStart(actx)
        @Expect(page.msg.get(), "计划不存在")
    }

    // 执行：没有可执行的发布项（全都没勾选）
    @TestCase
    public func covPlanDetail_doStartNoExecutableItems(): Unit {
        let state = makePortalState("team")
        let upId = covSeedUpstream(state, "start-up")
        let pid = covSeedPlan(state, "start-empty", targetUpstream: upId)
        let _ = covSeedPlanItem(state, pid, "alpha", 1, selected: false)
        let page = mountPlanDetailCov(state, pid)
        let (actx, _) = covActx(state)
        let _ = page.doStart(actx)
        @Expect(page.msg.get(), "没有可执行的发布项")
        @Expect(containsId(state.planRunIds.get(), pid), false)
    }

    // 执行：所有项都已完成
    @TestCase
    public func covPlanDetail_doStartAllCompleted(): Unit {
        let state = makePortalState("team")
        let upId = covSeedUpstream(state, "start-up2")
        let pid = covSeedPlan(state, "start-done", targetUpstream: upId)
        let _ = covSeedPlanItem(state, pid, "alpha", 1, status: "completed")
        let page = mountPlanDetailCov(state, pid)
        let (actx, _) = covActx(state)
        let _ = page.doStart(actx)
        @Expect(page.msg.get(), "所有项都已完成，无需重复推送")
        @Expect(containsId(state.planRunIds.get(), pid), false)
    }

    // 执行：真的起线程（无 App → runExecutionInner 走 app 为 None 的收尾分支）
    @TestCase
    public func covPlanDetail_doStartWithoutApp(): Unit {
        let state = makePortalState("team")
        let doc = covSeedPublishable(state, "ystyle", "alpha", "1.0.0")
        let upId = covSeedUpstream(state, "start-up3")
        let pid = covSeedPlan(state, "start-run", targetUpstream: upId)
        let _ = covSeedPlanItem(state, pid, "alpha", 1)
        let page = mountPlanDetailCov(state, pid)
        let (actx, _) = covActx(state)
        let _ = page.doStart(actx)

        // 立即状态：已登记执行、计划置 running、进度复位、启动审计
        @Expect(state.adminData.getPlan(pid).getOrThrow().status, "running")
        @Expect(state.planStatus.get(), "running")
        @Expect(state.planProgress.get().startsWith("0/"), true)
        let (_, total) = state.adminData.queryLogs(Some("publish"), "start plan", "", 0, 0, 0, 10)
        @Expect(total, 1)

        // 等异步线程收口（无 App → 直接返回并解登记）
        var waited = 0
        while (containsId(state.planRunIds.get(), pid) && waited < 300) {
            sleep(10 * Duration.millisecond)
            waited++
        }
        @Expect(containsId(state.planRunIds.get(), pid), false)
        @Expect(state.planBusy.get(), false)
        @Expect(doc.sha256.isEmpty(), false)
    }

    // 执行：直接跑执行线程（有 App 为 None 与无制品库两条内部错误出口）
    @TestCase
    public func covPlanDetail_runExecutionInnerWithoutExecutor(): Unit {
        let state = makePortalState("team")   // blobStore 未注入
        let upId = covSeedUpstream(state, "exec-up")
        let pid = covSeedPlan(state, "exec-plan", targetUpstream: upId)
        let page = mountPlanDetailCov(state, pid)
        let items = ArrayList<PlanItem>()
        items.add(PlanItem(1, "alpha", "ystyle", "1.0.0", PlanCategory.NeedPublish, 1))
        let docIds = HashMap<Int64, Int64>()
        let up = state.upStore.getById(upId).getOrThrow()
        page.runExecution(state, "sid-test", items, docIds, up, 0)
        // 无 App → 第一条内部错误出口：只解登记、清 busy
        @Expect(containsId(state.planRunIds.get(), pid), false)
        @Expect(state.planBusy.get(), false)

        // 有 App 但无制品库：走「制品库未注入」出口（App 用真实 App 也能构造）
        let app = App()
        state.app = Some(app)
        addPlanId(state, pid, false)
        page.runExecution(state, "sid-test", items, docIds, up, 0)
        @Expect(page.msg.get(), "内部错误：制品库未注入，无法执行发布计划")
        @Expect(containsId(state.planRunIds.get(), pid), false)
        @Expect(state.planBusy.get(), false)
    }

    // 执行线程真的跑起来（有制品库、目标不可达）：走 execute 的失败收口与 summary 分支。
    //
    // 用 `http://127.0.0.1:1` 当目标（必然连不上）→ 执行器内部重试后判该项失败 →
    // runExecutionInner 的 catch/summary/落盘/解登记整条收口链路都被走到。
    @TestCase
    public func covPlanDetail_runExecutionRealFailurePath(): Unit {
        let state = makePortalState("team")
        // runExecutionInner 的第一道判据就是 st.app：没有 App 会直接早退（不写计划状态）。
        // 这里注入一个真实 App：它没有对应 WS 会话，pushUpdate 返回 false 但不抛 —— 正好只
        // 走「落库 + 收口」，把 UI 推送那层隔离开，断言才聚焦在状态机上。
        state.app = Some(App())
        let blob = MemoryBlobStore()
        state.blobStore = Some(blob)
        let doc = covSeedPublishable(state, "ystyle", "alpha", "1.0.0")
        blob.put(doc.sha256, [UInt8(1), UInt8(2)])
        // 目标上游指向一个必然连不上的地址（本项目不依赖外网）
        let upId = covSeedUpstream(state, "dead-up", url: "http://127.0.0.1:1")
        let pid = covSeedPlan(state, "real-exec", targetUpstream: upId)
        let itemId = covSeedPlanItem(state, pid, "alpha", 1)
        let page = mountPlanDetailCov(state, pid)

        let items = ArrayList<PlanItem>()
        let it = PlanItem(doc.id, "alpha", "ystyle", "1.0.0", PlanCategory.NeedPublish, 1)
        items.add(it)
        let docIds = HashMap<Int64, Int64>()
        docIds[doc.id] = itemId
        let up = state.upStore.getById(upId).getOrThrow()
        addPlanId(state, pid, false)
        page.runExecution(state, "sid-test", items, docIds, up, 0)

        // 收口：解登记 + 清 busy（runExecution 的 finally）
        @Expect(containsId(state.planRunIds.get(), pid), false)
        @Expect(containsId(state.planCancelIds.get(), pid), false)
        @Expect(state.planBusy.get(), false)
        // 计划落 failed 并写了失败原因；条目状态与错误也落库了（先落盘再推界面）
        let plan = state.adminData.getPlan(pid).getOrThrow()
        @Expect(plan.status, "failed")
        @Expect(plan.lastError.startsWith("失败 1 项："), true)
        @Expect(state.adminData.getPlanItem(itemId).getOrThrow().status, "failed")
        // 发布态审计：无论成败都记一条
        let (logs, total) = state.adminData.queryLogs(Some("publish"), "plan ${pid} failed", "", 0, 0, 0, 10)
        @Expect(total, 1)
        @Expect(logs[0].status, "failed")
    }

    // 执行线程：全部跳过（未勾选）→ 「本次没有实际上传」这条 summary 分支
    @TestCase
    public func covPlanDetail_runExecutionAllSkippedSummary(): Unit {
        let state = makePortalState("team")
        state.app = Some(App())
        let blob = MemoryBlobStore()
        state.blobStore = Some(blob)
        let upId = covSeedUpstream(state, "skip-up", url: "http://127.0.0.1:1")
        let pid = covSeedPlan(state, "skip-exec", targetUpstream: upId)
        let page = mountPlanDetailCov(state, pid)

        let items = ArrayList<PlanItem>()
        let it = PlanItem(1, "alpha", "ystyle", "1.0.0", PlanCategory.NeedPublish, 1)
        it.selected = false          // 未勾选 → 执行器记 skipped
        items.add(it)
        let up = state.upStore.getById(upId).getOrThrow()
        page.runExecution(state, "sid-test", items, HashMap<Int64, Int64>(), up, 0)

        let plan = state.adminData.getPlan(pid).getOrThrow()
        @Expect(plan.status, "completed")   // 0 失败、total>0 → completed
        @Expect(plan.lastError.startsWith("本次没有实际上传："), true)
        @Expect(state.planBusy.get(), false)
    }

    // 执行线程：用户已请求停止 → aborted 收口为 paused + 额外记一条「用户停止」审计
    @TestCase
    public func covPlanDetail_runExecutionAbortedSummary(): Unit {
        let state = makePortalState("team")
        state.app = Some(App())
        let blob = MemoryBlobStore()
        state.blobStore = Some(blob)
        let upId = covSeedUpstream(state, "abort-up", url: "http://127.0.0.1:1")
        let pid = covSeedPlan(state, "abort-exec", targetUpstream: upId)
        let page = mountPlanDetailCov(state, pid)

        // 先登记「已请求停止」：执行器每项开推前会看到 → aborted
        addPlanId(state, pid, true)
        let items = ArrayList<PlanItem>()
        items.add(PlanItem(1, "alpha", "ystyle", "1.0.0", PlanCategory.NeedPublish, 1))
        let up = state.upStore.getById(upId).getOrThrow()
        page.runExecution(state, "sid-test", items, HashMap<Int64, Int64>(), up, 0)

        let plan = state.adminData.getPlan(pid).getOrThrow()
        @Expect(plan.status, "paused")
        @Expect(plan.lastError, "用户已停止执行")
        // 停止有专门的审计（与常规收口那条并存）
        let (_, stopLogs) = state.adminData.queryLogs(Some("publish"), "用户停止", "", 0, 0, 0, 10)
        @Expect(stopLogs, 1)
        @Expect(containsId(state.planCancelIds.get(), pid), false)   // 收口时两条登记都清掉
    }

    // 停止执行：非管理员 / 没在跑 / 正常请求停止
    @TestCase
    public func covPlanDetail_stopExecution(): Unit {
        let state = makePortalState("team")
        let pid = covSeedPlan(state, "stop-plan", status: "running")
        let page = mountPlanDetailCov(state, pid)

        let (plain, _) = covActx(state, dbIsAdmin: false, ctxIsAdmin: true, username: "covplain")
        let _ = page.stopExecution(plain)
        @Expect(page.msg.get(), "无权限：需要管理员登录")

        let (actx, _) = covActx(state)
        let _ = page.stopExecution(actx)
        @Expect(page.msg.get(), "该计划当前没有在执行")

        addPlanId(state, pid, false)
        let _ = page.stopExecution(actx)
        @Expect(page.msg.get(), "已请求停止：正在收尾（已推出去的项会保留）")
        @Expect(containsId(state.planCancelIds.get(), pid), true)
        @Expect(covRender(page.render()).contains("停止中…"), true)
    }

    // 渲染：执行中显示进度行 + 停止按钮；未执行且无等索引项时两个入口都不在
    @TestCase
    public func covPlanDetail_executingBranches(): Unit {
        let state = makePortalState("team")
        let pid = covSeedPlan(state, "exec-render", status: "running")
        let _ = covSeedPlanItem(state, pid, "alpha", 1)
        let page = mountPlanDetailCov(state, pid)
        @Expect(covRender(page.render()).contains("执行中: "), false)

        addPlanId(state, pid, false)
        state.planProgress.set("3/7")
        let json = covRender(page.render())
        @Expect(json.contains("执行中: 3/7"), true)
        @Expect(json.contains("停止执行"), true)
        @Expect(json.contains("开始执行"), false)
        @Expect(json.contains("继续执行"), false)

        // 有等索引项、但**正在执行**：按钮判据是 `!executing && hasWaitingIndex()`
        // ——执行中不给「检查索引」（正在跑的那轮自己会探），所以这里不该出现
        let _ = covSeedPlanItem(state, pid, "beta", 2, status: "waiting_index",
            targetCompared: true, targetVersion: "1.0.0")
        page.refreshItems()
        @Expect(page.hasWaitingIndex(), true)
        @Expect(covRender(page.render()).contains("检查索引"), false)

        // 执行结束（解登记）后同一份数据才出现该入口
        removePlanId(state, pid, false)
        @Expect(covRender(page.render()).contains("检查索引"), true)
    }

    // 隐藏开关 + 行数文案 + 空态提示（与既有用例互补：这里覆盖 no-rows 与计数两态）
    @TestCase
    public func covPlanDetail_rowCountText(): Unit {
        let state = makePortalState("team")
        let pid = covSeedPlan(state, "count-plan")
        let _ = covSeedPlanItem(state, pid, "alpha", 1)
        let _ = covSeedPlanItem(state, pid, "beta", 2, selected: false)
        let page = mountPlanDetailCov(state, pid)
        @Expect(page.itemCountText(), "共 2 项")
        page.hideUnpublished.set(true)
        @Expect(page.itemCountText(), "显示 1 / 共 2 项（隐藏 1 项不推送的）")
        // 全量没有项时不提示"没有会推送的项"（条件要求 items.size > 0）
        let pid2 = covSeedPlan(state, "empty-items")
        let page2 = mountPlanDetailCov(state, pid2)
        page2.hideUnpublished.set(true)
        @Expect(page2.itemsHint(), "")
        @Expect(page2.itemRows.get().size, 0)
    }

    // 返回列表：跳转
    @TestCase
    public func covPlanDetail_backToList(): Unit {
        let state = makePortalState("team")
        let pid = covSeedPlan(state, "back-plan")
        let page = mountPlanDetailCov(state, pid)
        let (actx, nav) = covActx(state)
        let _ = page.backToList(actx)
        @Expect(nav[0], "/admin/publish-plans")
    }

    // 目标仓名兜底：#id
    @TestCase
    public func covPlanDetail_upstreamNameFallback(): Unit {
        let state = makePortalState("team")
        let pid = covSeedPlan(state, "up-name", targetUpstream: 424242)
        let page = mountPlanDetailCov(state, pid)
        @Expect(page.upstreamName(state, 424242), "#424242")
        @Expect(covRender(page.render()).contains("#424242"), true)
    }

    // 计划状态 Tag：六个分支（含无执行登记时的 interrupted）
    @TestCase
    public func covPlanDetail_statusTagBranches(): Unit {
        let state = makePortalState("team")
        let pid = covSeedPlan(state, "tag-plan", status: "running")
        let page = mountPlanDetailCov(state, pid)
        for ((s, label) in [("running", "执行中"), ("completed", "已完成"), ("failed", "失败"),
                            ("paused", "已暂停"), ("pending", "待执行"), ("interrupted", "上次未收口")]) {
            @Expect(covRender(page.statusTag(s)).contains(label), true)
        }
        // 库里 running 且无登记 → 「上次未收口」
        @Expect(covRender(page.render()).contains("上次未收口"), true)

        // 登记后 → 「执行中」
        addPlanId(state, pid, false)
        @Expect(covRender(page.render()).contains("执行中"), true)
    }

    // msg 提示槽位 + 计划级原因在无值时不留 Tag
    @TestCase
    public func covPlanDetail_msgSlot(): Unit {
        let state = makePortalState("team")
        let pid = covSeedPlan(state, "msg-plan")
        let page = mountPlanDetailCov(state, pid)
        @Expect(covRender(page.render()).contains("el-tag--warning"), false)   // lastError 为空
        page.msg.set("已请求停止")
        @Expect(covRender(page.render()).contains("已请求停止"), true)
    }

    // onUnmount：释放 binding（Some 分支）；之后刷新不再重算显示行
    @TestCase
    public func covPlanDetail_unmountDisposesBinding(): Unit {
        let state = makePortalState("team")
        let pid = covSeedPlan(state, "unmount-plan")
        let _ = covSeedPlanItem(state, pid, "alpha", 1)
        let page = mountPlanDetailCov(state, pid)
        @Expect(page.itemRows.get().size, 1)

        page.onUnmount(covPlanDetailCtx(state, pid, true))
        page.hideUnpublished.set(true)
        @Expect(page.itemRows.get().size, 1)   // binding 已 dispose，不再重算

        // 重新挂载：rebind 走 Some 分支（先 dispose 旧绑定再建新的）。
        // hideUnpublished 仍是 true，但 alpha 是「会推送」的项，所以显示行数还是 1。
        page.onMount(covPlanDetailCtx(state, pid, true))
        @Expect(page.itemRows.get().size, 1)
        @Expect(page.hideUnpublished.get(), true)

        // 无绑定时再 unmount：走 None 分支
        let fresh = PublishPlanDetailPage()
        fresh.onUnmount(covPlanDetailCtx(state, pid, true))
        @Expect(fresh.items.get().size, 0)
    }

    // 路由参数非法 / 缺失：planId 保持 0，页面给出「计划不存在」
    @TestCase
    public func covPlanDetail_badRouteParam(): Unit {
        let state = makePortalState("team")
        let params = HashMap<String, String>()
        params.add("id", "not-a-number")
        let states = HashMap<String, AppState>()
        states.add(TypeInfo.of<CjregState>().qualifiedName, state)
        let sctx: SessionContext = SessionContextState(userCtxMap(1, "admin", true))
        let page = PublishPlanDetailPage()
        page.onMount(LifecycleContext("sid", params, Option<String>.None, Option<String>.None,
            states: states, sessionContext: Some(sctx)))
        @Expect(page.planId, 0)
        @Expect(covRender(page.render()).contains("计划不存在或已删除"), true)

        // 完全没有 id 参数
        let page2 = PublishPlanDetailPage()
        page2.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
        @Expect(page2.planId, 0)
    }
}
