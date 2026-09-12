# Docker 部署（默认）

推荐用 Docker Compose 部署 cjreg：一条命令起服务，卷即数据，升级只需换镜像。

## 1. 前置

- Docker 24+ 与 Docker Compose v2
- **仓颉工具链**（`cjc` / `cjpm` 1.1.3）—— 镜像采用「宿主编译、镜像打包」策略，
  因为 cjreg 通过 path 依赖引用 `../cjxt`，容器内自构建需要额外准备兄弟仓库与工具链镜像
  （与同系列仓颉项目忆时塔/集思阁保持一致）

## 2. 一键部署

```shell
git clone https://atomgit.com/ystyle/cjreg && cd cjreg
export ADMIN_PASS='<强口令>'
bash scripts/docker-deploy.sh
```

脚本做的事：编译 → `docker build` → 首次 `init`（创建管理员 + 默认上游 + 生成 `cjreg.toml`）→
`docker compose up -d` → 健康检查并打印访问地址。

## 3. 分步部署

```shell
# 1) 宿主编译（产出 target/release/bin/ystyle::cjreg）
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"
cjpm build -j 16

# 2) 构建镜像并启动
docker compose up -d --build

# 3) 首次初始化（只需一次；写 ./data）
docker compose run --rm cjreg /app/cjreg init -d /data \
  --username admin --password '<强口令>'

# 4) 访问
#    门户 http://localhost:8060/    管理后台 http://localhost:8060/admin
#    健康 GET /api/health
```

## 4. 目录与卷

```
./data（挂载到容器 /data）
├── cjreg.db        # bstorm（badger-cj）：包/用户/组织/团队/上游/日志/索引缓存
├── blobs/          # 制品内容寻址存储
└── cjreg.toml      # 服务端配置（改完 docker compose restart 生效）
```

**备份/迁移 = 拷贝 `./data`**；换机器后 `docker compose up -d` 即可。

## 5. 环境变量

`docker-compose.yml` 通过 `${VAR:-default}` 暴露这些开关：

| 变量 | 默认 | 说明 |
|---|---|---|
| `CJREG_PORT` | `8060` | 宿主端口映射（容器内固定 8060） |
| `CJREG_HEAP_SIZE` | `2GB` | `cjHeapSize` —— 仓颉 GC 堆上限（运行时默认 256 MB；**发布 >30 MB 的包时必须调大**） |
| `CJREG_GC_THRESHOLD` | `1GB` | `cjGCThreshold` 配套阈值 |

服务端业务配置（权限模式、读鉴权、对外地址、请求体上限）在**数据卷里的 `cjreg.toml`** ——
见[服务端配置](/deploy/env)。

## 6. 健康检查与优雅关闭

- 镜像内置 `HEALTHCHECK`（`curl -fsS /api/health`），compose 里也有同名检查；
- `stop_grace_period: 30s` + 应用侧的 SIGTERM 处理：`docker stop` / `docker compose stop`
  会走「停止 HTTP 服务 → flush memtable 落盘 → exit 0」，实测日志：

  ```
  [badger] received SIGINT/SIGTERM, closing gracefully...
  cjreg: 收到退出信号，正在优雅关闭（停止服务 → 落盘 → 退出）...
  ```

- 数据库以 `syncWrites` 打开（每次写入 fsync），即使 `docker kill` 也不丢已确认写入。

## 7. 常用运维命令

```shell
docker compose logs -f cjreg          # 日志
docker compose restart cjreg          # 改完 cjreg.toml 后重启
docker compose down                   # 停服（保留卷）
docker compose up -d --build          # 升级：重新编译 + 重建镜像 + 滚动替换
docker compose run --rm cjreg /app/cjreg admin reset-password -d /data \
  --username admin --password '<新口令>'   # 应急重置管理员
```

## 8. 使用发布好的镜像（可选）

Release 工作流会把镜像推送到 `ghcr.io/<owner>/cjreg`：

```yaml
services:
  cjreg:
    image: ghcr.io/ystyle/cjreg:latest
    container_name: cjreg
    restart: unless-stopped
    ports: ["8060:8060"]
    volumes: ["./data:/data"]
    environment:
      cjHeapSize: "2GB"
      cjGCThreshold: "1GB"
    stop_grace_period: 30s
```

## 9. 镜像说明

| 项 | 值 |
|---|---|
| 基础镜像 | `archlinux:latest`（与宿主编译环境 glibc 一致，避免 GLIBC 符号缺失） |
| 预装 | `liburing`（badger-cj io_uring）、`tzdata`、`ca-certificates`、`curl`（健康检查） |
| 运行用户 | 非 root，uid 1000；**挂载的数据目录属主须为 1000**（否则 `init`/写入报 Permission denied） |
| 体积 | 约 500 MB（与同系列仓颉项目一致；主要为 archlinux 底座） |
| 数据目录属主 | `sudo chown -R 1000:1000 ./data`（`scripts/docker-deploy.sh` 会自动处理；CI 冒烟同样处理） |
| 入口 | `/app/cjreg serve -d /data` |

> 需要更小体积可考虑：把底座换成带 `liburing2` 的 `debian:slim`，或用工具链镜像做多阶段自构建
> （后者在 CI 中需要 cjxt 的仓库访问权）。
