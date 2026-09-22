# Changelog

本文件记录 cjreg 的重要变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Added — 组织 CRUD REST（管理 API）

- `GET /api/admin/organizations`：组织列表（含 `packageCount`/`versionCount`/`teamCount`）
- `GET /api/admin/organizations/:id`：组织详情
- `POST /api/admin/organizations`：创建（`{name, displayName?, description?, isDefault?}`）
  —— 名称格式校验（1–64 字符，`[A-Za-z0-9_-]`）、重名 409、非法名 400；`isDefault=true` 时清除其它组织的默认标记
- `PUT /api/admin/organizations/:id`：更新（未传字段保持原值）；`name` 变化视为**改名**，
  该组织下仍有包时 409（避免孤儿包），无包时校验格式与重名
- `DELETE /api/admin/organizations/:id`：软删；组织下仍有包 409、仍被团队关联 409（错误消息列出团队名）
- 审计：`create_org` / `update_org` / `delete_org`（detail 记 id 与 affected；守卫失败记 failed + 原因）
- 测试：`org_service_test.cj` 4 组（名称校验与 JSON 形状、创建与默认唯一化、改名与更新守卫、删除守卫与统计）；
  `tests/e2e.sh` 第 9 步（创建/重名/非法名/列表/详情/更新/改名守卫/删除守卫/重复删除/公开列表一致/审计）

### Added — GitHub 镜像手动同步脚本

- `scripts/sync-github.sh`：把 AtomGit 主仓库的 `master` 与 tag 手动同步到 GitHub 镜像。
  背景是推送镜像实测会长时间停滞（曾 90 分钟不推进）且不镜像 tag，导致 master 上的提交在
  GitHub 侧缺失、CI / 文档站 / Release 都不触发。脚本幂等、只快进、绝不 force（不覆盖已发布 tag），
  也支持 `bash scripts/sync-github.sh v0.1.0` 只同步指定 tag；`docs/RELEASE.md` 增补对应排查条目

### Fixed — 测试用内存态 Storm 不回收导致 CI 覆盖率构建 OOM

- GitHub CI 的 `Coverage report` 步骤（`cjpm test --coverage`）在 server 包出现 18 例
  `OutOfMemoryError`（`badgercj.skiplist.Segment::init`）：每个 `Storm.inMemory()` 打开即预分配
  ~17 万个原子对象（含 1.3 MB 连续数组），且后台线程持有实例引用，不 `close()` 既回收不了内存、
  又持续占着大对象空间；server/store/ui 三个测试包共 19 处夹具只建不关
- 新增包内夹具 `src/{server,store,ui}/test_stores_test.cj`：`beginTestStores()` 关闭上一代、
  `testStorm()` 新建并登记；夹具工厂开头统一调用。`testPublishUnauthorized` 改为三条断言共用一个夹具
- 回归：`cjHeapSize=128MB cjpm test --coverage -j 16 --no-progress` → **179/179 全绿**
  （修复前同一命令 18 例 OOM）；默认堆下单测 179/179、`tests/e2e.sh` 9 步全绿
- 详见 `docs/verification.md` §4.7（含复现命令与结论）

### Fixed — 管理端「搜索/筛选」输入即生效（全站同类缺陷一起修）

- 根因有两层：① cjxt 的 `Table.data()` **只接受 `Signal<ArrayList<T>>`**，过滤结果只能由一个信号承载；
  ② 前端对同一元素**先 action 后 bind**（`public/js/cangjie-ui.js:333` 收到 `input` 立即发 action，
  而 `:490` 的 bind 有 300ms 防抖）——在 action 里 `refresh()` 读到的关键字还是**上一次**的，
  且过滤结果被缓存进 rows、render 又不读过滤信号，于是"搜索完全无效，必须再点一次刷新/筛选"。
- 修法：过滤/分页/查询都是**信号派生**（`Effect` 读哪些信号就订阅哪些信号），输入框与下拉**只 bind**，
  动作只做"回第一页"这类不读关键字的事。新增 `src/ui/list_binding.cj`（`bindRows` / `bindPaged` /
  `bindVisible`）与 `src/ui/plan_items_filter.cj`
- 落地范围：包管理（主表搜索/组织筛选/分页）、用户管理（搜索）、日志（关键字/类型/结果 + 服务端分页查询）、
  团队弹窗（包关联 / 成员关联搜索）、发布计划新建向导的包选择（结果由 render 现算，不缓存）
- 日志页的服务端查询也改为派生：查询条件（关键字/类型/结果/页码/每页条数）任一变即重查；
  页越界（条件变严、上一页被清理）时**本地退到最后一页**重查，不回写页码信号（避免 Effect 自订阅成环）
- 回归：`src/ui/list_binding_test.cj`、`package_rows_test.cj`、`pages_manage_render_test.cj`、
  `pages_users_render_test.cj`、`pages_plan_render_test.cj`、`logs_search_test.cj`、`team_dialog_search_test.cj`

### Fixed — 浏览器 QA 抓到的三条「单元测试看不见」的补丁层缺陷

单测直接 `render()` 断言树是对的，但真浏览器里走的是「动作写信号 → 服务端挑脏组件 → 下发子补丁 →
客户端 reconcile」这条路，下面三条只有真跑浏览器才会暴露（均已修 + 补结构性回归）：

- **打字完全没反应**：搜索输入框除了 `bind` 还挂了 `on("input")` 动作，前端是**先 action 后 bind**
  （`cjxt public/js/cangjie-ui.js:333` 立即发 action，`:490` 的 bind 有 300ms 防抖），那个 action 立刻换来
  一次补丁，补丁应用完会无条件清掉焦点元素的 `bindDirty` 守卫（`:710`），随后 `applyAttrs` 把输入框的值
  退回服务端旧值（`:309`）——300ms 后才发出的 bind 读到的是**空串**，写回信号等于没搜。
  修法：输入框/下拉一律只 `bind`（`src/ui/pages_manage.cj`、`pages_org.cj`、`pages_plan.cj`）；
  回归断言"整页不存在 `input` 事件动作"（含一条正向对照，证明该断言有牙）。
- **「共 N 条」回到上一次的值**：`cjxt Pagination` 的 `total` 是**创建时的快照**，而过滤条件变化时若顺手
  回写页码信号，分页器自己就变脏、在同一批补丁里被**旧实例**重渲一次，且该补丁排在页面补丁**之后**
  → 把刚算好的条数顶回旧值。修法：过滤条件变化不回写页码，页越界交给本地钳制
  （服务端分页退到最后一页重查；`bindPaged` 只影响切片，分页器自己会夹显示页）。
- **中文空态被空表格顶掉**：原来"没有行就返回提示、否则返回表格"是**换节点类型**，同批补丁里父（页面）
  与子（表格）都会变脏、子补丁后应用，于是提示被空表格的英文 "No Data" 覆盖（搜索无命中、计划项全隐藏
  时都能看到）。修法：新增 `layout.cj` 的 `listBody(提示, 表格)`，提示槽与表格槽**永远都在**（槽位固定），
  表格自带空文案改中文（`Table.emptyText("暂无数据")`）。
- 另外修掉主子表的"点一下没反应"：选中态原先是普通字段，渲染里读不到 → 写它也不会有组件变脏 →
  服务端不下发补丁（单测直接 `select()`+`render()` 是好的，浏览器里右栏一直停在空态）。
  选中态改为信号并在渲染里读取，回归断言"选中/开关会标脏"。

### Changed — 包管理：版本列表改为「左主（包）右子（版本）」主子表

- 原来「包列表 + 版本按钮弹窗」的两段式交互改为同页主子表：左栏选中一个包，右栏即时列出该包各版本
  （来源/大小/sha256/时间/下载/状态/操作），版本操作（详情·重拉·软删|恢复·硬删）跟着右栏走
- 单版本详情（含 README 全文）仍是弹窗：README 正文长，塞进右栏会把版本表挤没
- 主表为聚合行（一个 `org::name` 一行：版本数/最新版本/下载合计），搜索支持 `包名 / 组织 / 描述`

### Changed — 发布计划：列表倒序 + 索引等待节奏 + 详情页可隐藏不推送的项

- 计划列表**新的在前**（`listPlans` 按 id 倒序）：建完计划不用翻到最后一页去找
- 索引等待节奏由 `5s → 1m → 3m → 5m → 每 5m` 改为 **`5s → 1m → 1m → 1m → 每 5m`**（默认仍不设总超时）：
  中间三次都用 1 分钟——索引要么很快出现（同机私有仓几乎即时），要么就是慢同步（几十分钟到几天），
  递增到 3 分钟在"快要出现"和"还早"之间各让一半，两边都不讨好。界面文案改为由常量投影
  （`indexWaitRhythmText()`），改节奏不会再漏改文案
- 详情页「发布项」新增**「隐藏不推送的项」**开关（没勾选、或已被判未推送的行不再占屏）；
  开关只筛显示行：明细（共 N 项 / 需发布 M）与「检查索引」按钮判据仍按全量算，
  全部隐藏时给明确空态提示而不是一张空表

### Changed — 创建计划页「选择要发布的包」重做（表格化 + 分页 + 独立的版本对照卡）

- 候选包从"每行一个「添加」按钮的纯文本列表（最多 30 行）"改成 **表格 + 分页**：
  列 = 包（`org::name`）/ 版本 / 描述 / 操作（添加 ↔ 移除，按是否已选切换），
  搜索框只 bind、过滤与分页都由信号派生（`bindPaged`），不再有"仅显示前 30 个"的截断。
- 「已选择的包」独立成表（含空态提示"从上面的结果里点「添加」（依赖会自动补齐）"），
  与候选表共用同一套列，选中项一眼可见、逐个可移除。
- 「版本对照（本地 → 目标仓）」从挤在同一个卡片底部的一大段文字改成**独立卡片 + 表格**：
  序 / 包 / 目标仓 / 分类 / 说明（分类与说明复用发布详情页的文案口径），
  空态与对照中的提示走 `listBody` 的固定提示槽（避免提示被表格补丁顶掉）。
- 三张表都只读信号（`previewRows` 直接作为表格数据源），异步对照结果回来即自动刷新。

### 计划中

- **发布链路流式化**（大包稳定 + 内存 O(1)）：当前 `POST /pkg` 整包读入内存（峰值 ≈ 包体 2–3 倍），
  受仓颉 GC 堆默认 256 MB 限制，40 MiB 以上的包在默认配置下可能 OOM —— 详见 `docs/finals-plan.md` 迭代 1
- 发布计划 item 六状态（`publishing`/`waiting_index`/`skipped`）与 SSE 进度流
- 镜像预热/周期同步（`serve --sync-interval`）与性能基准报告
- 团队所有者（owner 自助管理成员）——设计见 `docs/user-portal-design.md` §7.4

## [0.1.0] - 2026-09-12

首个可用版本：与官方中心仓协议互通的纯仓颉私有中心仓 + 多仓体系，静态单二进制交付。

### Added — 审计日志（发布 / 认证 / 管理）

- **发布审计**：`POST /pkg` 的每次发布都落审计（操作者、`org/name@version`、包大小、成功/失败与原因），
  令牌无效时记为匿名 `failed`，**不记录令牌明文**
- **IP / User-Agent**：`X-Forwarded-For` 首个 → `X-Real-IP` → TCP 对端；UA 截断 200 字节
- **认证与管理审计**：登录成功/失败（含尝试的用户名与原因）、注销、创建用户、提升/取消管理员（含「最后一个启用管理员」失败记录）、
  上游新增/删除、**发布计划推送**（目标仓地址、`success=N/M`、首条错误；`target_token` 只记「是否显式传入」不落明文），
  以及管理端页面的用户/组织/团队/成员/上游/包/计划写入（UI 侧无 HTTP 上下文，IP/UA 记为 `admin-ui`）
- **查询与清理端点**：`GET /api/admin/logs/:kind`（关键字/结果/时间范围/分页，`total` 为命中总数）、
  `POST /api/admin/logs/clean`（按类型或时间清理，清理动作自身入审计）
- **管理端审计日志页**：时间/类型/操作者/操作/IP/UA/错误信息 列 + 关键字与筛选 + 分页 + 分范围清理弹窗
- **单实例审计存储**：`AdminDataStore` 由 `main.cj` 单实例注入 HTTP handler 与 cjxt 状态，
  修复原先两处 `new` 导致的自增 id 相互覆盖（日志/团队 id 撞车）
- 文档：`docs/audit-log.md`（模型/动作词表/端点/边界）、文档站「审计日志」页与 API 表
- 测试：`admin_data_test.cj` 过滤/排序/分页/清理用例、`audit_test.cj` 辅助函数用例、
  `tests/e2e.sh` 第 5 步审计端到端（发布登记 / 失败记录 / 登录审计 / 过滤 / 分页 / 清理 / 401）

### Added — 公开只读 API（C1–C5）

- `GET /api/stats`：包/版本/下载/组织/团队/用户数、存储字节、服务端版本、启动时间与运行时长
- `GET /api/packages`：包列表（分页 + 搜索 + `org::name` 语法 + 分类 OR + `updated/downloads/name` 排序）
- `GET /api/packages/:name`：包详情（全部版本 + 聚合 + 最新版本 README）
- `GET /api/packages/:name/:version`：版本详情（meta 全字段 + `sha256` + 制品字节 + 发布者）
- `GET /api/organizations`：组织列表（含包/版本计数；有包但未登记的组织以 `id=0` 下发）
- 可见性：`require_auth=false` 公开；`true` 时要求有效 Token，并按 `checkReadPermission`（与下载/索引同一裁决）
  过滤（未登录 401、越权 403）；软删版本对所有公开端点不可见
- 文档：`docs/public-api.md` + 文档站「公开只读 API」页与 API 表
- 测试：`public_service_test.cj` 9 组用例（语法/分页/过滤排序/软删隐藏/统计/版本/组织计数/私有可见性/JSON 转义）、
  `tests/e2e.sh` 第 6 步双仓实测 5 个端点

### Added — 包三级删除闭环（软删 / 恢复 / 硬删）

- `GET /api/admin/packages`：管理端版本列表（`organization`/`name`/`includeDeleted`/`page`/`size`，
  输出 `id`/`sha256`/`deletedAt`/`tarballSize` 等，供自动化调用删除端点）
- `DELETE /api/admin/packages/:id`：**软删除**（`deletedAt`；索引/下载/公开 API 立即不可见，制品保留）
- `PUT /api/admin/packages/:id/restore`：**恢复**（**校验制品仍在**：本地 blob 存在或该版本来自上游可回源；
  制品丢失时 409 拒绝，避免恢复出下载 404 的版本）
- `DELETE /api/admin/packages/:id/hard`：**硬删除**（仅允许对已软删版本执行，否则 409；
  删除记录 + 制品文件，不可恢复）
- **发布计划联动**：删除某版本时，引用它的未完成计划项标记为 `skipped`（`completed`/`failed` 保留历史；
  重复删除不重复计数），响应返回 `skippedPlanItems`
- 审计：`delete_package` / `restore_package` / `hard_delete_package`（detail 含 `skippedPlanItems`/`blobRemoved`/`artifactPresent`）
- 管理端包管理页：行内与版本弹窗均按状态给出「软删除」或「恢复/硬删除」，确认弹窗文案随模式变化
- 测试：`package_lifecycle_test.cj` 5 组用例（幂等软删、恢复校验制品/上游回源、硬删前置与制品清理、
  计划项联动、JSON 形状）；`tests/e2e.sh` 第 8 步（软删→下载/索引/公开 API 消失→恢复→硬删→文件清理→审计）
- 修复：`BlobStore.exists` 与 `std.fs.exists` **同名导致 `DiskBlobStore` 内部自递归**（依赖制品下载时
  触发 `Out of memory`），接口方法更名 `has`——详见 `docs/verification.md` §4

### Added — 上游连通性测试端点

- `POST /api/admin/upstreams/:id/test?name=&organization=`：诊断上游可达性与索引可用性
  - 指定 `name`（≥3 字符）→ 请求该上游的 NDJSON 索引端点；未指定 → 请求基地址
  - 返回 `reachable`（是否拿到响应）/`healthy`（200 且索引非空）/`status`/`latencyMs`/`bodyBytes`/
    `authUsed`/`packages`（索引包名样本）/`error`/`summary`（中文摘要）
  - 语义：404 = 连通但该上游未收录此包（不算故障）；401/403 = 认证失败；无响应 = 不可达（含原因）
  - 探测动作入审计（`test_upstream`，成功/失败分别记录，detail 含状态码与耗时）
- 测试：`upstream_probe_test.cj` 5 组用例（索引包名扫描容错、六种结果分类、认证标记、JSON 形状、URL 归一）；
  `tests/e2e.sh` 第 7 步（可达上游 / 上游无此包 / 不可达上游 / 不存在的上游 404 / 审计）
- 实测：官方上游 `cordis_core@ystyle` → 200（340 字节，样本 cordis_core/tomlcj/jsonvalue）；
  本地上游 → 200；`127.0.0.1:9` → 不可达（Connection refused）

### Added — 交付形态（Docker / 文档站 / CI）

- **Docker / Compose 部署**：`Dockerfile`（archlinux 基础 + liburing/tzdata，宿主机构建二进制入镜像、非 root 运行）、
  `docker-compose.yml`（卷持久化 + 环境变量 + 健康检查）、`scripts/docker-deploy.sh`，CI 含镜像构建与容器冒烟
  （初始化 → 启动 → 健康 → 优雅关闭 → 重启后数据留存）
- **VitePress 文档站**：`docs-site/`（指南/API/部署/关于，local search，`base=/cjreg/`），
  `docs-deploy.yml` 自动发布到 GitHub Pages + 华为云 CDN 刷新（`https://ystyle.top/cjreg/`）
- **CI / Release**：`ci.yml`（构建 + 单测 + 覆盖率 + 双仓 e2e + 文档站 + **本地**镜像冒烟）、
  `release.yml`（**tag 驱动**：linux-amd64 二进制产物 + 自动创建 GitHub Release + 推送 `ghcr.io/ystyle/cjreg:<tag>`/`:latest`）
- 发版流程文档：`docs/RELEASE.md`（tag 为两侧唯一事实来源，含前置检查/校验命令/常见问题）
- 容器冒烟两处修复：镜像构建后 `chmod 0755`（CI artifact 往返丢执行位 → `permission denied`）；
  数据目录属主对齐容器 uid 1000（`scripts/docker-deploy.sh` 自动 chown，文档补充说明）

### Added — 官方协议互通（M1/M2）

- `POST /pkg/:name[?organization=]`：官方二进制格式（meta 段 + tar 段，各自的版本号与长度前缀）解析与入库；
  meta-data.json 15 字段全量存储；meta 与 URL 一致性校验；制品 SHA-256 校验；同版本同 sha 幂等
- `GET /pkg/:name/:version`：制品下载（tar.gz + `Content-Disposition`），本地未命中回源上游；下载计数
- `GET /index/:mo/:du/:name`：NDJSON 索引生成，依赖条目（`dependencies`/`test-dependencies`/`script-dependencies`
  与 `target`/`type`/`output-type`）原样透传
- 统一错误响应体 `{"error": ...}` 与 400/401/403/404/409 语义
- 兼容性修复（均固化为回归测试）：官方索引 `index-version` 为字符串、cjpm meta 为 pretty 多行 JSON、
  sha256sum/dependencies 位于嵌套 index、bstorm 重启 reindex 与跨进程 id 恢复、二进制制品读取不能走 UTF-8 文本流

### Added — 存储与配置

- bstorm（badger-cj）嵌入式 JSON 文档库；集合划分 `pkg`/`blob`/`user`/`org`/`upstream`/`log`/`cache:index`
- 制品内容寻址（sha256）去重存储，落盘 `dataDir/blobs`
- 服务端配置 `cjreg.toml`（`[server] public_url / port / permission_mode / require_auth`）：
  `cjreg init` 生成带注释模板；优先级 命令行（`-p`）> 配置文件 > 默认值；无环境变量配置项
- 对外地址 `public_url` 贯通用户门户示例与帮助文档；`-c/--config` 指定配置路径

### Added — 认证与权限（M3）

- pbkdf2（SHA512 + 随机 salt）用户名口令认证；`sess-*` 会话 token（24h TTL）与 `publish-*` 发布 token
- 管理 API：`login`/`logout`/`me`/用户列表与创建；`init` 在空数据目录创建首个管理员（无 HTTP bootstrap、无 admin key）
- 团队权限模型：团队 = 权限单元（`read`/`write`/`overwrite`），关联组织/包/成员（`TeamOrganization`/`TeamPackage`/`TeamMember`）
- 发布双路径裁决：`有效权限 = max(个人发布路径, 团队路径)`
  - 新包在**未被团队纳管**的命名空间可被任意有效 token 认领（首次发布者成为 owner）
  - 已有包新版本需 `write`；覆盖同版本（sha 不同）需 `overwrite`
  - 覆盖为原地更新（保持 id/createdAt），且不转移包名所有权
  - 组织 ID 语义：空组织 = 0，未登记组织 = -1（不匹配任何组织关联）
- 包名所有者（owner）唯一：取该包最早一条版本记录的发布者；版本级 `publisherId` 逐版本累加仅作事实记录
- 读鉴权开关 `require_auth = true`：下载/索引需有效 token + `read` 权限（401/403 分支）
- 多管理员安全约束：禁止禁用/降级「最后一个启用管理员」；`PUT /api/admin/users/:id/admin` 提升/取消管理员
- 应急通道：`cjreg admin reset-password`（重置口令 + 强制启用管理员）

### Added — 多仓/代理/解析（M4/M5）

- 上游数据表（name/url/enabled/cacheTtl/authToken/isOfficial/priority），官方仓自动识别且受保护不可删除
- 按 priority 的多上游回源（索引 + 制品，302 跟随），索引缓存 `cache:index`（按 cacheTtl 过期）
- 上游认证：回源与推送均带 `Authorization: {authToken}`（裸 token，对齐官方规格）
- `GET /api/admin/resolve`：多仓解析诊断（候选仓 trace、conflicts、strict 模式、`replaced_by`）

### Added — 发布计划（M5/M6）

- `analyze`：复用 cjdep 的依赖拓扑排序，四分类（`need_publish`/`version_optional`/`already_exists`/`conflict`）
- `execute`：按拓扑序串行推送至目标上游；`target_token` 或按 URL 匹配上游表取 `authToken`
- 重启恢复：启动时把 `running`/`paused` 计划复位为 `pending`，避免悬挂
- 管理端页面：计划列表/详情、items 选择、开始/暂停、进度推送（`App.pushUpdate`）

### Added — 界面（cjxt，全栈仓颉零 JS 构建链）

- 管理后台：登录、仪表盘、包管理、上游管理、组织管理、团队管理（成员/组织/包关联）、用户管理、日志、发布计划
- 公开门户：首页（统计/分类）、包列表（搜索/分类筛选/分页）、包详情（安装配置引导）、帮助文档（6 章）
- 用户门户：`/user/login`（接受所有启用用户，含管理员）+ `/me`（我的发布 Token / 我的包 / 我的团队与权限）
- 公开导航按登录态显示（未登录「登录」/ 已登录「我的」/ 管理员额外「管理后台」），渲染期读 cjxt 会话上下文
- 登录页 loading：`Loading` 组件 + 「先出 loading 补丁、后台线程校验口令、`pushUpdate` 收尾」
- 用户 API：`/api/user/me`、`/api/user/me/publish-token`、`/api/user/me/packages`、`/api/user/me/teams`

### Added — 部署与运维

- `cjreg init`（创建管理员 + 默认官方上游 + 生成 `cjreg.toml`）、`cjreg serve`（HTTP + 管理 API + Web UI 单端口）、
  `cjreg admin reset-password`（应急）
- **优雅关闭**：`serve`/`admin-ui` 注册 SIGINT/SIGTERM（`Ctrl+C` / `docker stop` / `systemctl stop`）→
  先停 HTTP 服务 → 关闭数据库（flush memtable 落盘）→ 正常退出（exit 0）；重复信号幂等
- **请求体上限可配**：`cjreg.toml` 的 `max_request_bytes`（默认 500 MiB，`-1` 不限）——stdx 默认仅 2 MB，会让大包发布被拒
- **Docker / Compose 部署**：`Dockerfile`（archlinux + liburing/tzdata/ca-certificates、非 root、健康检查、
  `STOPSIGNAL SIGTERM`）、`docker-compose.yml`（卷 / 端口 / GC 环境变量 / `stop_grace_period`）、
  `scripts/docker-deploy.sh` 一键部署脚本；容器内实测优雅关闭与卷数据留存
- **CI / Release 工作流**（GitHub Actions，供镜像仓使用）：构建 + 单测 + 覆盖率 + 双仓 e2e + 文档站构建 +
  容器冒烟；Release 触发产出二进制并推送 `ghcr.io` 镜像
- **文档站自动部署**：`docs-deploy.yml` → GitHub Pages（`DOCS_BASE=/cjreg/`）+ 华为云 CDN 缓存刷新，
  发布地址 <https://ystyle.top/cjreg/>
- **内存说明文档化**：badger arena（2×memTableSize）+ 仓颉 GC 堆默认 256 MB 的构成，以及 `cjHeapSize`/`cjGCThreshold`/`cjGCInterval` 调参
- `--static` 静态编译单二进制；多 target 配置（Linux x86_64/aarch64、macOS、Windows、OpenHarmony）
- 数据目录即数据：备份/迁移 = 拷贝目录

### Fixed

- HTTP 请求体沿用 stdx 默认上限 **2 MB**，超过即被拒（413/连接重置）；现由 `max_request_bytes` 控制（默认 500 MiB）
- `httpPostBinary` / `httpGet` 未设置 `Authorization` 头（含上游 `authToken`、发布计划推送目标仓）——
  导致向需要认证的目标仓推送必然 401、私有上游回源无法认证
- `tests/e2e.sh` 未注入发布 token（测试包 `cangjie-repo.toml` 的 token 为空 → 发布必然 401）
- 发布端点在 team 模式下的权限裁决此前未区分「新包 / 新版本 / 覆盖」三态
- 发布入库未写 `createdAt`/`updatedAt`；未知组织名会落到「无组织」桶导致越权
- `POST /api/admin/users` 此前硬编码 `isAdmin = false` 且只认 multipart 表单（JSON 请求会异常）

### Security

- 口令 pbkdf2（SHA512、90 万次迭代、16 字节随机 salt），对齐 cjcc 规范
- 会话 token 可登出失效；禁用用户即刻失效（每次鉴权反查用户状态）
- 发布/回源/发布计划确认三处 SHA-256 校验；同版本异 sha 不静默覆盖
- 读鉴权开关（私有仓部署建议开启）；管理操作与认证事件写入审计日志

### Changed

- 依赖升级：`bstorm` 1.4.7 → **1.4.8**

### Tests

- 单元测试 24 个文件 / 154 个用例（`cjpm test` 全绿）；纯逻辑层行覆盖 85%–97%（protocol 97%、auth 96%、
  config 95%、index 94%、store 85%、server 逻辑 92%），整体 `src/` 行覆盖 39.3%（含 UI/HTTP 适配层，
  后者以 e2e 与浏览器冒烟验证为主）
- 双仓 e2e（`tests/e2e.sh`）：6 个真实依赖包发布 → 拓扑分析 → 6/6 推送至目标仓 → 目标仓索引/下载/依赖校验
- 权限矩阵 e2e：401/403/200 分支（含 owner 与团队 write/overwrite、覆盖不转移所有权）；配置优先级 e2e

[Unreleased]: https://atomgit.com/ystyle/cjreg/compare/v0.1.0...HEAD
[0.1.0]: https://atomgit.com/ystyle/cjreg/releases/tag/v0.1.0
