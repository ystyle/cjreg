// 公开端各页面共用：导航/分类/字节与版本展示等辅助
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
// sctx = 会话上下文（cjxt SessionContext 接口，页面 onMount 取、render 期读）：
// 未登录 → 「登录」入口（用户门户 /user/login）；已登录 → 「我的」（/me）；
// 管理员额外显示「管理后台」入口（登录后才显示管理入口）。
// 注意必须在 render() 里读：令牌恢复后的就地重渲不会重跑 onMount。
public func publicNav(active: String, sctx: Option<SessionContext>, siteName!: String = ""): IComponent {
    let isAdmin = match (sctx) {
        case Some(s) => s.isAdmin
        case None => false
    }
    let loggedIn = match (sctx) {
        case Some(s) => s.uid > 0
        case None => false
    }
    let children = ArrayList<IComponent>()
    let brandGo: ActionHandler = { c => c.route.push("/"); PatchResult.ReRender }
    var brand = div([text(if (siteName.isEmpty()) { SITE_NAME } else { siteName })],
        attrs: Some(HashMap<String, String>([("class", cls("public-brand"))])))
    brand = brand.onClick(brandGo)
    children.add(brand)
    children.add(navLink("/", "首页", active == "/"))
    children.add(navLink("/packages", "包列表", active == "/packages"))
    children.add(navLink("/docs", "帮助文档", active == "/docs"))
    if (loggedIn) {
        children.add(navLink("/me", "我的", active == "/me"))
    } else {
        children.add(navLink("/user/login", "登录", active == "/user/login"))
    }
    if (isAdmin) {
        children.add(navLink("/admin", "管理后台", false))
    }
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

// 制品字节数 → 可读体积（包级：侧栏与版本历史共用）
public func formatBytesText(bytes: Int64): String {
    if (bytes <= 0) { return "0 B" }
    let k = 1024
    if (bytes < k) { return "${bytes} B" }
    if (bytes < k * k) { return "${bytes / k} KB" }
    if (bytes < k * k * k) { return "${bytes / (k * k)} MB" }
    return "${bytes / (k * k * k)} GB"
}

// sha256 缩写（版本历史里展示；完整值挂 title 悬停）
public func shortShaText(sha: String): String {
    if (sha.size <= 12) {
        return sha
    }
    return sha[0..12]
}

// 版本历史的制品大小文案：拿不到（老回源版本没补过 size）就空串，不留占位符
public func versionSizeText(d: PackageDoc): String {
    if (d.tarballSize <= 0) {
        return ""
    }
    return formatBytesText(d.tarballSize)
}

// 版本时间：本地发布的版本是「发布于」（cjreg 就是发布方），
// 回源镜像的版本只有「本仓收录于」（上游发布时间不在索引协议里，拿不到）
public func versionTimeMs(d: PackageDoc): Int64 {
    if (d.upstreamId == 0) {
        return d.createdAt
    }
    if (d.createdAt > 0) {
        return d.createdAt
    }
    return d.updatedAt
}

public func versionTimePrefix(d: PackageDoc): String {
    if (d.upstreamId == 0) {
        return "发布于 "
    }
    return "收录于 "
}

public func versionTimeText(d: PackageDoc): String {
    let t = versionTimeMs(d)
    if (t <= 0) {
        return "时间未知"
    }
    versionTimePrefix(d) + DateTime.fromUnixTimeStamp(Duration.millisecond * t).inLocal().format("yyyy-MM-dd HH:mm")
}

// 详情页头部时间：优先「更新于」（真实事件），没有则退回版本时间文案
func reqDateText(vs: Array<PackageDoc>): String {
    if (vs.size == 0) { return "未知" }
    let t = vs[0].updatedAt
    if (t > 0) {
        return "更新于 " + DateTime.fromUnixTimeStamp(Duration.millisecond * t).inLocal().format("yyyy-MM-dd HH:mm")
    }
    return versionTimeText(vs[0])
}

// 外链（新窗口打开）：用 target=_blank 的 <a>
func linkOut(url: String, text_: String): IComponent {
    VNode("a", [text(text_)], attrs: Some(HashMap<String, String>([
        ("class", cls("info-link")), ("href", url), ("target", "_blank"), ("rel", "noreferrer")
    ])))
}
