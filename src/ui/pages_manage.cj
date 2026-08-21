// cjxt 管理界面页面：仪表盘 / 上游管理 / 包管理
package ystyle::cjreg.ui

import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import ystyle::cjreg.store.*
import ystyle::cjreg.config.*
import std.collection.*
import std.convert.*

// ===== 仪表盘 =====
@Page["/admin"]
class DashboardPage <: Component {
    var state: Option<CjregState> = None

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
    }

    public func render(): IComponent {
        let st = match (this.state) {
            case Some(s) => s
            case None => return div()
        }
        let pkgCount = st.pkgStore.storm.all<PackageDoc>().size
        let userCount = st.userStore.listAllUsers().size
        let upCount = st.upStore.listAll().size
        let planCount = st.adminData.listPlans().size
        let logCount = st.adminData.listLogs(Option<String>.None, 1000).size
        let stats = ArrayList<IComponent>()
        stats.add(statCard("${pkgCount}", "包总数"))
        stats.add(statCard("${userCount}", "用户数"))
        stats.add(statCard("${upCount}", "上游数"))
        stats.add(statCard("${planCount}", "发布计划"))
        stats.add(statCard("${logCount}", "日志条数"))
        adminLayout("/admin", [
            div([text("仪表盘")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            div(stats.toArray(), attrs: Some(HashMap<String, String>([("class", cls("stat-grid"))]))),
        ])
    }
}

func statCard(value: String, label: String): IComponent {
    div([
        div([text(value)], attrs: Some(HashMap<String, String>([("class", cls("stat-value"))]))),
        div([text(label)], attrs: Some(HashMap<String, String>([("class", cls("stat-label"))]))),
    ], attrs: Some(HashMap<String, String>([("class", cls("stat-card"))])))
}

// ===== 上游管理 =====
@Page["/admin/upstreams"]
class UpstreamsPage <: Component {
    var state: Option<CjregState> = None
    var rows = Signal<ArrayList<HashMap<String, String>>>(ArrayList<HashMap<String, String>>())
    var newName = Signal<String>("")
    var newUrl = Signal<String>("")
    var newPriority = Signal<String>("0")
    var msg = Signal<String>("")

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        refresh()
    }

    func refresh(): Unit {
        match (this.state) {
            case Some(st) =>
                let list = st.upStore.listAll()
                let data = ArrayList<HashMap<String, String>>()
                for (u in list) {
                    let m = HashMap<String, String>()
                    m["id"] = u.id.toString()
                    m["name"] = u.name
                    m["url"] = u.url
                    m["enabled"] = if (u.enabled) { "是" } else { "否" }
                    m["official"] = if (u.isOfficial) { "官方" } else { "镜像" }
                    m["priority"] = u.priority.toString()
                    data.add(m)
                }
                this.rows.set(data)
            case None => ()
        }
    }

    public func render(): IComponent {
        let toolbar = div([
            Input().bind(this.newName).placeholder("名称"),
            Input().bind(this.newUrl).placeholder("URL"),
            Input().bind(this.newPriority).placeholder("优先级"),
            Button([text("添加上游")]).kind(ButtonKind.Primary).onClick(addUpstream),
            if (this.msg.get() != "") {
                Tag([text(this.msg.get())]).kind(ComponentKind.Success)
            } else {
                div()
            },
        ], attrs: Some(HashMap<String, String>([("class", cls("toolbar"))])))
        let table = Table()
            .data(this.rows)
            .stripe()
            .add(TableColumn().label("ID").colProp("id").width(60))
            .add(TableColumn().label("名称").colProp("name"))
            .add(TableColumn().label("URL").colProp("url"))
            .add(TableColumn().label("类型").colProp("official").width(80))
            .add(TableColumn().label("状态").colProp("enabled").width(80))
            .add(TableColumn().label("优先级").colProp("priority").width(80))
        adminLayout("/admin/upstreams", [
            div([text("上游管理")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            adminCard("多仓上游配置", [toolbar, table]),
        ])
    }

    func addUpstream(ctx: ActionContext): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (this.newName.get().isEmpty() || this.newUrl.get().isEmpty()) {
            this.msg.set("名称和 URL 必填")
            return PatchResult.ReRender
        }
        let priority = Int64.parse(this.newPriority.get())
        match (st.upStore.getByName(this.newName.get())) {
            case Some(_) =>
                this.msg.set("上游已存在")
                return PatchResult.ReRender
            case None => ()
        }
        let upSvc = UpstreamService(st.upStore)
        match (upSvc.add(this.newName.get(), this.newUrl.get(), priority, "", 0)) {
            case Some(u) =>
                this.newName.set("")
                this.newUrl.set("")
                this.msg.set("已添加 ${u.name}")
                st.adminData.addLog(LogKind.Admin, 0, "admin", "add upstream ${u.name}", "ok", nowMs())
            case None =>
                this.msg.set("添加失败")
        }
        refresh()
        PatchResult.ReRender
    }
}

// ===== 包管理 =====
@Page["/admin/packages"]
class PackagesPage <: Component {
    var state: Option<CjregState> = None
    var rows = Signal<ArrayList<HashMap<String, String>>>(ArrayList<HashMap<String, String>>())
    var search = Signal<String>("")

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        refresh()
    }

    func refresh(): Unit {
        match (this.state) {
            case Some(st) =>
                let all = st.pkgStore.storm.all<PackageDoc>()
                let data = ArrayList<HashMap<String, String>>()
                for (d in all) {
                    if (this.search.get() != "" && !d.name.contains(this.search.get())) {
                        continue
                    }
                    let m = HashMap<String, String>()
                    m["id"] = d.id.toString()
                    m["org"] = d.organization
                    m["name"] = d.name
                    m["version"] = d.version
                    m["downloads"] = d.downloadCount.toString()
                    m["deleted"] = if (d.deletedAt != 0) { "已删" } else { "正常" }
                    data.add(m)
                }
                this.rows.set(data)
            case None => ()
        }
    }

    func doRefresh(ctx: ActionContext): PatchResult {
        this.refresh()
        PatchResult.ReRender
    }

    public func render(): IComponent {
        let toolbar = div([
            Input().bind(this.search).placeholder("搜索包名").on("input", { _ =>
                this.refresh()
                PatchResult.ReRender
            }),
            Button([text("刷新")]).onClick(doRefresh),
        ], attrs: Some(HashMap<String, String>([("class", cls("toolbar"))])))
        let table = Table()
            .data(this.rows)
            .stripe()
            .add(TableColumn().label("ID").colProp("id").width(60))
            .add(TableColumn().label("组织").colProp("org").width(100))
            .add(TableColumn().label("包名").colProp("name"))
            .add(TableColumn().label("版本").colProp("version").width(120))
            .add(TableColumn().label("下载").colProp("downloads").width(80))
            .add(TableColumn().label("状态").colProp("deleted").width(80))
        adminLayout("/admin/packages", [
            div([text("包管理")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            adminCard("已发布包", [toolbar, table]),
        ])
    }
}
