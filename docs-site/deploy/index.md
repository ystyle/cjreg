# 部署指南

cjreg 是**单个二进制**（含服务端 + 管理后台 + 门户），部署形态有三种，推荐程度从高到低：

| 方式 | 适用 | 入口 |
|---|---|---|
| **Docker Compose（默认）** | 生产/演示/评审复现，一键起服、卷即数据 | [Docker 部署](/deploy/docker) |
| Docker 单容器 | 已有编排体系，只想要一个容器 | 见下文 |
| 手动（裸机 + systemd） | 无 Docker 环境、要求极致轻量 | 见下文 |

## 方式一：Docker Compose（默认）

```shell
git clone https://atomgit.com/ystyle/cjreg && cd cjreg
export ADMIN_PASS='<强口令>'
bash scripts/docker-deploy.sh          # 编译 → 构建镜像 → init → 启动 → 健康检查
```

完整说明（卷、环境变量、优雅关闭、运维命令、ghcr 镜像）：[Docker 部署](/deploy/docker)。

## 方式二：Docker 单容器

```shell
cjpm build -j 16                                     # 宿主工具链编译
docker build -t cjreg:latest .
mkdir -p data
docker run --rm -v "$PWD/data:/data" cjreg:latest \
  /app/cjreg init -d /data --username admin --password '<强口令>'
docker run -d --name cjreg -p 8060:8060 \
  -v "$PWD/data:/data" -e cjHeapSize=2GB --restart unless-stopped cjreg:latest
```

## 方式三：手动（裸机 / systemd）

```shell
# 1) 编译（或下载 Release 里的静态二进制）
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"
cjpm build -j 16

# 2) 初始化并启动
mkdir -p /var/lib/cjreg
./target/release/bin/ystyle::cjreg init -d /var/lib/cjreg --username admin --password '<强口令>'
./target/release/bin/ystyle::cjreg serve -d /var/lib/cjreg -p 8060
```

systemd 单元（注意 `Environment=cjHeapSize=...`，发布大包需要）：

```ini
[Unit]
Description=cjreg registry
After=network.target

[Service]
Type=simple
User=cjreg
WorkingDirectory=/var/lib/cjreg
Environment=cjHeapSize=2GB
Environment=cjGCThreshold=1GB
Environment=cjGCInterval=100ms
ExecStart=/usr/local/bin/cjreg serve -d /var/lib/cjreg -p 8060
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
```

运行时依赖：`liburing.so.2`（badger-cj 的 io_uring）、glibc、libstdc++；
非 Debian 系发行版请确认 `liburing` 已安装。

## 反向代理与对外地址

放在 Nginx/Caddy 之后时，把外部域名写进数据目录的 `cjreg.toml`：

```toml
[server]
public_url = "https://pkg.example.com"
```

用户门户与帮助文档里的 `registry` 示例会直接显示该地址（避免用户复制到错误地址）。

## 备份与迁移

停服（或依赖 `syncWrites` + 优雅关闭）后拷贝**整个数据目录**：`cjreg.db` + `blobs/` + `cjreg.toml`。
容器部署就是拷 `./data`。

## 配置项

全部服务端配置见[服务端配置](/deploy/env)。
