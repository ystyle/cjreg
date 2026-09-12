# cjreg — 仓颉私有中心仓与多仓工具

用仓颉实现私有中心仓与多仓体系：多仓配置与优先级查找、依赖解析/冲突/版本强制替换、私有仓一键部署、镜像/代理/仓库同步。

课题：仓颉中心仓多仓配置与私有化体系建设。

## 命令

```
cjreg <command> [options]

  serve      启动私有中心仓 HTTP 服务（发布/下载/索引 + 管理 API）
  init       初始化数据目录（空数据目录创建首个管理员 + 默认官方上游）
  admin      应急管理（reset-password --username <u> --password <p>）
```

选项：

```
  -d, --data <dir>    数据目录（默认 ./data）
  -p, --port <n>      serve 端口（默认 8060）
  -h, --help          帮助
```

## 构建与测试

```bash
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"
cjpm build -j 16
cjpm test -j 16 --no-progress
./target/release/bin/ystyle::cjreg --help
```

> `--static` 静态编译；`cangjie-repo.toml` 缓存到项目本地（沙箱只读 `~/.cjpm` 场景）。

## 快速开始（私有仓）

**方式一：Docker Compose（推荐）**

```bash
git clone https://atomgit.com/ystyle/cjreg && cd cjreg
export ADMIN_PASS='YourPass'
bash scripts/docker-deploy.sh        # 编译 → 构建镜像 → init → 启动 → 健康检查
# 门户 http://localhost:8060/    管理后台 http://localhost:8060/admin
```

**方式二：手动（裸机 / systemd）**

```bash
# 1. 构建
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"
cjpm build -j 16

# 2. 初始化（首个管理员 + 默认官方上游 + 生成 cjreg.toml）
./target/release/bin/ystyle::cjreg init -d ./data --username admin --password YourPass

# 3. 启动
./target/release/bin/ystyle::cjreg serve -p 8060 -d ./data
```

> Docker/Compose/手动三种部署形态、卷与环境变量、优雅关闭与运维命令：
> [docs-site/deploy](docs-site/deploy/index.md)（在线站点 `docs-site/`，VitePress 构建）。

### 管理 API（HTTP）

```
POST   /api/admin/login              登录获取 token
GET    /api/admin/me                 当前用户
GET    /api/admin/users              用户列表（admin）
POST   /api/admin/users              创建用户（admin，JSON body {username,password,isAdmin?,email?}）
PUT    /api/admin/users/:id/admin    提升/取消管理员（admin，JSON body {isAdmin}；最后一个启用管理员不可取消，409）
GET    /api/admin/upstreams          上游列表（admin）
POST   /api/admin/upstreams          添加上游（admin，JSON body {name,url,priority}）
DELETE /api/admin/upstreams/:id      删除上游（官方仓受保护）
GET    /api/admin/resolve            多仓解析诊断 ?name=&organization=&require=
POST   /api/admin/publish-plans/analyze  发布计划依赖分析（拓扑排序）
POST   /api/admin/publish-plans/execute  发布计划执行（推送包到目标上游）
```

### 用户门户（普通用户）

```
GET    /me                          个人门户：发布 Token / 我的包 / 我的团队与权限
GET    /user/login                  用户登录（接受所有启用用户，含管理员）
```

公开导航按登录态显示：未登录「登录」→ 已登录「我的」→ 管理员额外显示「管理后台」。

### 用户 API（session token）

```
GET    /api/user/me                  当前用户 + 掩码 Token + 权限模式
POST   /api/user/me/publish-token    重置自己的发布 Token（旧 Token 立即失效）
GET    /api/user/me/packages         我发布过版本的包（分页/搜索，含 owner 标记）
GET    /api/user/me/teams           我所属团队 + 权限 + 关联组织/包
```

### 内存与优雅关闭

**常驻内存构成**（一个数据目录 = 一个 badger-cj 库）：

| 项 | 默认 | 说明 |
|---|---|---|
| MemTable arena | 2 × memTableSize = **32 MB** | bstorm 默认 `memTableSize` 16 MB（badger 内部 arena = 2×，属原生内存） |
| 仓颉 GC 堆上限 | **256 MB** | 仓颉运行时默认，全部托管对象都在此配额内 |

`POST /pkg` 目前把**整个请求体读入内存**后再分段落盘，峰值约为包体的 2–3 倍 —— 发布 30 MB 以上的包前请调大堆上限：

```shell
export cjHeapSize=2GB          # 提高 GC 堆上限（默认 256MB）
export cjGCThreshold=1GB       # 触发 GC 的堆阈值（配套）
export cjGCInterval=100ms      # GC 轮询间隔（配套）
```

> 环境变量名以当前仓颉运行时版本为准；后续将改为流式解析（边读边算 sha256、直接落盘），彻底消除该限制。
> 请求体上限本身由 `cjreg.toml` 的 `max_request_bytes` 控制（默认 500 MiB，`-1` 不限）。

**优雅关闭**：`serve` 已注册 SIGINT/SIGTERM（`Ctrl+C` / `docker stop` / `systemctl stop`）处理 ——
收到信号后先停止 HTTP 服务，再关闭数据库（flush memtable 落盘成 SSTable），最后进程正常退出（exit 0）。
配合默认开启的 `syncWrites`（每次写入 fsync），即使 `kill -9` 也不会丢已确认的写入。

### 官方协议端点

```
POST  /pkg/:name[?organization=]    发布（官方二进制 meta+tar；Authorization: 发布 token）
GET   /pkg/:name/:version           下载制品（本地无则回源上游）
GET   /index/:mo/:du/:name          索引 NDJSON（本地无则回源上游）
GET   /api/health                   健康检查
```

### 服务端配置（`cjreg.toml`）

配置只有一处来源：数据目录下的 **`cjreg.toml`**（`cjreg init` 会自动生成一份带注释的模板，完整示例见 `cjreg.toml.example`），也可用 `-c/--config <file>` 指定其它路径；文件不存在时全部走默认值。

```toml
[server]
public_url = "https://pkg.example.com"   # 对外地址：用户门户与帮助文档里的示例用它
port = 8060                              # 监听端口（命令行 -p 优先）
permission_mode = "open"                 # open = 有效 token 即可发布；team = 双路径裁决
require_auth = false                     # 下载/索引是否需有效 token + read 权限
```

- 优先级：**命令行 > 配置文件 > 默认值**（目前只有 `-p` 会覆盖 `port`）
- 没有环境变量配置项；唯一保留的环境变量是 `CJREG_SEED_DEMO=1`（开发调试：往空库注入演示包）

**team 模式双路径裁决**（`docs/design.md` §5.4.3）：

- **新包**：命名空间未被团队纳管（无 `TeamOrganization` 关联该组织 / `TeamPackage` 关联该包）→ 任意有效 token 可认领，首次发布者成为 `publisherId`
- **已有包新版本**：**包名所有者**（owner = 该包最早一条版本记录的发布者，唯一）**或** 所在团队对该包/该组织有 `write` → 放行，否则 403
  - 版本级 `publisherId` 逐版本累加记录（谁发的这一版，供追溯），但只有 owner 参与权限判定
- **覆盖已存在版本**（同版本不同 sha）：需团队 `overwrite`；owner 自身不具备覆盖权，覆盖也不转移所有权
- `open` 模式下同版本不同 sha 不静默覆盖，仍返回 409

## 双仓发布计划 e2e（验证）

用 6 个有依赖关系的测试包（`tests/pkgs/`）验证发布 → 拓扑分析 → 推送：

```bash
./tests/e2e.sh
```

流程：A(:18060) 按依赖顺序发布 6 包 → `analyze` 展开拓扑 → `execute` 推送到 B(:18070) → 验证 B 收到全部包 + 索引/下载/依赖完整。

```
app ──→ encryptUtils ──→ mathUtils, strUtils
     └─→ dataUtils   ──→ mathUtils, netUtils
```

## 技术选型

- 存储：**bstorm**（badger-cj + gjson 的 JSON 文档库）+ 制品 blob 落盘（`dataDir/blobs`）
- HTTP 服务端：**tang**（path `../tang`）
- HTTP 客户端：`stdx.net.http`（上游回源，302 跟随 + 二进制读取）
- 配置解析：`tomlcj`；版本匹配：`semver` + `semver_range`
- 认证：pbkdf2（用户名密码）+ 会话/发布 token

## 文档

- **在线文档站**：<https://ystyle.top/cjreg/>（VitePress，源码在 `docs-site/`，
  由 `.github/workflows/docs-deploy.yml` 自动部署到 GitHub Pages + 华为云 CDN 刷新）

- 设计：[docs/design.md](docs/design.md)
- 差距与实施对照：[docs/gap-analysis.md](docs/gap-analysis.md)
- **验证报告**（环境/方法/实测数据/复现步骤/已知限制）：[docs/verification.md](docs/verification.md)
- **决赛迭代计划**（初赛基线 + 迭代项 + 差异性说明模板）：[docs/finals-plan.md](docs/finals-plan.md)
- 用户门户设计：[docs/user-portal-design.md](docs/user-portal-design.md)
- 可行性评估（仓颉重写 cjrepo）：`../cjdep/docs/eval-cjrepo-cangjie.md`
