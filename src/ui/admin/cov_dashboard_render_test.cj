// 仪表盘（/admin）渲染回归。
//
// 仪表盘是一屏统计卡 + 最近操作表，几乎全是分支：每个计数都是"遍历某类文档按条件累加"。
// 原先只有 1.4% 行覆盖（只有类声明被踩到），这里把每个统计口径与两个空/非空分支都钉住：
//   * 包：总数 / 未软删版本数 / 累计下载 / 软删包数；
//   * 用户：总数 / 禁用数；上游：总数 / 启用数；
//   * 计划：总数 / running 数；日志：总数 / failed 数；
//   * 最近操作表只取 8 条、时间戳为 0 显示「-」、结果列 ok→成功 / 其它→失败。
package ystyle::cjreg.ui.admin

import ystyle::cjreg.ui.*
import cjxt.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

func mountDashboard(state: CjregState): DashboardPage {
    let page = DashboardPage()
    page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
    page
}

// 仪表盘把统计值渲染进 Statistic，序列化后的形状是：
//   {"class":"el-statistic__head"} … {"text":"标题"} … {"class":"el-statistic__value"} … {"text":"N"}
// 用「标题 → 它后面第一个 value 文本」的配对把数字取出来，避免只靠 contains 断言（数字会互相撞车）。
// **必须先跳到 stat-grid**：「发布计划」这类标签在侧栏导航里也有一份，从全文找会命中侧栏那个。
func statValueOf(json: String, label: String): String {
    let grid = match (json.indexOf("stat-grid")) {
        case Some(g) => json[g..json.size]
        case None => json
    }
    let needle = "\"text\":\"" + label + "\""
    match (grid.indexOf(needle)) {
        case Some(i) =>
            let rest = grid[i..grid.size]
            let vneedle = "el-statistic__value"
            match (rest.indexOf(vneedle)) {
                case Some(j) =>
                    let tail = rest[(j + vneedle.size)..rest.size]
                    match (tail.indexOf("\"text\":\"")) {
                        case Some(k) =>
                            let body = tail[(k + 8)..tail.size]
                            match (body.indexOf("\"")) {
                                case Some(e) => body[0..e]
                                case None => ""
                            }
                        case None => ""
                    }
                case None => ""
            }
        case None => ""
    }
}

@Test
public class CovDashboardRenderTest {
    // 全空：12 张卡都在，数字全 0；最近操作表为空态
    @TestCase
    public func covDashboard_allEmpty(): Unit {
        let state = makePortalState("team")
        let page = mountDashboard(state)
        let json = covRender(page.render())
        for (label in ["包总数", "发布版本", "累计下载", "软删包", "注册用户", "禁用用户",
                       "上游总数", "启用上游", "发布计划", "执行中", "操作日志", "失败操作"]) {
            @Expect(json.contains(label), true)
        }
        @Expect(statValueOf(json, "包总数"), "0")
        @Expect(statValueOf(json, "发布版本"), "0")
        @Expect(statValueOf(json, "累计下载"), "0")
        @Expect(statValueOf(json, "软删包"), "0")
        @Expect(statValueOf(json, "注册用户"), "0")
        @Expect(statValueOf(json, "禁用用户"), "0")
        @Expect(statValueOf(json, "上游总数"), "0")
        @Expect(statValueOf(json, "启用上游"), "0")
        @Expect(statValueOf(json, "发布计划"), "0")
        @Expect(statValueOf(json, "执行中"), "0")
        @Expect(statValueOf(json, "操作日志"), "0")
        @Expect(statValueOf(json, "失败操作"), "0")
        @Expect(json.contains("仪表盘"), true)
        @Expect(json.contains("仓库运行概览"), true)
    }

    // 包口径：包总数 = 文档数（含软删），发布版本 = 未软删数，软删包 = 软删数，累计下载 = 全部之和
    @TestCase
    public func covDashboard_packageCountersSeparateDeleted(): Unit {
        let state = makePortalState("team")
        let _ = covSeedPkg(state, "ystyle", "a", "1.0.0", downloads: 10)
        let _ = covSeedPkg(state, "ystyle", "a", "1.0.1", downloads: 5)
        let _ = covSeedPkg(state, "ystyle", "b", "2.0.0", deleted: true, downloads: 100)
        let json = covRender(mountDashboard(state).render())

        @Expect(statValueOf(json, "包总数"), "3")
        @Expect(statValueOf(json, "发布版本"), "2")
        @Expect(statValueOf(json, "软删包"), "1")
        // 累计下载含软删版本的下载数（口径：文档字段求和，与是否软删无关）
        @Expect(statValueOf(json, "累计下载"), "115")
    }

    // 用户 / 上游：总数与"禁用/启用"两个反向计数的分支
    @TestCase
    public func covDashboard_userAndUpstreamCounters(): Unit {
        let state = makePortalState("team")
        let a = state.auth.createUser("admin-a", "Pass12345", true).getOrThrow()
        let _ = state.auth.createUser("plain-a", "Pass12345", false).getOrThrow()
        let _ = state.auth.setUserActive(a.id, false)   // 唯一管理员不能禁用 → 先加一个
        // 上面那步会被"最后一个启用管理员"保护拒绝，所以再加一个管理员再禁用它
        let b = state.auth.createUser("admin-b", "Pass12345", true).getOrThrow()
        let _ = state.auth.setUserActive(b.id, false)

        let _ = covSeedUpstream(state, "on", enabled: true)
        let _ = covSeedUpstream(state, "off", enabled: false)
        let _ = covSeedUpstream(state, "on2", enabled: true)
        let json = covRender(mountDashboard(state).render())

        @Expect(statValueOf(json, "注册用户"), "3")
        @Expect(statValueOf(json, "禁用用户"), "1")
        @Expect(statValueOf(json, "上游总数"), "3")
        @Expect(statValueOf(json, "启用上游"), "2")
    }

    // 计划：running 单独计数（其它状态不计入）
    @TestCase
    public func covDashboard_planCountersCountRunningOnly(): Unit {
        let state = makePortalState("team")
        let p1 = state.adminData.createPlan("run-1", 0, 10, 600, 1000)
        let _ = state.adminData.updatePlanStatus(p1, "running", 0, 1000)
        let p2 = state.adminData.createPlan("run-2", 0, 10, 600, 1000)
        let _ = state.adminData.updatePlanStatus(p2, "running", 0, 1000)
        let p3 = state.adminData.createPlan("done", 0, 10, 600, 1000)
        let _ = state.adminData.updatePlanStatus(p3, "completed", 3, 1000)
        let json = covRender(mountDashboard(state).render())

        @Expect(statValueOf(json, "发布计划"), "3")
        @Expect(statValueOf(json, "执行中"), "2")
    }

    // 日志：总数 + failed 计数；最近操作表最多 8 条、按时间倒序
    @TestCase
    public func covDashboard_logsCountersAndRecentTable(): Unit {
        let state = makePortalState("team")
        for (i in 0..10) {
            let status = if (i % 5 == 0) { "failed" } else { "ok" }
            let _ = state.adminData.addLog(LogKind.Admin, 1, "admin", "op-${i}", status,
                1000 + i, target: "t-${i}", ipAddr: "1.1.1.1", userAgent: "ut")
        }
        let page = mountDashboard(state)
        let json = covRender(page.render())

        @Expect(statValueOf(json, "操作日志"), "10")
        @Expect(statValueOf(json, "失败操作"), "2")
        // 最近操作表：8 条（listLogs 的 limit）
        @Expect(page.recentLogs.get().size, 8)
        // 倒序：最新（op-9）在前，op-1 因只有 8 条被挤出（op-0 也出局）
        @Expect(page.recentLogs.get()[0].action, "op-9")
        @Expect(json.contains("op-9"), true)
        @Expect(json.contains("op-1\""), false)
        // 结果列：ok → 成功、failed → 失败
        @Expect(json.contains("成功"), true)
        @Expect(json.contains("失败"), true)
        @Expect(json.contains("admin"), true)
        @Expect(json.contains("t-9"), true)
    }

    // 时间戳为 0 时时间列显示「-」（formatLogTime 的 <= 0 分支）
    @TestCase
    public func covDashboard_zeroTimestampShowsDash(): Unit {
        let state = makePortalState("team")
        let _ = state.adminData.addLog(LogKind.Admin, 1, "admin", "no-time", "ok", 0)
        let json = covRender(mountDashboard(state).render())
        @Expect(json.contains("no-time"), true)
        @Expect(json.contains("\"-\""), true)
    }

    // refreshLogs 是公开动作点：清空日志后再刷新，表格跟着变空
    @TestCase
    public func covDashboard_refreshLogsReflectsStoreChanges(): Unit {
        let state = makePortalState("team")
        let _ = state.adminData.addLog(LogKind.Publish, 1, "admin", "publish a@1.0.0", "ok", 1000)
        let page = mountDashboard(state)
        @Expect(page.recentLogs.get().size, 1)

        state.adminData.clearLogs()
        page.refreshLogs()
        @Expect(page.recentLogs.get().size, 0)
        @Expect(statValueOf(covRender(page.render()), "操作日志"), "0")
    }

    // 未挂载 state：render 返回空 div（不抛异常），refreshLogs 走 None 分支
    @TestCase
    public func covDashboard_renderWithoutStateIsEmpty(): Unit {
        let page = DashboardPage()
        page.refreshLogs()
        @Expect(page.recentLogs.get().size, 0)
        let json = covRender(page.render())
        @Expect(json.contains("仪表盘"), false)
        @Expect(json.contains("stat-grid"), false)
        @Expect(json.contains("admin-layout"), false)
    }

    // 导出按钮所属的顶部区域存在：page-title / page-subtitle 两个 class 都渲染出来
    @TestCase
    public func covDashboard_hasTitleAndSubtitleClasses(): Unit {
        let state = makePortalState("team")
        let json = covRender(mountDashboard(state).render())
        @Expect(json.contains("page-title"), true)
        @Expect(json.contains("page-subtitle"), true)
        @Expect(json.contains("stat-grid"), true)
        @Expect(json.contains("最近操作"), true)
    }

    // 超长操作文案与超长错误不被截断（accessor 直出，宽度由列定义管）
    @TestCase
    public func covDashboard_longTextPassesThrough(): Unit {
        let state = makePortalState("team")
        let long = covLongText("x", 300)
        let _ = state.adminData.addLog(LogKind.Admin, 1, "admin", long, "failed", 1000,
            target: long, error: long)
        let json = covRender(mountDashboard(state).render())
        @Expect(json.contains(long), true)
        @Expect(statValueOf(json, "失败操作"), "1")
    }
}
