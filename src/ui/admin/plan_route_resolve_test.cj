// 发布计划：路由解析回归（静态页不能被同深度的参数页抢先匹配）
//
// 背景（2026-10-28 生产事故）：`/admin/publish-plans/create` 与
// `/admin/publish-plans/[id]` **同深度**、都"匹配"该路径。cjxt ≤ 1.1.0 的
// `RouteRegistry.resolve` 按**注册顺序**取第一个匹配项，而 `@Page` 的注册语句分散在
// 不同文件的顶层初始化里、先后由编译器决定 —— 实测参数路由先注册，于是点
// 「创建发布计划」打开的是详情页：`[id]` 拿到 "create" 解析失败、计划 id 留在 0，
// 页面显示"计划不存在或已删除"。
//
// 处置：创建页放到 `/admin/new-publish-plan`（3 段路径，不与详情页的 4 段
// `/admin/publish-plans/[id]` 同深度），不依赖框架升级即可正确解析；
// 框架侧的字面路径优先修复在 cjxt 1.1.2（本仓升级后再改回 `/admin/publish-plans/create` 亦可）。
//
// 断言只用公开 API（`create` / `getTitle`）：`RouteMatch` 的字段是框架包内可见的。
package ystyle::cjreg.ui.admin

import cjxt.*
import ystyle::cjreg.ui.*
import ystyle::cjreg.store.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class PlanRouteResolveTest {
    @TestCase
    public func testCreatePlanRouteResolvesToCreatePage(): Unit {
        match (RouteRegistry.global().create("/admin/new-publish-plan")) {
            case Some(page) =>
                match (page) {
                    case p: PublishPlanCreatePage => ()
                    case _ => @Fail("/admin/new-publish-plan 解析到了别的页面（创建页被同级参数路由吃掉）")
                }
            case None => @Fail("/admin/new-publish-plan 未解析到任何页面")
        }
    }

    @TestCase
    public func testPlanDetailRouteStillResolves(): Unit {
        match (RouteRegistry.global().create("/admin/publish-plans/7")) {
            case Some(page) =>
                match (page) {
                    case p: PublishPlanDetailPage => ()
                    case _ => @Fail("/admin/publish-plans/7 未解析到发布计划详情页")
                }
            case None => @Fail("/admin/publish-plans/7 未解析到任何页面")
        }
    }

    // 标题也要取到各自页面的（标题查表同样按字面路径命中）
    @TestCase
    public func testPlanRouteTitles(): Unit {
        match (RouteRegistry.global().getTitle("/admin/new-publish-plan")) {
            case Some(t) => @Expect(t, "创建发布计划")
            case None => @Fail("/admin/new-publish-plan 没有页面标题")
        }
        match (RouteRegistry.global().getTitle("/admin/publish-plans/7")) {
            case Some(t) => @Expect(t, "发布计划详情")
            case None => @Fail("/admin/publish-plans/7 没有页面标题")
        }
    }

    // 列表页「创建计划」按钮必须跳到解析得到创建页的那条路径上：
    // 路径改回 4 段的 `/create` 会被详情页吃掉，这条用例把它钉住。
    @TestCase
    public func testPlanListCreateButtonTargetsResolvablePath(): Unit {
        let state = makePortalState("team")
        let page = PublishPlansPage()
        page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
        let (actx, nav) = covActx(state)
        let _ = page.gotoCreate(actx)
        @Expect(nav.size > 0, true)
        match (RouteRegistry.global().create(nav[0])) {
            case Some(target) =>
                match (target) {
                    case p: PublishPlanCreatePage => ()
                    case _ => @Fail("「创建计划」跳转目标解析到了非创建页：${nav[0]}")
                }
            case None => @Fail("「创建计划」跳转目标没有对应页面：${nav[0]}")
        }
    }
}
