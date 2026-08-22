// cjxt 公开页面：首页 / 包列表 / 包详情（无需登录）
package ystyle::cjreg.ui

import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import ystyle::cjreg.store.*
import ystyle::cjreg.index.*
import std.collection.*

// ===== 公开顶部导航 =====
public func publicNav(active: String): IComponent {
    let children = ArrayList<IComponent>()
    children.add(div([text("cjreg")], attrs: Some(HashMap<String, String>([("class", cls("brand"))]))))
    children.add(navLink("/", "首页", active == "/"))
    children.add(navLink("/packages", "包列表", active == "/packages"))
    children.add(navLink("/admin", "管理后台", false))
    children.add(navLink("/admin/login", "登录", false))
    div(children.toArray(), attrs: Some(HashMap<String, String>([("class", cls("public-nav"))])))
}

// ===== 首页 =====
@Page["/"]
class PublicHome <: Component {
    var state: Option<CjregState> = None

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
    }

    func gotoPackages(ctx: ActionContext): PatchResult {
        ctx.route.push("/packages")
        PatchResult.ReRender
    }

    public func render(): IComponent {
        let st = match (this.state) {
            case Some(s) => s
            case None => return div([text("加载中...")])
        }
        let all = st.pkgStore.storm.all<PackageDoc>()
        var versions: Int64 = 0
        var downloads: Int64 = 0
        for (d in all) {
            versions++
            downloads += d.downloadCount
        }
        let users = st.userStore.listAllUsers().size
        let stats = ArrayList<IComponent>()
        stats.add(statCard("${all.size}", "包总数"))
        stats.add(statCard("${versions}", "版本总数"))
        stats.add(statCard("${users}", "注册用户"))
        stats.add(statCard("${downloads}", "累计下载"))
        div([
            publicNav("/"),
            div([
                div([
                    div([text("仓颉私有中心仓")], attrs: Some(HashMap<String, String>([("class", cls("hero-title"))]))),
                    div([text("多仓配置 · 依赖解析 · 私有化部署")], attrs: Some(HashMap<String, String>([("class", cls("hero-sub"))]))),
                    Button([text("浏览包列表")]).kind(ButtonKind.Primary).onClick(gotoPackages),
                ], attrs: Some(HashMap<String, String>([("class", cls("hero"))]))),
                div(stats.toArray(), attrs: Some(HashMap<String, String>([("class", cls("stat-grid"))]))),
            ], attrs: Some(HashMap<String, String>([("class", cls("public-main"))]))),
        ])
    }
}

// ===== 包列表 =====
@Page["/packages"]
class PublicPackages <: Component {
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
                    if (d.deletedAt != 0) {
                        continue
                    }
                    if (this.search.get() != "" && !d.name.contains(this.search.get())) {
                        continue
                    }
                    let m = HashMap<String, String>()
                    m["id"] = d.id.toString()
                    m["name"] = d.name
                    m["org"] = if (d.organization.isEmpty()) { "-" } else { d.organization }
                    m["version"] = d.version
                    m["downloads"] = d.downloadCount.toString()
                    data.add(m)
                }
                this.rows.set(data)
            case None => ()
        }
    }

    public func render(): IComponent {
        let toolbar = div([
            Input().bind(this.search).placeholder("搜索包名").on("input", { _ =>
                this.refresh()
                PatchResult.ReRender
            }),
            Button([text("搜索")]).onClick(doSearch),
        ], attrs: Some(HashMap<String, String>([("class", cls("toolbar"))])))
        let table = Table()
            .data(this.rows)
            .stripe()
            .add(TableColumn().label("包名").colProp("name"))
            .add(TableColumn().label("组织").colProp("org").width(120))
            .add(TableColumn().label("版本").colProp("version").width(120))
            .add(TableColumn().label("下载").colProp("downloads").width(80))
        div([
            publicNav("/packages"),
            div([
                div([text("包列表")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
                adminCard("全部包", [toolbar, table]),
            ], attrs: Some(HashMap<String, String>([("class", cls("public-main"))]))),
        ])
    }

    func doSearch(ctx: ActionContext): PatchResult {
        this.refresh()
        PatchResult.ReRender
    }
}

// ===== 包详情 =====
@Page["/packages/[name]"]
class PublicPackageDetail <: Component {
    var state: Option<CjregState> = None
    var pkgName: String = ""
    var pkgOrg: String = ""
    var pkgVersion: String = ""
    var depsJson: String = ""

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        match (ctx.route.params.get("name")) {
            case Some(n) =>
                this.pkgName = n
                loadPkg()
            case None => ()
        }
    }

    func loadPkg(): Unit {
        match (this.state) {
            case Some(st) =>
                let all = st.pkgStore.storm.all<PackageDoc>()
                for (d in all) {
                    if (d.name == this.pkgName && d.deletedAt == 0) {
                        this.pkgOrg = d.organization
                        this.pkgVersion = d.version
                        // 解析 meta 里的依赖
                        let entries = parseNDJSON(d.indexJson)
                        if (entries.size > 0) {
                            let sb = StringBuilder()
                            sb.append("[")
                            for (i in 0..entries[0].dependencies.size) {
                                let dep = entries[0].dependencies[i]
                                if (i > 0) { sb.append(",") }
                                sb.append("${dep.name}@${dep.require}")
                            }
                            sb.append("]")
                            this.depsJson = sb.toString()
                        }
                        break
                    }
                }
            case None => ()
        }
    }

    public func render(): IComponent {
        let installToml = if (this.pkgOrg.isEmpty()) {
            "${this.pkgName} = { version = '${this.pkgVersion}' }"
        } else {
            "'${this.pkgOrg}::${this.pkgName}' = { version = '${this.pkgVersion}' }"
        }
        div([
            publicNav("/packages"),
            div([
                div([text("${this.pkgName}@${this.pkgVersion}")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
                adminCard("包信息", [
                    div([
                        div([text("名称: ${this.pkgName}")]),
                        div([text("组织: ${if (this.pkgOrg.isEmpty()) { "-" } else { this.pkgOrg }}")]),
                        div([text("版本: ${this.pkgVersion}")]),
                    ]),
                ]),
                adminCard("依赖", [
                    if (this.depsJson == "[]") {
                        div([text("无依赖")])
                    } else {
                        div([text(this.depsJson)])
                    },
                ]),
                adminCard("安装", [
                    div([
                        div([text("在 cjpm.toml 中添加：")]),
                        div([text(installToml)], attrs: Some(HashMap<String, String>([("class", cls("code-block"))]))),
                    ]),
                ]),
            ], attrs: Some(HashMap<String, String>([("class", cls("public-main"))]))),
        ])
    }
}
