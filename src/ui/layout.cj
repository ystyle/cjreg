// cjxt 管理界面公共布局：侧边导航 + 页面容器
package ystyle::cjreg.ui

import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import ystyle::cjreg.auth.model.*
import std.collection.*

let adminCSS = @importCSS("admin.css")
public func cls(name: String): String { adminCSS.get(name) }

// 通用：侧边导航项
public func navLink(path: String, label: String, active: Bool): IComponent {
    let clsName = if (active) { cls("nav-item") + " " + cls("nav-active") } else { cls("nav-item") }
    div([text(label)], attrs: Some(HashMap<String, String>([("class", clsName)]))).onClick({ c =>
        c.route.push(path)
        PatchResult.ReRender
    })
}

// 侧边导航（activePath 高亮）
public func adminSidebar(activePath: String): IComponent {
    let items = HashMap<String, String>([
        ("/admin", "仪表盘"),
        ("/admin/packages", "包管理"),
        ("/admin/upstreams", "上游管理"),
        ("/admin/publish-plans", "发布计划"),
        ("/admin/organizations", "组织管理"),
        ("/admin/teams", "团队管理"),
        ("/admin/users", "用户管理"),
        ("/admin/logs", "日志"),
    ])
    let children = ArrayList<IComponent>()
    children.add(div([text("cjreg 管理")], attrs: Some(HashMap<String, String>([("class", cls("admin-brand"))]))))
    for ((path, label) in items) {
        let active = path == activePath
        children.add(navLink(path, label, active))
    }
    children.add(logoutNav())
    div(children.toArray(), attrs: Some(HashMap<String, String>([("class", cls("admin-sidebar"))])))
}

// 退出登录：清除会话鉴权上下文 + 登录态信号，回到登录页
func logoutNav(): IComponent {
    let item = div([text("退出登录")], attrs: Some(HashMap<String, String>([("class", cls("nav-item"))])))
    item.onClick({ c =>
        c.setContext("uid", "")
        c.setContext("username", "")
        c.setContext("isAdmin", "")
        c.setContext("token", "")
        try {
            c.getState<CjregState>().currentUser.set(Option<User>.None)
        } catch (e: Exception) { () }
        c.route.push("/admin/login")
        PatchResult.ReRender
    })
}

// 页面主区容器
public func adminMain(children: Array<IComponent>): IComponent {
    div(children, attrs: Some(HashMap<String, String>([("class", cls("admin-main"))])))
}

// 完整布局：侧边 + 主区
public func adminLayout(activePath: String, children: Array<IComponent>): IComponent {
    div([
        adminSidebar(activePath),
        adminMain(children),
    ], attrs: Some(HashMap<String, String>([("class", cls("admin-layout"))])))
}

// 卡片容器
public func adminCard(title: String, children: Array<IComponent>): IComponent {
    div([
        div([text(title)], attrs: Some(HashMap<String, String>([("class", cls("admin-card-title"))]))),
        div(children),
    ], attrs: Some(HashMap<String, String>([("class", cls("admin-card"))])))
}

// 空态提示（列表无数据时）
public func emptyState(text: String): IComponent {
    div([
        Empty().description(text),
    ], attrs: Some(HashMap<String, String>([("class", cls("empty-line"))])))
}
