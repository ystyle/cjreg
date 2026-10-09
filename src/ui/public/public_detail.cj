// 公开端包详情（@Page /packages/[name]）
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

// ===== 包详情 =====
@Page["/packages/[name]"]
class PublicPackageDetail <: Component {
    var state: Option<CjregState> = None
    var sctx: Option<SessionContext> = None
    var pkgName: String = ""
    var pkgOrg: String = ""
    var versionRows = Signal<ArrayList<PackageDoc>>(ArrayList<PackageDoc>())
    var activeTab = Signal<String>("overview")
    var depTab = Signal<String>("source")

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        this.sctx = ctx.getSessionContext()
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
            items.add(this.infoItem("包大小", [text(formatBytesText(p.tarballSize))]))
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
            "${name} = \"${p.version}\""
        } else {
            "'${org}::${name}' = \"${p.version}\""
        }
    }

    // 返回包列表（包详情头部返回按钮）
    func gotoPackages(ctx: ActionContext): PatchResult {
        ctx.route.push("/packages")
        PatchResult.ReRender
    }

    public func render(): IComponent {
        let latestOpt = this.latest()
        match (latestOpt) {
            case None =>
                return div([
                    publicNav("/packages", this.sctx),
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
        headerMeta.add(this.metaItem("时间", [text(reqDateText(vs.toArray()))]))
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
            verMain.add(span([text(versionTimeText(v))], attrs: Some(HashMap<String, String>([("class", cls("version-date"))]))))
            // 制品大小 + sha256 缩写（悬停看完整 sha）：和后台版本列表同一口径
            let sizeText = versionSizeText(v)
            if (!sizeText.isEmpty()) {
                verMain.add(span([text(sizeText)], attrs: Some(HashMap<String, String>([("class", cls("version-size"))]))))
            }
            if (!v.sha256.isEmpty()) {
                verMain.add(span([text("sha256 " + shortShaText(v.sha256))],
                    attrs: Some(HashMap<String, String>([("class", cls("version-sha")), ("title", v.sha256)]))))
            }
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

        let backBtn = Button("返回").icon("arrow-left").plain().onClick(gotoPackages)
        let header = div([
            div([
                div([
                    span([text(displayName)], attrs: Some(HashMap<String, String>([("class", cls("detail-name"))]))),
                    Tag([text(p.version)]).kind(ComponentKind.Success).size(TagSize.Large),
                ], attrs: Some(HashMap<String, String>([("class", cls("detail-title-left"))]))),
                backBtn,
            ], attrs: Some(HashMap<String, String>([("class", cls("detail-title-row"))]))),
            div([text(if (p.description.isEmpty()) { "暂无描述" } else { p.description })], attrs: Some(HashMap<String, String>([("class", cls("detail-desc"))]))),
            div(headerMeta.toArray(), attrs: Some(HashMap<String, String>([("class", cls("detail-meta"))]))),
        ], attrs: Some(HashMap<String, String>([("class", cls("detail-header"))])))

        div([
            publicNav("/packages", this.sctx),
            div([
                header,
                div([
                    div([div([contentTabs], attrs: Some(HashMap<String, String>([("class", cls("detail-card"))])))], attrs: Some(HashMap<String, String>([("class", cls("detail-left"))]))),
                    div([sidebar], attrs: Some(HashMap<String, String>([("class", cls("detail-right"))]))),
                ], attrs: Some(HashMap<String, String>([("class", cls("detail-row"))]))),
            ], attrs: Some(HashMap<String, String>([("class", cls("public-main"))]))),
        ])
    }
}
