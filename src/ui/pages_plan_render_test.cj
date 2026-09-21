// 发布计划：列表倒序 + 详情页「隐藏不推送的项」开关（渲染层回归）
//
// 契约：开关只筛**显示行**，不动计划的真实构成与可执行动作 ——
//   * 明细（共 N 项 / 需发布 M）与「检查索引」按钮判据都按全量算，否则隐藏几条不推送的项，
//     计数会跟着变小（像项丢了）、在等索引的项还会被藏到按钮失明；
//   * 列表倒序（新的在前）由 store 的 listPlans 提供，这里守到页面这一层。
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

// 详情页计划项夹具：默认「需发布 + 勾选 + 未推送」，按用例改 status/selected
func seedDetailItem(state: CjregState, planId: Int64, name: String, order: Int64,
                    selected!: Bool = true, status!: String = "pending",
                    category!: String = "need_publish"): Int64 {
    let id = state.adminData.addPlanItem(planId, order + 100, "ystyle", name, "1.0.0",
        order, category, selected)
    if (status != "pending") {
        let _ = state.adminData.updatePlanItem(id, status, "", 2000)
    }
    return id
}

func renderPlanList(state: CjregState): String {
    let page = PublishPlansPage()
    page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
    serializeSubtree(page.render(), HashMap<String, ActionHandler>())
}

@Test
public class PublishPlanListAndDetailRenderTest {
    // 列表倒序：新建的计划排在最前（id 大的在前），渲染出来的表格行顺序一致
    @TestCase
    public func testPlanListShowsNewestFirst(): Unit {
        let state = makePortalState("team")
        let older = seedPlan(state, "旧计划", "completed")
        let newer = seedPlan(state, "新计划", "pending")
        let page = PublishPlansPage()
        page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
        let rows = page.rows.get()
        @Expect(rows.size, 2)
        @Expect(rows[0].doc.id, newer)
        @Expect(rows[1].doc.id, older)
        let json = serializeSubtree(page.render(), HashMap<String, ActionHandler>())
        @Expect(json.contains("新计划"), true)
        @Expect(json.contains("旧计划"), true)
    }

    // 「点了没反应」的结构性回归：开关写的是信号，但页面上必须有人读它才会变脏、才有补丁
    @TestCase
    public func testHideToggleMarksPageDirty(): Unit {
        let state = makePortalState("team")
        let planId = seedPlan(state, "隐藏开关脏标记", "paused")
        let _ = seedDetailItem(state, planId, "alpha", 1)
        let page = PublishPlanDetailPage()
        page.onMount(detailMountCtx(state, planId, true))
        let _ = RenderContext.expandTree(page, "")
        RenderContext.clearDirty()
        @Expect(RenderContext.collectDirty().size, 0)

        page.hideUnpublished.set(true)
        @Expect(RenderContext.collectDirty().size > 0, true)
        RenderContext.clearDirty()
    }

    // 开关关闭（默认）：所有项都显示
    @TestCase
    public func testDetailShowsAllItemsByDefault(): Unit {
        let state = makePortalState("team")
        let planId = seedPlan(state, "全量显示", "paused")
        let _ = seedDetailItem(state, planId, "alpha", 1)
        let _ = seedDetailItem(state, planId, "beta", 2, selected: false)
        let _ = seedDetailItem(state, planId, "gamma", 3, status: "skipped")

        let page = PublishPlanDetailPage()
        page.onMount(detailMountCtx(state, planId, true))
        @Expect(page.items.get().size, 3)
        @Expect(page.itemRows.get().size, 3)
        @Expect(page.itemCountText(), "共 3 项")
        let json = serializeSubtree(page.render(), HashMap<String, ActionHandler>())
        @Expect(json.contains("alpha"), true)
        @Expect(json.contains("beta"), true)
        @Expect(json.contains("gamma"), true)
    }

    // 开关打开：只留下"会推送"的项；全量明细与计数不变
    @TestCase
    public func testHideUnpublishedFiltersRowsOnly(): Unit {
        let state = makePortalState("team")
        let planId = seedPlan(state, "隐藏不推送", "paused")
        let _ = seedDetailItem(state, planId, "alpha", 1)
        let _ = seedDetailItem(state, planId, "beta", 2, selected: false)
        let _ = seedDetailItem(state, planId, "gamma", 3, status: "skipped")

        let page = PublishPlanDetailPage()
        page.onMount(detailMountCtx(state, planId, true))
        page.hideUnpublished.set(true)

        // 显示行只剩 alpha；全量仍是 3 项，明细按全量报
        @Expect(page.itemRows.get().size, 1)
        @Expect(page.itemRows.get()[0].packageName, "alpha")
        @Expect(page.items.get().size, 3)
        @Expect(page.itemBreakdown().contains("共 3 项"), true)
        @Expect(page.itemBreakdown().contains("需发布 3"), true)
        @Expect(page.itemCountText(), "显示 1 / 共 3 项（隐藏 2 项不推送的）")

        let json = serializeSubtree(page.render(), HashMap<String, ActionHandler>())
        @Expect(json.contains("alpha"), true)
        @Expect(json.contains("beta"), false)
        @Expect(json.contains("gamma"), false)
    }

    // 反手把开关关掉：显示行回到全量（Effect 双向都跟着信号走）
    @TestCase
    public func testTurningHideOffRestoresAllRows(): Unit {
        let state = makePortalState("team")
        let planId = seedPlan(state, "开关来回", "paused")
        let _ = seedDetailItem(state, planId, "alpha", 1)
        let _ = seedDetailItem(state, planId, "beta", 2, selected: false)

        let page = PublishPlanDetailPage()
        page.onMount(detailMountCtx(state, planId, true))
        page.hideUnpublished.set(true)
        @Expect(page.itemRows.get().size, 1)
        page.hideUnpublished.set(false)
        @Expect(page.itemRows.get().size, 2)
    }

    // 隐藏项里有"在等索引"的项时，「检查索引」入口不能跟着消失（它按全量判）
    @TestCase
    public func testHiddenWaitingIndexItemStillKeepsCheckButton(): Unit {
        let state = makePortalState("team")
        let planId = seedPlan(state, "隐藏等索引项", "paused")
        let _ = seedDetailItem(state, planId, "alpha", 1)
        // 没勾选、且在等索引：默认会被隐藏
        let _ = seedDetailItem(state, planId, "beta", 2, selected: false, status: "waiting_index")

        let page = PublishPlanDetailPage()
        page.onMount(detailMountCtx(state, planId, true))
        page.hideUnpublished.set(true)
        @Expect(page.itemRows.get().size, 1)
        @Expect(page.hasWaitingIndex(), true)
        let json = serializeSubtree(page.render(), HashMap<String, ActionHandler>())
        @Expect(json.contains("检查索引"), true)
    }

    // 全被隐藏时给明确空态，而不是一张空表
    @TestCase
    public func testAllHiddenShowsEmptyHint(): Unit {
        let state = makePortalState("team")
        let planId = seedPlan(state, "全部隐藏", "paused")
        let _ = seedDetailItem(state, planId, "beta", 2, selected: false)

        let page = PublishPlanDetailPage()
        page.onMount(detailMountCtx(state, planId, true))
        page.hideUnpublished.set(true)
        @Expect(page.itemRows.get().size, 0)
        let json = serializeSubtree(page.render(), HashMap<String, ActionHandler>())
        @Expect(json.contains("没有会推送的项"), true)
    }
}
