# cjreg 设计文档

仓颉私有中心仓与多仓工具（课题：仓颉中心仓多仓配置与私有化体系建设）

```txt
Cangjie	技术课题	

技术课题名称：仓颉中心仓多仓配置与私有化体系建设

主要交付内容：
1. 为 cjpm 提供多仓配置及优先级查找能力  
2. 适配多仓依赖解析、冲突处理和版本强制替换  
3. 提供私有中心仓一键部署工具  
4. 支持镜像仓、代理仓及仓库间同步	

关键验收指标：
多仓机制不得破坏原有依赖解析规则；私有中心仓能够部署、运行并完成镜像、代理或同步等核心场景验证
```

## 1. 定位与目标

用仓颉重写/扩展 [cjrepo](https://github.com/ystyle/cjrepo) 的能力，形成"私有中心仓 + 多仓"完整体系。**服务端 100% 仓颉实现**；**测试脚本与 Web 管理前端复用 cjrepo 资产**。

### 1.1 资产复用策略（测试 + 前端）

| 资产 | 来源 | 复用方式 | 需改写部分 |
|---|---|---|---|
| **hurl API 测试** | cjrepo `tests/*.hurl`（7 文件 + runner） | 后端 API 契约对齐 cjrepo（路径/请求/响应字段）后直接复用：public-api / organization / team-permission / package-management / publish-plan / pagination | **auth.hurl / user-management.hurl**（认证模式不同：admin_key md5 → pbkdf2 用户名密码），按 cjreg 认证改写 |
| **Web 管理前端** | cjrepo `frontend/`（Vue 3 + Vite + TS，`src/api/*.ts` 即 API 契约） | 构建产物由 cjreg serve 托管（静态文件）；API 层契约 = cjreg 后端实现依据 | **登录/用户管理页**（adminKey → 用户名密码）；`src/api/admin.ts` 的 login 适配 |

**约束（重要）**：复用即契约——cjreg 后端 API 的**路径、请求/响应 JSON 结构**必须与 cjrepo 的 `frontend/src/api/*.ts` 与 `tests/*.hurl` 保持一致（除认证相关），否则前端与测试无法复用。API 差异点（如 `GET /api/admin/resolve` 等 cjreg 增强）以追加端点方式扩展，不改动既有契约。

面向课题 4 项需求与验收点：

| # | 需求 | 验收点 |
|---|---|---|
| 1 | 为 cjpm 提供多仓配置及优先级查找能力 | 多仓机制**不得破坏原有依赖解析规则** |
| 2 | 适配多仓依赖解析、冲突处理和版本强制替换 | 同上 + `[replace]` 保留 |
| 3 | 提供私有中心仓一键部署工具 | 私有中心仓能够**部署、运行** |
| 4 | 支持镜像仓、代理仓及仓库间同步 | 完成**镜像、代理或同步**核心场景验证 |

## 2. 命令设计（`std.argopt`）

```
cjreg <command> [options]

命令：
  serve      启动私有中心仓 HTTP 服务（发布/下载/索引 + 管理 API）
             · 内置按需回源代理（本地未命中 → 按优先级回源上游并缓存）
             · 可选后台任务：--sync-interval <dur> 定期镜像/同步（增强）
  init       初始化数据目录（空数据目录上创建首个管理员 + 默认官方上游 + 组织），生成 docker 配置
  admin      应急管理（reset-password 重置用户密码，直接操作本地数据目录）

选项：
  -d, --data <dir>      数据目录（默认 ./data）
  -p, --port <n>        serve 端口（默认 8060）
  -j, --json            JSON 输出
  -h, --help
```

> **命令收敛说明**：私有仓的运维能力（上游表、发布计划、团队、解析诊断、镜像/同步）全部为**服务端能力**——serve 内置 + 管理 API，**发布计划/解析诊断等为 Web 界面功能**（配管理前端），不设独立 CLI 子命令；CLI 只保留部署/应急三件套（serve / init / admin）。

## 3. 多仓配置模型（需求 1）

> **主线策略（默认，对齐 cjrepo 模式）**：**客户端 cjpm 零修改**——通过替换 `cangjie-repo.toml` 中 `[repository.home].registry` 的地址指向"入口仓"（私有仓），多仓配置与优先级查找全部由**服务端**承担（私有仓配置多个上游）。cjpm 原有依赖解析规则完全不变（验收点"不破坏原有规则"天然满足）。
> 改 cjpm 源码加客户端原生多仓（`[repository.<name>]` + priority）为**可选加分项**，本地有 cjpm 源码，`SettingsConfig.repository` 本就是多命名 map，改动面小。

### 3.1 客户端视角（cjpm 零修改，替换地址）

```toml
# 用户侧 cangjie-repo.toml —— 只改 registry 地址指向入口仓（与 cjrepo 工作流一致）
[repository.cache]
    path = "./.cache"

[repository.home]                    # 语义不变，仅地址指向私有仓
    registry = "http://repo.internal.cangjie.cn:8060"
    token = "..."
```

- 单仓库对 cjpm 完全透明：`resolve` 命中即用，未命中即 404（由服务端决定是否回源）。
- 环境切换 = 换地址：切官方/私有/测试仓只需改这一行，`cjpm clean && cjpm update` 刷新缓存。

### 3.2 服务端多上游（数据库表管理，多仓核心）

多上游存**数据库表**（bstorm 集合 `upstream`，对齐 cjrepo `upstreams` 表），通过管理 API 增删改查，**不使用配置文件**。

#### 数据模型

```
Upstream { id, name(唯一), url, enabled, cacheTtl(默认 86400s),
           authToken, isOfficial, priority, lastSyncAt }
```

- `isOfficial`：是否**官方中心仓**（`https://pkg.cangjie-lang.cn/registry`）。录入时按 URL 自动识别，也可显式指定。
- `authToken` 两种用途：
  1. **回源认证**（只读拉取）：部分非官方仓需要；
  2. **发布认证**（写操作）：向该仓 `POST /pkg` 发布时需要——**向官方中心仓发布必须配置官方 token**（即用户 `cangjie-repo.toml` 的 `repository.home.token`），由发布计划/发布任务读取使用。

#### 官方仓 vs 非官方仓的差异处理

| 维度 | 官方仓（isOfficial=true） | 非官方仓（私有/第三方镜像） |
|---|---|---|
| 默认存在 | 首次初始化自动录入一条官方上游 | 需手动添加 |
| 删除/禁用 | 受保护：不可删除（可禁用需二次确认） | 可自由增删改/禁用 |
| 拉取认证 | 索引公开，无需 token | 可能需要 `authToken` |
| **发布认证** | **必须配置 `authToken`（官方 token）才能向官方仓发布** | 私有仓用各自用户/发布 token |
| 可信度 | 默认信任 | 制品做 **sha256 校验 + 记录来源**（来源标记入元数据） |
| 冲突裁决 | 同版本不同 sha 时官方仓优先（除非显式调整 priority） | 按 priority |

#### 管理 API（session+admin，对齐 cjrepo）

| 端点 | 说明 |
|---|---|
| `GET/POST /api/admin/upstreams` | 上游列表（含 isOfficial）/ 添加 |
| `PUT/DELETE /api/admin/upstreams/:id` | 更新（url/priority/enabled/cacheTtl）/ 删除（官方仓拒绝） |
| `POST /api/admin/upstreams/:id/test` | 连通性测试 |
| `GET /api/admin/upstreams/:id/cache-stats` | 缓存统计 |
| `POST /api/admin/upstreams/:id/clear-cache` | 清缓存 |

- 服务端按优先级依次查各上游索引（`/index/{mo}/{du}/{name}`），命中即缓存返回；本地已发布优先于上游。
- **发布目标**：默认只写本地仓（`POST /pkg` 用本地用户发布 token）；发布计划可选"转发发布到指定上游"（如官方中心仓，`POST {upstream}/pkg` 用该上游的 `authToken`）。
- 缓存：索引按 (upstream,name,org)、制品按 (upstream,name,version)（bstorm/文件），按 `cacheTtl` 过期。

### 3.3 优先级查找

```
resolve(name, org, version):
  repos = sort(上游项, by priority asc, 出现顺序 asc)
  for repo in repos:
     idx = GET {repo.registry}/index/{mo}/{du}/{name}?organization={org}
     if 命中 version → 返回 (repo, entry, tarball)
  未命中 → 返回 not_found（并记录"候选仓列表"供诊断）
```

### 3.4 可选加分项：cjpm 客户端原生多仓（改源码）

- `central_repository.cj`：`RepositoryInfo` 增加 `priority`/`readonly`/`upstream`，`SettingsConfig.deserialize` 容错未知字段；
- 客户端 `resolve` 按优先级遍历多仓；不破坏 `[repository.home]` 原语义；
- 作为课题答辩时的"为 cjpm 提供多仓配置能力"直接证据，不阻塞主线。

## 4. 依赖解析、冲突与版本强制替换（需求 2）

### 4.1 多仓解析
`resolver/`：给定 `(name, org, require)`，按优先级在各仓索引中查找满足 `require` 的最佳版本（复用 `semver_range`：精确/区间/caret/tilde/预发布）。

### 4.2 冲突处理
- 冲突定义：同 `name+version` 在不同仓 `sha256sum` 不一致。
- 策略（可配置，默认）：
  - **解析期**：取优先级最高仓的结果，标记 `conflict` 并在日志/报告提示；
  - **严格模式**（接口参数 `strict=true` 或全局配置）：遇冲突直接报错，不静默选择。
- 对齐 cjrepo `Analyze` 的 `conflict` 分类。

### 4.3 版本强制替换
- 保留 cjpm `[replace]`（工作空间统一版本）语义：`replace` 命中时，跨仓一律按 `[replace]` 指定的版本解析，忽略各仓实际差异。
- 解析结果输出 `replaced_by` 说明。

### 4.4 解析诊断接口（`GET /api/admin/resolve`）

多仓解析的诊断能力做成 **HTTP 接口**（而非 CLI 命令），serve 起来后 Web 界面 / curl 均可查询：

```
GET /api/admin/resolve?name={module}&org={org}&require={版本需求}&strict={true|false}
→ 200 {
    "name": "...", "org": "...", "require": "...",
    "selected": {"repo": "official", "version": "1.1.0", "sha256sum": "..."},
    "candidates": [ {"repo": "...", "version": "...", "sha256sum": "...", "conflict": false}, ... ],
    "conflicts": [...], "replaced_by": "...", "replaced": false,
    "trace": [ "official: index hit 1.1.0", "backup: 404", ... ]   // 候选仓排查链路
  }
→ 404 { "error": "not found", "trace": [...] }
```

- `trace` 记录每个上游的查找结果（命中/404/冲突），用于排查"为什么解析到 X / 为什么找不到"；
- 管理界面（可选）加"包解析查询"页，直接展示候选链路与冲突。

## 5. 私有中心仓服务端（需求 3）

### 5.1 协议（与官方中心仓互通）

**规格依据**：官方通信/元数据/配置规格（cjrepo 仓库 `docs/` 三份整理件）：
`中心仓通信规格.md`（端点与返回码）、`中心仓元数据规格.md`（meta-data.json 与 index 条目）、`中心仓相关CJPM配置项.md`（bundle 与模块名/组织名规格）。

| 端点 | 说明 |
|---|---|
| `POST /pkg/:name[?organization=]` | **发布**（官方二进制拼接格式，见下）；`Authorization: {token}` |
| `GET /pkg/:name/:version[?organization=]` | 下载制品，返回 `tar.gz` 源码包 |
| `GET /index/:mo/:du/:name[?organization=]` | 索引下载，每行一个 JSON 条目（NDJSON） |
| `/api/...` | cjreg 自有管理 API（用户/团队/包/上游/发布计划/日志/统计），非官方协议 |

**发布请求体格式（对齐官方二进制拼接，非 multipart）**：

```
[meta 段]  meta-version(1B) + 长度(4B LE) + meta-data.json 字节流
[tar 段]   index-version(1B) + 长度(4B LE) + .cjp 制品字节流
```
- 约束：段版本必须匹配（meta=1 / tar=1）；单段 ≤ 500MB；长度不符/数据不完整 → 400
- 入库校验：meta 中 name/org/version 与 URL 一致；`sha256sum`（index 条目）与 tarball 实际 SHA-256 一致（`stdx.crypto`）

**索引 URL 短名规则**（对齐官方 `mo`/`du` 分片）：
- 官方模块名规格为 **[3, 64] 字符**（组织名不能为 `default`）——`<3` 字符模块名本就不合规，索引 URL 的 `<3` 分支是防御性处理

**返回码规格**：`200` 成功 / `400` 参数或元数据/索引解析错误 / `401` 认证失败 / `403` 无权限 / `404` 不存在 / `409` 与已有制品冲突 / `>=500` 服务器故障
- 统一错误响应体：`{"error": "<message>"}`（对齐 cjrepo customErrorHandler）
- **覆盖 vs 409 语义**：同版本重复发布时——有 `overwrite` 权限 → 覆盖（先删旧记录再入库，200）；无 `overwrite` 权限 → 403（无权限）；与已有制品 sha256 完全一致 → 幂等 200 或 409（按配置）

**本地仓读写鉴权开关（requireAuth，私有化必需）**：
- `requireAuth=false`（默认）：`GET /pkg`、`GET /index` 公开（无需认证）；`POST /pkg` 仍需发布 token
- `requireAuth=true`：下载/索引也需有效 token，且做团队 `read` 权限检查——私有仓部署建议开启

**下载响应头**：`Content-Type: application/x-gzip` + `Content-Disposition: attachment; filename="{name}-{version}.cjp"`

**官方仓 base URL 定死**：`https://pkg.cangjie-lang.cn/registry`（含 `/registry` 后缀）；`isOfficial` 自动识别即匹配此前缀。

> **注意**：官方协议**没有健康检查端点**；cjreg 自有存活检查固定走 `/api/health`，不属于互通协议。

### 5.2 存储（bstorm —— 基于 badger-cj 的 JSON 文档数据库）
`store/` 基于 **bstorm**（自研嵌入式 JSON 文档数据库，badger-cj 存储引擎 + gjson 查询，零 FFI）：
- **JSON 文档原生**：包元数据/索引/用户/上游/日志均以 JSON 文档存储，无需 Schema，天然对齐 `meta-data.json` 的 `index` 字段。
- **流式扫描**：全表/条件扫描无内存压力（适合索引遍历、镜像同步 diff、日志查询）。
- 集合划分：`pkg`、`blob`（内容寻址去重）、`user`、`org`、`upstream`、`log`、`cache:index`。

#### 5.2.1 包文档字段（meta 之外的服务端附加字段）

`pkg` 集合文档 = meta-data.json 全字段 + 服务端附加字段：

```
pkg 文档 { ...meta-data.json 15 字段（organization/name/version/cjc-version/description/
          artifact-type/executable/authors/repository/homepage/documentation/tag/category/
          license/index/meta-version）,
          publisherId,        // 发布者用户 ID（A1 个人发布路径）
          downloadCount,      // 下载计数（下载时自增）
          upstreamId,         // 来源上游 ID（回源落库时写入）
          upstreamName,       // 来源上游名
          readme,             // 发布时从 .cjp 提取 README_zh.md/README.md（可选）
          deletedAt,          // 软删除时间戳（三级删除模型，见 §5.6）
          createdAt, updatedAt }
```

- 元数据字段级处理：发布入库时校验并整存 meta 全字段；`category`（上限 5，大小写归一化）、`tag`（上限 5）、`executable` 等字段用于索引生成与包展示
- index 条目的依赖项需**原样透传** `{name, require, target, type, output-type}`（平台隔离/编译模式/产物类型）与三类依赖（dependencies/test-dependencies/script-dependencies）

#### 5.2.2 数据迁移策略

- bstorm 无 schema，但 JSON 文档结构会演进：采用**版本化迁移**——`meta` 字段记录集合结构版本（`docVersion`），迁移脚本按版本升级文档（对齐 cjrepo migrations 框架的语义，避免长期维护失控）。

### 5.3 认证（用户名密码 + 发布 token）

课题对认证有强要求，采用**完整用户体系（cjcc 模式）**，无 admin key、无 HTTP bootstrap 端点：

| 机制 | 用途 | 参考 |
|---|---|---|
| **用户名 + 密码 → pbkdf2 校验 → 签发 session token** | 管理面认证（管理员/普通用户登录） | cjcc 模式 |
| per-user **发布 token**（`publish-*`，写入 cangjie-repo.toml `token`） | `POST /pkg` 上传鉴权，与 cjpm 发布链兼容 | cjrepo token |

安全层级：发布 token < 管理面 session token < 密码本身。

**首个管理员创建**：部署期 `cjreg init --username admin --password <pwd>`，**信任凭证 = 本地 CLI + 空数据目录**（已初始化则拒绝，无需任何 key）。**应急重置**：`cjreg admin reset-password --username <u> --password <new>`，直接操作本地数据目录（拥有文件系统即拥有权限）。

```
部署引导流程：
  cjreg init --username admin --password <pwd>
    → 空数据目录上创建首个管理员用户（已初始化则拒绝）
    → 生成默认配置 + 数据目录 + Docker 配置
应急（忘记密码）：
  cjreg admin reset-password --username admin --password <new>
```

#### 5.3.1 密码哈希（对齐 cjcc）

- `pbkdf2(password.toUpper(), salt, 900000 迭代, 64 字节, SHA512)`（`pbkdf2` 库）
- 存储格式：`{salt}:{hex(hash)}`；salt 16 字节，`SecureRandom` 生成

#### 5.3.2 数据模型

```
User       { id, username, passwordHash, isAdmin, isActive, publishToken }
UserToken  { token, userId, kind: session|publish, expiresAt }
UserStore  接口：saveUser / getUserByUsername / getUser / getToken / saveToken / removeToken
           ├── MemoryUserStore（测试/内存）
           └── BstormUserStore（M2 接入 bstorm 集合）
TokenGenerator：sess-* / publish-* + 32 位随机串（cjcc 同款）
```

#### 5.3.3 认证 API（tang 路由）

| 端点 | 鉴权 | 说明 |
|---|---|---|
| `POST /api/admin/login` | 无 | 用户名+密码 → `{user, token, expiresAt}` |
| `POST /api/admin/logout` | session | 注销 token |
| `GET  /api/admin/me` | session | 当前用户信息 |
| `POST /api/admin/users` | session+admin | 创建用户（普通/管理员，body `{username,password,isAdmin?,email?}`） |
| `PUT  /api/admin/users/:id/admin` | session+admin | 提升/取消管理员（body `{isAdmin}`；最后一个启用管理员 → 409） |
| `PUT  /api/admin/users/:id/password` | session+admin/本人 | 修改密码 |
| `POST /api/admin/users/:id/reset-token` | session+admin | 重置发布 token |
| `POST /pkg/:name` | **发布 token** | 包上传（兼容 cjpm cangjie-repo.toml token） |

> 首个管理员走 CLI `init`（空数据目录），HTTP 层无 bootstrap 端点、无 admin key。

#### 5.3.4 登录流程（普通用户）

```
POST /api/admin/login {username, password}
  → UserStore.getUserByUsername
  → isActive 校验 → PasswordHash.verify
  → TokenGenerator.generateSessionToken()（TTL 默认 24h）
  → UserStore.saveToken → 返回 token
之后所有管理 API 带 Authorization: Bearer <token>
  → AuthService.validateSessionToken → ctx.kvSet("userId")
```

#### 5.3.5 测试计划

| 用例 | 断言 |
|---|---|
| PasswordHash.hash/verify | 正确密码通过、错误密码失败、salt 随机 |
| initAdmin（CLI 语义） | 空数据目录创建管理员；已初始化/目录非空拒绝 |
| login | 成功签发 session token；密码错/用户不存在/停用 → None |
| validateSessionToken | 有效 token 通过；过期/类型不符/登出后 → None |
| validatePublishToken | 用户发布 token 可发布；错误 token 拒绝 |
| createUser/changePassword/resetPublishToken | 普通用户全生命周期 |

#### 5.3.6 权限检查流程（对齐 cjrepo 双路径）

```
请求（发布/下载/索引/管理）→ 提取 token → 获取用户
  1. 超级管理员（isAdmin）→ 直接放行（全部操作）
  2. 发布/下载/索引按资源查权限：
     a. 先查 TeamPackage（包级权限）→ 命中即用
     b. 无包级 → 查 TeamOrganization（组织级权限）
     c. 都无 → 走"个人发布路径"（仅发布场景，见下）
  3. 权限级别满足 → 放行；否则 403
```

**发布动态权限（对齐 cjrepo）**：
- **新包**（该 name 无任何版本）：任意有效发布 token 即可 → 记录 `publisherId`，首次发布者自动成为 publisher
- **已有包新版本**：publisher 自动获得 write；非 publisher 需团队 write 权限
- **覆盖已存在版本**：需 `overwrite` 权限（publisher 无覆盖权，走团队路径）；无权限 → 403

**个人发布路径（无组织包）**：`publisherId` 驱动——包级权限裁决 = max(团队权限, 个人 publisher 权限)，任一满足即放行。

### 5.4 团队管理（对齐 cjrepo）

按 cjrepo 的团队权限模型：**团队 = 权限单元**，关联"组织/包 + 成员"，对关联资源整体授予权限级别。

#### 5.4.1 数据模型

```
Team              { id, name(唯一), displayName, description, permission: read|write|overwrite }
TeamOrganization  { id, teamId, organizationId（null = 无组织包） }
TeamPackage       { id, teamId, organization（空 = 无组织包）, packageName }
TeamMember        { id, teamId, userId }
```

#### 5.4.2 管理 API（tang 路由，session+admin）

| 端点 | 说明 |
|---|---|
| `GET/POST /api/admin/teams` | 团队列表 / 创建 |
| `PUT/DELETE /api/admin/teams/:id` | 更新（含 permission）/ 删除 |
| `GET/PUT /api/admin/teams/:id/organizations` | 团队-组织关联 |
| `GET/PUT /api/admin/teams/:id/packages` | 团队-包关联 |
| `GET/PUT /api/admin/teams/:id/members` | 团队-成员关联 |
| `GET /api/admin/users/:id/teams` | 用户所属团队列表（A4） |

#### 5.4.3 权限语义

- 用户对包的操作权限 = max(个人 publisher 角色, 所在团队对该包/所属组织的 permission)
- `read`：可下载/查看；`write`：可发布新版本；`overwrite`：可覆盖已存在版本
- 检查顺序与发布动态权限见 §5.3.6（包级 TeamPackage → 组织级 TeamOrganization → 个人发布路径）

### 5.5 发布计划（对齐 cjrepo，分析能力复用 cjdep）

**发布计划 = 依赖分析（拓扑排序）+ 顺序发布执行 + 进度事件**。分析部分（resolvePackages/分类）正是 cjdep 已实现并验证的能力（vendored 复用）。

#### 5.5.1 数据模型

```
PublishPlan    { id, name, targetUpstream, status, totalCount, completedCount, pollInterval, pollTimeout }
PublishPlanItem{ id, planId, packageId, order, category, status, selected, error, startedAt, completedAt }
```

- `category`：`need_publish` / `version_optional` / `already_exists` / `conflict`（cjdep 已验证）
  - 判定条件：`conflict`=版本相同+SHA256 不同；`need_publish`=目标仓无此版本；`version_optional`=存在更高/部分版本缺失；`already_exists`=版本相同+SHA256 相同；推荐版本 = 满足依赖范围的最高版本
- `status` 状态机：`pending → running ⇄ paused → completed/failed`
- **item 状态枚举**（对齐 cjrepo 6 状态）：`pending`（待发布）/ `publishing`（发布中）/ `waiting_index`（已发布，等待目标仓索引出现该版本）/ `completed`（索引确认通过）/ `failed`（失败，含 error）/ `skipped`（跳过，含用户手动跳过与依赖失败跳过）

#### 5.5.2 管理 API（tang 路由，session+admin）

| 端点 | 说明 |
|---|---|
| `GET/POST /api/admin/publish-plans` | 计划列表 / 创建 |
| `POST /api/admin/publish-plans/analyze` | 依赖分析：拓扑排序 + 分类（复用 cjdep analyzer） |
| `GET /api/admin/publish-plans/:id` | 详情（含 items） |
| `PUT /api/admin/publish-plans/:id/items` | 选择/取消 items（selected） |
| `DELETE /api/admin/publish-plans/:id` | 删除 |
| `POST /api/admin/publish-plans/:id/start` | 开始执行（按 order 顺序发布） |
| `POST /api/admin/publish-plans/:id/pause` / `resume` | 暂停 / 继续 |
| `GET /api/admin/publish-plans/:id/events` | SSE 进度事件流（`data: {type, payload}`） |

**analyze 请求/响应**：
- 请求：`{packages: [{organization, name, version}], target_upstream}`（等价 `org::name@version` 入参）
- 响应：`{packages: [{name, version, category, dependency_range, local_versions, remote_versions, recommended_version, selected, sha256, remote_sha256}], publish_order}`
- 去重规则：同包名同版本 → 保留一个；同包名不同版本 → 用用户指定版本或最高版本

#### 5.5.3 执行引擎

- 按拓扑顺序（依赖先于依赖者）逐个发布：发布 → 轮询目标仓索引确认 → 标记 completed → 下一个
  - **确认条件**：目标仓索引出现该版本**且 SHA256 一致**（不止版本存在）
- **发布目标与认证**：默认发布到本地私有仓（`POST /pkg` 用本地用户发布 token）；计划可配置 `targetUpstream`——转发发布到指定上游（如官方中心仓，`POST {upstream}/pkg` 用该上游配置的 `authToken`），满足"向中心仓发布需要 token"场景
- **失败处理**：失败项标记 `failed` + error；支持手动 `skipped`（跳过）；计划可 `start` 重试（failed → pending）
- **重启恢复**：服务启动时扫描计划表，将 `running` 计划置为 `paused`（防止重启后悬挂）
- **轮询/并发默认值**：`pollInterval=60s`、`pollTimeout=10min`、`maxConcurrent=1`（串行）；SSE 推送为主，每 60s 兜底轮询
- 事件流：`status`（计划状态）/ `publish`（每包进度），SSE 长连接

### 5.6 HTTP 服务端（tang）
- 使用 **tang**（自研轻量 web 框架）：Radix 路由、中间件、JSON、Cookie/Session；`POST /pkg` 发布为**二进制流**（官方协议），直接读 body 字节解析。
- 管理 API 与静态文件（`/docs/*`、复用前端的构建产物 `frontend/dist`）走 tang 路由。

#### 5.6.1 公开 API（无需认证，Web 前端/第三方数据源）

| 端点 | 说明 |
|---|---|
| `GET /api/stats` | 包/用户/版本数/下载量/存储占用/站点名/构建信息 |
| `GET /api/packages` | 包列表（分页/搜索/`org::` 语法/多分类 OR 筛选） |
| `GET /api/packages/:name` | 包详情（全部版本，支持 `org::name`） |
| `GET /api/packages/:name/:version` | 版本详情 |
| `GET /api/organizations` | 组织列表 |

#### 5.6.2 用户管理补充（session+admin）

| 端点 | 说明 |
|---|---|
| `GET /api/admin/users` | 用户列表（分页/搜索 username） |
| `DELETE /api/admin/users/:id` | 删除用户 |
| `PUT /api/admin/users/:id/toggle` | 启用/禁用用户 |

#### 5.6.3 组织管理（session+admin）

| 端点 | 说明 |
|---|---|
| `GET/POST /api/admin/organizations` | 组织列表（含成员/包数统计）/ 创建 |
| `PUT/DELETE /api/admin/organizations/:id` | 更新 / 删除 |
| 默认组织 | `cjreg init` 可指定默认组织（单组织场景可省多组织 UI） |

#### 5.6.4 包生命周期（session+admin）

| 端点 | 说明 |
|---|---|
| `GET /api/admin/packages/versions/:name` | 包版本列表（含已删） |
| `DELETE /api/admin/packages/:id` | **软删除**（deletedAt；索引/缓存/发布计划引用联动标记） |
| `PUT /api/admin/packages/:id/restore` | 恢复（校验 tarball 仍在） |
| `DELETE /api/admin/packages/:id/hard` | **硬删除**（删记录+制品文件，写审计日志，不可恢复） |
| `GET /api/admin/dashboard` | Dashboard 统计（包/版本/用户/存储字节/发布成功失败数） |

#### 5.6.5 审计日志

| 端点 | 说明 |
|---|---|
| `GET /api/admin/logs/publish` | 发布日志（org/name/version/status success\|failed/error/IP/UA，发布成功失败都写入） |
| `GET /api/admin/logs/admin` | 管理操作日志（action/target/details JSON/IP/UA；登录/删包/建用户/重置 token/清日志均记录） |
| `POST /api/admin/logs/clean` | 日志清理（logType=publish\|admin + days，物理删除） |

### 5.7 一键部署
- 单 `--static` 静态二进制（已验证 cjdep 可静态编译、裸环境运行、TLS 中心仓查询可用）。
- `cjreg init`：创建数据目录 + 默认配置 + 管理员/组织/上游；生成 `Dockerfile`/`docker-compose.yml`。
- 容器 = 单二进制 + 数据卷；`restart: always`。

## 6. 镜像 / 代理 / 仓库间同步（需求 4）

> **核心结论（对齐 cjrepo 实际实现）**：cjrepo 的"上游"全部是**按需回源**——`/index` 与 `/pkg` 请求本地未命中时，才去上游拉取并缓存（download/index/publish_plan 三个触发点），**没有主动全量镜像任务**。因此：
> - **核心验收 = 代理仓（上游按需回源）+ 发布计划**：课题验收点是"镜像、代理**或**同步"（三选一），代理即为核心场景，发布计划补齐"发布"链路；
> - 镜像预热 / 仓库间同步为**可选增强**（cjrepo 本身没有，实现优先级后置）。

### 6.1 代理仓（proxy）—— 核心，对齐 cjrepo
```
client GET /index/... → 本地无 → 回源 upstream（GET {upstream}/index/...）→ 缓存 → 返回
client GET /pkg/...   → 本地无 → 回源 upstream（GET {upstream}/pkg/...）→ 缓存 → 返回
```
纯 HTTP 字节透传 + JSON 解析（对齐 cjrepo `buildIndexURL`/`buildPackageURL`/`DownloadFromUpstream`/`FetchAndSavePackage`）；缓存带过期策略（cjrepo `cache expired` 语义）。

### 6.2 镜像预热（可选增强）
- 主动全量/增量拉取上游索引 + 制品（serve 后台任务：`cjreg serve --sync-interval 6h`，std 并发 / `cron-cj`），用于"离线完整副本"场景；
- 非课题必选：代理按需回源累积即可形成近似镜像。

### 6.3 仓库间同步（可选增强）
- 单向/双向：源仓 → 目标仓，按索引 diff（`sha256sum` 比对）增量同步；
- 冲突：目标已存在同版本不同 sha → 按配置 `skip`/`overwrite`/`error`。

## 7. 模块结构（src/，按子包模块化，对齐 cjcc 风格）

```
src/
├── main.cj                      入口：argopt 命令分发
├── cli.cj                       命令定义与参数解析
│
├── protocol/                    中心仓协议（与官方互通）
│   ├── url.cj                   索引/制品 URL 构造（短名规则，复用 cjdep 验证逻辑）
│   └── url_test.cj
│
├── index/                       索引
│   ├── ndjson.cj                NDJSON 索引生成/解析
│   └── ndjson_test.cj
│
├── config/                      上游表（多仓核心）
│   ├── upstream_store.cj        上游表 CRUD（bstorm 集合）+ 官方仓识别/保护
│   ├── upstream_store_test.cj
│
├── semver_range/                版本区间匹配（vendored：复制自 cjdep，已含单测）
│   ├── semver_range.cj
│   └── semver_range_test.cj
│
├── auth/                        认证（pbkdf2 用户名密码 + session/发布 token）
│   ├── auth_service.cj          AuthService：initAdmin / login / token 校验 / 用户生命周期
│   ├── auth_service_test.cj
│   ├── model/
│   │   ├── user.cj              User / UserToken / UserStore 接口 + MemoryUserStore
│   │   └── user_test.cj
│   └── util/
│       ├── password_hash.cj     PasswordHash（pbkdf2 SHA512）
│       ├── token.cj             TokenGenerator + 时间工具
│       └── util_test.cj
│
├── team/                        团队管理
│   ├── team.cj                  Team/TeamOrganization/TeamPackage/TeamMember 模型 + TeamService
│   └── team_test.cj
│
├── publish_plan/                发布计划
│   ├── plan.cj                  PublishPlan/PublishPlanItem 模型 + 状态机
│   ├── analyzer.cj              依赖分析 + 拓扑排序 + 分类（复用 cjdep 能力）
│   ├── executor.cj              顺序发布执行引擎 + SSE 事件
│   └── *_test.cj
│
├── store/                       存储层（bstorm JSON 文档库）
│   ├── store.cj                 集合划分：pkg / blob / user / org / upstream / log
│   ├── bstorm_user_store.cj     UserStore 的 bstorm 实现（接入 auth）
│   └── store_test.cj
│
├── server/                      HTTP 服务端（tang）
│   ├── server.cj                路由注册：发布/下载/索引 + 管理 API + 公开 API
│   ├── publish_handler.cj       POST /pkg（官方二进制格式解析 + sha256 校验 + 发布动态权限）
│   ├── index_handler.cj         GET /index（含上游回源透传 + requireAuth 检查）
│   ├── download_handler.cj      GET /pkg（下载计数 + 响应头 + requireAuth 检查）
│   ├── public_handler.cj        公开 API（stats/packages/organizations）
│   ├── admin_handler.cj         管理 API（用户/包生命周期/组织/日志/dashboard）
│   ├── team_handler.cj          团队管理 API
│   ├── publish_plan_handler.cj  发布计划 API（含 SSE）
│   └── *_test.cj
│
├── upstream/                    上游：代理回源（核心）
│   ├── proxy.cj                 按需回源 + 缓存（对齐 cjrepo FetchAndSavePackage）
│   ├── mirror.cj                镜像预热（可选增强）
│   ├── sync.cj                  仓库间同步（可选增强）
│   └── *_test.cj
│
├── resolver/                    多仓解析
│   ├── resolver.cj              优先级查找 + 冲突 + [replace] 强制替换
│   └── resolver_test.cj
│
└── deploy/                      部署
    ├── init.cj                  cjreg init（空数据目录创建首个管理员 + 配置）
    ├── admin_cmd.cj             cjreg admin（reset-password 应急）
    └── *_test.cj
```

> **复用 cjdep**：`semver_range`、`protocol.url`（buildIndexURL）已在 cjdep 验证（含单测、真实中心仓跑通）。cjreg 以 vendored 方式引入（cjdep 当前为 executable 包，无法作为库依赖；后续可把 cjdep 拆 lib+cli 统一复用）。

## 8. 技术选型与依赖

| 用途 | 选型 | 来源 |
|---|---|---|
| 配置解析 | `tomlcj` 1.0.0 | 中心仓 |
| 版本匹配 | `semver` 0.0.3 + `semver_range`（vendored） | 中心仓 + cjdep |
| 存储 | **bstorm** 1.4.x（badger-cj 上的 JSON 文档库） | 本地 path `../storm-cj` / 中心仓 |
| HTTP 服务端/客户端 | **tang**（服务端）+ `stdx.net.http`（客户端回源） | 本地 path `../tang` / 中心仓 |
| 序列化 | `bstorm` JSON 文档 + `stdx.encoding.json.stream` | stdx |
| 认证 | `pbkdf2` 1.0.x（密码哈希）+ `stdx.crypto`（SecureRandom/token） | 本地 path `../pbkdf2` / 中心仓 |
| 静态编译 | `--static` | 已验证 |

## 9. 测试计划（TDD）

| 模块 | 用例 |
|---|---|
| config | 上游表 CRUD；官方仓识别（URL 匹配）与保护（不可删除）；优先级排序；cacheTtl 过期 |
| protocol | 索引/制品 URL 构造（≥4/3/<3 字符、org 参数）；制品 URL |
| semver_range | vendored 自 cjdep（已 11 用例） |
| resolver | 多仓优先级命中；未命中回退；冲突标记/严格模式；`[replace]` 覆盖；resolve 接口 trace/候选链 |
| index | NDJSON 生成/解析；yanked；sha256sum |
| store | badgercj 读写/内容寻址去重/缓存 |
| auth | 见 §5.3.5（密码哈希/引导/登录/session/发布 token/用户生命周期）+ §5.3.6 权限双路径（超管直通/包级→组织级→个人 publisher/发布动态权限） |
| team | 团队 CRUD；组织/包/成员关联；permission 权限裁决；用户-团队查询 |
| publish_plan | analyze 拓扑/分类/去重；item 六状态（含 waiting_index/skipped）；重启恢复（running→paused）；轮询确认需 SHA256 一致；失败重试；SSE 事件 |
| server | 发布（官方二进制格式解析 + sha256 校验 + 动态权限）→ 索引 → 下载 端到端；requireAuth 开关；三级删除/恢复；公开 API；审计日志字段（IP/UA） |
| upstream | 代理回源+缓存；镜像增量 diff；sync 冲突策略 |
| deploy | init 幂等；docker 配置生成 |
| **hurl 集成测试（复用）** | cjrepo `tests/*.hurl` 直接复用（public-api/organization/team-permission/package-management/publish-plan/pagination）；auth/user-management 按 pbkdf2 改写；`hurl` 8.x 已具备 |
| 集成（手工） | 本地起仓 → 发布测试包 → `cjpm publish` 对接到私有仓 → 代理/镜像到官方中心仓验证；前端复用 cjrepo frontend 构建产物验证管理面 |

## 10. 里程碑

1. **M0（已完成）**：`cjpm init` 项目骨架 + 静态编译验证
2. **M1**：config + protocol + semver_range（vendored）+ 单测
3. **M2**：store（bstorm）+ index + server（发布/下载/索引）
4. **M3**：auth（用户名密码登录）+ 团队管理 + 管理 API + init/部署
5. **M4**：upstream 代理（按需回源 + 缓存，对齐 cjrepo）+ resolver（多仓/冲突/替换）；镜像预热/仓库间同步为可选增强（时间允许再补）
6. **M5**：发布计划（analyze 复用 cjdep + 执行引擎 + SSE）+ 改 cjpm 多仓配置 + 端到端验证
7. **M6**：对接 cjdep 发布顺序、CI 脚本、文档

## 11. 验收映射

| 验收点 | 对应设计 |
|---|---|
| 多仓不破坏原解析规则 | §3.1 客户端替换地址（cjpm 零修改）+ §3.2 服务端多上游 + §4.3 `[replace]` 保留 |
| 私有仓部署运行 | §5.7 单静态二进制 + §5.1 官方协议 |
| 镜像/代理/同步场景验证（三选一） | **核心**：§6.1 代理仓（上游按需回源）+ §5.5 发布计划（Analyze 查上游 + 顺序发布）；增强：§6.2 镜像预热、§6.3 仓库间同步（可选） |
