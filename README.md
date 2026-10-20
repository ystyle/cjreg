# cjreg — 仓颉私有中心仓与多仓工具

> 🎬 **演示视频**：[cjreg 演示（B 站）](https://www.bilibili.com/video/BV1e9pw6WELk/)
> —— 部署 · 门户与包列表 · cjpm 发布 · 多仓解析 · 上游与发布计划推送 · 权限 · 审计 · 三级删除

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

**方式一：直接用现成镜像（最快，无需仓颉工具链）**

```bash
mkdir -p ~/cjreg/data
# 初始化：创建首个管理员 + 默认官方上游 + 生成 cjreg.toml（只需一次）
docker run --rm -v ~/cjreg/data:/data ghcr.io/ystyle/cjreg:latest \
  /app/cjreg init -d /data --username admin --password 'YourPass'
# 启动
docker run -d --name cjreg -p 8060:8060 -v ~/cjreg/data:/data --restart unless-stopped \
  ghcr.io/ystyle/cjreg:latest
# 门户 http://localhost:8060/    管理后台 http://localhost:8060/admin
```

> 镜像 `ghcr.io/ystyle/cjreg`（公开，linux/amd64）已内置 Web 静态资源；数据全部在挂载的 `/data`
> （`cjreg.db` + `blobs/` + `cjreg.toml`），容器以 uid 1000 运行、数据目录属主需可写。
> 发布大包（>30MB）按机器内存加 `-e cjHeapSize=4GB`。

**方式二：Docker Compose（源码构建）**

```bash
git clone https://atomgit.com/ystyle/cjreg && cd cjreg
export ADMIN_PASS='YourPass'
bash scripts/docker-deploy.sh        # 编译 → 构建镜像 → init → 启动 → 健康检查
# 门户 http://localhost:8060/    管理后台 http://localhost:8060/admin
```

**方式三：手动（裸机 / systemd）**

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
GET    /api/admin/upstreams          上游列表（admin，含 proxyEnabled/asTarget 两个开关）
POST   /api/admin/upstreams          添加上游（admin，{name,url,priority,proxy_enabled,as_target}；
                                     默认 proxy_enabled=true、as_target=false）
PUT    /api/admin/upstreams/:id      局部更新上游（enabled/proxyEnabled/asTarget/priority/cacheTtl/authToken）
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

`POST /pkg`、下载与回源都是**流式**的：边读边算 sha256、直接落临时文件 / 转发给响应，
**峰值内存与包体大小无关**（实测发布 2 / 32 / 200 MiB 时进程 VmHWM 恒定 ~291 MiB，
下载 200 MiB 同样平稳，见 `docs/benchmark.md`）。因此发布大包**不需要再调大堆上限**：

```shell
# 可选：仅在「高并发 + 大包」叠加、或需要更激进的回收策略时才调
export cjHeapSize=2GB          # 提高 GC 堆上限（默认 256MB）
export cjGCThreshold=1GB       # 触发 GC 的堆阈值（配套）
```

> 环境变量名以当前仓颉运行时版本为准。请求体上限由 `cjreg.toml` 的 `max_request_bytes` 控制
> （默认 500 MiB，`-1` 不限）。

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

## 相关工具

围绕仓颉多仓体系，同作者维护了两个配套命令行工具（均为公开仓库，与本仓口径一致）：

- **[`cjdep`](https://atomgit.com/ystyle/cjdep)** —— 依赖与「口径」工具。查某个包在本机生效 registry 上的
  最新版本、逐仓可解析情况，以及**哪些包需要发布**；发版与预演前的第一道核查：

  ```shell
  cjdep plan -r https://pkg.cangjie-lang.cn/registry   # 指定 registry，避免被本地缓存误导
  ```

- **[`cjpm-ws`](https://atomgit.com/ystyle/cjpm-ws)** —— cjpm workspace（多包产品）工具。统一成员版本号并按依赖
  拓扑序发布，`check` 可作 CI 闸门：

  ```shell
  cjpm ws check <workspace-dir>     # 版本/依赖一致性检查（不齐退出码 1）
  cjpm ws bump <ver> -w             # 物化版本号（默认 dry-run）
  cjpm ws publish                   # 拓扑序批量发布（拒绝官方仓需显式确认）
  ```

> 与 cjreg 的对应关系：`/api/admin/resolve` 的逐仓命中链路对应 `cjdep` 的解析顺序；
> 发布计划的目标仓推送与 `cjpm-ws publish` 的拓扑序一致 —— 两者可以互为验证。

## 技术选型

- 存储：**bstorm**（badger-cj + gjson 的 JSON 文档库）+ 制品 blob 落盘（`dataDir/blobs`）
- HTTP 服务端：**tang**（path `../tang`）
- HTTP 客户端：`stdx.net.http`（上游回源，302 跟随 + 二进制读取）
- 配置解析：`tomlcj`；版本匹配：`semver` + `semver_range`
- 认证：pbkdf2（用户名密码）+ 会话/发布 token

## 文档

- **在线文档站**：<https://ystyle.top/cjreg/>（VitePress，源码在 `docs-site/`，
  由 `.github/workflows/docs-deploy.yml` 自动部署到 GitHub Pages + 华为云 CDN 刷新）

- 发版流程（tag 驱动：二进制产物 + GitHub Release + ghcr 镜像）：[docs/RELEASE.md](docs/RELEASE.md)
- 演示视频脚本（分镜/解说词/复现说明）：[docs/demo-video.md](docs/demo-video.md)（演示环境：`bash scripts/demo-data.sh`）
- 审计日志：[docs/audit-log.md](docs/audit-log.md)
- 公开只读 API：[docs/public-api.md](docs/public-api.md)
- 设计：[docs/design.md](docs/design.md)
- 差距与实施对照：[docs/gap-analysis.md](docs/gap-analysis.md)
- **验证报告**（环境/方法/实测数据/复现步骤/已知限制）：[docs/verification.md](docs/verification.md)
- **决赛迭代计划**（初赛基线 + 迭代项 + 差异性说明模板）：[docs/finals-plan.md](docs/finals-plan.md)
- 用户门户设计：[docs/user-portal-design.md](docs/user-portal-design.md)
- 可行性评估（仓颉重写 cjrepo）：`../cjdep/docs/eval-cjrepo-cangjie.md`
