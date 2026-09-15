// 发布计划详情页「操作按钮」可见性（渲染层回归）
//
// 契约：**只要计划不是「不存在」，详情页就必须始终有「重新分析」入口**。
// 「重新分析」是对着目标仓索引重算分类与顺序的动作，和"这一轮执行到哪了"无关：
// 一旦被 `if (!executing)` 之类包住，用户在最长一轮「等索引」（= 计划的 pollTimeout，
// 默认 10 分钟）里就完全看不到它，只能干等或先停执行。
//
// 这里用 cjxt serializeSubtree 直接渲染组件树断言 JSON，不起 HTTP、不依赖浏览器
// （执行得快慢也影响不到断言——真实执行是毫秒级收口，浏览器里根本抓不到"执行中"那一瞬）。
package ystyle::cjreg.ui

import cjxt.*
import bstorm.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.util.*
import ystyle::cjreg.auth.model.*
import ystyle::cjreg.config.*
import std.collection.*
import std.reflect.*
import std.unittest.*
import std.unittest.testmacro.*

// 详情页挂载上下文：带路由参数 id（onMount 从 route.params 取计划 id）
func detailMountCtx(state: CjregState, planId: Int64, isAdmin: Bool): LifecycleContext {
    let states = HashMap<String, AppState>()
    states.add(TypeInfo.of<CjregState>().qualifiedName, state)
    let params = HashMap<String, String>()
    params.add("id", planId.toString())
    let sctx: SessionContext = SessionContextState(userCtxMap(1, "admin", isAdmin))
    LifecycleContext("sid-plan-detail", params, None, None, states: states, sessionContext: Some(sctx))
}

func renderPlanDetail(state: CjregState, planId: Int64): String {
    let page = PublishPlanDetailPage()
    page.onMount(detailMountCtx(state, planId, true))
    serializeSubtree(page.render(), HashMap<String, ActionHandler>())
}

// 建一个计划并把它置成指定状态；返回计划 id
func seedPlan(state: CjregState, name: String, status: String): Int64 {
    let id = state.adminData.createPlan(name, 0, 10, 600, 1000)
    state.adminData.updatePlanStatus(id, status, 0, 1000)
    return id
}

@Test
public class PlanDetailButtonsRenderTest {
    // 执行中：既有「停止执行」出口，也不丢「重新分析」
    @TestCase
    public func testExecutingKeepsReanalyzeButton(): Unit {
        let state = makePortalState("team")
        let planId = seedPlan(state, "执行中计划", "running")
        addPlanId(state, planId, false)
        let json = renderPlanDetail(state, planId)
        @Expect(json.contains("重新分析"), true)
        @Expect(json.contains("停止执行"), true)
        // 执行中不该同时出现"再点一次执行"的入口
        @Expect(json.contains("开始执行"), false)
        @Expect(json.contains("继续执行"), false)
    }

    // 已请求停止（停止中）：按钮换成禁用态，但「重新分析」依旧在
    @TestCase
    public func testCancellingKeepsReanalyzeButton(): Unit {
        let state = makePortalState("team")
        let planId = seedPlan(state, "停止中计划", "running")
        addPlanId(state, planId, false)
        addPlanId(state, planId, true)
        let json = renderPlanDetail(state, planId)
        @Expect(json.contains("重新分析"), true)
        @Expect(json.contains("停止中"), true)
    }

    // 整个计划跑完（completed）：仍然可以重新分析（目标仓可能又变了），但没有可执行的入口
    @TestCase
    public func testCompletedPlanKeepsReanalyzeButNoStart(): Unit {
        let state = makePortalState("team")
        let planId = seedPlan(state, "已完成计划", "completed")
        let json = renderPlanDetail(state, planId)
        @Expect(json.contains("重新分析"), true)
        @Expect(json.contains("开始执行"), false)
        @Expect(json.contains("继续执行"), false)
    }

    // 暂停/失败（可续跑）：重新分析与「继续执行」并存——两个动作互不替代
    @TestCase
    public func testPausedPlanHasReanalyzeAndResume(): Unit {
        let state = makePortalState("team")
        let pausedId = seedPlan(state, "已暂停计划", "paused")
        let paused = renderPlanDetail(state, pausedId)
        @Expect(paused.contains("重新分析"), true)
        @Expect(paused.contains("继续执行"), true)

        let failedId = seedPlan(state, "失败计划", "failed")
        let failed = renderPlanDetail(state, failedId)
        @Expect(failed.contains("重新分析"), true)
        @Expect(failed.contains("继续执行"), true)
    }

    // 待执行（新建后没跑过）：同样有「重新分析」，按钮集合里它是常驻项
    @TestCase
    public func testPendingPlanKeepsReanalyzeButton(): Unit {
        let state = makePortalState("team")
        let planId = seedPlan(state, "待执行计划", "pending")
        let json = renderPlanDetail(state, planId)
        @Expect(json.contains("重新分析"), true)
        @Expect(json.contains("开始执行"), true)
    }

    // 计划确实不存在时才给空态（此时没有可分析的对象，按钮可以没有）
    @TestCase
    public func testMissingPlanShowsEmptyState(): Unit {
        let state = makePortalState("team")
        let json = renderPlanDetail(state, 999999)
        @Expect(json.contains("计划不存在或已删除"), true)
    }
}
