// 公开端首页（@Page /）
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

// ===== 首页 =====
@Page["/"]
class PublicHome <: Component {
    var state: Option<CjregState> = None
    // 会话上下文（渲染期读登录态，决定导航显示「登录」还是「管理后台」）
    var sctx: Option<SessionContext> = None

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        this.sctx = ctx.getSessionContext()
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
            publicNav("/", this.sctx),
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
