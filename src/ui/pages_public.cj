// cjxt 公开页面：首页 / 包列表 / 包详情 / 文档（无需登录）
// 对齐 cjrepo 公开页面（Vue + Element Plus）：首页 hero+统计+功能+CTA、包列表卡片网格+分类筛选、包详情 tab+侧栏
package ystyle::cjreg.ui

import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import ystyle::cjreg.store.*
import ystyle::cjreg.index.*
import ystyle::cjreg.semver_range.*
import std.collection.*
import std.convert.*
import std.time.*

// ===== 通用辅助 =====
func formatDownloadCount(count: Int64): String {
    if (count <= 0) { return "0" }
    if (count >= 10000) { return "${count / 10000}万" }
    if (count >= 1000) { return "${count / 1000}k" }
    return count.toString()
}

// 拆分 "org::name" 标识：无 "::" 时 org 为空
func splitPkgIdentifier(raw: String): (String, String) {
    let idx = raw.indexOf("::")
    if (idx.isSome()) {
        let i = idx.getOrThrow()
        return (raw[0..i], raw[i + 2..raw.size])
    }
    return ("", raw)
}

func pkgDisplayName(org: String, name: String): String {
    if (org.isEmpty()) { return name }
    "${org}::${name}"
}

// ===== 官方制品分类（对齐 cjrepo / 中心仓相关CJPM配置项.md） =====
// 返回 (分类名, 中文标签)；分类名与 meta-data 中 category 字段的标准值一致
func officialCategories(): ArrayList<(String, String)> {
    let list = ArrayList<(String, String)>()
    list.add(("Network", "网络"))
    list.add(("Database Driver", "数据库驱动"))
    list.add(("Data Encapsulation and Transfer", "数据封装传递"))
    list.add(("Data Analysis", "数据解析"))
    list.add(("Database Framework", "数据库框架"))
    list.add(("Object Storage", "对象存储"))
    list.add(("Distributed", "分布式"))
    list.add(("Task Scheduling", "任务调度"))
    list.add(("Security", "安全类"))
    list.add(("Utility", "工具类"))
    list.add(("Logging", "日志类"))
    list.add(("Algorithm", "算法类"))
    list.add(("Audio and Video", "音视频"))
    list.add(("Character Encoding", "字符编码"))
    list.add(("Image Processing", "图像处理"))
    list.add(("Developer Tools", "开发者工具"))
    list.add(("Animation", "动画类"))
    list.add(("Infrastructure", "基础设施"))
    list.add(("Geographic Information", "地理信息"))
    list.add(("UI", "UI 类"))
    list.add(("Scientific Computing", "科学计算"))
    list.add(("Programming Framework", "编程框架"))
    list.add(("Data Monitoring", "数据监控"))
    list.add(("Circuit Breaker and Downgrading", "熔断降级"))
    list.add(("Message Queue", "消息队列"))
    list
}

// 分类名 → 中文标签（未在官方列表时回退原名）
func categoryLabel(name: String): String {
    for ((cn, label) in officialCategories()) {
        if (cn == name) { return label }
    }
    name
}

// 分类名是否在官方列表内（用于包卡片显示中文标签时，无需额外校验）
func isOfficialCategory(name: String): Bool {
    for ((cn, _) in officialCategories()) {
        if (cn == name) { return true }
    }
    false
}

// 把一组分类名映射为中文标签列表
func categoryLabels(strs: ArrayList<String>): ArrayList<String> {
    let out = ArrayList<String>()
    for (s in strs) {
        out.add(categoryLabel(s))
    }
    out
}

// ===== 公开顶部导航 =====
public func publicNav(active: String): IComponent {
    let children = ArrayList<IComponent>()
    children.add(div([text("cjreg")], attrs: Some(HashMap<String, String>([("class", cls("public-brand"))]))))
    children.add(navLink("/", "首页", active == "/"))
    children.add(navLink("/packages", "包列表", active == "/packages"))
    children.add(navLink("/docs", "帮助文档", active == "/docs"))
    children.add(navLink("/admin", "管理后台", false))
    div(children.toArray(), attrs: Some(HashMap<String, String>([("class", cls("public-nav"))])))
}

// 功能卡（首页核心功能）
func featureCard(icon: String, title: String, desc: String, color: String): IComponent {
    div([
        div([
            Icon(icon).size("32px").color(color),
        ], attrs: Some(HashMap<String, String>([("class", cls("feature-icon")), ("style", "background-color:${color}20")]))),
        div([text(title)], attrs: Some(HashMap<String, String>([("class", cls("feature-title"))]))),
        div([text(desc)], attrs: Some(HashMap<String, String>([("class", cls("feature-desc"))]))),
    ], attrs: Some(HashMap<String, String>([("class", cls("feature-card"))])))
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

    func gotoDocs(ctx: ActionContext): PatchResult {
        ctx.route.push("/docs")
        PatchResult.ReRender
    }

    // 统计：包总数 = 最新版本包去重（org::name 唯一）；版本数 = 全部版本；下载 = 累计
    func collectStats(st: CjregState): (Int64, Int64, Int64, Int64) {
        let all = st.pkgStore.storm.all<PackageDoc>()
        var pkgTotal: Int64 = 0
        var versions: Int64 = 0
        var downloads: Int64 = 0
        let keys = ArrayList<String>()
        for (d in all) {
            if (d.deletedAt != 0) { continue }
            versions++
            downloads += d.downloadCount
            let key = d.organization + "::" + d.name
            var found = false
            for (k in keys) { if (k == key) { found = true; break } }
            if (!found) {
                keys.add(key)
                pkgTotal++
            }
        }
        (pkgTotal, versions, downloads, keys.size)
    }

    public func render(): IComponent {
        let st = match (this.state) {
            case Some(s) => s
            case None => return div([text("加载中...")])
        }
        let (pkgTotal, versions, downloads, _) = this.collectStats(st)
        let users = st.userStore.listAllUsers().size

        let stats = ArrayList<IComponent>()
        stats.add(statCard("${pkgTotal}", "包总数", "view", "#409eff"))
        stats.add(statCard("${versions}", "版本数", "more", "#f5576c"))
        stats.add(statCard("${users}", "用户数", "user", "#4facfe"))
        stats.add(statCard("${formatDownloadCount(downloads)}", "下载量", "arrow-down", "#43e97b"))

        let features = ArrayList<IComponent>()
        features.add(featureCard("view", "包管理", "轻松发布、管理和发现仓颉语言包", "#409EFF"))
        features.add(featureCard("arrow-down", "快速下载", "高速下载，支持版本管理和依赖解析", "#67C23A"))
        features.add(featureCard("more", "统计分析", "完整的统计信息和使用分析", "#E6A23C"))
        features.add(featureCard("edit", "版本控制", "支持多版本管理和回滚", "#F56C6C"))

        div([
            publicNav("/"),
            // Hero
            div([
                div([
                    div([text("发现和使用仓颉语言包")], attrs: Some(HashMap<String, String>([("class", cls("hero-title"))]))),
                    div([text("统一的包管理和分发平台，让仓颉开发更简单")], attrs: Some(HashMap<String, String>([("class", cls("hero-sub"))]))),
                    div([
                        Button([text("浏览包")]).kind(ButtonKind.Primary).size(ButtonSize.Large).onClick(gotoPackages),
                        Button([text("快速开始")]).size(ButtonSize.Large).onClick(gotoDocs),
                    ], attrs: Some(HashMap<String, String>([("class", cls("hero-actions"))]))),
                ], attrs: Some(HashMap<String, String>([("class", cls("hero"))]))),
            ], attrs: Some(HashMap<String, String>([("class", cls("hero-band"))]))),
            div([
                div([
                    div([text("平台统计")], attrs: Some(HashMap<String, String>([("class", cls("section-title"))]))),
                    div([text("实时数据展示平台活跃度")], attrs: Some(HashMap<String, String>([("class", cls("section-sub"))]))),
                ], attrs: Some(HashMap<String, String>([("class", cls("public-section-header"))]))),
                div(stats.toArray(), attrs: Some(HashMap<String, String>([("class", cls("stat-grid"))]))),
            ], attrs: Some(HashMap<String, String>([("class", cls("public-block"))]))),
            div([
                div([
                    div([text("核心功能")], attrs: Some(HashMap<String, String>([("class", cls("section-title"))]))),
                    div([text("强大的功能支持仓颉生态发展")], attrs: Some(HashMap<String, String>([("class", cls("section-sub"))]))),
                ], attrs: Some(HashMap<String, String>([("class", cls("public-section-header"))]))),
                div(features.toArray(), attrs: Some(HashMap<String, String>([("class", cls("features-grid"))]))),
            ], attrs: Some(HashMap<String, String>([("class", cls("public-block"))]))),
            div([
                div([
                    div([text("准备好开始了吗?")], attrs: Some(HashMap<String, String>([("class", cls("cta-title"))]))),
                    div([text("立即探索 cjreg，发现精彩的仓颉语言包")], attrs: Some(HashMap<String, String>([("class", cls("cta-sub"))]))),
                    div([
                        Button([text("探索包")]).kind(ButtonKind.Primary).size(ButtonSize.Large).onClick(gotoPackages),
                        Button([text("查看文档")]).size(ButtonSize.Large).onClick(gotoDocs),
                    ], attrs: Some(HashMap<String, String>([("class", cls("hero-actions"))]))),
                ], attrs: Some(HashMap<String, String>([("class", cls("cta"))]))),
            ], attrs: Some(HashMap<String, String>([("class", cls("cta-band"))]))),
        ])
    }
}

// ===== 包列表（卡片网格 + 分类筛选） =====
@Page["/packages"]
class PublicPackages <: Component {
    var state: Option<CjregState> = None
    var search = Signal<String>("")
    var selectedCategories = Signal<ArrayList<String>>(ArrayList<String>())
    var currentPage = Signal<Int64>(1)
    var pageSize = Signal<Int64>(12)

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
    }

    func gotoDetail(ctx: ActionContext, org: String, name: String): PatchResult {
        ctx.route.push("/packages/${pkgDisplayName(org, name)}")
        PatchResult.ReRender
    }

    // 取每个 org::name 的最新版本（按 semver 比较），返回包子集
    func collectLatest(all: ArrayList<PackageDoc>): ArrayList<PackageDoc> {
        let keys = ArrayList<String>()
        let result = ArrayList<PackageDoc>()
        for (d in all) {
            if (d.deletedAt != 0) { continue }
            let key = d.organization + "::" + d.name
            var idx = -1
            for (i in 0..keys.size) { if (keys[i] == key) { idx = i; break } }
            if (idx < 0) {
                keys.add(key)
                result.add(d)
            } else {
                if (compareVersions(d.version, result[idx].version) > 0) {
                    result[idx] = d
                }
            }
        }
        result
    }

    // 匹配：名称/描述/组织 包含搜索词；分类命中任一选中分类
    func matchesSearch(p: PackageDoc, q: String): Bool {
        if (q.isEmpty()) { return true }
        if (p.name.contains(q)) { return true }
        if (p.organization.contains(q)) { return true }
        if (p.description.contains(q)) { return true }
        return false
    }

    func matchesCategory(p: PackageDoc, cats: ArrayList<String>): Bool {
        if (cats.size == 0) { return true }
        for (c in p.category) {
            for (sel in cats) {
                if (c == sel) { return true }
            }
        }
        false
    }

    func loadPage(all: ArrayList<PackageDoc>): (ArrayList<PackageDoc>, Int64) {
        let latest = this.collectLatest(all)
        let q = this.search.get()
        let cats = this.selectedCategories.get()
        let filtered = ArrayList<PackageDoc>()
        for (p in latest) {
            let searchHit = this.matchesSearch(p, q)
            let catHit = this.matchesCategory(p, cats)
            if (searchHit && catHit) { filtered.add(p) }
        }
        let total = filtered.size
        let size = this.pageSize.get()
        let pageCount = if (total == 0) { 1 } else { (total + size - 1) / size }
        var page = this.currentPage.get()
        if (page > pageCount) { page = pageCount }
        if (page < 1) { page = 1 }
        let start = (page - 1) * size
        var end = start + size
        if (end > total) { end = total }
        let slice = ArrayList<PackageDoc>()
        if (start < total) {
            var i = start
            while (i < end) {
                slice.add(filtered[i])
                i++
            }
        }
        (slice, total)
    }

    func onSearch(ctx: ActionContext): PatchResult {
        this.currentPage.set(1)
        PatchResult.ReRender
    }

    func onSearchInput(ctx: ActionContext): PatchResult {
        this.currentPage.set(1)
        PatchResult.ReRender
    }

    func renderCard(p: PackageDoc): IComponent {
        let go: ActionHandler = { c => this.gotoDetail(c, p.organization, p.name) }
        let title = pkgDisplayName(p.organization, p.name)
        let header = ArrayList<IComponent>()
        header.add(div([text(if (p.organization.isEmpty()) { p.name } else { title })], attrs: Some(HashMap<String, String>([("class", cls("pkg-card-name"))]))))
        header.add(Tag([text(p.version)]).size(TagSize.Small).kind(ComponentKind.Success))
        let meta = ArrayList<IComponent>()
        meta.add(Tag([text(if (p.artifactType == "src") { "源码" } else { "二进制" })]).size(TagSize.Small).kind(if (p.artifactType == "src") { ComponentKind.Info } else { ComponentKind.Warning }))
        if (p.executable) { meta.add(Tag([text("可执行")]).size(TagSize.Small).kind(ComponentKind.Danger)) }
        if (p.license.size > 0) { meta.add(Tag([text(p.license[0])]).size(TagSize.Small).kind(ComponentKind.Primary)) }
        if (p.category.size > 0) { meta.add(Tag([text(categoryLabel(p.category[0]))]).size(TagSize.Small).kind(ComponentKind.Warning)) }
        var tagCount = 0
        for (t in p.tag) {
            if (tagCount >= 2) { break }
            meta.add(Tag([text(t)]).size(TagSize.Small))
            tagCount++
        }
        var card = div([
            div(header.toArray(), attrs: Some(HashMap<String, String>([("class", cls("pkg-card-header"))]))),
            div([text(if (p.description.isEmpty()) { "暂无描述" } else { p.description })], attrs: Some(HashMap<String, String>([("class", cls("pkg-card-desc"))]))),
            div([
                Icon("arrow-down").size("14px").color("#909399"),
                span([text(formatDownloadCount(p.downloadCount))], attrs: Some(HashMap<String, String>([("class", cls("pkg-card-download"))]))),
            ], attrs: Some(HashMap<String, String>([("class", cls("pkg-card-stats"))]))),
            div(meta.toArray(), attrs: Some(HashMap<String, String>([("class", cls("pkg-card-meta"))]))),
        ], attrs: Some(HashMap<String, String>([("class", cls("pkg-card"))])))
        card = card.onClick(go)
        card
    }

    public func render(): IComponent {
        let st = match (this.state) {
            case Some(x) => x
            case None => return div()
        }
        let all = st.pkgStore.storm.all<PackageDoc>()
        let (rows, total) = this.loadPage(all)
        let cats = officialCategories()

        let categoryItems = ArrayList<IComponent>()
        for ((cn, label) in cats) {
            categoryItems.add(Checkbox([text(label)], cn))
        }
        let sidebar = div([
            div([
                Icon("more").size("16px").color("#303133"),
                span([text("分类筛选")], attrs: Some(HashMap<String, String>([("class", cls("sidebar-title"))]))),
            ], attrs: Some(HashMap<String, String>([("class", cls("sidebar-header"))]))),
            if (categoryItems.size == 0) {
                div([text("暂无分类")], attrs: Some(HashMap<String, String>([("class", cls("sidebar-empty"))])))
            } else {
                CheckboxGroup(categoryItems.toArray()).bind(this.selectedCategories)
            },
        ], attrs: Some(HashMap<String, String>([("class", cls("pkg-sidebar"))])))

        let cards = ArrayList<IComponent>()
        for (p in rows) {
            cards.add(this.renderCard(p))
        }

        let pager = Pagination()
            .currentPage(this.currentPage)
            .pageSize(this.pageSize)
            .pageSizes([12, 24, 48, 96])
            .total(total)
            .background()
            .layout("total, sizes, prev, pager, next, jumper")
            .onChange(onSearch)

        div([
            publicNav("/packages"),
            div([
                div([
                    div([text("发现仓颉包")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
                    div([text("浏览和搜索仓颉生态系统中的精彩包")], attrs: Some(HashMap<String, String>([("class", cls("page-subtitle"))]))),
                    div([
                        Input().bind(this.search).placeholder("搜索包名、描述，或使用 org::关键词 格式搜索组织包...").on("input", { ctx => this.onSearchInput(ctx) }),
                    ], attrs: Some(HashMap<String, String>([("class", cls("search-box"))]))),
                ], attrs: Some(HashMap<String, String>([("class", cls("search-section"))]))),
                div([
                    div([
                        sidebar,
                        div([
                            if (cards.size == 0) {
                                Empty().description(if (total == 0) { "没有找到匹配的包" } else { "暂无包数据" })
                            } else {
                                div(cards.toArray(), attrs: Some(HashMap<String, String>([("class", cls("pkg-grid"))])))
                            },
                            if (cards.size > 0) {
                                div([pager], attrs: Some(HashMap<String, String>([("class", cls("pager-wrap"))])))
                            } else {
                                div([])
                            },
                        ], attrs: Some(HashMap<String, String>([("class", cls("pkg-list"))]))),
                    ], attrs: Some(HashMap<String, String>([("class", cls("pkg-layout"))]))),
                ], attrs: Some(HashMap<String, String>([("class", cls("public-block"))]))),
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
    var versionRows = Signal<ArrayList<PackageDoc>>(ArrayList<PackageDoc>())
    var activeTab = Signal<String>("overview")
    var depTab = Signal<String>("source")

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        match (ctx.route.params.get("name")) {
            case Some(n) =>
                let (org, name) = splitPkgIdentifier(n)
                this.pkgOrg = org
                this.pkgName = name
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
                    if (d.deletedAt != 0) { continue }
                    if (d.name != this.pkgName) { continue }
                    if (!this.pkgOrg.isEmpty() && d.organization != this.pkgOrg) { continue }
                    versions.add(d)
                }
                // 最新在前（semver 降序）
                let sorted = ArrayList<PackageDoc>()
                for (d in versions) {
                    var inserted = false
                    for (i in 0..sorted.size) {
                        if (compareVersions(d.version, sorted[i].version) > 0) {
                            sorted.add(d, at: i)
                            inserted = true
                            break
                        }
                    }
                    if (!inserted) { sorted.add(d) }
                }
                this.versionRows.set(sorted)
            case None => ()
        }
    }

    // 最新版本（第一个）
    func latest(): ?PackageDoc {
        let vs = this.versionRows.get()
        if (vs.size == 0) { return None }
        Some(vs[0])
    }

    func renderInfoItems(p: PackageDoc, totals: Int64): Array<IComponent> {
        let items = ArrayList<IComponent>()
        items.add(this.infoItem("最新版本", [Tag([text(p.version)]).kind(ComponentKind.Success)]))
        items.add(this.infoItem("组织", [Tag([text(if (p.organization.isEmpty()) { "默认" } else { p.organization })]).kind(ComponentKind.Primary)]))
        if (!p.cjcVersion.isEmpty()) { items.add(this.infoItem("SDK 版本", [Tag([text(p.cjcVersion)]).kind(ComponentKind.Info)])) }
        items.add(this.infoItem("类型", [Tag([text(if (p.artifactType == "src") { "源码" } else { "二进制" })]).kind(if (p.artifactType == "src") { ComponentKind.Info } else { ComponentKind.Warning })]))
        if (p.executable) { items.add(this.infoItem("可执行", [Tag([text("是")]).kind(ComponentKind.Danger)])) }
        if (p.license.size > 0) {
            items.add(this.infoItem("协议", this.tags(p.license, ComponentKind.Success)))
        }
        if (p.category.size > 0) {
            items.add(this.infoItem("分类", this.tags(categoryLabels(p.category), ComponentKind.Warning)))
        }
        if (p.tag.size > 0) {
            items.add(this.infoItem("标签", this.tags(p.tag, ComponentKind.Info)))
        }
        if (p.authors.size > 0) {
            let authorText = String.join(p.authors.toArray(), delimiter: ", ")
            items.add(this.infoItem("作者", [text(authorText)]))
        }
        if (!p.repository.isEmpty()) {
            items.add(this.infoItem("仓库", [linkOut(p.repository, "查看代码")]))
        }
        if (!p.homepage.isEmpty()) {
            items.add(this.infoItem("主页", [linkOut(p.homepage, "访问主页")]))
        }
        if (!p.documentation.isEmpty()) {
            items.add(this.infoItem("文档", [linkOut(p.documentation, "查看文档")]))
        }
        if (p.tarballSize > 0) {
            items.add(this.infoItem("包大小", [text(this.formatSize(p.tarballSize))]))
        }
        items.add(this.infoItem("下载次数", [text(formatDownloadCount(totals))]))
        items.toArray()
    }

    func infoItem(label: String, content: Array<IComponent>): IComponent {
        div([
            span([text(label)], attrs: Some(HashMap<String, String>([("class", cls("info-label"))]))),
            div(content, attrs: Some(HashMap<String, String>([("class", cls("info-value"))]))),
        ], attrs: Some(HashMap<String, String>([("class", cls("info-item"))])))
    }

    // 头部 meta 行内单项（label + 内容并排）
    func metaItem(label: String, content: Array<IComponent>): IComponent {
        div([
            span([text(label)], attrs: Some(HashMap<String, String>([("class", cls("meta-label"))]))),
            div(content, attrs: Some(HashMap<String, String>([("class", cls("meta-value"))]))),
        ], attrs: Some(HashMap<String, String>([("class", cls("detail-meta-item"))])))
    }

    func tags(strs: ArrayList<String>, kind: ComponentKind): Array<IComponent> {
        let arr = ArrayList<IComponent>()
        for (s in strs) {
            arr.add(Tag([text(s)]).size(TagSize.Small).kind(kind))
        }
        arr.toArray()
    }

    func formatSize(bytes: Int64): String {
        if (bytes <= 0) { return "0 B" }
        let k = 1024
        if (bytes < k) { return "${bytes} B" }
        if (bytes < k * k) { return "${bytes / k} KB" }
        if (bytes < k * k * k) { return "${bytes / (k * k)} MB" }
        return "${bytes / (k * k * k)} GB"
    }

    func depEntry(dep: DependencyEntry): IComponent {
        let go: ActionHandler = { c => c.route.push("/packages/${dep.name}"); PatchResult.ReRender }
        let depsMain = ArrayList<IComponent>()
        let nameEl = div([text(dep.name)], attrs: Some(HashMap<String, String>([("class", cls("dep-name"))])))
        var nameNode = nameEl
        nameNode = nameNode.onClick(go)
        depsMain.add(nameNode)
        depsMain.add(Tag([text(dep.require)]).size(TagSize.Small).kind(ComponentKind.Info))
        let meta = ArrayList<IComponent>()
        if (!dep.target.isEmpty()) { meta.add(text("目标: ${dep.target}")) }
        if (!dep.mode.isEmpty()) { meta.add(text("模式: ${dep.mode}")) }
        if (!dep.outputType.isEmpty()) { meta.add(text("类型: ${dep.outputType}")) }
        let children = ArrayList<IComponent>()
        children.add(div(depsMain.toArray(), attrs: Some(HashMap<String, String>([("class", cls("dep-main"))]))))
        if (meta.size > 0) {
            children.add(div(meta.toArray(), attrs: Some(HashMap<String, String>([("class", cls("dep-meta"))]))))
        }
        div(children.toArray(), attrs: Some(HashMap<String, String>([("class", cls("dep-item"))])))
    }

    func depList(deps: ArrayList<DependencyEntry>, emptyText: String): IComponent {
        if (deps.size == 0) {
            return Empty().description(emptyText)
        }
        let items = ArrayList<IComponent>()
        for (d in deps) {
            items.add(this.depEntry(d))
        }
        div(items.toArray(), attrs: Some(HashMap<String, String>([("class", cls("dep-list"))])))
    }

    func parseIndex(d: PackageDoc): ?PackageIndex {
        let entries = parseNDJSON(d.indexJson)
        if (entries.size == 0) { return None }
        Some(entries[0])
    }

    func installToml(p: PackageDoc, org: String, name: String): String {
        if (org.isEmpty()) {
            "${name} = { version = '${p.version}' }"
        } else {
            "'${org}::${name}' = { version = '${p.version}' }"
        }
    }

    public func render(): IComponent {
        let latestOpt = this.latest()
        match (latestOpt) {
            case None =>
                return div([
                    publicNav("/packages"),
                    div([emptyState("未找到该包")], attrs: Some(HashMap<String, String>([("class", cls("public-main"))]))),
                ])
            case Some(p) => return this.renderDetail(p)
        }
    }

    func renderDetail(p: PackageDoc): IComponent {
        let vs = this.versionRows.get()
        var totals: Int64 = 0
        for (v in vs) { totals += v.downloadCount }
        let displayName = pkgDisplayName(this.pkgOrg, this.pkgName)

        // header meta 行
        let headerMeta = ArrayList<IComponent>()
        headerMeta.add(this.metaItem("更新于", [text(reqDateText(vs.toArray()))]))
        if (p.category.size > 0) {
            headerMeta.add(this.metaItem("分类", this.tags(categoryLabels(p.category), ComponentKind.Warning)))
        }
        if (p.tag.size > 0) {
            headerMeta.add(this.metaItem("标签", this.tags(p.tag, ComponentKind.Info)))
        }

        // 概览 tab：README
        let overviewContent = if (p.readme.isEmpty()) {
            Empty().description("暂无 README 文档")
        } else {
            Markdown().content(p.readme)
        }

        // 依赖 tab
        let depIndex = this.parseIndex(p)
        let deps = match (depIndex) {
            case Some(idx) => idx.dependencies
            case None => ArrayList<DependencyEntry>()
        }
        let testDeps = match (depIndex) {
            case Some(idx) => idx.testDependencies
            case None => ArrayList<DependencyEntry>()
        }
        let scriptDeps = match (depIndex) {
            case Some(idx) => idx.scriptDependencies
            case None => ArrayList<DependencyEntry>()
        }
        let depTabContent = Tabs([
            TabPane([this.depList(deps, "暂无源码依赖")], "source", "源码依赖"),
            TabPane([this.depList(testDeps, "暂无测试依赖")], "test", "测试依赖"),
            TabPane([this.depList(scriptDeps, "暂无构建脚本依赖")], "script", "构建脚本依赖"),
        ]).bind(this.depTab).tabType("card")

        // 版本历史 tab
        let versionItems = ArrayList<IComponent>()
        for (v in vs) {
            let verMain = ArrayList<IComponent>()
            verMain.add(span([text(v.version)], attrs: Some(HashMap<String, String>([("class", cls("version-number"))]))))
            if (v.version == p.version) {
                verMain.add(Tag([text("最新")]).size(TagSize.Small).kind(ComponentKind.Success))
            }
            verMain.add(span([text("发布于 " + reqDateText([v]))], attrs: Some(HashMap<String, String>([("class", cls("version-date"))]))))
            versionItems.add(div(verMain.toArray(), attrs: Some(HashMap<String, String>([("class", cls("version-item"))]))))
        }

        let installTomlText = this.installToml(p, this.pkgOrg, this.pkgName)

        let contentTabs = Tabs([
            TabPane([overviewContent], "overview", "概览"),
            TabPane([depTabContent], "dependencies", "依赖"),
            TabPane([div(versionItems.toArray(), attrs: Some(HashMap<String, String>([("class", cls("versions-card"))])))], "versions", "版本历史"),
        ]).bind(this.activeTab)

        let sidebar = div([
            div([text("包信息")], attrs: Some(HashMap<String, String>([("class", cls("sidebar-head-title"))]))),
            div(this.renderInfoItems(p, totals), attrs: Some(HashMap<String, String>([("class", cls("info-list"))]))),
            div([text("使用指南")], attrs: Some(HashMap<String, String>([("class", cls("sidebar-head-title"))]))),
            div([text("添加到 cjpm.toml 的 dependencies 部分")], attrs: Some(HashMap<String, String>([("class", cls("usage-tip"))]))),
            div([
                div([text(installTomlText)], attrs: Some(HashMap<String, String>([("class", cls("code-block"))]))),
            ], attrs: Some(HashMap<String, String>([("class", cls("usage-block"))]))),
        ], attrs: Some(HashMap<String, String>([("class", cls("sidebar-card"))])))

        let header = div([
            div([
                span([text(displayName)], attrs: Some(HashMap<String, String>([("class", cls("detail-name"))]))),
                Tag([text(p.version)]).kind(ComponentKind.Success).size(TagSize.Large),
            ], attrs: Some(HashMap<String, String>([("class", cls("detail-title-row"))]))),
            div([text(if (p.description.isEmpty()) { "暂无描述" } else { p.description })], attrs: Some(HashMap<String, String>([("class", cls("detail-desc"))]))),
            div(headerMeta.toArray(), attrs: Some(HashMap<String, String>([("class", cls("detail-meta"))]))),
        ], attrs: Some(HashMap<String, String>([("class", cls("detail-header"))])))

        div([
            publicNav("/packages"),
            div([
                header,
                Row([
                    Col([contentTabs], span: 16),
                    Col([sidebar], span: 8),
                ], gutter: 24),
            ], attrs: Some(HashMap<String, String>([("class", cls("public-main"))]))),
        ])
    }
}

// "更新于/发布于" 文本：取版本列表最早 createdAt（简化：列表第一个的时间）
func reqDateText(vs: Array<PackageDoc>): String {
    if (vs.size == 0) { return "未知" }
    let t = vs[0].updatedAt
    if (t <= 0) { return "未知" }
    DateTime.fromUnixTimeStamp(Duration.millisecond * t).inLocal().format("yyyy-MM-dd HH:mm")
}

// 外链（新窗口打开）：用 target=_blank 的 <a>
func linkOut(url: String, text_: String): IComponent {
    VNode("a", [text(text_)], attrs: Some(HashMap<String, String>([
        ("class", cls("info-link")), ("href", url), ("target", "_blank"), ("rel", "noreferrer")
    ])))
}

// ===== 文档页（VitePress 风格：左导航 + markdown 内容） =====
@Page["/docs", "文档"]
class DocsPage <: Component {
    var activeDoc = Signal<String>(docsDefaultId())

    func navItem(sid: String, title: String, active: Bool): IComponent {
        let clsName = if (active) { cls("docs-nav-item") + " " + cls("docs-nav-active") } else { cls("docs-nav-item") }
        div([text(title)], attrs: Some(HashMap<String, String>([("class", clsName)]))).onClick({ c =>
            this.activeDoc.set(sid)
            PatchResult.ReRender
        })
    }

    public func render(): IComponent {
        let sections = docsSections()
        let active = this.activeDoc.get()
        let navItems = ArrayList<IComponent>()
        for ((sid, title) in sections) {
            navItems.add(this.navItem(sid, title, sid == active))
        }
        let content = docContent(if (docsIdValid(active)) { active } else { docsDefaultId() })
        div([
            publicNav("/docs"),
            div([
                div(navItems.toArray(), attrs: Some(HashMap<String, String>([("class", cls("docs-nav"))]))),
                div([
                    Markdown().content(content),
                ], attrs: Some(HashMap<String, String>([("class", cls("docs-content"))]))),
            ], attrs: Some(HashMap<String, String>([("class", cls("docs-layout"))]))),
        ])
    }
}
