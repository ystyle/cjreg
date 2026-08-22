# cjrepo vs cjreg Web 页面实现对比报告（UI Gap Report）

> 对比基准：**cjrepo**（Go + Vue3，功能完整参照） vs **cjreg**（Cangjie + cjxt 服务端驱动 UI，当前实现）。
> 分析范围：公开页 4 组 + 管理页 11 个页面，覆盖功能清单、字段对比、外键/关联交互（"直接写 id"）、页面结构四个维度。
> 结论一句话：**cjreg 所有页面均为"只读表格 + 顶部内联输入"的最小实现，缺编辑/删除/对话框/筛选/分页/详情等大部分交互；所有关联字段（团队-组织、计划-上游、日志-操作者）均为手填 ID 或硬编码值，而 cjrepo 全部使用下拉选择器或"搜索→添加"联动选择器。**

---

## 1. 页面清单对照表

| # | 分组 | cjrepo 页面（路由） | cjreg 页面（路由） | 状态 |
|---|------|--------------------|-------------------|------|
| 1 | 公开 | Home.vue（`/`） | PublicHome（`/`） | 简化版（缺特性区/CTA/骨架/入口） |
| 2 | 公开 | Packages.vue（`/packages`） | PublicPackages（`/packages`） | 简化版（缺分类筛选/分页/卡片/tag） |
| 3 | 公开 | PackageDetail.vue（`/packages/:name`） | PublicPackageDetail（`/packages/[name]`） | 简化版（缺 README/版本历史/明细栏） |
| 4 | 公开 | Docs.vue（帮助文档页） | **无** | **缺失**（首页也无文档入口） |
| 5 | 管理 | Login.vue（`/admin/login`） | LoginPage（`/admin/login`） | 有，认证机制不同（密钥+JWT vs 账号密码+会话） |
| 6 | 管理 | Dashboard.vue（`/admin/dashboard`） | DashboardPage（`/admin`） | 简化版（指标不同，缺快捷入口） |
| 7 | 管理 | admin/Packages.vue（`/admin/packages`） | PackagesPage（`/admin/packages`） | 简化版（缺筛选/版本对话框/删除） |
| 8 | 管理 | Upstreams.vue（`/admin/upstreams`） | UpstreamsPage（`/admin/upstreams`） | 简化版（缺编辑/删除/测试/缓存/switch） |
| 9 | 管理 | Users.vue（`/admin/users`） | UsersPage（`/admin/users`） | 简化版（缺邮箱/Token/启停/删除/组织） |
| 10 | 管理 | Organizations.vue（`/admin/organizations`） | OrganizationsPage（`/admin/organizations`） | 简化版（缺编辑/删除/默认/统计列） |
| 11 | 管理 | Teams.vue（`/admin/teams`） | TeamsPage（`/admin/teams`） | **大幅简化**（缺成员/组织/包三关联、权限） |
| 12 | 管理 | PublishPlans.vue（`/admin/publish-plans`） | PublishPlansPage（`/admin/publish-plans`） | 简化版（缺详情入口/删除/分页） |
| 13 | 管理 | PublishPlanCreate.vue（`/admin/publish-plans/create`） | **无**（创建内联在列表页） | **缺失**（三步向导页） |
| 14 | 管理 | PublishPlanDetail.vue（`/admin/publish-plans/:id`） | **无** | **缺失**（详情/进度/SSE 页） |
| 15 | 管理 | Logs.vue（`/admin/logs`） | LogsPage（`/admin/logs`） | 简化版（缺筛选/分页/清理/双 Tab） |

cjreg 额外有但 cjrepo 没有的页面：无。cjreg 的路由 `/admin` 直接是仪表盘（cjrepo 是 `/admin` → redirect `/admin/dashboard`，等价）。

---

## 2. 逐页详细差异

### 2.1 公开页

#### 2.1.1 首页（Home）

**功能清单对比**

| 功能/交互 | cjrepo | cjreg | 缺失 |
|---|---|---|---|
| Hero 区（品牌徽章/标题/副标题） | ✅ 渐变 Hero + 徽章 + 悬浮 logo | ✅ 简易 Hero（标题/副标题） | — |
| "浏览包"按钮跳 /packages | ✅ | ✅ | — |
| "快速开始/查看文档"按钮 | ✅ 跳 Docs | ❌ | 缺失 |
| 平台统计卡片 | ✅ 包总数/版本数/用户数/下载量 | ✅ 包总数/版本总数/注册用户/累计下载 | — |
| 统计加载骨架屏（Skeleton） | ✅ | ❌（直接渲染） | 缺失 |
| 下载量人性化格式（万/k） | ✅ `formatDownloadCount` | ❌（Int64 原样） | 缺失 |
| 核心功能特性卡片区 | ✅ 4 张卡片 | ❌ | 缺失 |
| CTA 区块 | ✅ | ❌ | 缺失 |
| 站点版本信息（buildDate/gitCommit） | ✅ /stats 返回 siteName/buildDate/gitCommit/gitVersion | ❌ | 缺失 |

**字段对比**：cjrepo `/stats` 返回 `{packages, users, versions, downloads, siteName, buildDate, gitCommit, gitVersion}`；cjreg 直接遍历 store 计数，仅覆盖前 4 项。cjreg 首页统计口径：`versions` = PackageDoc 行数（等价 cjrepo 的 versions 行数），`downloads` = 各包 downloadCount 之和（等价）。

#### 2.1.2 包列表（Packages）

**功能清单对比**

| 功能/交互 | cjrepo | cjreg | 缺失 |
|---|---|---|---|
| 关键词搜索（回车/按钮/清空触发） | ✅ 搜索包名、描述、`org::关键词` | ✅ 仅包名 `contains`，输入即刷 | 部分缺失（无描述/org::） |
| 分类筛选（25 个官方分类，多选） | ✅ 左侧 CheckboxGroup 侧栏 | ❌ | **核心缺失** |
| 分页（pageSize 12/24/48/96 + 页码跳转） | ✅ | ❌（全量渲染） | **核心缺失** |
| 结果总数/筛选条件回显 | ✅ | ❌ | 缺失 |
| 卡片式展示（名称/版本/描述/下载/tag） | ✅ 卡片 + 类型/可执行/协议/分类/标签 tag | ❌ 简单表格（包名/组织/版本/下载） | 缺失 |
| 点击卡片进详情 | ✅ | ❌（无点击跳转） | 缺失 |

**字段对比（表格/卡片列）**

| 字段 | cjrepo | cjreg | 说明 |
|---|---|---|---|
| id | ✅ | ✅ | |
| name（org::name 显示） | ✅ | ✅ name + org 分列 | |
| organization | ✅ | ✅ | cjreg 空组织显示 "-" |
| version | ✅ | ✅ | |
| download_count | ✅（格式化 万/k） | ✅（原样数字） | 显示格式差异 |
| description | ✅ | ❌ | **缺失** |
| artifact_type / executable | ✅ tag 源码/二进制/可执行 | ❌ | **缺失** |
| licenses / categories / tags | ✅ tag 展示（JSON 数组解析） | ❌ | **缺失** |
| 分页/总数 | ✅ | ❌ | 缺失 |

#### 2.1.3 包详情（PackageDetail）

**功能清单对比**

| 功能/交互 | cjrepo | cjreg | 缺失 |
|---|---|---|---|
| 头部（org::name + 版本徽章 + 描述 + 相对时间） | ✅ | ✅（名称/组织/版本纯文本） | 部分 |
| 概览 Tab：README Markdown 渲染 | ✅ markdown-it 渲染 | ❌ | **核心缺失** |
| 依赖 Tab：源码/测试/构建脚本 3 子 Tab | ✅ 每依赖显示 name/require/target/type，可点击跳详情 | ✅ 仅源码依赖，纯文本 `name@require` 字符串 | 部分缺失 |
| 版本历史 Tab（所有版本 + 最新标识 + 复制配置） | ✅ | ❌ | **核心缺失** |
| 包信息侧栏（最新版本/更新时间/分类/标签/组织/SDK版本/类型/可执行/协议/作者/仓库/主页/文档/创建时间/包大小/下载次数） | ✅ | ❌ 仅有名称/组织/版本 | **核心缺失** |
| 使用指南（cjpm install 安装命令 + 依赖配置 TOML，复制按钮） | ✅ | ✅ 仅 TOML 代码块展示，**无复制按钮** | 部分缺失 |
| 加载骨架/错误提示 | ✅ Skeleton + Alert | ❌ | 缺失 |
| 路由支持 `org::name` 多组织歧义 | ✅ `/packages/org::name` | ❌ `/packages/[name]` 仅按 name 匹配（同 name 多组织时取第一个） | 字段/路由缺陷 |

**字段对比**：cjreg 详情页只展示 `name/organization/version/dependencies`，dependencies 从 `indexJson` 的 `dependencies` 数组提取，缺 `test-dependencies`、`script-dependencies`、`target/type`，也不解析 `meta_data`（cjc-version、license、category、tag、authors、repository、homepage、documentation）。PackageDoc 模型本身已含大部分字段（cjcVersion/description/artifactType/executable/authors/repository/homepage/documentation/tag/category/license/readme），**只差 UI 不展示**。

#### 2.1.4 Docs 帮助文档页

| 维度 | cjrepo | cjreg |
|---|---|---|
| 页面 | Docs.vue：快速开始/配置 cjpm/发布包/使用包/常见问题（FAQ 折叠），带目录锚点导航、代码块、CTA | **无任何文档页** |
| 入口 | 首页"快速开始/查看文档"按钮、CTA 区入口 | 首页无文档入口 |
| 结论 | — | **整页缺失**（建议新增 `/docs` 静态页） |

### 2.2 管理页

#### 2.2.1 登录（Login）

| 功能/交互 | cjrepo | cjreg | 说明 |
|---|---|---|---|
| 认证模型 | 管理密钥（MD5）→ JWT，存 localStorage，401 自动跳登录，`redirect` 回跳 | 用户名+密码 → 会话 token，写 ctx 上下文（uid/username/isAdmin/token），刷新后 WS 回传恢复 | 架构不同，不算缺失；但回跳/过期处理 cjreg 无 |
| 非空校验 | ✅ | ✅ | |
| 仅管理员可登录 | ❌（密钥即管理员） | ✅ 校验 isAdmin | cjreg 更严 |
| 回车提交 | ✅ | ❌ | 缺失 |
| 密码可见切换 / autofocus | ✅ show-password + autofocus | ✅ password() 输入框；无 autofocus | 部分 |
| 登录中 loading 态 | ✅ | ❌ | 缺失 |
| 登录日志 | ✅ 写 admin_log | ✅ addLog(LogKind.Auth) | |
| 会话过期/非法 token 处理 | ✅ 401 拦截清 token 跳登录 | ✅ auth 钩子校验失败返回登录页 | |

#### 2.2.2 仪表盘（Dashboard）

| 统计/功能 | cjrepo（7 项 + 快捷入口） | cjreg（5 项） | 缺失 |
|---|---|---|---|
| 包总数 | ✅ | ✅ | |
| 版本总数 | ✅ | ❌ | 缺失 |
| 用户总数 | ✅ | ✅ | |
| 活跃用户（is_active） | ✅ | ❌ | 缺失 |
| 存储使用（tarball_size 合计） | ✅ | ❌ | 缺失 |
| 发布成功 / 发布失败计数 | ✅ | ❌ | 缺失 |
| 上游数 / 发布计划数 / 日志条数 | ❌（cjrepo 无） | ✅ | cjreg 独有指标 |
| 刷新按钮 | ✅ | ❌ | 缺失 |
| 快捷入口卡片（包管理/团队/发布计划） | ✅ 可点击跳转 | ❌ | 缺失 |

#### 2.2.3 上游管理（Upstreams）

**功能清单对比**

| 功能/交互 | cjrepo | cjreg | 缺失 |
|---|---|---|---|
| 添加上游 | ✅ 对话框表单（校验必填、默认 URL、默认 cache_ttl=86400） | ✅ 工具栏 3 个输入框直接创建 | 部分（无校验表单） |
| 编辑上游 | ✅ 编辑对话框 | ❌ | **核心缺失** |
| 删除上游 | ✅ 确认框 | ❌ | **核心缺失** |
| 启用/禁用 switch | ✅ 行内 switch | ❌ | 缺失 |
| 测试连接 | ✅ testUpstream | ❌ | 缺失 |
| 缓存统计 + 清除缓存 | ✅ 弹窗显示包数/空间/最近包 + 清缓存 | ❌ | 缺失 |
| 分页 | ✅ | ❌ | 缺失 |
| cache_ttl / auth_token 配置 | ✅ InputNumber(秒) + password 输入 | ❌ 硬编码 `cacheTtl=0→86400`、`authToken=""` | **核心缺失** |
| 最后同步时间列 | ✅ | ❌（模型有 lastSyncAt，UI 未展示） | 缺失 |

**字段对比**

| 字段 | cjrepo Upstream | cjreg UpstreamDoc | 说明 |
|---|---|---|---|
| id / name / url / enabled | ✅ | ✅ | |
| cache_ttl | ✅ | ✅ cacheTtl | cjreg UI 不配置 |
| auth_token | ✅ | ✅ authToken | cjreg UI 不配置 |
| last_sync_at | ✅ | ✅ lastSyncAt | cjreg UI 不展示 |
| created_at / updated_at | ✅ | ❌ | cjreg 缺时间戳 |
| priority / isOfficial | ❌（cjrepo 无） | ✅ | **cjreg 多余字段**（cjrepo 无优先级/官方标识概念，UI 手填 priority） |

#### 2.2.4 包管理（admin/Packages）

**功能清单对比**

| 功能/交互 | cjrepo | cjreg | 缺失 |
|---|---|---|---|
| 搜索（包名/描述） | ✅ | ✅（仅包名） | 部分 |
| 组织筛选下拉（filterable，从 /organizations 加载） | ✅ | ❌ | 缺失 |
| 类型筛选（源码/二进制/可执行） | ✅ | ❌ | 缺失 |
| 重置按钮 | ✅ | ❌ | 缺失 |
| 版本列表对话框（某包所有版本 + 删除状态） | ✅ | ❌ | **核心缺失** |
| 删除包（输入包名二次确认） | ✅ | ❌ | **核心缺失** |
| 恢复/硬删除（API 有 restore/hard） | API ✅，UI 仅在版本对话框显示已删状态 | ❌ | 缺失 |
| 分页 | ✅ | ❌ | 缺失 |
| 刷新 | ✅ | ✅ | |

**字段对比（表格列）**

| 字段 | cjrepo | cjreg | 说明 |
|---|---|---|---|
| id / name / version / organization | ✅ | ✅ | |
| description | ✅ | ❌ | 缺失 |
| artifact_type / executable | ✅ tag | ❌ | 缺失 |
| tarball_size | ✅ 格式化 B/KB/MB | ❌ | 缺失 |
| created_at | ✅ | ❌（模型有 createdAt） | 缺失 |
| download_count | ❌（管理列表无） | ✅ | cjreg 独有 |
| deleted 状态列 | ✅（版本对话框内） | ✅ deletedAt!=0 显示"已删" | |

#### 2.2.5 用户管理（Users）

**功能清单对比**

| 功能/交互 | cjrepo | cjreg | 缺失 |
|---|---|---|---|
| 创建用户 | ✅ 对话框（用户名/邮箱/所属组织下拉）→ 创建后弹 Token 展示+复制 | ✅ 工具栏（用户名/密码）→ 仅消息提示 | 部分（无邮箱/组织/Token 展示） |
| 重置 Token | ✅ 弹窗显示新 Token + 复制 + 警告 | ❌ | **核心缺失** |
| 行内复制 Token | ✅ | ❌ | 缺失 |
| 启用/禁用 switch | ✅ toggleUser | ❌（模型有 isActive，UI 只读） | **核心缺失** |
| 删除用户 | ✅ popconfirm | ❌ | 缺失 |
| 分页 | ✅ | ❌ | 缺失 |
| 刷新 | ✅ | ❌ | 缺失 |

**字段对比**

| 字段 | cjrepo User | cjreg UserDoc | 说明 |
|---|---|---|---|
| id / username | ✅ | ✅ | |
| email | ✅ | ❌ | **字段缺失**（cjreg 无邮箱） |
| token（发布/访问令牌） | ✅ token 列 + 复制/重置 | ❌ publishToken 存在但 UI 不暴露 | **核心缺失** |
| is_active | ✅ switch | ✅ isActive（只读列） | 交互缺失 |
| is_admin / passwordHash | ❌（cjrepo 无） | ✅ | cjreg 独有（认证体系不同） |
| created_at | ✅ | ❌ | 缺失 |

> 注：cjrepo 创建用户请求 `CreateUserRequest{username, email, organization_id?}`，后端实际只消费 username/email（organization_id 前端下发但 Go handler 忽略）；cjreg 后端无 organization 绑定。**但 cjrepo 前端仍是"所属组织下拉选择器"**，交互对齐仍以 cjrepo 前端为准。

#### 2.2.6 组织管理（Organizations）

**功能清单对比**

| 功能/交互 | cjrepo | cjreg | 缺失 |
|---|---|---|---|
| 创建组织 | ✅ 对话框（标识必填/名称必填/描述 textarea + 提示"唯一不可改"） | ✅ 工具栏（组织名/显示名） | 部分（无校验） |
| 编辑组织 | ✅ 对话框（标识禁用） | ❌ | **核心缺失** |
| 删除组织 | ✅ 确认框 | ❌（store 有 deleteOrg，UI 未用） | **核心缺失** |
| 设置默认组织（is_default switch） | ✅ | ❌（模型无 isDefault 字段） | **核心缺失** |
| 成员数 / 包数统计列 | ✅ member_count/package_count | ❌（可计算但未展示） | 缺失 |
| 分页 / 空态引导 | ✅ | ❌ | 缺失 |

**字段对比**

| 字段 | cjrepo Organization | cjreg OrgDoc | 说明 |
|---|---|---|---|
| id / name / display_name / description | ✅ | ✅ | |
| is_default | ✅ | ❌ | **字段缺失** |
| member_count / package_count | ✅（handler 计算） | ❌ | 字段缺失（可算） |
| owner_id | ❌（cjrepo 无） | ✅ ownerId | cjreg 独有；创建时**硬编码 0** |
| created_at / updated_at | ✅ | ✅ createdAt / ❌ updatedAt | 部分 |

#### 2.2.7 团队管理（Teams）——差异最大

**功能清单对比**

| 功能/交互 | cjrepo | cjreg | 缺失 |
|---|---|---|---|
| 创建/编辑团队 | ✅ 对话框（标识/名称/描述/默认权限下拉） | ✅ 仅创建（工具栏"团队名"） | 编辑缺失 |
| 删除团队 | ✅ 确认框 | ❌（store 有 deleteTeam 无，UI 未用） | **核心缺失** |
| 默认权限（read/write/overwrite 下拉 + 说明） | ✅ Select | ❌（**TeamDoc 无 permission 字段**） | **核心缺失** |
| **成员管理**（搜索用户→添加/移除→保存 user_ids） | ✅ 搜索选择器（防抖调 /admin/users?search） | ❌（TeamMemberDoc 存在但 UI 完全未暴露） | **核心缺失** |
| **组织关联**（搜索组织→添加/移除→保存 organization_ids 含 null） | ✅ 搜索选择器（防抖调 /admin/organizations?search） | ❌ 仅创建时手填"组织ID" | **核心缺失** |
| **包权限**（搜索包 org:: 支持→添加/移除→保存 {organization, package_name}） | ✅ 搜索选择器（防抖调 /admin/packages） | ❌ | **核心缺失** |
| 成员数/组织数/包权限数统计列 | ✅ | ❌ | 缺失 |
| 分页 / 空态 | ✅ | ❌ | 缺失 |

**字段对比**

| 字段 | cjrepo Team | cjreg TeamDoc | 说明 |
|---|---|---|---|
| id / name / description / created_at | ✅ | ✅ | |
| display_name | ✅ | ❌ | **字段缺失** |
| permission（read/write/overwrite） | ✅ | ❌ | **字段缺失** |
| member_count / org_count / package_count | ✅ | ❌ | 缺失 |
| orgId（单组织外键，0=全局） | ❌ 无此字段 | ✅ | **cjreg 独有且语义错误**：cjrepo 是"团队↔组织多对多关联表 TeamOrganization"，cjreg 退化成单组织外键 |
| deleted_at | ✅ 软删 | ✅ deletedAt | |

**数据结构差异（重要）**：cjrepo 有三张关联表 `team_organizations`（可含 NULL=无组织）、`team_packages`（organization+package_name）、`team_members`（user_id），UI 对应三个独立对话框；cjreg 只有 `TeamMemberDoc(teamId,userId)` 一张，且 UI 没接入；组织关联退化为 `TeamDoc.orgId` 单值外键——**这是"关联直接写 id"最典型的页面**。

#### 2.2.8 发布计划列表（PublishPlans）

| 功能/交互 | cjrepo | cjreg | 缺失 |
|---|---|---|---|
| 列表列 | 名称/目标上游(ID)/包数量/状态tag/创建时间/操作 | ID/计划名/状态/目标(URL)/进度 | 部分 |
| 新建计划 | ✅ 按钮跳创建向导页 | ✅ 工具栏"计划名+目标URL"内联创建（**同步执行完**） | 部分（无向导） |
| 查看详情 | ✅ 跳详情页 | ❌ | **核心缺失** |
| 删除计划 | ✅ 确认框 | ❌（store 有 deletePlan，UI 未用） | 缺失 |
| 状态中文映射 + tag 颜色 | ✅ pending/running/completed/failed/paused | ✅ 原样字符串（无 tag 颜色） | 部分 |
| 分页 | ✅ | ❌ | 缺失 |

**字段对比**

| 字段 | cjrepo PublishPlan | cjreg PlanDoc | 说明 |
|---|---|---|---|
| id / name / status / total_count / completed_count / created_at | ✅ | ✅ | |
| **target_upstream** | **Int64（上游 ID）** | **String（上游 URL）** | **字段类型/语义错误**：cjrepo 存上游外键 ID（详情/创建页用 Select 选），cjreg 存 URL 字符串 |
| updated_at（完成时间） | ✅ | ❌ | 缺失 |
| poll_interval / poll_timeout | ✅ | ❌ | **字段缺失**（cjreg 无轮询参数） |
| items | ✅ 独立 PublishPlanItem 表（package_id/order/category/status/selected/error/started_at/completed_at） | ❌ itemsJson 字符串内嵌（name/org/version/order/status） | 结构简化，无 package_id 关联、无 category/selected/error/时间戳 |

#### 2.2.9 发布计划创建向导（PublishPlanCreate）——整页缺失

| 步骤/功能 | cjrepo | cjreg |
|---|---|---|
| 三步向导（选择包→分析结果→确认创建） | ✅ ElSteps 向导 | ❌ 无（列表页内联简化创建） |
| 目标上游选择 | ✅ **下拉 Select**（从 /admin/upstreams 加载，展示名称） | ❌ **手填 URL 输入框** |
| 起始包选择 | ✅ 搜索框防抖 → 结果点击添加 → 已选 tag 列表（package_id 去重） | ❌ 不选包（以"全部本地包为根"自动分析） |
| 依赖分析（analyzePackages） | ✅ 进度条 + 分类结果（冲突/需要发布/可选版本/已存在）+ checkbox 选择 + 按 publish_order 排序 | ✅ 简化拓扑分析（仅判环）+ **创建后同步执行推送** |
| 轮询间隔 / 总超时配置 | ✅ InputNumber + 建议值 | ❌ |
| 确认页（计划名/上游回显/包表预览） | ✅ | ❌ |
| 校验（计划名必填/上游必选/至少选一个包） | ✅ | ✅（仅计划名+URL 非空） |

#### 2.2.10 发布计划详情（PublishPlanDetail）——整页缺失

| 功能/交互 | cjrepo | cjreg |
|---|---|---|
| 详情页路由 `/admin/publish-plans/:id` | ✅ | ❌ **无此页** |
| 统计卡（状态/目标上游/创建时间/完成时间） | ✅ | ❌ |
| 进度条（completed/total %） | ✅ ElProgress | ❌ |
| 发布项表格（序号/org::name@version/状态tag/错误信息） | ✅ | ❌ |
| 开始 / 暂停 / 恢复 / 删除（按状态条件显示） | ✅ start/pause/resume/delete API | ❌ |
| 实时进度（SSE /admin/publish-plans/:id/events + 5s 兜底轮询） | ✅ fetch-event-source | ❌ |
| 执行日志展示 | ✅（预留 logs） | ❌ |

#### 2.2.11 日志（Logs）

**功能清单对比**

| 功能/交互 | cjrepo | cjreg | 缺失 |
|---|---|---|---|
| 双 Tab（发布日志/管理员操作日志） | ✅ | ❌ 单表合并展示（kind 列） | 缺失 |
| 发布日志：状态筛选下拉 | ✅ success/failed | ❌ | 缺失 |
| 管理员日志：操作类型筛选下拉 | ✅ delete_package/create_user/reset_token/restore_package/admin_login | ❌ | 缺失 |
| 分页 | ✅（两组独立分页） | ❌（仅取最新 200 条） | 缺失 |
| 清理日志（类型+时间范围 90/180/365 天下拉 + 危险确认） | ✅ 对话框 + popconfirm | ❌（store 无清理方法） | **核心缺失** |
| 操作中文映射 + tag 颜色 | ✅ | ❌ 原样字符串 | 缺失 |
| 错误信息列（发布失败原因） | ✅ | ❌（LogDoc 有 detail 但 UI 未展示） | 缺失 |

**字段对比**

| 字段 | cjrepo PublishLog | cjreg LogDoc | 说明 |
|---|---|---|---|
| id / status / created_at | ✅ | ✅ | |
| package_name / version / organization | ✅ | ❌（LogDoc 只有 action 描述串） | **字段缺失**：cjreg 日志不落结构化包名/版本/组织 |
| error | ✅ | ❌ | 缺失 |
| ip_addr / user_agent | ✅ | ❌ | **字段缺失** |
| actor 字段 | ❌（cjrepo AdminLog 无 actor，用 action/target） | ✅ actorId/actorName | cjreg 独有 |
| target（操作目标 ID） | ✅ AdminLog.target | ❌ | 缺失 |
| action 枚举 | ✅ 结构化枚举 | ❌ 自由文本描述 | 缺失 |

---

## 3. 字段差异汇总表（所有不一致字段）

> 标注：**[缺]** = cjreg 缺失；**[错]** = cjreg 字段存在但语义/类型错误；**[多]** = cjreg 多余；**[显]** = 模型有但 UI 未展示。

| 实体 | 字段 | cjrepo | cjreg | 状态 | 备注 |
|---|---|---|---|---|---|
| User | email | ✅ | ❌ | [缺] | cjreg 无邮箱概念 |
| User | token（访问令牌） | ✅ 展示/复制/重置 | publishToken 存在 | [显] | UI 未暴露 token 管理 |
| User | is_active 交互 | ✅ switch | 只读列 | [显] | 缺启停操作 |
| User | created_at | ✅ | ❌ | [缺] | |
| Organization | is_default | ✅ | ❌ | [缺] | cjreg 无默认组织概念 |
| Organization | member_count / package_count | ✅ | ❌ | [缺] | 可计算未展示 |
| Organization | owner_id | ❌ | ✅ | [多] | 创建时硬编码 0 |
| Organization | updated_at | ✅ | ❌ | [缺] | |
| Team | display_name | ✅ | ❌ | [缺] | |
| Team | permission（read/write/overwrite） | ✅ | ❌ | [缺] | 权限模型整体缺失 |
| Team | member_count / org_count / package_count | ✅ | ❌ | [缺] | |
| Team | orgId（0=全局） | ❌ 无 | ✅ | [错] | 应为多对多 TeamOrganization 关联表；单外键退化 |
| TeamOrganization | organization_id（可 NULL=无组织） | ✅ | ❌ | [缺] | 关联表整体缺失 |
| TeamPackage | organization + package_name | ✅ | ❌ | [缺] | 包级权限关联缺失 |
| TeamMember | user_id | ✅ | ✅ TeamMemberDoc | [显] | UI 未接入 |
| PublishPlan | **target_upstream** | **Int64（上游 ID）** | **String（URL）** | **[错]** | 类型/语义错误 |
| PublishPlan | poll_interval / poll_timeout | ✅ | ❌ | [缺] | |
| PublishPlan | updated_at | ✅ | ❌ | [缺] | |
| PublishPlanItem | package_id / order / category / selected / error / started_at / completed_at | ✅ 独立表 | ❌ 内嵌 itemsJson | [缺] | 无包外键、无分类/选择/时间戳 |
| Upstream | cache_ttl | ✅ UI 可配 | 模型有，UI 硬编码 | [显] | |
| Upstream | auth_token | ✅ UI 可配 | 模型有，UI 传 "" | [显] | |
| Upstream | last_sync_at | ✅ 展示 | 模型有，UI 未展示 | [显] | |
| Upstream | created_at / updated_at | ✅ | ❌ | [缺] | |
| Upstream | priority / isOfficial | ❌ | ✅ | [多] | cjrepo 无此概念 |
| Log（发布） | package_name / version / organization | ✅ | ❌ | [缺] | cjreg 日志非结构化 |
| Log | error | ✅ | ❌ | [缺] | |
| Log | ip_addr / user_agent | ✅ | ❌ | [缺] | |
| Log（管理） | action 枚举 / target / details | ✅ | ❌（自由文本 action） | [缺] | |
| Log | detail | ❌ | ✅ | [多] | UI 未展示 |
| Package（公开列表） | description / artifact_type / executable / licenses / categories / tags | ✅ | 模型有 | [显] | 公开列表/详情 UI 未展示 |
| Package（管理列表） | tarball_size / created_at / description / artifact_type | ✅ | 模型有 | [显] | 管理列表未展示 |

---

## 4. "直接写 id / 写死值" 位置清单（cjreg 需改为选择器的地方）

> cjxt 组件库已具备 `Select.cj / Dialog.cj / Pagination.cj / InputNumber.cj / Switch.cj / Tabs.cj`（见 `/home/ystyle/Projects/Cangjie/cjxt/src/components/`），以下改造均可行，无需新造组件。

| # | 文件:位置 | 当前做法 | cjrepo 对应做法 | 改造建议 |
|---|---|---|---|---|
| 1 | `src/ui/pages_org.cj` TeamsPage `newOrgId` 输入框（placeholder "组织ID(0=全局)"） | 创建团队时 `Int64.parse(this.newOrgId.get())` 手填组织 ID | Teams.vue"组织"对话框：**搜索框防抖 → 结果列表点击添加 → 已关联列表移除**，保存 `organization_ids`（含 null=无组织），多对多 | 改为组织 **Select/搜索选择器**；数据模型从 `TeamDoc.orgId` 升级为 TeamOrganization 关联表 |
| 2 | `src/ui/pages_plan.cj` PublishPlansPage `targetUrl` 输入框（placeholder "目标上游 URL"） | 手填上游 URL 字符串创建计划 | PublishPlanCreate.vue Step1：**目标上游下拉 Select**（从 /admin/upstreams 加载，展示 name，存 id） | 改为上游 **Select 下拉**；`PlanDoc.targetUpstream` 改存 Int64 上游 ID |
| 3 | `src/ui/pages_plan.cj` createPlan | 不选包，以"全部本地包为根"分析 | 创建向导：**搜索包 → 选择 package_id 列表**（`package_ids: number[]`）提交 | 增加包选择器（搜索+多选 tag），PlanDoc 增加结构化 plan items |
| 4 | `src/ui/pages_manage.cj` UpstreamsPage `newPriority` | 手填优先级数字（cjrepo 无此字段） | cjrepo 无 priority；上游用"缓存时间/令牌"表单字段 | 若保留 priority 改为 Select/InputNumber；更应对齐 cjrepo 去掉或挪到编辑表单 |
| 5 | `src/ui/pages_manage.cj` UpstreamsPage addUpstream | `upSvc.add(name, url, priority, "", 0)` authToken/cacheTtl 写死空串/0 | 编辑对话框：auth_token password 输入 + cache_ttl InputNumber | 表单化，默认 86400 |
| 6 | `src/ui/pages_manage.cj` addUpstream 写日志 | `addLog(LogKind.Admin, 0, "admin", ...)` actorId=0、actorName 写死 "admin" | cjrepo 从会话/JWT 记录操作者（admin_log.target/details） | **从会话上下文取 uid/username**（login 已写 ctx，"admin" 是写死值） |
| 7 | `src/ui/pages_org.cj` UsersPage createUser 写日志 | `addLog(..., 0, "admin", ...)` 同上 | 同上 | 同上 |
| 8 | `src/ui/pages_org.cj` OrganizationsPage createOrg | `createOrg(name, display, 0, now)` ownerId **硬编码 0** | cjrepo 无 ownerId（组织不绑定 owner） | 填当前登录 uid，或去掉该字段 |
| 9 | `src/ui/pages_org.cj` OrganizationsPage 写日志 | `addLog(..., "create org ${this.newName.get()}", ...)` 但 newName 已清空 → 日志内容为空串 | — | **bug**：先 set("") 再写日志，action 恒为空；应记录旧值 |
| 10 | `src/store/admin_data.cj` TeamMemberDoc | `addTeamMember(teamId, userId)` 需 userId，UI 未暴露任何入口 | Teams.vue"成员"对话框：**搜索用户 → 添加/移除**，保存 user_ids | 新增成员管理对话框（用户搜索选择器） |
| 11 | `src/ui/pages_plan.cj` PublishPlansPage | 创建即同步执行（阻塞 UI），无异步计划状态机 | 详情页开始/暂停/恢复 + SSE 进度 | 改异步执行 + 选择器 + 详情页 |
| 12 | `src/ui/login.cj` doLogin | 登录成功写 ctx 上下文 ✅（正确做法，保留） | — | 无（这是正确的，无需改） |

**汇总**：核心"直接写 id"共 3 处需要改造为选择器（#1 团队-组织、#2 计划-上游、#4 上游-优先级），"写死值/硬编码"共 4 处（#5/#6/#7/#8，含 actorId/ownerId/authToken/cacheTtl），逻辑 bug 1 处（#9 日志空 action），关联模型缺失 2 处（#10 成员管理、#3 包选择）。

---

## 5. 功能缺失清单（按优先级排序）

> 🔴 = 核心缺失（影响可用性/正确性），🟡 = 重要缺失，⚪ = 次要缺失。

**P0 —— 核心缺失（先做）**

| # | 页面 | 缺失项 | 说明 |
|---|---|---|---|
| 1 | 🔴 团队管理 | 成员/组织/包三类关联管理（搜索选择器） | cjrepo 团队页核心价值所在；cjreg 仅剩"团队名+组织ID" |
| 2 | 🔴 团队管理 | permission 权限字段 + 下拉 | TeamDoc 缺字段，权限体系整体缺失 |
| 3 | 🔴 发布计划 | 详情页（开始/暂停/恢复/删除/进度/SSE） | 整页缺失 |
| 4 | 🔴 发布计划 | 创建向导页（上游下拉 + 包搜索选择 + 依赖分析分类） | 整页缺失；targetUpstream 类型错误（URL vs ID） |
| 5 | 🔴 上游管理 | 编辑/删除/启用禁用/测试/缓存管理 | 上游 CRUD 只剩"添加+列表" |
| 6 | 🔴 用户管理 | 邮箱字段、Token 复制/重置、启停、删除 | 用户管理只剩"创建+列表" |
| 7 | 🔴 组织管理 | 编辑/删除/默认组织 switch | 只剩"创建+列表" |
| 8 | 🔴 日志 | 发布日志结构化字段 + 状态/类型筛选 + 清理 | 只剩"最近 200 条只读" |

**P1 —— 重要缺失**

| # | 页面 | 缺失项 |
|---|---|---|
| 9 | 🟡 包管理(admin) | 版本列表对话框、删除（含二次确认）、组织/类型筛选、分页 |
| 10 | 🟡 包详情(公开) | README Markdown 渲染、版本历史、明细侧栏（协议/作者/仓库/主页/文档/包大小等）、依赖子分类与跳转 |
| 11 | 🟡 包列表(公开) | 分类筛选、分页、卡片+tag 展示、点击进详情 |
| 12 | 🟡 仪表盘 | 版本数/活跃用户/存储/发布成败统计、刷新、快捷入口 |
| 13 | 🟡 Docs 文档页 | 整页缺失（含首页"快速开始"入口） |

**P2 —— 次要缺失**

| # | 页面 | 缺失项 |
|---|---|---|
| 14 | ⚪ 全局 | 分页组件（所有列表页）、空态引导、加载骨架 |
| 15 | ⚪ 登录 | 回车提交、loading 态、redirect 回跳 |
| 16 | ⚪ 首页 | 特性卡片区、CTA、下载量格式化、统计骨架 |
| 17 | ⚪ 日志 | 操作中文映射 + tag 颜色、错误信息列、ip/ua |
| 18 | ⚪ 上游 | 最后同步时间列、cache_ttl/auth_token 表单 |

---

## 6. 结论摘要

1. **整体形态差距**：cjrepo 是"表格 + 对话框表单 + 搜索联动选择器 + 分页 + 状态管理"的完整 CRUD 管理后台；cjreg 目前是"只读表格 + 顶部内联输入创建"的最小骨架，所有页面缺编辑/删除/详情/筛选/分页/对话框，**没有一个页面达到 cjrepo 的功能完整性**。

2. **关联交互是最大问题**：cjrepo 所有外键/关联（团队→组织/包/成员、计划→上游、用户→组织）全部使用**下拉 Select 或"搜索→添加→移除→保存"联动选择器**；cjreg 对应位置全是**手填数字 ID / 手填 URL / 硬编码 0**（详见第 4 节清单），且 `PlanDoc.targetUpstream` 的字段类型（String URL vs Int64 ID）与 cjrepo 契约不符。

3. **字段缺口**：核心业务字段缺失集中在 User.email/token 管理、Team.permission/display_name、Organization.is_default、Plan.poll_interval/poll_timeout/结构化 items、Log 的包名/版本/组织/error/ip/ua；另有 cjreg 独有但语义错误的 Team.orgId 单外键设计（应为多对多关联表）。

4. **页面缺失**：Docs 帮助文档页、发布计划创建向导页、发布计划详情页（含 SSE 实时进度）3 个整页缺失；其余页面均为"缩水版"。

5. **改造可行性**：cjxt 组件库已具备 Select/Dialog/Pagination/InputNumber/Switch/Tabs 等组件，上述改造不需要引入新依赖；建议按 P0（团队关联 + 发布计划三页 + 上游/用户/组织 CRUD + 日志）→ P1 → P2 顺序推进，并先修正 `PlanDoc.targetUpstream` 类型与"组织多对多"数据模型。
