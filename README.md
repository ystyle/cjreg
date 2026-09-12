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

```bash
# 1. 构建
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"
cjpm build -j 16

# 2. 初始化（首个管理员 + 默认官方上游）
./target/release/bin/ystyle::cjreg init -d ./data --username admin --password YourPass

# 3. 启动
./target/release/bin/ystyle::cjreg serve -p 8060 -d ./data
```

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

### 官方协议端点

```
POST  /pkg/:name[?organization=]    发布（官方二进制 meta+tar）
GET   /pkg/:name/:version           下载制品（本地无则回源上游）
GET   /index/:mo/:du/:name          索引 NDJSON（本地无则回源上游）
GET   /api/health                   健康检查
```

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

- 设计：[docs/design.md](docs/design.md)
- 差距与实施对照：[docs/gap-analysis.md](docs/gap-analysis.md)
- 可行性评估（仓颉重写 cjrepo）：`../cjdep/docs/eval-cjrepo-cangjie.md`
