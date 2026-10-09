// 管理端仪表盘（@Page /admin）
package ystyle::cjreg.ui.admin

import ystyle::cjreg.ui.public.*
import ystyle::cjreg.ui.*
import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import ystyle::cjreg.store.*
import ystyle::cjreg.config.*
import ystyle::cjreg.server.{BlobStore, LifecycleOutcome, LifecycleResult, MemoryBlobStore, RefetchOutcome, hardDeleteVersion, refetchVersion, restoreVersion, shortSha, softDeleteVersion}
import ystyle::cjreg.semver_range.*
import std.collection.*
import std.convert.*
import std.sort.*
import std.time.*

@Page["/admin", "仪表盘", requireAdmin]
class DashboardPage <: Component {
    var state: Option<CjregState> = None
    // 最近操作日志（Table 信号）
    var recentLogs = Signal<ArrayList<LogDoc>>(ArrayList<LogDoc>())

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        refreshLogs()
    }

    func refreshLogs(): Unit {
        match (this.state) {
            case Some(st) =>
                let logs = st.adminData.listLogs(Option<String>.None, 8)
                let data = ArrayList<LogDoc>()
                for (l in logs) { data.add(l) }
                this.recentLogs.set(data)
            case None => ()
        }
    }

    public func render(): IComponent {
        let st = match (this.state) {
            case Some(s) => s
            case None => return div()
        }
        let allPkgs = st.pkgStore.storm.all<PackageDoc>()
        var versions: Int64 = 0
        var downloads: Int64 = 0
        var deletedPkgs: Int64 = 0
        for (d in allPkgs) {
            if (d.deletedAt != 0) {
                deletedPkgs++
            } else {
                versions++
            }
            downloads += d.downloadCount
        }
        // 用户
        let users = st.userStore.listAllUsers()
        var disabledUsers: Int64 = 0
        for (u in users) {
            if (!u.isActive) { disabledUsers++ }
        }
        // 上游
        let ups = st.upStore.listAll()
        var enabledUps: Int64 = 0
        for (u in ups) {
            if (u.enabled) { enabledUps++ }
        }
        // 计划
        let plans = st.adminData.listPlans()
        var runningPlans: Int64 = 0
        for (p in plans) {
            if (p.status == "running") { runningPlans++ }
        }
        // 日志
        let logs = st.adminData.listLogs(Option<String>.None, 1000)
        var failedLogs: Int64 = 0
        for (l in logs) {
            if (l.status == "failed") { failedLogs++ }
        }
        let stats = ArrayList<IComponent>()
        stats.add(statCard("${allPkgs.size}", "包总数", "view", "#409eff"))
        stats.add(statCard("${versions}", "发布版本", "more", "#409eff"))
        stats.add(statCard("${downloads}", "累计下载", "arrow-down", "#67c23a"))
        stats.add(statCard("${deletedPkgs}", "软删包", "circle-close", "#f56c6c"))
        stats.add(statCard("${users.size}", "注册用户", "user", "#e6a23c"))
        stats.add(statCard("${disabledUsers}", "禁用用户", "lock", "#f56c6c"))
        stats.add(statCard("${ups.size}", "上游总数", "arrow-up", "#409eff"))
        stats.add(statCard("${enabledUps}", "启用上游", "check", "#67c23a"))
        stats.add(statCard("${plans.size}", "发布计划", "calendar", "#9b59b6"))
        stats.add(statCard("${runningPlans}", "执行中", "loading", "#e6a23c"))
        stats.add(statCard("${logs.size}", "操作日志", "edit", "#909399"))
        stats.add(statCard("${failedLogs}", "失败操作", "error-filled", "#f56c6c"))
        // 最近操作
        let recentTable = Table<LogDoc>()
            .data(this.recentLogs)
            .stripe()
            .add(TableColumn<LogDoc>().label("时间").width(150).render({ l, i =>
                timeCell(formatLogTime(l.createdAt))
            }))
            .add(TableColumn<LogDoc>().label("操作者").accessor({ l => l.actorName }).width(110))
            .add(TableColumn<LogDoc>().label("操作").accessor({ l => l.action }).minWidth(260).showOverflowTooltip())
            .add(TableColumn<LogDoc>().label("对象").accessor({ l => l.target }).minWidth(150).showOverflowTooltip())
            .add(TableColumn<LogDoc>().label("结果").width(80).render({ l, i =>
                if (l.status == "ok") {
                    Tag([text("成功")]).kind(ComponentKind.Success)
                } else {
                    Tag([text("失败")]).kind(ComponentKind.Danger)
                }
            }))
        adminLayout("/admin", [
            div([text("仪表盘")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            div([text("仓库运行概览")], attrs: Some(HashMap<String, String>([("class", cls("page-subtitle"))]))),
            div(stats.toArray(), attrs: Some(HashMap<String, String>([("class", cls("stat-grid"))]))),
            adminCard("最近操作", [recentTable]),
        ])
    }
}
