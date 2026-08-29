// 公开文档站点：章节列表 + markdown 内容（对齐 VitePress 导航/内容模式，用 cjxt Markdown 渲染）
package ystyle::cjreg.ui

import std.collection.*

// 章节列表：(id, title)
public func docsSections(): ArrayList<(String, String)> {
    let l = ArrayList<(String, String)>()
    l.add(("quickstart", "快速开始"))
    l.add(("client-config", "客户端配置"))
    l.add(("publish", "发布包"))
    l.add(("multi-repo", "多仓与代理"))
    l.add(("publish-plan", "发布计划"))
    l.add(("permission", "访问控制"))
    l
}

// 章节 id 索引校验：id 非法时返回 quickstart
public func docsDefaultId(): String { "quickstart" }

public func docsIdValid(id: String): Bool {
    for ((sid, _) in docsSections()) {
        if (sid == id) { return true }
    }
    false
}

// 各章节 markdown 内容
public func docContent(id: String): String {
    match (id) {
        case "quickstart" => return docQuickstart()
        case "client-config" => return docClientConfig()
        case "publish" => return docPublish()
        case "multi-repo" => return docMultiRepo()
        case "publish-plan" => return docPublishPlan()
        case "permission" => return docPermission()
        case _ => return docQuickstart()
    }
}

func docQuickstart(): String {
    "# 快速开始\n\n"
    + "**cjreg** 是仓颉私有中心仓与多仓工具，提供包发布 / 下载 / 索引 / 依赖解析 / 上游代理与一键部署能力。\n\n"
    + "## 1. 初始化数据目录\n\n"
    + "首次使用需创建首个管理员并写入默认官方上游：\n\n"
    + "```shell\n"
    + "cjreg init -d ./data --username admin --password <强口令>\n"
    + "```\n\n"
    + "## 2. 启动服务\n\n"
    + "```shell\n"
    + "cjreg serve -d ./data -p 8060\n"
    + "```\n\n"
    + "服务启动后，浏览器访问管理后台：\n\n"
    + "- 管理后台：`http://localhost:8060/admin`\n"
    + "- 公开首页：`http://localhost:8060/`\n\n"
    + "## 3. 体验\n\n"
    + "管理后台可用 `admin` / 初始化密码登录，查看仪表盘、包管理、上游管理、发布计划等。"
}

func docClientConfig(): String {
    "# 客户端配置\n\n"
    + "## cjpm.toml 依赖\n\n"
    + "在项目 `cjpm.toml` 的 `[dependencies]` 中配置来自本仓的依赖（registry 指向本服务）：\n\n"
    + "```toml\n"
    + "name = \"my-app\"\n"
    + "version = \"0.1.0\"\n\n"
    + "[dependencies]\n"
    + "'demo::demo-app' = { version = '1.0.0' }\n"
    + "```\n\n"
    + "- 无组织包：`name = { version = 'x.y.z' }`\n"
    + "- 有组织包：`'org::name' = { version = 'x.y.z' }`\n\n"
    + "## 发布配置 cangjie-repo.toml\n\n"
    + "发布时需要配置 registry 地址与发布 Token（管理后台「用户管理」获取）：\n\n"
    + "```toml\n"
    + "[repository.home]\n"
    + "registry = \"http://localhost:8060\"\n"
    + "token = \"<发布 Token>\"\n"
    + "```"
}

func docPublish(): String {
    "# 发布包\n\n"
    + "进入管理后台 → 包管理 → 发布包，填写 meta-data 信息并上传制品。\n\n"
    + "## 发布要求\n\n"
    + "- 模块名 / 组织名长度 `[3, 64]`，不能为仓颉关键字；组织名不能为 `default`。\n"
    + "- `cjpm.toml` 需包含 `description`。\n"
    + "- 根目录需包含 `README_zh.md` 或 `README.md`。\n\n"
    + "## 访问控制\n\n"
    + "发布遵循服务端权限模式：\n\n"
    + "- **open 模式（默认）**：有效 Token 即可发布，发布者会被记录。\n"
    + "- **team 模式**：需团队/组织/包关联，并按权限级别（read / write / overwrite）校验。\n\n"
    + "切换模式见「访问控制」章节。"
}

func docMultiRepo(): String {
    "# 多仓与代理\n\n"
    + "在管理后台 → 上游管理 中配置镜像仓：\n\n"
    + "- **官方仓**：默认存在，不可删除（上游为 `https://pkg.cangjie-lang.cn/registry`）。\n"
    + "- **镜像仓**：可新增，配置认证 Token 与缓存时间。\n\n"
    + "## 依赖解析\n\n"
    + "依赖解析按上游优先级选择，本地缓存未命中时自动回源拉取并落库。可通过「回源缓存」缩略图判断是否命中本地缓存。\n\n"
    + "## 仓库同步\n\n"
    + "「发布计划」可将本地包按依赖拓扑排序推送至目标上游。"
}

func docPublishPlan(): String {
    "# 发布计划\n\n"
    + "发布计划用于把本地包批量发布到目标上游，按依赖拓扑排序执行。\n\n"
    + "## 使用流程\n\n"
    + "1. 创建发布计划：选择目标上游。\n"
    + "2. 添加待发布的包（支持从仓库/上游拉取）。\n"
    + "3. 启动计划：按依赖顺序逐个推送。\n"
    + "4. 详情页可查看每个包的执行状态与错误信息，支持暂停 / 恢复。"
}

func docPermission(): String {
    "# 访问控制\n\n"
    + "cjreg 提供两种发布权限模式，通过环境变量 `CJREG_PERMISSION_MODE` 切换：\n\n"
    + "## open 模式（默认）\n\n"
    + "- 适合小企业内部先试用。\n"
    + "- 任何持有有效发布 Token 的用户均可发布（新包 / 新版本）。\n"
    + "- 发布者仍会被记录，作为审计基础。\n\n"
    + "## team 模式\n\n"
    + "- 适合组织化 / 权限严格管控。\n"
    + "- 校验团队、组织、包的关联关系，并按权限级别（read=1 / write=2 / overwrite=3）校验。\n"
    + "- 新包首发布免权（有效 Token），新版本需 write，覆盖版本需 overwrite。\n\n"
    + "## 权限矩阵\n\n"
    + "| 场景 | open | team |\n"
    + "| --- | --- | --- |\n"
    + "| 新包首发布 | 有效 Token | 有效 Token |\n"
    + "| 新版本 | 有效 Token | 成员 + write |\n"
    + "| 覆盖版本 | 409 冲突（未实现覆盖） | 成员 + overwrite |"
}
