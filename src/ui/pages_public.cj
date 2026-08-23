// cjxt 公开页面：首页 / 包列表 / 包详情 / 文档（无需登录）
package ystyle::cjreg.ui

import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import ystyle::cjreg.store.*
import ystyle::cjreg.index.*
import std.collection.*
import std.convert.*

// ===== 公开顶部导航 =====
public func publicNav(active: String): IComponent {
    let children = ArrayList<IComponent>()
    children.add(div([text("cjreg")], attrs: Some(HashMap<String, String>([("class", cls("brand"))]))))
    children.add(navLink("/", "首页", active == "/"))
    children.add(navLink("/packages", "包列表", active == "/packages"))
    children.add(navLink("/docs", "文档", active == "/docs"))
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
            if (d.deletedAt != 0) { continue }
            versions++
            downloads += d.downloadCount
        }
        let users = st.userStore.listAllUsers().size
        let stats = ArrayList<IComponent>()
        stats.add(statCard("${all.size}", "包总数", "view", "#409eff"))
        stats.add(statCard("${versions}", "版本总数", "more", "#409eff"))
        stats.add(statCard("${users}", "注册用户", "user", "#e6a23c"))
        stats.add(statCard("${downloads}", "累计下载", "arrow-down", "#67c23a"))
        div([
            publicNav("/"),
            div([
                div([
                    div([text("仓颉私有中心仓")], attrs: Some(HashMap<String, String>([("class", cls("hero-title"))]))),
                    div([text("多仓配置 · 依赖解析 · 私有化部署")], attrs: Some(HashMap<String, String>([("class", cls("hero-sub"))]))),
                    div([
                        Button([text("浏览包列表")]).kind(ButtonKind.Primary).onClick(gotoPackages),
                    ], attrs: Some(HashMap<String, String>([("class", cls("toolbar"))]))),
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
    // 行数据 + 分页（泛型 Table<PackageDoc>）
    var rows = Signal<ArrayList<PackageDoc>>(ArrayList<PackageDoc>())
    var search = Signal<String>("")
    var orgFilter = Signal<String>("all")
    var currentPage = Signal<Int64>(1)
    var pageSize = Signal<Int64>(20)
    var total = Signal<Int64>(0)

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        refresh()
    }

    func refresh(): Unit {
        match (this.state) {
            case Some(st) =>
                let all = st.pkgStore.storm.all<PackageDoc>()
                let filtered = ArrayList<PackageDoc>()
                for (d in all) {
                    if (d.deletedAt != 0) { continue }
                    if (this.orgFilter.get() != "all" && d.organization != this.orgFilter.get()) {
                        continue
                    }
                    if (this.search.get() != "" && !d.name.contains(this.search.get())) {
                        continue
                    }
                    filtered.add(d)
                }
                this.total.set(filtered.size)
                let (start, end) = pageWindow(filtered.size, this.currentPage.get(), this.pageSize.get())
                let data = ArrayList<PackageDoc>()
                var i = start
                while (i < end) {
                    data.add(filtered[i])
                    i++
                }
                this.rows.set(data)
            case None => ()
        }
    }

    func onPageChange(ctx: ActionContext): PatchResult {
        this.refresh()
        PatchResult.ReRender
    }

    func gotoDetail(ctx: ActionContext, name: String): PatchResult {
        ctx.route.push("/packages/${name}")
        PatchResult.ReRender
    }

    func renderList(): IComponent {
        if (this.rows.get().size == 0) {
            return emptyState("暂无包数据")
        }
        Table<PackageDoc>()
            .data(this.rows)
            .stripe()
            .onRowClick({ d, i, ctx => this.gotoDetail(ctx, d.name) })
            .add(TableColumn<PackageDoc>().label("包名").accessor({ d => d.name }).minWidth(140))
            .add(TableColumn<PackageDoc>().label("组织").accessor({ d => if (d.organization.isEmpty()) { "-" } else { d.organization } }).width(100))
            .add(TableColumn<PackageDoc>().label("版本").accessor({ d => d.version }).width(120))
            .add(TableColumn<PackageDoc>().label("描述").accessor({ d => d.description }).minWidth(260).showOverflowTooltip())
            .add(TableColumn<PackageDoc>().label("下载").accessor({ d => d.downloadCount.toString() }).width(90))
            .add(TableColumn<PackageDoc>().label("操作").width(90).render({ d, i =>
                let detailH: ActionHandler = { c => this.gotoDetail(c, d.name) }
                Button([text("详情")]).size(ButtonSize.Small).onClick(detailH)
            }))
    }

    func doSearch(ctx: ActionContext): PatchResult {
        this.currentPage.set(1)
        this.refresh()
        PatchResult.ReRender
    }

    public func render(): IComponent {
        let st = match (this.state) {
            case Some(x) => x
            case None => return div()
        }
        let orgOptions = ArrayList<IComponent>()
        orgOptions.add(SelectOption([text("全部组织")], "all"))
        let seen = ArrayList<String>()
        for (d in st.pkgStore.storm.all<PackageDoc>()) {
            if (d.deletedAt != 0) { continue }
            var dup = false
            for (s in seen) {
                if (s == d.organization) {
                    dup = true
                    break
                }
            }
            if (!dup && d.organization != "") {
                orgOptions.add(SelectOption([text(d.organization)], d.organization))
                seen.add(d.organization)
            }
        }
        let toolbar = div([
            Input().bind(this.search).placeholder("搜索包名").on("input", { _ =>
                this.currentPage.set(1)
                this.refresh()
                PatchResult.ReRender
            }),
            Select(orgOptions.toArray()).bind(this.orgFilter).placeholder("组织"),
            Button([text("搜索")]).onClick(doSearch),
        ], attrs: Some(HashMap<String, String>([("class", cls("toolbar"))])))
        let pager = Pagination()
            .currentPage(this.currentPage)
            .pageSize(this.pageSize)
            .total(this.total.get())
            .layout("total, prev, pager, next, sizes")
            .onChange(onPageChange)
        div([
            publicNav("/packages"),
            div([
                div([text("包列表")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
                adminCard("全部包", [toolbar, this.renderList(), pager]),
            ], attrs: Some(HashMap<String, String>([("class", cls("public-main"))]))),
        ])
    }
}

// ===== 包详情 =====
@Page["/packages/[name]"]
class PublicPackageDetail <: Component {
    var state: Option<CjregState> = None
    var pkgName: String = ""
    var pkgOrg: String = ""
    var pkgVersion: String = ""
    var pkgDesc: String = ""
    var pkgAuthors: String = ""
    var pkgRepo: String = ""
    var pkgHomepage: String = ""
    var pkgDocs: String = ""
    var pkgLicense: String = ""
    var pkgType: String = ""
    var pkgReadme: String = ""
    var depsJson: String = ""
    var versionRows = Signal<ArrayList<PackageDoc>>(ArrayList<PackageDoc>())

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
                let versions = ArrayList<PackageDoc>()
                for (d in all) {
                    if (d.name == this.pkgName && d.deletedAt == 0) {
                        this.pkgOrg = d.organization
                        this.pkgVersion = d.version
                        this.pkgDesc = d.description
                        this.pkgAuthors = String.join(d.authors.toArray(), delimiter: ", ")
                        this.pkgRepo = d.repository
                        this.pkgHomepage = d.homepage
                        this.pkgDocs = d.documentation
                        this.pkgLicense = String.join(d.license.toArray(), delimiter: ", ")
                        this.pkgType = d.artifactType
                        this.pkgReadme = d.readme
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
                        // 版本列表
                        versions.add(d)
                    }
                }
                // 全量版本（含软删？只显示正常）
                for (d in st.pkgStore.listVersions(this.pkgOrg, this.pkgName)) {
                    if (d.deletedAt == 0) {
                        var dup = false
                        for (existing in versions) {
                            if (existing.version == d.version) {
                                dup = true
                                break
                            }
                        }
                        if (!dup) {
                            versions.add(d)
                        }
                    }
                }
                this.versionRows.set(versions)
            case None => ()
        }
    }

    public func render(): IComponent {
        let installToml = if (this.pkgOrg.isEmpty()) {
            "${this.pkgName} = { version = '${this.pkgVersion}' }"
        } else {
            "'${this.pkgOrg}::${this.pkgName}' = { version = '${this.pkgVersion}' }"
        }
        let versionTable = Table<PackageDoc>()
            .data(this.versionRows)
            .stripe()
            .add(TableColumn<PackageDoc>().label("版本").accessor({ d => d.version }))
            .add(TableColumn<PackageDoc>().label("下载").accessor({ d => d.downloadCount.toString() }).width(100))
        div([
            publicNav("/packages"),
            div([
                div([text("${this.pkgName}@${this.pkgVersion}")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
                adminCard("包信息", [
                    Descriptions()
                        .border()
                        .column(2)
                        .labelWidth("100px")
                        .add(DescriptionsItem().label("名称").children([text(this.pkgName)]))
                        .add(DescriptionsItem().label("组织").children([text(if (this.pkgOrg.isEmpty()) { "-" } else { this.pkgOrg })]))
                        .add(DescriptionsItem().label("版本").children([text(this.pkgVersion)]))
                        .add(DescriptionsItem().label("描述").children([text(this.pkgDesc)]))
                        .add(DescriptionsItem().label("类型").children([text(this.pkgType)]))
                        .add(DescriptionsItem().label("作者").children([text(this.pkgAuthors)]))
                        .add(DescriptionsItem().label("仓库").children([text(this.pkgRepo)]))
                        .add(DescriptionsItem().label("主页").children([text(this.pkgHomepage)]))
                        .add(DescriptionsItem().label("文档").children([text(this.pkgDocs)]))
                        .add(DescriptionsItem().label("许可证").children([text(this.pkgLicense)])),
                ]),
                adminCard("依赖", [
                    if (this.depsJson == "[]") {
                        div([text("无依赖")])
                    } else {
                        div([text(this.depsJson)])
                    },
                ]),
                adminCard("版本历史", [versionTable]),
                adminCard("README", [
                    if (this.pkgReadme.isEmpty()) {
                        div([text("无 README")])
                    } else {
                        Markdown().content(this.pkgReadme)
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

// ===== 文档页 =====
@Page["/docs", "文档"]
class DocsPage <: Component {
    public func render(): IComponent {
        div([
            publicNav("/docs"),
            div([
                div([text("使用文档")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
                adminCard("快速开始", [
                    div([
                        div([text("1. 初始化数据目录（创建管理员 + 官方上游）：")]),
                        div([text("cjreg init -d ./data --username admin --password <密码>")], attrs: Some(HashMap<String, String>([("class", cls("code-block"))]))),
                        div([text("2. 启动服务：")]),
                        div([text("cjreg serve -d ./data -p 8060")], attrs: Some(HashMap<String, String>([("class", cls("code-block"))]))),
                        div([text("3. 浏览器访问管理后台 http://localhost:8060/admin 登录。")]),
                    ]),
                ]),
                adminCard("客户端配置", [
                    div([
                        div([text("在 cjpm.toml 中配置私有仓依赖（registry 指向本服务）：")]),
                        div([text("name = \"my-app\"\nversion = \"0.1.0\"\n\n[dependencies]\n'demo::demo-app' = { version = '1.0.0' }")], attrs: Some(HashMap<String, String>([("class", cls("code-block"))]))),
                        div([text("发布配置（cangjie-repo.toml）：")]),
                        div([text("[registry]\nurl = \"http://localhost:8060\"\ntoken = \"<用户在管理后台获取的发布 Token>\"")], attrs: Some(HashMap<String, String>([("class", cls("code-block"))]))),
                    ]),
                ]),
                adminCard("多仓与代理", [
                    div([
                        div([text("在上游管理中配置镜像仓：官方仓不可删除，镜像仓可配置认证 Token 与缓存时间。")]),
                        div([text("依赖解析按优先级选择上游，本地无缓存时自动回源拉取并落库。")]),
                    ]),
                ]),
                adminCard("发布计划", [
                    div([
                        div([text("创建发布计划：选择目标上游与要发布的包，系统按依赖拓扑排序后推送。")]),
                        div([text("详情页可查看每个包的执行状态与错误信息。")]),
                    ]),
                ]),
            ], attrs: Some(HashMap<String, String>([("class", cls("public-main"))]))),
        ])
    }
}
