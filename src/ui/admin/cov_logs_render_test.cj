// 审计日志页（/admin/logs）渲染 + 交互回归。
//
// 页面已有搜索/筛选的用例（logs_search_test.cj），这里补的是**没被覆盖的另一半**：
//   * 清理确认弹窗的全过程（askClear / cancelClear / confirmClear）与三种清理范围；
//   * 清理动作自身的审计记录（scope / deleted 计数进 detail）；
//   * 非管理员与未登录被拒（confirmClear 的 isAdminSession 分支）；
//   * kindLabel 的三档映射、时间/类型/结果/错误各列的渲染分支；
//   * 未挂载 state 的 None 分支。
package ystyle::cjreg.ui.admin

import ystyle::cjreg.ui.*
import cjxt.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

func mountLogsCov(state: CjregState): LogsPage {
    let page = LogsPage()
    page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
    page
}

func seedCovLog(state: CjregState, kind: LogKind, action: String, status!: String = "ok",
                 actor!: String = "admin", target!: String = "", error!: String = "",
                 ip!: String = "127.0.0.1", ua!: String = "ut", detail!: String = "",
                 createdAt!: Int64 = 1000): Int64 {
    state.adminData.addLog(kind, 1, actor, action, status, createdAt,
        target: target, error: error, ipAddr: ip, userAgent: ua, detail: detail)
}

@Test
public class CovLogsRenderTest {
    // 表头九列齐全（含 IP / User-Agent / 错误信息三列，其余页面没有）
    @TestCase
    public func covLogs_tableColumns(): Unit {
        let state = makePortalState("team")
        let _ = seedCovLog(state, LogKind.Admin, "clean_logs", ip: "10.0.0.1", ua: "Mozilla/5.0")
        let json = covRender(mountLogsCov(state).render())
        for (label in ["时间", "类型", "操作者", "操作", "对象", "结果", "IP", "User-Agent", "错误信息"]) {
            @Expect(json.contains(label), true)
        }
        @Expect(json.contains("10.0.0.1"), true)
        @Expect(json.contains("Mozilla/5.0"), true)
        @Expect(json.contains("审计日志"), true)
        @Expect(json.contains("操作日志"), true)
    }

    // kindLabel 三档：publish→发布、auth→认证、其余（含未知值）→管理
    @TestCase
    public func covLogs_kindLabelMapping(): Unit {
        let state = makePortalState("team")
        let page = mountLogsCov(state)
        @Expect(page.kindLabel("publish"), "发布")
        @Expect(page.kindLabel("auth"), "认证")
        @Expect(page.kindLabel("admin"), "管理")
        @Expect(page.kindLabel("whatever"), "管理")

        let _ = seedCovLog(state, LogKind.Publish, "publish a@1.0.0", createdAt: 3000)
        let _ = seedCovLog(state, LogKind.Auth, "login", createdAt: 2000)
        let _ = seedCovLog(state, LogKind.Admin, "clean_logs", createdAt: 1000)
        page.reload()
        let json = covRender(page.render())
        @Expect(json.contains("发布"), true)   // 类型列 + 下拉选项都有「发布」
        @Expect(json.contains("认证"), true)
        @Expect(json.contains("管理"), true)
    }

    // 结果列：ok → 成功（Success Tag），非 ok → 失败（Danger Tag）；错误信息列直出
    @TestCase
    public func covLogs_statusAndErrorColumns(): Unit {
        let state = makePortalState("team")
        let _ = seedCovLog(state, LogKind.Publish, "publish a@1.0.0", createdAt: 2000)
        let _ = seedCovLog(state, LogKind.Publish, "publish b@1.0.0", status: "failed", createdAt: 1000,
            error: "409 invalid")
        let page = mountLogsCov(state)
        let json = covRender(page.render())
        @Expect(json.contains("成功"), true)
        @Expect(json.contains("失败"), true)
        @Expect(json.contains("el-tag--success"), true)
        @Expect(json.contains("el-tag--danger"), true)
        @Expect(json.contains("409 invalid"), true)
    }

    // 时间列：0 → 「-」，正数 → MM-dd HH:mm（列宽内的可读时间）
    @TestCase
    public func covLogs_timeColumn(): Unit {
        let state = makePortalState("team")
        let _ = seedCovLog(state, LogKind.Admin, "no-time", createdAt: 0)
        let _ = seedCovLog(state, LogKind.Admin, "with-time", createdAt: 1700000000000)
        let page = mountLogsCov(state)
        let json = covRender(page.render())
        @Expect(json.contains("with-time"), true)
        @Expect(json.contains("\"-\""), true)
        // 1700000000000 ms = 2023-11-15（本地时区），格式为 MM-dd HH:mm
        @Expect(json.contains("11-15"), true)
    }

    // 清理确认弹窗：askClear 打开、cancelClear 关闭（关着不渲染 Dialog 节点）
    @TestCase
    public func covLogs_clearDialogOpenAndCancel(): Unit {
        let state = makePortalState("team")
        let _ = seedCovLog(state, LogKind.Admin, "clean_logs")
        let page = mountLogsCov(state)
        let (actx, _) = covActx(state)

        @Expect(page.confirmVisible.get(), false)
        @Expect(covRender(page.render()).contains("清理审计日志"), false)

        let _ = page.askClear(actx)
        @Expect(page.confirmVisible.get(), true)
        let opened = covRender(page.render())
        @Expect(opened.contains("清理审计日志"), true)
        @Expect(opened.contains("清理范围："), true)
        @Expect(opened.contains("确认清理"), true)
        // Select 收起时只渲染**当前选中项**的标签（下拉面板要展开才有全部选项）
        @Expect(opened.contains("全部日志"), true)
        @Expect(opened.contains("仅发布日志"), false)

        // 换清理范围：选中项标签跟着变（render 里 findLabel 现读信号）
        page.cleanKind.set("publish")
        @Expect(covRender(page.render()).contains("仅发布日志"), true)
        page.cleanKind.set("admin")
        @Expect(covRender(page.render()).contains("仅管理日志"), true)
        page.cleanKind.set("auth")
        @Expect(covRender(page.render()).contains("仅认证日志"), true)

        let _ = page.cancelClear(actx)
        @Expect(page.confirmVisible.get(), false)
        @Expect(covRender(page.render()).contains("清理审计日志"), false)
    }

    // 确认清理（全部）：日志清空、提示带条数、弹窗关闭、页码回 1，且**清理动作自身入审计**
    @TestCase
    public func covLogs_confirmClearAll(): Unit {
        let state = makePortalState("team")
        let _ = seedCovLog(state, LogKind.Publish, "publish a@1.0.0", createdAt: 3000)
        let _ = seedCovLog(state, LogKind.Auth, "login", createdAt: 2000)
        let _ = seedCovLog(state, LogKind.Admin, "clean_logs", createdAt: 1000)
        let page = mountLogsCov(state)
        let (actx, _) = covActx(state)
        @Expect(page.rows.get().size, 3)

        page.cleanKind.set("all")
        page.currentPage.set(3)
        let _ = page.askClear(actx)
        let _ = page.confirmClear(actx)

        @Expect(page.msg.get(), "已清理 3 条全部日志")
        @Expect(page.confirmVisible.get(), false)
        @Expect(page.currentPage.get(), 1)
        // 清理动作自己写了一条审计（admin 类），所以现在只剩 1 条
        @Expect(page.total.get(), 1)
        @Expect(page.rows.get()[0].action, "clean_logs")
        @Expect(page.rows.get()[0].ipAddr, "admin-ui")
        @Expect(page.rows.get()[0].userAgent, "cjxt-admin-ui")
        @Expect(page.rows.get()[0].target, "all")
        @Expect(page.rows.get()[0].detail, "deleted=3 via=admin-ui")
        @Expect(page.rows.get()[0].actorName, "covadmin")
        @Expect(covRender(page.render()).contains("已清理 3 条全部日志"), true)
    }

    // 确认清理（仅发布）：只删 publish 类，提示用类型中文名，审计 target 记该 scope
    @TestCase
    public func covLogs_confirmClearScoped(): Unit {
        let state = makePortalState("team")
        let _ = seedCovLog(state, LogKind.Publish, "publish a@1.0.0", createdAt: 3000)
        let _ = seedCovLog(state, LogKind.Publish, "publish b@1.0.0", createdAt: 2500)
        let _ = seedCovLog(state, LogKind.Auth, "login", createdAt: 2000)
        let _ = seedCovLog(state, LogKind.Admin, "clean_logs", createdAt: 1000)
        let page = mountLogsCov(state)
        let (actx, _) = covActx(state)

        page.cleanKind.set("publish")
        let _ = page.confirmClear(actx)
        @Expect(page.msg.get(), "已清理 2 条发布日志")
        @Expect(page.total.get(), 3)   // 剩下 auth + admin + 本次审计

        let (logs, total) = state.adminData.queryLogs(Some("admin"), "clean_logs", "", 0, 0, 0, 10)
        // 种子里那条 admin 日志 + 本次清理自己写的审计
        @Expect(total, 2)
        @Expect(logs[0].target, "publish")

        // 认证范围：kindLabel("auth") = 认证（先 bump 让列表跟上第二次删除）
        page.cleanKind.set("auth")
        page.bump()
        let _ = page.confirmClear(actx)
        @Expect(page.msg.get(), "已清理 1 条认证日志")
    }

    // 没有可清的日志：提示「已清理 0 条…」而不是报错
    @TestCase
    public func covLogs_confirmClearWhenEmpty(): Unit {
        let state = makePortalState("team")
        let page = mountLogsCov(state)
        let (actx, _) = covActx(state)
        page.cleanKind.set("all")
        let _ = page.confirmClear(actx)
        @Expect(page.msg.get(), "已清理 0 条全部日志")
        @Expect(page.total.get(), 1)   // 审计那一条
    }

    // 权限：非管理员（库里已降级）与未登录都不能清理，且**不该留下审计**
    @TestCase
    public func covLogs_confirmClearRequiresAdmin(): Unit {
        let state = makePortalState("team")
        let _ = seedCovLog(state, LogKind.Admin, "keep-me")
        let page = mountLogsCov(state)

        let (plainCtx, _) = covActx(state, dbIsAdmin: false, ctxIsAdmin: true, username: "covplain")
        let _ = page.confirmClear(plainCtx)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(page.confirmVisible.get(), false)
        @Expect(state.adminData.queryLogs(Option<String>.None, "", "", 0, 0, 0, 10)[1], 1)

        let anon = covAnonActx(state)
        let _ = page.confirmClear(anon)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(state.adminData.queryLogs(Option<String>.None, "", "", 0, 0, 0, 10)[1], 1)
    }

    // 「筛选」按钮：回第一页 + bump 强制重查（条件没变时信号不动，靠 bump 才能看到新数据）
    @TestCase
    public func covLogs_refreshResetsPageAndRequeries(): Unit {
        let state = makePortalState("team")
        for (i in 0..25) {
            let _ = seedCovLog(state, LogKind.Admin, "op-${i}", createdAt: 1000 + i)
        }
        let page = mountLogsCov(state)
        let (actx, _) = covActx(state)
        page.currentPage.set(2)
        @Expect(page.rows.get().size, 5)

        let _ = page.doRefresh(actx)
        @Expect(page.currentPage.get(), 1)
        @Expect(page.rows.get().size, 20)

        // 期间新增一条：bump 后总数跟着变
        let _ = seedCovLog(state, LogKind.Admin, "added-later", createdAt: 9999)
        let _ = page.doRefresh(actx)
        @Expect(page.total.get(), 26)
        @Expect(page.rows.get()[0].action, "added-later")
    }

    // 页大小为 0/负数或页码 < 1：reload 内部钳制，不能算出负偏移空表
    @TestCase
    public func covLogs_reloadClampsPageAndSize(): Unit {
        let state = makePortalState("team")
        for (i in 0..5) {
            let _ = seedCovLog(state, LogKind.Admin, "op-${i}", createdAt: 1000 + i)
        }
        let page = mountLogsCov(state)
        page.pageSize.set(0)
        @Expect(page.rows.get().size, 5)      // size<=0 → 退回 20
        page.currentPage.set(0)
        @Expect(page.rows.get().size, 5)      // page<1 → 退回 1
        @Expect(page.total.get(), 5)
    }

    // 清理后页码超范围：reload 退到最后一页重查（不是空表）
    @TestCase
    public func covLogs_outOfRangePageAfterClean(): Unit {
        let state = makePortalState("team")
        for (i in 0..30) {
            let _ = seedCovLog(state, LogKind.Admin, "op-${i}", createdAt: 1000 + i)
        }
        let page = mountLogsCov(state)
        page.currentPage.set(2)
        @Expect(page.rows.get().size, 10)

        let _ = state.adminData.removeLogs(Option<String>.None, 0)
        let _ = seedCovLog(state, LogKind.Admin, "only-one", createdAt: 5000)
        page.bump()
        @Expect(page.rows.get().size, 1)
        @Expect(page.rows.get()[0].action, "only-one")
    }

    // 空态：一条日志都没有时给出表格自带空文案 + 0 条
    @TestCase
    public func covLogs_emptyState(): Unit {
        let state = makePortalState("team")
        let page = mountLogsCov(state)
        let json = covRenderExpanded(page.render())
        @Expect(json.contains("暂无数据"), true)
        @Expect(json.contains("共 0 条"), true)
    }

    // 未挂载 state：onMount/onUnmount 之外的入口都走 None 分支，reload 不动 rows
    @TestCase
    public func covLogs_withoutState(): Unit {
        let state = makePortalState("team")
        let _ = seedCovLog(state, LogKind.Admin, "x")
        let page = LogsPage()
        page.reload()
        @Expect(page.rows.get().size, 0)
        @Expect(page.total.get(), 0)
        let (actx, _) = covActx(state)
        let _ = page.confirmClear(actx)
        @Expect(page.rows.get().size, 0)
        page.onUnmount(mountCtx(state, userCtxMap(1, "admin", true)))   // binding=None 的 None 分支
    }

    // 重新挂载：old binding 被 dispose（rebind 里 Some 分支），订阅不累积
    @TestCase
    public func covLogs_remountRebuildsBinding(): Unit {
        let state = makePortalState("team")
        let _ = seedCovLog(state, LogKind.Admin, "before")
        let page = mountLogsCov(state)
        @Expect(page.rows.get().size, 1)

        // 二次 onMount：应替换绑定（不是叠加），随后数据变化仍只反映一次
        page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
        let _ = seedCovLog(state, LogKind.Admin, "after", createdAt: 5000)
        page.bump()
        @Expect(page.total.get(), 2)
        page.onUnmount(mountCtx(state, userCtxMap(1, "admin", true)))
        // 卸载后再写条件：不再重查（Effect 已 dispose）
        let before = page.total.get()
        page.keyword.set("after")
        @Expect(page.total.get(), before)
    }

    // 超长错误/UA 不被截断（showOverflowTooltip 只影响样式，内容照出）
    @TestCase
    public func covLogs_longTextPassesThrough(): Unit {
        let state = makePortalState("team")
        let long = covLongText("e", 400)
        let _ = seedCovLog(state, LogKind.Admin, "long", status: "failed", error: long, ua: long)
        let page = mountLogsCov(state)
        let json = covRender(page.render())
        @Expect(json.contains(long), true)
    }

    // 弹窗里的清理范围：Select 收起时只渲染当前选中项的标签，换 scope 标签跟着变
    @TestCase
    public func covLogs_cleanScopeSelectionLabel(): Unit {
        let state = makePortalState("team")
        let page = mountLogsCov(state)
        page.confirmVisible.set(true)
        let json = covRender(page.render())
        @Expect(json.contains("清理范围："), true)
        @Expect(json.contains("全部日志"), true)
        page.cleanKind.set("auth")
        @Expect(covRender(page.render()).contains("仅认证日志"), true)
    }
}
