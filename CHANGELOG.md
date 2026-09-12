# Changelog

本文件记录 cjreg 的重要变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

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

### Added — 交付形态（本版）

- **Docker / Compose 部署**：`Dockerfile`（archlinux 基础 + liburing/tzdata，宿主机构建二进制入镜像、非 root 运行）、
  `docker-compose.yml`（卷持久化 + 环境变量 + 健康检查）、`scripts/docker-deploy.sh`，CI 含镜像构建与容器冒烟
  （初始化 → 启动 → 健康 → 优雅关闭 → 重启后数据留存）
- **VitePress 文档站**：`docs-site/`（指南/API/部署/关于，local search，`base=/cjreg/`），
  `docs-deploy.yml` 自动发布到 GitHub Pages + 华为云 CDN 刷新（`https://ystyle.top/cjreg/`）
- **CI / Release**：`ci.yml`（构建 + 单测 + 覆盖率 + 双仓 e2e + 文档站 + 镜像）、`release.yml`（linux-amd64 二进制 + ghcr 镜像）
- 容器冒烟两处修复：镜像构建后 `chmod 0755`（CI artifact 往返丢执行位 → `permission denied`）；
  数据目录属主对齐容器 uid 1000（`scripts/docker-deploy.sh` 自动 chown，文档补充说明）

### 计划中

- **发布链路流式化**（大包稳定 + 内存 O(1)）：当前 `POST /pkg` 整包读入内存（峰值 ≈ 包体 2–3 倍），
  受仓颉 GC 堆默认 256 MB 限制，40 MiB 以上的包在默认配置下可能 OOM —— 详见 `docs/finals-plan.md` 迭代 1
- 包三级删除闭环（恢复/硬删入口与索引、缓存、发布计划联动）
- 组织 CRUD REST 端点（当前仅管理端界面）
- 发布计划 item 六状态（`publishing`/`waiting_index`/`skipped`）与 SSE 进度流
- 镜像预热/周期同步（`serve --sync-interval`）与性能基准报告
- 团队所有者（owner 自助管理成员）——设计见 `docs/user-portal-design.md` §7.4

## [0.1.0] - 2026-09-12

首个可用版本：与官方中心仓协议互通的纯仓颉私有中心仓 + 多仓体系，静态单二进制交付。

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
