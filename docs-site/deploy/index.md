# 部署指南

## 单机（推荐起步）

```shell
# 1) 下载静态二进制并放到 /usr/local/bin/cjreg
# 2) 初始化
cjreg init -d /var/lib/cjreg --username admin --password '<强口令>'
# 3) 编辑配置（对外域名、权限模式、请求体上限等）
vi /var/lib/cjreg/cjreg.toml
# 4) 启动
cjreg serve -d /var/lib/cjreg
```

## systemd

```ini
[Unit]
Description=cjreg registry
After=network.target

[Service]
Type=simple
User=cjreg
WorkingDirectory=/var/lib/cjreg
# 发布大包（>30MB）时按需调大 GC 堆
Environment=cjHeapSize=2GB
Environment=cjGCThreshold=1GB
Environment=cjGCInterval=100ms
ExecStart=/usr/local/bin/cjreg serve -d /var/lib/cjreg -p 8060
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
```

`serve` 处理 SIGTERM：会先停服、把数据落盘再退出，`systemctl stop/restart` 安全。

## 容器

`Dockerfile` / `docker-compose.yml`（数据卷、`restart: always`、`cjHeapSize` 环境变量示例）在迭代计划中，
当前可用卷挂载方式自行封装静态二进制。

## 反向代理

放在 Nginx/Caddy 之后时，把外部域名配置到 `cjreg.toml` 的 `public_url`
——用户门户与文档里的 `registry` 示例会直接显示该地址，避免用户复制到错误地址。

## 备份与迁移

停服（或依赖 `syncWrites` 与优雅关闭）后拷贝整个数据目录即可；`blobs/` 与 `cjreg.db` 必须一起拷。
