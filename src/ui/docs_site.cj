// 公开文档站点：章节列表 + markdown 内容（对齐 VitePress 导航/内容模式，用 cjxt Markdown 渲染）
package ystyle::cjreg.ui

import std.collection.*
import ystyle::cjreg.config.*

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
// cfg = 服务端配置（cjreg.toml）：文档里的服务地址、registry 示例与配置片段一律显示实际配置值，
// 避免「文档说 A、服务在 B」。
public func docContent(id: String, cfg: CjregConfig): String {
    match (id) {
        case "quickstart" => return docQuickstart(cfg)
        case "client-config" => return docClientConfig(cfg.publicUrl)
        case "publish" => return docPublish()
        case "multi-repo" => return docMultiRepo()
        case "publish-plan" => return docPublishPlan()
        case "permission" => return docPermission(cfg.publicUrl)
        case _ => return docQuickstart(cfg)
    }
}

func docQuickstart(cfg: CjregConfig): String {
    let publicUrl = cfg.publicUrl
    let port = cfg.port
    let modeText = if (cfg.permissionMode == "team") { "team" } else { "open" }
    "# 快速开始\n\n"
    + "**cjreg** 是仓颉私有中心仓与多仓工具，提供包发布 / 下载 / 索引 / 依赖解析 / 上游代理与一键部署能力。\n\n"
    + "## 1. 初始化数据目录\n\n"
    + "首次使用需创建首个管理员并写入默认官方上游：\n\n"
    + "```shell\n"
    + "cjreg init -d ./data --username admin --password <强口令>\n"
    + "```\n\n"
    + "## 2. 启动服务\n\n"
    + "```shell\n"
    + "cjreg serve -d ./data -p ${port}\n"
    + "```\n\n"
    + "服务启动后，浏览器访问（地址取自配置文件 `server.public_url`）：\n\n"
    + "- 用户门户：`${publicUrl}/`（登录后 `/me` 领取发布 Token）\n"
    + "- 管理后台：`${publicUrl}/admin`\n\n"
    + "## 3. 服务端配置（可选）\n\n"
    + "数据目录下的 `cjreg.toml`（`cjreg init` 已生成模板；`-c/--config` 可指定其它路径）：\n\n"
    + "```toml\n"
    + "[server]\n"
    + "public_url = \"${publicUrl}\"      # 对外地址：本文档里的地址与 registry 示例都用它\n"
    + "port = ${port}\n"
    + "permission_mode = \"${modeText}\"          # open = 有效 token 即可发布；team = 双路径裁决\n"
    + "require_auth = ${cfg.requireAuth}                # 下载/索引是否需 token + read 权限\n"
    + "```\n\n"
    + "- 优先级：命令行（`-p`）> 配置文件 > 默认值；配置文件不存在时全走默认值。\n"
    + "- 没有环境变量配置项（唯一的 `CJREG_SEED_DEMO=1` 是开发调试开关）。\n\n"
    + "## 4. 体验\n\n"
    + "管理后台可用 `admin` / 初始化密码登录，查看仪表盘、包管理、上游管理、发布计划等；"
    + "普通用户从 `${publicUrl}/` 登录后进入「我的」门户领取发布 Token。"
}

func docClientConfig(publicUrl: String): String {
    "# 客户端配置\n\n"
    + "## cjpm.toml 依赖\n\n"
    + "在项目 `cjpm.toml` 的 `[dependencies]` 中配置来自本仓的依赖（registry 指向本服务）：\n\n"
    + "```toml\n"
    + "name = \"my-app\"\n"
    + "version = \"0.1.0\"\n\n"
    + "[dependencies]\n"
    + "'demo::demo-app' = \"1.0.0\"\n"
    + "```\n\n"
    + "- 无组织包：`name = \"x.y.z\"`\n"
    + "- 有组织包：`'org::name' = \"x.y.z\"`\n\n"
    + "## 发布配置 cangjie-repo.toml\n\n"
    + "发布时需要配置 registry 地址与发布 Token（登录后到「我的」门户页获取 / 重置）：\n\n"
    + "```toml\n"
    + "[repository.home]\n"
    + "registry = \"${publicUrl}\"\n"
    + "token = \"<发布 Token>\"\n"
    + "```"
}

func docPublish(): String {
    "# 发布包\n\n"
    + "命令行发布：在项目根目录配置 `cangjie-repo.toml`（registry + Token，Token 从「我的」门户页获取），"
    + "再执行 `cjpm publish`。管理员也可在管理后台 → 包管理 → 发布包 上传制品。\n\n"
    + "## 发布要求\n\n"
    + "- 模块名 / 组织名长度 `[3, 64]`，不能为仓颉关键字；组织名不能为 `default`。\n"
    + "- `cjpm.toml` 需包含 `description`。\n"
    + "- 根目录需包含 `README_zh.md` 或 `README.md`。\n\n"
    + "## 访问控制\n\n"
    + "发布遵循服务端权限模式：\n\n"
    + "- **open 模式（默认）**：有效 Token 即可发布，发布者会被记录。\n"
    + "- **team 模式**：按「包名所有者 / 团队成员」双路径裁决，按权限级别（read / write / overwrite）校验。\n\n"
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

func docPermission(publicUrl: String): String {
    "# 访问控制\n\n"
    + "cjreg 提供两种发布权限模式，通过环境变量 `CJREG_PERMISSION_MODE` 切换；"
    + "下载/索引的读鉴权由 `CJREG_REQUIRE_AUTH=1` 单独开启（默认公开）。\n\n"
    + "## open 模式（默认）\n\n"
    + "- 适合小企业内部先试用。\n"
    + "- 任何持有有效发布 Token 的用户均可发布（新包 / 新版本）。\n"
    + "- 同版本重复发布（sha 不同）仍返回 409，不会静默覆盖。\n"
    + "- 发布者仍会被记录，作为审计基础。\n\n"
    + "## team 模式\n\n"
    + "按**双路径**计算你对某个包的权限级别（取两者较高）：\n\n"
    + "- **包名所有者**（owner）：该包**最早一条版本记录**的发布者，唯一；具备 write。\n"
    + "- **团队成员**：你所属团队关联了该包或该组织时，取团队权限（read / write / overwrite）。\n"
    + "- 平台管理员：overwrite（直通）。\n\n"
    + "发布裁决：\n\n"
    + "- **新包**：命名空间未被团队纳管时，任意有效 Token 可认领（首次发布者成为 owner）；已被纳管则需 write。\n"
    + "- **新版本**：需 write（owner 天然具备）。\n"
    + "- **覆盖已存在版本**（同版本、内容不同）：需 overwrite；owner 自身没有覆盖权，覆盖也不转移 owner。\n"
    + "- 团队成员退出团队后即失去该包的权限（owner 除外）。\n\n"
    + "## 发布 Token\n\n"
    + "- 登录用户门户（`${publicUrl}/me`）即可查看 / 重置自己的发布 Token。\n"
    + "- 重置后旧 Token 立即失效，正在使用它的 CI 需要同步更新。\n\n"
    + "## 权限矩阵\n\n"
    + "| 场景 | open | team |\n"
    + "| --- | --- | --- |\n"
    + "| 新包首发布 | 有效 Token | 有效 Token（命名空间未纳管）/ write |\n"
    + "| 新版本 | 有效 Token | owner 或成员 + write |\n"
    + "| 覆盖版本 | 409 冲突 | 成员 + overwrite |\n"
    + "| 下载 / 索引 | 公开 | 公开；`CJREG_REQUIRE_AUTH=1` 时需 read |"
}
