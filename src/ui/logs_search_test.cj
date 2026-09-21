// 审计日志页：搜索/筛选"输入即生效"（渲染层回归）
//
// 这条是"搜索无效"缺陷的另一半：日志的过滤在**服务端**查询里做（量大，不能像包管理那样
// 全量拉进来在内存里筛），旧实现把查询挂在输入框的 action 上——而前端对同一元素是
// **先 action 后 bind**（cjxt public/js/cangjie-ui.js:333 action 立即发，:490 的 bind 有
// 300ms 防抖），action 里读到的关键字还是上一次的，表现为"打字没反应，必须再点一次筛选"。
// 现在查询是派生：只 set 信号，不触发任何动作，结果就该跟着变。
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

// 造日志：kind = publish/admin/auth，status = ok/failed
func seedLog(state: CjregState, kind: LogKind, action: String, status!: String = "ok",
             actor!: String = "admin", target!: String = "", error!: String = "",
             createdAt!: Int64 = 1000): Int64 {
    state.adminData.addLog(kind, 1, actor, action, status, createdAt,
        target: target, error: error, ipAddr: "127.0.0.1", userAgent: "ut")
}

func mountLogs(state: CjregState): LogsPage {
    let page = LogsPage()
    page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
    page
}

@Test
public class LogsPageSearchTest {
    // 关键字：只 set 信号（等价于输入框 bind 落地的那一下），表格立刻只剩命中的行
    @TestCase
    public func testKeywordFiltersImmediately(): Unit {
        let state = makePortalState("team")
        let _ = seedLog(state, LogKind.Publish, "publish alpha@1.0.0", target: "alpha")
        let _ = seedLog(state, LogKind.Admin, "delete_package", target: "beta")

        let page = mountLogs(state)
        @Expect(page.rows.get().size, 2)

        page.keyword.set("alpha")
        let rows = page.rows.get()
        @Expect(rows.size, 1)
        @Expect(rows[0].action, "publish alpha@1.0.0")

        page.keyword.set("beta")
        @Expect(page.rows.get()[0].action, "delete_package")

        // 清空关键字：回到全量
        page.keyword.set("")
        @Expect(page.rows.get().size, 2)
    }

    // 关键字输入框只 bind，不许再挂 input 动作（见 list_binding.cj 头部说明）
    @TestCase
    public func testKeywordInputCarriesNoInputAction(): Unit {
        let state = makePortalState("team")
        let _ = seedLog(state, LogKind.Admin, "clean_logs")
        let page = mountLogs(state)
        let json = renderExpanded(page.render())
        @Expect(json.contains("\"input\":"), false)
        @Expect(json.contains("data-bind-id"), true)
    }

    // 分页器文案必须跟着条件走：改筛选后**不回写页码**（回写会让旧分页器实例的快照补丁
    // 排在页面补丁之后，把新总数顶回旧值），所以这里守住"渲染出来的条数就是过滤后的条数"
    @TestCase
    public func testPagerTotalFollowsFilter(): Unit {
        let state = makePortalState("team")
        let _ = seedLog(state, LogKind.Auth, "login", createdAt: 3000)
        let _ = seedLog(state, LogKind.Admin, "clean_logs", createdAt: 2000)
        let _ = seedLog(state, LogKind.Publish, "publish alpha@1.0.0", createdAt: 1000)

        let page = mountLogs(state)
        @Expect(renderExpanded(page.render()).contains("共 3 条"), true)

        page.kindFilter.set("admin")
        let after = renderExpanded(page.render())
        @Expect(after.contains("共 1 条"), true)
        @Expect(after.contains("共 3 条"), false)
        @Expect(page.currentPage.get(), 1)     // 条件变化不动页码
    }

    // 类型/结果下拉：同样是 bind 落地即重查（动作只负责回第一页，不参与过滤）
    @TestCase
    public func testKindAndStatusFiltersApplyImmediately(): Unit {
        let state = makePortalState("team")
        let _ = seedLog(state, LogKind.Publish, "publish alpha@1.0.0")
        let _ = seedLog(state, LogKind.Auth, "login", status: "failed")
        let _ = seedLog(state, LogKind.Admin, "clean_logs")

        let page = mountLogs(state)
        page.kindFilter.set("auth")
        @Expect(page.rows.get().size, 1)
        @Expect(page.rows.get()[0].action, "login")

        page.kindFilter.set("all")
        page.statusFilter.set("failed")
        @Expect(page.rows.get().size, 1)
        @Expect(page.rows.get()[0].status, "failed")

        // 两个条件叠加：都不命中就是空
        page.kindFilter.set("publish")
        @Expect(page.rows.get().size, 0)
        @Expect(page.total.get(), 0)
    }

    // 翻页参数也是派生的：pageSize 一变按新页大小重查
    @TestCase
    public func testPageSizeChangeRequeries(): Unit {
        let state = makePortalState("team")
        for (i in 0..25) {
            let _ = seedLog(state, LogKind.Admin, "op-${i}", createdAt: 1000 + i)
        }
        let page = mountLogs(state)
        @Expect(page.rows.get().size, 20)
        @Expect(page.total.get(), 25)
        page.pageSize.set(10)
        @Expect(page.rows.get().size, 10)
        @Expect(page.total.get(), 25)
    }

    // 页越界（条件变严 / 上一页被清理）：退到最后一页，不返回空表
    @TestCase
    public func testOutOfRangePageFallsBackToLastPage(): Unit {
        let state = makePortalState("team")
        for (i in 0..25) {
            let _ = seedLog(state, LogKind.Admin, "op-${i}", createdAt: 1000 + i)
        }
        let page = mountLogs(state)
        page.currentPage.set(5)                 // 25 条 / 每页 20 → 只有 2 页
        @Expect(page.total.get(), 25)
        @Expect(page.rows.get().size, 5)
        // 回写的是"查询用的页码"之外的东西一个都不动：currentPage 信号保持不变（避免自订阅成环）
        @Expect(page.currentPage.get(), 5)
    }

    // 清理日志后靠 bump 强制重查（查询条件没变，信号不会自己变）
    @TestCase
    public func testBumpRefetchesAfterClean(): Unit {
        let state = makePortalState("team")
        let _ = seedLog(state, LogKind.Publish, "publish alpha@1.0.0")
        let _ = seedLog(state, LogKind.Admin, "clean_logs")
        let page = mountLogs(state)
        @Expect(page.rows.get().size, 2)
        let _ = state.adminData.removeLogs(Some("publish"), 0)
        page.bump()
        @Expect(page.rows.get().size, 1)
        @Expect(page.rows.get()[0].action, "clean_logs")
    }
}

// 临时诊断（跑完删）：筛选后页面组件本身是否变脏
@Test
public class LogsDirtyDiag {
    @TestCase
    public func diagPageDirtyOnFilter(): Unit {
        let state = makePortalState("team")
        let _ = seedLog(state, LogKind.Admin, "clean_logs")
        let page = mountLogs(state)
        let _ = RenderContext.expandTree(page, "")
        RenderContext.clearDirty()
        @Expect(RenderContext.collectDirty().size, 0)
        page.kindFilter.set("admin")
        let dirty = RenderContext.collectDirty()
        var paths = ""
        for (c in dirty) { paths += "[" + c.getPath() + "]" }
        @Expect(paths.contains("[]"), true)
        RenderContext.clearDirty()
    }
}
