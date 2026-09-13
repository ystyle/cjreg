// cjxt 管理界面公共布局：侧边导航 + 页面容器
package ystyle::cjreg.ui

import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import ystyle::cjreg.auth.model.*
import ystyle::cjreg.config.*
import std.collection.*

let adminCSS = @importCSS("admin.css")
public func cls(name: String): String { adminCSS.get(name) }

// 站点名称（浏览器标签标题 + 品牌文字）：由 main.cj 启动时按 cjreg.toml 的 site_name 注入。
// 用包级变量而不是给每个页面传参：品牌文字是全局的，12 处 adminLayout 调用没必要都加参数。
public var SITE_NAME: String = DEFAULT_SITE_NAME

public func setSiteName(name: String): Unit {
    SITE_NAME = normalizeSiteName(name)
}

// 站点名解析：显式参数优先（便于单测），否则用启动时注入的包级值
func resolvedSiteName(explicit: String): String {
    if (explicit.isEmpty()) {
        return SITE_NAME
    }
    explicit
}

// 通用：侧边导航项
public func navLink(path: String, label: String, active: Bool): IComponent {
    let clsName = if (active) { cls("nav-item") + " " + cls("nav-active") } else { cls("nav-item") }
    div([text(label)], attrs: Some(HashMap<String, String>([("class", clsName)]))).onClick({ c =>
        c.route.push(path)
        PatchResult.ReRender
    })
}

// 侧边导航（activePath 高亮）— Menu/MenuItem 组件
public func adminSidebar(activePath: String, siteName!: String = ""): IComponent {
    let brandName = resolvedSiteName(siteName)
    let entries = ArrayList<(String, String)>()
    entries.add(("/admin", "仪表盘"))
    entries.add(("/admin/packages", "包管理"))
    entries.add(("/admin/upstreams", "上游管理"))
    entries.add(("/admin/publish-plans", "发布计划"))
    entries.add(("/admin/organizations", "组织管理"))
    entries.add(("/admin/teams", "团队管理"))
    entries.add(("/admin/users", "用户管理"))
    entries.add(("/admin/logs", "日志"))
    let menu = Menu()
        .dark()
    for ((path, label) in entries) {
        let go: ActionHandler = { c =>
            c.route.push(path)
            PatchResult.ReRender
        }
        menu.add(
            MenuItem(path, [text(label)])
                .active(path == activePath)
                .onClick(go)
        )
    }
    // 退出登录单独放一个暗色 Menu 里：MenuItem 一旦脱离 .el-menu，就拿不到 dark() 注入的
    // `--el-menu-text-color` 等变量 → 渲染成浅色主题，在深色侧栏上「看不清」。
    let logoutMenu = Menu().dark()
    logoutMenu.add(logoutMenuItem())
    div([
        div([text(brandName + " 管理")],
            attrs: Some(HashMap<String, String>([("class", cls("admin-brand"))]))),
        menu,
        logoutMenu,
    ], attrs: Some(HashMap<String, String>([("class", cls("admin-sidebar"))])))
}

// 纵向卡片栈：给相邻卡片之间留出间距。
// EP 的 .el-card 本身没有外边距，两张卡片直接做兄弟节点会**贴在一起**。
public func cardStack(children: Array<IComponent>): IComponent {
    div(children, attrs: Some(HashMap<String, String>([
        ("style", "display:flex;flex-direction:column;gap:16px")])))
}

// 退出登录：清除会话鉴权上下文 + 登录态信号，回到登录页
func logoutMenuItem(): MenuItem {
    let item = MenuItem("logout", [text("退出登录")])
    let go: ActionHandler = { c =>
        c.setContext("uid", "")
        c.setContext("username", "")
        c.setContext("isAdmin", "")
        c.setContext("token", "")
        try {
            c.getState<CjregState>().currentUser.set(Option<User>.None)
        } catch (e: Exception) {
            // 组件回调（用户点击「退出登录」）里吞异常：登录态信号没清掉也毫无线索，
            // 页面照样跳登录页，问题只在后续请求里以「还是登录着」的形式冒出来。
            println("[cjreg] 退出登录清空 currentUser 失败: " + e.toString())
        }
        c.route.push("/admin/login")
        PatchResult.ReRender
    }
    item.onClick(go)
}

// 页面主区容器
public func adminMain(children: Array<IComponent>): IComponent {
    div(children, attrs: Some(HashMap<String, String>([("class", cls("admin-main"))])))
}

// 完整布局：侧边 + 主区
public func adminLayout(activePath: String, children: Array<IComponent>, siteName!: String = ""): IComponent {
    div([
        adminSidebar(activePath, siteName: siteName),
        adminMain(children),
    ], attrs: Some(HashMap<String, String>([("class", cls("admin-layout"))])))
}

// 卡片容器 — Card 组件
public func adminCard(title: String, children: Array<IComponent>): IComponent {
    Card(children).header(title)
}

// 空态提示（列表无数据时）
public func emptyState(text: String): IComponent {
    div([
        Empty().description(text),
    ], attrs: Some(HashMap<String, String>([("class", cls("empty-line"))])))
}
