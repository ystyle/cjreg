// 公开端文档页（@Page /docs）
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

// ===== 文档页（VitePress 风格：左导航 + markdown 内容） =====
@Page["/docs", "文档"]
class DocsPage <: Component {
    var activeDoc = Signal<String>(docsDefaultId())
    var sctx: Option<SessionContext> = None
    // 服务配置（对外地址/端口）：文档里的地址与 registry 示例显示配置值
    var state: Option<CjregState> = None

    public func onMount(ctx: LifecycleContext): Unit {
        this.sctx = ctx.getSessionContext()
        this.state = Some(ctx.getState<CjregState>())
    }

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
        let st = match (this.state) {
            case Some(x) => x
            case None => return div()
        }
        let content = docContent(if (docsIdValid(active)) { active } else { docsDefaultId() }, st.config)
        div([
            publicNav("/docs", this.sctx),
            div([
                div(navItems.toArray(), attrs: Some(HashMap<String, String>([("class", cls("docs-nav"))]))),
                div([
                    Markdown().content(content),
                ], attrs: Some(HashMap<String, String>([("class", cls("docs-content"))]))),
            ], attrs: Some(HashMap<String, String>([("class", cls("docs-layout"))]))),
        ])
    }
}
