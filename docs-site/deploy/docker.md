# Docker 部署（默认）

推荐用容器部署 cjreg：卷即数据，升级只需换镜像。

## 1. 前置

- **方式一（现成镜像）**：只需要 Docker 24+ —— 镜像已发布在 `ghcr.io/ystyle/cjreg`
- **方式二（源码构建镜像）**：另需**仓颉工具链**（`cjc` / `cjpm` 1.1.3），
  因为镜像采用「宿主编译、镜像打包」策略（cjreg 通过 path 依赖引用 `../cjxt`，
  容器内自构建需要额外准备兄弟仓库与工具链镜像）

## 2. 直接用现成镜像（推荐）

```shell
mkdir -p ~/cjreg/data
# 初始化（只需一次）：创建首个管理员 + 默认官方上游 + 生成 cjreg.toml
docker run --rm -v ~/cjreg/data:/data ghcr.io/ystyle/cjreg:latest \
  /app/cjreg init -d /data --username admin --password '<强口令>'
# 启动
docker run -d --name cjreg -p 8060:8060 -v ~/cjreg/data:/data --restart unless-stopped \
  ghcr.io/ystyle/cjreg:latest
# 门户 http://localhost:8060/    管理后台 http://localhost:8060/admin
```

等价 Compose（推荐用于长期运行；`stop_grace_period` 给关闭落盘留时间）：

```yaml
services:
  cjreg:
    image: ghcr.io/ystyle/cjreg:latest
    container_name: cjreg
    ports: ["8060:8060"]
    volumes: ["./data:/data"]
    restart: unless-stopped
    environment:
      TZ: Asia/Shanghai
      cjHeapSize: 2GB
    stop_grace_period: 30s
```

- 镜像公开（`linux/amd64`），内置 Web 静态资源；容器以 **uid 1000** 运行，数据目录属主需可写。
- 数据全在 `/data`：`cjreg.db` + `blobs/` + `cjreg.toml`；备份 = 拷贝目录或用 `admin backup` 打成 tar.gz，迁移 = 换机器（见[备份与恢复](/guide/backup)）。
- 发布大包（>30MB）按机器内存调 `cjHeapSize`。

## 3. 从源码构建镜像（一键）

```shell
git clone https://atomgit.com/ystyle/cjreg && cd cjreg
export ADMIN_PASS='<强口令>'
bash scripts/docker-deploy.sh
```

脚本做的事：编译 → `docker build` → 首次 `init`（创建管理员 + 默认上游 + 生成 `cjreg.toml`）→
`docker compose up -d` → 健康检查并打印访问地址。

## 5. 自包含构建镜像（评审无需仓颉工具链）

上面两种方式都要求**本机已装仓颉工具链**（镜像是「宿主编译、镜像打包」）。若希望**一条命令从源码到可用镜像**，用 `Dockerfile.build`：

```shell
docker build -f Dockerfile.build -t cjreg:selfbuild .
docker run -d --name cjreg -p 8060:8060 -v ~/cjreg/data:/data cjreg:selfbuild
```

- 工具链在容器内用 **[cjv](https://github.com/Zxilly/cjv)**（Cangjie Version Manager）安装，
  与 GitHub Actions 里 `Zxilly/setup-cangjie` 同源；刻意不用发行版包管理器或 `cjvs` ——
  后者的覆盖面取决于发行版，换基础镜像就得跟着改。
- 工具链版本用 `--build-arg CANGJIE_VERSION=<版本>` 指定（默认 `1.1.3`，对应 `cjpm.toml` 的 `cjc-version`）。
- ⚠️ **glibc 一致性**：构建阶段与运行阶段使用**同一个基础镜像**（`archlinux:latest`）。
  仓颉产物动态依赖 glibc，两侧版本不一致会出现 `GLIBC_2.x not found` → 容器反复重启；
  升级基础镜像时两个阶段一起升（并在宿主机 `docker pull archlinux:latest` 后再构建）。
- 取舍：自包含构建需要在容器内下载工具链，首次构建较慢；日常迭代仍推荐用「宿主工具链 + `Dockerfile`」的快路径。

## 6. 反向代理与 HTTPS

cjreg 自身只监听 HTTP（默认容器内 8060），生产建议前置反向代理终止 TLS。

Caddy（自动申请证书，最省事）：

```caddyfile
cjreg.example.com {
    encode zstd gzip
    # 大包发布：与 cjreg 的 max_request_bytes 对齐（默认 500 MiB）
    request_body { max_size 1GB }
    reverse_proxy 127.0.0.1:8060 {
        flush_interval -1     # 发布/下载是流式大体量传输，关缓冲
    }
}
```

Nginx：

```nginx
server {
    listen 443 ssl http2;
    server_name cjreg.example.com;
    ssl_certificate     /etc/letsencrypt/live/cjreg.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/cjreg.example.com/privkey.pem;

    client_max_body_size 600m;          # 与 max_request_bytes 对齐

    location / {
        proxy_pass http://127.0.0.1:8060;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_request_buffering off;    # 大制品不要缓冲到磁盘/内存
        proxy_buffering off;
    }
}
```

要点：

- **`public_url` 必须配成对外地址**（`cjreg.toml` 的 `[server] public_url`）——门户展示、发布计划推送都取它；
- 反代链路里的 `X-Forwarded-For` 会被写进审计日志（IP 列）；
- 前面若还有 CDN，`client_max_body_size` / `max_request_bytes` / CDN 上传上限三者要对齐，否则大包会在不同环节被截断。

## 4. 分步部署

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

**备份/迁移**：停服后拷贝 `./data`，或用 `admin backup` 生成可校验的 `tar.gz`；换机器后 `docker compose up -d` 即可。详见[备份与恢复](/guide/backup)。

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

发布版本时（**推送 `v*` tag**）Release 工作流会把镜像推送到 `ghcr.io/ystyle/cjreg`，
tag 为版本号与 `latest`：

```shell
docker pull ghcr.io/ystyle/cjreg:v0.2.0     # 具体版本
docker pull ghcr.io/ystyle/cjreg:latest     # 最新
```

> 私有仓库的镜像默认私有，拉取前先 `docker login ghcr.io -u <用户名> -p <PAT>`（PAT 勾选 `read:packages`）；
> 需要公开拉取则在 GitHub → Packages → cjreg → Package settings 改为 public。
> 发版步骤（含校验命令）见 `docs/RELEASE.md`。

Compose 引用：

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

## 自包含构建（无需本地仓颉工具链）

仓库内提供 `Dockerfile.build`（多阶段）：构建阶段在容器里安装官方 SDK 编译，运行阶段与构建阶段**同一基础镜像**
（保证 glibc 一致），评审或新机器上不必先装 `cjc/cjpm`：

```shell
docker build -f Dockerfile.build -t cjreg:selfbuild .
docker run --rm -p 8060:8060 -v "$PWD/data:/data" cjreg:selfbuild
```

- 该文件里另有一个 `dev` target，供在容器内做构建/测试（已带 cmake/ninja/flatc 等 stdx 依赖）；
- 当前官方镜像只提供 **linux/amd64**；arm64 与镜像瘦身仍在路线图中。

