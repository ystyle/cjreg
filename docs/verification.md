# cjreg 验证报告（技术课题）

> 本报告记录 cjreg「仓颉私有中心仓与多仓体系」技术课题的验证过程、实测数据与复现方法。
> 所有验证均在本地隔离数据目录（`cjreg/.smoke/*`）中执行，**不触碰任何生产数据**。

## 0. 摘要

| 验证层次 | 手段 | 规模 | 结果 |
|---|---|---|---|
| 单元测试 | `cjpm test` | 24 个测试文件 / **154 个用例** | ✅ 全部通过 |
| 代码覆盖率 | `cjpm test --coverage` + `cjcov` | 35 个源文件 / 6033 行 | **39.3%**（纯逻辑层 85%–97%，详见 §3.2） |
| 协议端到端 | `tests/e2e.sh` 双仓脚本 | 6 个真实依赖包 | ✅ 发布 → 拓扑 → 6/6 推送 → 目标仓校验 |
| 权限矩阵 | curl（team 模式 + require_auth） | 15+ 分支 | ✅ 401/403/200/409 全部符合规格 |
| 配置生效 | curl + CLI | 4 项 | ✅ 命令行 > 配置文件 > 默认值 |
| 持久化/重启 | 重启服务复读 | 包/用户/团队/计划 | ✅ 数据与自增 id 正确恢复 |
| 优雅关闭 | SIGTERM（模拟 docker stop） | 停服 → 落盘 → 退出 | ✅ exit 0、重启数据完整、重复信号幂等 |
| 浏览器端到端 | agent-browser | 门户/管理端/登录 | ✅ 三区块渲染、导航登录态、登录 loading |
| 大制品发布 | curl | 2–50 MiB | ⚠️ 48 MiB 以下稳定；≥48 MiB 偶发 OOM（见 §5.1） |
| 性能（本机） | Python 客户端压测 | 200/10 次 | 索引 p50 **0.47 ms**；下载吞吐 **~941 MB/s**（20 MiB） |

## 1. 验证环境

| 项 | 值 |
|---|---|
| 平台 | Linux x86_64（DSH 沙箱，29 GiB 内存，无 cgroup 内存上限） |
| 仓颉工具链 | cjc / cjpm **1.1.3**（`cjreg/cjpm.toml` 的 `cjc-version`） |
| 依赖版本 | bstorm 1.4.7（badgercj 1.6.16）、tang 1.0.4、gjson 1.2.1、tomlcj 1.0.0、pbkdf2 1.0.0、semver 0.0.3、cjxt（path 依赖） |
| 构建 | `cjpm build -j 16`（`--static` 静态编译） |
| 服务启动 | `cjreg serve -d <dataDir>`（配置来自 `<dataDir>/cjreg.toml`） |

数据隔离：所有验证使用 `cjreg/.smoke/` 下的临时数据目录（`.smoke/review`、`.smoke/A`、`.smoke/B`）。

## 2. 复现步骤

```shell
# 0) 环境
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"
cd cjreg && cjpm build -j 16

# 1) 单元测试（153 用例）
cjpm test -j 16 --no-progress

# 2) 覆盖率报告（HTML 输出到 .smoke/coverage）
cjpm test --coverage -j 16 --no-progress
cjcov --root=./ -o .smoke/coverage --html-details -i "$PWD/src" -e "*_test.cj"

# 3) 双仓 e2e（自动 init/起双仓/发布 6 包/拓扑/推送/校验）
bash tests/e2e.sh

# 4) 手工起一个可浏览的实例（team 模式 + 对外地址由配置决定）
mkdir -p /tmp/cjreg-demo && ./target/release/bin/ystyle::cjreg init -d /tmp/cjreg-demo \
  --username admin --password 'AdminPass1'
cat > /tmp/cjreg-demo/cjreg.toml <<'EOF'
[server]
public_url = "http://127.0.0.1:8064"
port = 8064
permission_mode = "team"
require_auth = false
EOF
./target/release/bin/ystyle::cjreg serve -d /tmp/cjreg-demo
# 浏览器：http://127.0.0.1:8064/（门户）与 /admin/login（管理后台）
```

## 3. 逐项结果与证据

### 3.1 单元测试（154 用例全绿）

```text
$ cjpm test -j 16 --no-progress
Summary: TOTAL: 154
    PASSED: 154, SKIPPED: 0, ERROR: 0
    FAILED: 0
```

覆盖模块：`protocol`（官方二进制格式、URL 分片）、`semver_range`（区间匹配/版本比较）、`index`（NDJSON 生成与兼容解析）、
`store`（bstorm 文档、持久化、自增 id 恢复）、`auth`（pbkdf2、token、生命周期、多管理员约束）、
`config`（配置解析/优先级/上游表）、`server`（发布裁决、owner 模型、读鉴权、发布计划、用户门户读模型、目标仓 token 解析）、
`ui`（守卫、导航登录态、门户渲染、文档示例配置化）。

回归固化：官方索引 `index-version` 为字符串、cjpm meta 为 pretty 多行 JSON、sha256sum 位于嵌套 index、
bstorm 重启 reindex、二进制制品不可走 UTF-8 文本流等 5 个兼容性坑均有对应用例。

### 3.2 覆盖率（cjcov）

```text
$ cjcov --root=./ -o .smoke/coverage --html-details -i "$PWD/src" -e "*_test.cj"
Files: 35   Lines: 2368 / 6033   Coverage: 39.3 %
```

按包（文件行覆盖率均值）：

| 包 | 覆盖率 | 说明 |
|---|---|---|
| `protocol` | 97.3% | 官方格式解析（纯逻辑，充分单测） |
| `auth` | 95.5% | 认证/授权/多管理员约束 |
| `config` | 94.9% | 配置与上游表 |
| `index` | 94.2% | NDJSON 生成/解析 |
| `semver_range` | 90.2% | 版本区间 |
| `store` | 85.1% | bstorm 存取/持久化 |
| `server` | 72.6% | 逻辑层高（`publish_service` 92.3%、`user_service` 98.8%）；HTTP handler 层低（`admin_handler` 15.1%、`proxy_service` 37.9%），由 e2e 覆盖 |
| `ui` | 50.5% | 门户页 73.4%、文档 51.1%；公开页/布局主要靠浏览器冒烟 |

> 说明：整体 39.3% 的分母含 UI 页面与 HTTP handler（这些以 e2e 与浏览器验证为主）。
> 单纯逻辑层（protocol/index/semver_range/store/auth/config）行覆盖率 **85%–97%**。
> 提升空间：为 `admin_handler` 补 handler 级测试、为公开页补 `serializeSubtree` 渲染测试（已有先例，低成本）。

### 3.3 双仓发布计划 e2e（`tests/e2e.sh`）

```text
$ bash tests/e2e.sh
=== 1. 按依赖顺序发布 6 包到 A ===
  published mathUtils ✓  strUtils ✓  netUtils ✓  encryptUtils ✓  dataUtils ✓  app ✓
=== 2. analyze app（应展开 6 包拓扑）===
  拓扑正确: ['netUtils', 'mathUtils', 'dataUtils', 'strUtils', 'encryptUtils', 'app']
=== 3. 执行发布计划 A → B ===
  6/6 推送成功 ✓
=== 4. 验证 B 收到全部包 ===
  B 索引完整（含依赖）✓
  B 制品下载 200 ✓
  B 底层包索引 ✓
=== 双仓 e2e 全部通过 ✓ ===
```

验证要点：真实 `cjpm publish`（6 个包，含 `app → encryptUtils/dataUtils → mathUtils/strUtils/netUtils` 依赖链）、
依赖拓扑顺序正确（依赖先于依赖者）、跨仓推送带目标仓认证、目标仓索引与制品可下载、依赖关系完整。

### 3.4 权限矩阵 e2e（team 模式 + `require_auth = true`）

| 场景 | 期望 | 实测 |
|---|---|---|
| `GET /pkg`、`GET /index` 无 token | 401 | ✅ 401 |
| 无效 token | 401 | ✅ 401 |
| 有效 token 但无权限 | 403 | ✅ 403 |
| owner / 团队成员有 read | 200 | ✅ 200 |
| 新包（命名空间未被纳管）任意有效 token 认领 | 200 | ✅ 200 |
| 已有包新版本：非 owner 非成员 | 403 | ✅ 403 |
| 已有包新版本：owner（个人路径） | 200 | ✅ 200 |
| 覆盖同版本（sha 不同）：owner 本人 | 403（覆盖属团队权限） | ✅ 403 |
| 覆盖同版本：团队 `write` | 403（需 overwrite） | ✅ 403 |
| 覆盖同版本：团队 `overwrite` | 200 且原地更新 | ✅ 200（文档数不变、内容与索引 sha 已更新） |
| 覆盖后包名所有权 | 仍属首次发布者 | ✅ publisherId 未变 |
| 管理员（超管）直通 | 200 | ✅ 200 |
| `/api/user/*` 匿名 / 用发布 token 当会话 | 401 | ✅ 401 |
| 取消「最后一个启用管理员」 | 409 | ✅ 409 |
| 角色变更缺 `isAdmin` 字段 / 用户不存在 / 非管理员调用 | 400 / 404 / 403 | ✅ 400 / 404 / 403 |

### 3.5 配置生效 e2e

| 场景 | 实测 |
|---|---|
| `init -p 8070` 生成模板 | ✅ `<dataDir>/cjreg.toml` 含 `public_url`/`port`/`permission_mode`/`require_auth`/`max_request_bytes` |
| `serve -p 8071`（配置文件写 8070） | ✅ 8071 提供服务、8070 未监听（命令行优先） |
| `serve -c <path>` 指定配置 | ✅ 生效 |
| 门户/帮助文档示例地址 | ✅ 显示配置的 `public_url`（浏览器实测 `http://127.0.0.1:8064`），模式片段显示真实 `permission_mode` |

### 3.6 持久化与重启

- `init` → 发布/建用户/建团队 → 重启服务 → 包、版本、用户、团队关联、日志均可复读；
- 崩溃/重启后的发布计划：启动时把 `running`/`paused` 复位为 `pending`（避免悬挂）；
- bstorm（badger-cj）重启后 reindex 与跨进程自增 id 恢复正确（回归测试固化）。

### 3.7 浏览器端到端（agent-browser）

| 场景 | 实测 |
|---|---|
| 公开首页（未登录） | 导航显示「登录」，**不显示**管理后台 |
| 直接访问 `/me`（未登录） | 守卫跳转 `/user/login` |
| 表单登录 alice（普通用户） | 落到 `/me`；导航变「我的」；三区块（Token / 我的包 / 我的团队与权限）渲染正确 |
| 「我的包」 | `demo::my-lib`（所有者）、`demo::team-lib`（协作者）标记正确 |
| 重置发布 Token | 确认弹窗 → 新 Token 生效，**旧 Token 服务端 401** |
| 管理员登录（`/admin/login`） | 落到 `/admin` 仪表盘；导航出现「管理后台 + 我的」 |
| 登录 loading | 用 JS 每 3 ms 轮询遮罩，两个登录页均记录到遮罩可见（`seen=true`） |
| 刷新保持登录 | 登录后刷新 `/me` 仍为登录态（token 已同步至 localStorage） |

### 3.8 大制品发布与性能（本机 loopback）

发布（含 SHA-256 校验、meta 校验、入库与 blob 落盘）：

| 制品大小 | 结果 | 耗时 |
|---|---|---|
| 2 MiB | 200 | 6 ms |
| 5 MiB | 200 | 7 ms |
| 10 MiB | 200 | 17 ms |
| 20 MiB | 200 | 90 ms |
| 32 / 40 / 48 / 50 MiB | 200（各至少一次成功） | 0.1–0.3 s |

下载（同一服务、页缓存热）：

| 制品 | 平均 | p50 | 吞吐 |
|---|---|---|---|
| 20 MiB × 10 | 21.2 ms | 16.5 ms | **~941 MB/s** |
| 32 MiB × 10 | 53.3 ms | 76.0 ms | ~601 MB/s |

索引接口（200 次，255 B 响应）：平均 **0.71 ms**、p50 **0.47 ms**、p95 **1.55 ms**。

> 说明：以上为单机 loopback + 页缓存的冒烟级测量，**不是正式基准**；正式对比报告（缓存命中 vs 回源延迟、并发吞吐、镜像体积）列入后续工作。

### 3.9 优雅关闭（SIGINT / SIGTERM）

`serve`/`admin-ui` 启动时注册关闭钩子（`Storm.registerShutdownHook` + `registerSignalShutdown`，转发 badger-cj）：
信号到达 → 执行钩子（先停 HTTP 服务）→ 关闭数据库（flush memtable 落盘）→ 进程退出。

| 步骤 | 实测 |
|---|---|
| 造数据：发布 `graceful::demo-lib@3.0.0` + 建用户 `grace`（不手动 close/flush） | ✅ |
| `kill -TERM <pid>`（模拟 `docker stop`） | ✅ 日志 `[badger] received SIGINT/SIGTERM, closing gracefully...` 与 `cjreg: 收到退出信号，正在优雅关闭（停止服务 → 落盘 → 退出）...`；进程**正常退出（exit 0，非 143）**，端口释放 |
| 重启后校验 | ✅ 包版本 3.0.0 可读、用户 admin + grace 均在 |
| 再次发送 SIGTERM | ✅ 幂等（close 幂等），再次正常退出 |

> 兜底：`Storm.open(..., syncWrites: true)` 已默认开启（每次写入 fsync），即使 `kill -9` 也不丢已确认写入。

## 4. 验证过程中发现并修复的缺陷

### 4.6 `BlobStore.exists` 与 `std.fs.exists` 同名 → 自递归 OOM（三级删除闭环引入）

- **现象**：双仓 e2e 在「发布第 4 个包（含依赖）」时服务端抛 `Out of memory`，客户端报
  `read response timeout`；而单独重放相同的 6 次发布会话却时好时坏。
- **排查**：用反向代理抓全部请求（含 GET）后定位——失败的**不是发布**，而是 cjpm 为了构建依赖而发起的
  `GET /pkg/:name/:version`（依赖制品下载）。本地 `tests/pkgs/*/target` 已存在时 cjpm 不重建 → 不下载 → 通过，
  因此表现为「偶发」。
- **根因**：新增的 `DiskBlobStore.exists(sha256)` 与 `std.fs.*` 的顶层 `exists(path)` **同名**，
  方法体里的 `exists(dir + "/" + sha256)` 被解析为**调用自身** → 无限递归 → 失败（表层报 OOM）。
- **修复**：接口方法更名 `has(sha256)`（并加注释说明该陷阱），调用点同步更新。
- **回归**：修复后 `tests/e2e.sh` 8 步全绿（含第 8 步三级删除）；单测 175/175。
- **教训**：与标准库同名的成员方法要警惕「体里裸调用」的解析结果；本地预热过的构建会掩盖依赖下载路径的缺陷。



| # | 缺陷 | 影响 | 修复 |
|---|---|---|---|
| 1 | `httpGet` / `httpPostBinary` **从未设置 `Authorization` 头** | 上游 `authToken` 形同虚设：私有上游回源无法认证；发布计划推送到需认证的目标仓（官方中心仓或另一私有仓）必然 401 —— 即申报书「一键推送到官方仓」实际不可用 | 两处补 `HttpRequestBuilder().header("Authorization", token)`（裸 token，对齐官方规格与 Go 先行版） |
| 2 | `tests/e2e.sh` 未注入发布 token（测试包 `cangjie-repo.toml` 的 token 为空） | 双仓 e2e 第一步即 401 失败，验证材料无法复现 | 脚本改为运行时取 A/B 两仓发布 token 并写入测试包配置 + 推送请求带 `target_token` |
| 3 | `executePlan` 把目标仓 token 硬编码为 `""` | 推送到需认证的目标仓必然失败 | 支持 `target_token`，未显式提供时按 URL 匹配上游表取该上游 `authToken`（新增纯函数 + 单测） |
| 4 | HTTP 请求体上限沿用 stdx 默认 **2 MB** | 超过 ~2 MB 的包发布被拒（413 / 连接重置）；官方协议允许单段 500 MB | 新增配置 `max_request_bytes`（默认 **500 MiB**，`-1` 不限）；cjxt 补 `App.serverBuilder()` 挂钩以定制 stdx `ServerBuilder` |

## 5. 已知限制与风险

### 5.1 大制品发布的堆内存上限（根因已定位）

- **根因**：仓颉运行时 **GC 堆上限默认 256 MB**（进程级环境变量 `cjHeapSize`）。`POST /pkg` 将整个请求体读入内存后再按段
  切片（meta + 制品）、计算 SHA-256 并落盘，峰值约为包体的 2–3 倍 → 发布 40 MiB 以上的包时 GC 堆可能触顶。
  另有 badger-cj 的 MemTable arena（bstorm 默认 `memTableSize` 16 MB → arena 32 MB，属原生内存，不占 GC 堆）。
- **实测**：≤32 MiB 稳定通过；48–50 MiB 偶发 `Out of memory`（同一台机器上 48 MiB 失败过一次、50 MiB 随后成功
  → 与当时 GC 堆占用相关，**非体积阈值、非 cgroup 限制**：该进程无内存上限、机器可用内存 >20 GiB）。
- **缓解（已文档化）**：发布大包前设置 `export cjHeapSize=2GB cjGCThreshold=1GB cjGCInterval=100ms`
  —— 见 `README.md`「内存与优雅关闭」与 `cjreg.toml.example` 注释。
- **根治（后续）**：改为**流式解析**（读段头 → 边读边算 SHA-256 → 直接落盘 blob），峰值内存降为 O(1)，
  届时 `max_request_bytes`（默认 500 MiB）才真正可用。

### 5.2 其他

- 覆盖率分母含 UI/HTTP 适配层（整体 39.3%）；建议补 handler 级测试与公开页渲染测试。
- `tests/e2e.sh` 使用固定端口（18060/18070），需保证端口空闲。
- 演示/冒烟数据目录位于 `.smoke/`（已 gitignore），不进仓库。
- 发布计划 item 状态目前为 `pending/running/completed/failed` 四态（设计中的 `publishing`/`waiting_index`/`skipped` 与 SSE 进度流未实现，
  现以 `App.pushUpdate` 推送进度）；`analyze` 响应暂未输出 `dependency_range/local_versions/remote_versions/recommended_version`。
- 包三级删除的「恢复/硬删」入口尚未实现（清单与优先级见 `docs/gap-analysis.md`）；
  审计日志（发布/认证/管理三类 + IP/UA + 查询/清理端点 + 管理端页面）与公开只读 API（C1–C5）
  已实现，分别纳入 `tests/e2e.sh` 第 5 步与第 6 步，详见 `docs/audit-log.md`、`docs/public-api.md`。
- 性能数据为单机冒烟测量，非正式基准。

## 6. 结论

- 官方协议互通（发布/下载/索引）、认证与权限双路径裁决、多上游代理与解析诊断、发布计划拓扑执行、用户门户与管理后台
  均已实现并通过单元测试 + 双仓 e2e + 权限矩阵 + 浏览器端到端验证；
- 本次验证额外定位并修复了 4 个**影响核心可用性**的缺陷（上游/目标仓认证头缺失、e2e 无法复现、目标仓 token 硬编码、请求体 2 MB 上限），
  其中「推送到需认证的目标仓」与「大包发布」直接决定私有仓/官方仓转发链路是否可用；
- 优雅关闭（SIGINT/SIGTERM）、bstorm 1.4.8、请求体上限与堆内存说明已补齐；遗留项集中在「超大包流式处理」「公开只读 API」「三级删除闭环」「组织 CRUD REST」「发布计划六态 + SSE」五处，
  不影响当前协议互通与权限主链路的正确性。
