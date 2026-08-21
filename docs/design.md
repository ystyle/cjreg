# cjreg 设计文档

仓颉私有中心仓与多仓工具（课题：仓颉中心仓多仓配置与私有化体系建设）

## 1. 定位与目标

用仓颉重写/扩展 [cjrepo](https://github.com/ystyle/cjrepo) 的能力，形成"私有中心仓 + 多仓"完整体系。**服务端 100% 仓颉实现**（唯一非仓颉部分为可选的 Web 管理前端）。

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
  init       初始化数据目录（建管理员/组织/默认上游），生成 docker 配置
  config     查看/校验多仓配置（cangjie-repo.toml）
  resolve    多仓解析一个包（按优先级），输出来源/版本/冲突
  proxy      代理模式：请求回源上游并缓存
  mirror     镜像模式：全量/增量同步上游索引 + 制品到本地仓
  sync       仓库间同步（源→目标，索引 diff）
  analyze    依赖分析与发布顺序（复用 cjdep 能力，可选子命令）

选项：
  -c, --config <path>   多仓配置文件（默认 ./cangjie-repo.toml → ~/.cjpm/cangjie-repo.toml）
  -d, --data <dir>      数据目录（默认 ./data）
  -p, --port <n>        serve 端口（默认 8060）
  -j, --json            JSON 输出
  -h, --help
```

## 3. 多仓配置模型（需求 1）

### 3.1 cangjie-repo.toml（扩展，向后兼容）

```toml
# 兼容原有字段（cjpm 已识别）：cache / home
[repository.cache]
    path = "./.cache"

[repository.home]                    # 默认主仓（语义不变）
    registry = "https://pkg.cangjie-lang.cn/registry"
    token = "..."

# 新增命名仓（cjpm SettingsConfig.repository 已是 HashMap<String, RepositoryInfo>，低摩擦扩展）
[repository.mirror]                  # 镜像仓（只读缓存）
    registry = "https://mirror.example.com/registry"
    priority = 1                     # 越小越优先；缺省按出现顺序（home 默认 0）
    readonly = true

[repository.proxy]                   # 代理仓（回源 home）
    registry = "https://private.example.com/registry"
    upstream = "home"                # 回源目标仓名
    priority = 2

[repository.private]                 # 私有仓（可写，发布目标）
    registry = "http://repo.internal.cangjie.cn:8060"
    token = "..."
    priority = 3
    readonly = false
```

- **不破坏原规则**：`[repository.home]`/`[repository.cache]` 字段与语义完全保留；新增 `priority`/`readonly`/`upstream` 为可选字段，老版本 cjpm/无多仓能力的客户端照常工作。
- cjpm 侧扩展：改 `central_repository.cj`，`RepositoryInfo` 增加 `priority`/`readonly`/`upstream`，`SettingsConfig.deserialize` 容错未知字段。

### 3.2 优先级查找

```
resolve(name, org, version):
  repos = sort(repository 项, by priority asc, 出现顺序 asc)
  for repo in repos:
     idx = GET {repo.registry}/index/{mo}/{du}/{name}?organization={org}
     if 命中 version → 返回 (repo, entry, tarball)
  未命中 → 返回 not_found（并记录"候选仓列表"供诊断）
```

- 发布只允许 `readonly=false` 的仓（home/private）。
- 缓存：索引按 (repo,name,org) 缓存，制品按 (repo,name,version) 缓存（badgercj/文件）。

## 4. 依赖解析、冲突与版本强制替换（需求 2）

### 4.1 多仓解析
`resolver.cj`：给定 `(name, org, require)`，按优先级在各仓索引中查找满足 `require` 的最佳版本（复用 `semver_range`：精确/区间/caret/tilde/预发布）。

### 4.2 冲突处理
- 冲突定义：同 `name+version` 在不同仓 `sha256sum` 不一致。
- 策略（可配置，默认）：
  - **解析期**：取优先级最高仓的结果，标记 `conflict` 并在日志/报告提示；
  - **严格模式**（`resolve --strict`）：遇冲突直接报错，不静默选择。
- 对齐 cjrepo `Analyze` 的 `conflict` 分类。

### 4.3 版本强制替换
- 保留 cjpm `[replace]`（工作空间统一版本）语义：`replace` 命中时，跨仓一律按 `[replace]` 指定的版本解析，忽略各仓实际差异。
- `resolve` 输出 `replaced_by` 说明。

## 5. 私有中心仓服务端（需求 3）

### 5.1 协议（与官方中心仓互通，cjdep 已验证）

| 端点 | 说明 |
|---|---|
| `POST /pkg/:name` | 发布（multipart：meta-data.json + tarball），校验 name/org/version 一致 |
| `GET /pkg/:name/:version` | 下载制品（支持 `?organization=`） |
| `GET /index/:mo/:du/:name?organization=` | NDJSON 索引（短名规则：≥4 字符取 `[0:2]`/`[2:4]`；3 字符 `du=第3字符`；<3 不支持） |
| `GET /health` | 健康检查 |
| `/api/...` | 管理 API（包/用户/组织/上游/日志/统计） |

### 5.2 存储（bstorm —— 基于 badger-cj 的 JSON 文档数据库）
`store.cj` 基于 **bstorm**（自研嵌入式 JSON 文档数据库，badger-cj 存储引擎 + gjson 查询，零 FFI）：
- **JSON 文档原生**：包元数据/索引/用户/上游/日志均以 JSON 文档存储，无需 Schema，天然对齐 `meta-data.json` 的 `index` 字段。
- **流式扫描**：全表/条件扫描无内存压力（适合索引遍历、镜像同步 diff、日志查询）。
- 集合划分：`pkg`、`blob`（内容寻址去重）、`user`、`org`、`upstream`、`log`、`cache:index`。

### 5.3 认证
- 管理面：token（`stdx.crypto` 生成/校验）+ `pbkdf2` 口令哈希；可选 JWT（中心仓 `soulsoft_web_authentication_jwtbearer` 或自实现 HS256）。
- 发布：per-token / per-user 权限；`CJREG_ADMIN_KEY` 引导初始化。

### 5.4 HTTP 服务端（tang）
- 使用 **tang**（自研轻量 web 框架）：Radix 路由、中间件、JSON、Cookie/Session，**内置 `opencj::multipart`**——正好用于 `POST /pkg/:name` 的 multipart 包上传。
- 管理 API 与静态文件（`/docs/*`）走 tang 路由。

### 5.5 一键部署
- 单 `--static` 静态二进制（已验证 cjdep 可静态编译、裸环境运行、TLS 中心仓查询可用）。
- `cjreg init`：创建数据目录 + 默认配置 + 管理员/组织/上游；生成 `Dockerfile`/`docker-compose.yml`。
- 容器 = 单二进制 + 数据卷；`restart: always`。

## 6. 镜像 / 代理 / 仓库间同步（需求 4）

### 6.1 代理仓（proxy）
```
client GET /index/... → 本地无 → 回源 upstream（GET {upstream}/index/...）→ 缓存 → 返回
client GET /pkg/...   → 本地无 → 回源 upstream（GET {upstream}/pkg/...）→ 缓存 → 返回
```
纯 HTTP 字节透传 + JSON 解析（对齐 cjrepo `buildIndexURL`/`buildPackageURL`/`DownloadFromUpstream`/`FetchAndSavePackage`）。

### 6.2 镜像仓（mirror）
- 全量：遍历上游索引（分片/分页），拉取制品；增量：按 `sha256sum`/时间 diff。
- 调度：`cjreg mirror --interval 6h`（std 并发 / `cron-cj`）。

### 6.3 仓库间同步（sync）
- 单向/双向：源仓 → 目标仓，按索引 diff（`sha256sum` 比对）增量同步；
- 冲突：目标已存在同版本不同 sha → 按配置 `skip`/`overwrite`/`error`。

## 7. 模块结构（src/）

```
src/
├── main.cj            入口：argopt 命令分发
├── cli.cj             命令定义与参数解析
├── config.cj          多仓配置解析/校验/回退链（本地 → ~/.cjpm → 默认）
├── model.cj           RepositoryInfo / PackageMeta / Upstream / ResolveResult / 枚举
├── protocol.cj        索引/制品 URL 构造（短名规则，复用 cjdep 验证逻辑）
├── index.cj           NDJSON 索引生成/解析
├── semver_range.cj    版本区间匹配（vendored：复制自 cjdep，已含单测）
├── store.cj           存储层（bstorm JSON 文档库 + 集合划分）
├── server.cj          HTTP 服务端（tang：发布/下载/索引 + 管理 API）
├── auth.cj            token 认证 + pbkdf2
├── upstream.cj        上游：代理回源 + 镜像同步 + 仓库间同步
├── resolver.cj        多仓解析 + 冲突 + [replace] 强制替换
├── deploy.cj          初始化 / 健康检查 / docker 配置生成
└── *_test.cj          各模块单元测试
```

> **复用 cjdep**：`semver_range.cj`、`protocol.cj`（buildIndexURL）已在 cjdep 验证（含单测、真实中心仓跑通）。cjreg 以 vendored 方式引入（cjdep 当前为 executable 包，无法作为库依赖；后续可把 cjdep 拆 lib+cli 统一复用）。

## 8. 技术选型与依赖

| 用途 | 选型 | 来源 |
|---|---|---|
| 配置解析 | `tomlcj` 1.0.0 | 中心仓 |
| 版本匹配 | `semver` 0.0.3 + `semver_range`（vendored） | 中心仓 + cjdep |
| 存储 | **bstorm** 1.4.x（badger-cj 上的 JSON 文档库） | 本地 path `../storm-cj` / 中心仓 |
| HTTP 服务端/客户端 | **tang**（服务端，含 multipart） + `stdx.net.http`（客户端回源） | 本地 path `../tang` / 中心仓 |
| 序列化 | `bstorm` JSON 文档 + `stdx.encoding.json.stream` | stdx |
| 认证 | `stdx.crypto` + `pbkdf2` | stdx/中心仓 |
| 静态编译 | `--static` | 已验证 |

## 9. 测试计划（TDD）

| 模块 | 用例 |
|---|---|
| config | 多仓解析/优先级排序/未知字段容错/回退链；`[repository.home]` 兼容性 |
| protocol | 索引/制品 URL 构造（≥4/3/<3 字符、org 参数）；制品 URL |
| semver_range | vendored 自 cjdep（已 11 用例） |
| resolver | 多仓优先级命中；未命中回退；冲突标记/严格模式；`[replace]` 覆盖 |
| index | NDJSON 生成/解析；yanked；sha256sum |
| store | badgercj 读写/内容寻址去重/缓存 |
| server | 发布→索引→下载 端到端；权限；multipart 校验 |
| upstream | 代理回源+缓存；镜像增量 diff；sync 冲突策略 |
| deploy | init 幂等；docker 配置生成；/health |
| 集成（手工） | 本地起仓 → 发布测试包 → `cjpm publish` 对接到私有仓 → 代理/镜像到官方中心仓验证 |

## 10. 里程碑

1. **M0（已完成）**：`cjpm init` 项目骨架 + 静态编译验证
2. **M1**：config + protocol + semver_range（vendored）+ 单测
3. **M2**：store（badgercj）+ index + server（发布/下载/索引）
4. **M3**：auth + 管理 API + init/部署
5. **M4**：upstream（代理/镜像/同步）+ resolver（多仓/冲突/替换）
6. **M5**：改 cjpm 多仓配置（central_repository.cj 扩展）+ 端到端验证
7. **M6**：对接 cjdep 发布顺序、CI 脚本、文档

## 11. 验收映射

| 验收点 | 对应设计 |
|---|---|
| 多仓不破坏原解析规则 | §3.1 向后兼容配置 + §4.3 `[replace]` 保留 |
| 私有仓部署运行 | §5.5 单静态二进制 + §5.1 官方协议 |
| 镜像/代理/同步场景验证 | §6 三种模式 + §9 集成测试（对官方中心仓实测） |
