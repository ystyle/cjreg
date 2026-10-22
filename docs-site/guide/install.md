# 安装与运行

![装好后的公开门户](/images/portal-home.webp)

## 运行形态

| 形态 | 说明 |
|---|---|
| 静态二进制 | `--static` 编译，无运行时依赖，单文件即可运行（推荐） |
| 裸机 + systemd | 用 `ExecStart=` 起 `serve`，配合 `Restart=always` |
| 容器（现成镜像） | `docker run ghcr.io/ystyle/cjreg:latest`，无需仓颉工具链（见「Docker 部署」） |
| 容器（源码构建） | 仓库内 `Dockerfile` / `docker-compose.yml`：宿主编译 → 镜像打包 |

## 命令

```
cjreg <command> [options]

命令：
  serve      启动服务（官方协议端点 + 管理 API + 用户 API + Web 界面）
  init       初始化数据目录（首个管理员 + 默认官方上游 + 配置模板）
  admin      应急管理（reset-password：重置口令并强制启用管理员）
  admin-ui   仅启动管理界面（调试用）

选项：
  -d, --data <dir>     数据目录（默认 ./data）
  -p, --port <n>       serve 端口（优先于配置文件）
  -c, --config <file>  配置文件（默认 <数据目录>/cjreg.toml）
  -h, --help
```

## 数据目录

```
data/
├── cjreg.db        # bstorm（badger-cj）嵌入式库：包/用户/组织/团队/上游/日志/索引缓存
├── blobs/          # 制品内容寻址存储（sha256 文件名，多版本/多上游共享同一份）
└── cjreg.toml      # 服务端配置
```

**备份**：拷贝整个目录，或用 `cjreg admin backup` 生成可校验的 `tar.gz`；**迁移**：拷到新机器后直接 `serve`（跨进程自增 id 与索引自动恢复）。详见[备份与恢复](/guide/backup)。

## 应急：忘记管理员口令

```shell
cjreg admin reset-password -d ./data --username admin --password '<新口令>'
```

语义是「重置口令 + 强制 `isAdmin=true` + `isActive=true`」——用于管理端锁死（管理员被禁用/降级）或口令丢失，
不会创建新用户。

## 优雅关闭

`serve` 已注册 SIGINT/SIGTERM：收到信号后先停止 HTTP 服务，再关闭数据库（flush 落盘），最后正常退出（exit 0）。
`Ctrl+C`、`docker stop`、`systemctl stop` 都走这条路径，详见[内存与优雅关闭](/guide/memory)。
