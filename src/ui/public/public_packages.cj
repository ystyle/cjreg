// 公开端包列表（@Page /packages）
package ystyle::cjreg.ui.public

import ystyle::cjreg.ui.*
import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import ystyle::cjreg.store.*
import ystyle::cjreg.index.*
import ystyle::cjreg.semver_range.*
import std.collection.*
import std.convert.*
import std.time.*

// ===== 包列表（卡片网格 + 分类筛选） =====
@Page["/packages"]
class PublicPackages <: Component {
    var state: Option<CjregState> = None
    var sctx: Option<SessionContext> = None
    var search = Signal<String>("")
    var selectedCategories = Signal<ArrayList<String>>(ArrayList<String>())
    var currentPage = Signal<Int64>(1)
    var pageSize = Signal<Int64>(12)

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        this.sctx = ctx.getSessionContext()
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
            publicNav("/packages", this.sctx),
            div([
                div([
                    div([text("发现仓颉包")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
                    div([text("浏览和搜索仓颉生态系统中的精彩包")], attrs: Some(HashMap<String, String>([("class", cls("page-subtitle"))]))),
                    div([
                        Input().bind(this.search).placeholder("搜索包名、描述，或使用 org::关键词 格式搜索组织包..."),
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
                ], attrs: Some(HashMap<String, String>([("class", cls("pkg-block"))]))),
            ], attrs: Some(HashMap<String, String>([("class", cls("public-main"))]))),
        ])
    }
}
