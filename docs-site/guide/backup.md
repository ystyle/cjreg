# 备份与恢复

cjreg 的数据目录有三部分：

```
data/
├── cjreg.db        # 元数据：包/用户/组织/团队/上游/日志/发布计划/索引缓存（bstorm 嵌入式库）
├── blobs/          # 制品内容寻址存储（sha256 文件名，多版本/多上游共享同一份）
└── cjreg.toml      # 服务端配置（对外地址、权限模式、请求体上限等）
```

对应两套工具，按用途选：

| 工具 | 用途 | 产物 |
|---|---|---|
| `admin backup` / `admin restore` | **完整备份与恢复**（数据库 + 制品内容，自带校验） | 单个 `tar.gz` |
| `admin dump` | **只读导出**数据行为 JSONL，用于升级前后 diff、人工检查、二次处理 | 目录（每表一个 `.jsonl` + `manifest.json`） |

> ⚠️ 命令行 `admin backup` / `admin dump` **必须停服后执行**：它们要独占打开数据目录。
> Docker 部署先 `docker compose stop`，操作完再 `up -d`（`stop` 走优雅关闭，会先把 memtable flush 落盘）。
> **不想停服就用上面第 0 节的管理后台在线备份**。

## 0. 管理后台：在线备份（不用停服）

管理后台 **「备份与恢复」**（`/admin/backups`，仅管理员）可以在**服务运行中**直接备份：

- **为什么能不停机**：备份在服务端进程内执行，复用已持有的数据库连接；底层整库扫描是**一个只读快照**
  （一个只读事务 + 一个迭代器），导出的数据行是自洽的；制品是内容寻址不可变的，备份期间新发布的
  制品不会被这次快照引用。
- **操作**：勾选「含制品」→ 点「立即备份」→ 等任务完成 → 列表里出现归档，可直接下载/校验/删除。
- **并发保护**：同一时间只允许一个备份任务（避免同时扫库把 IO 打满），重复点击返回 409。
- **保留策略**：默认保留最近 7 份（`keepCount`），更早的自动清理；删除只作用于 `cjreg-*.tar.gz`。
- **下载**：浏览器的 `<a>` 带不了 Bearer 头，下载走**一次性票据**（`POST /api/admin/backups/:file/ticket`
  签发，5 分钟有效、用后即焚、绑定文件名），URL 里不会出现长期 session token。
- **权限**：全部接口 `requireAdmin`；备份/下载/校验/标记恢复都写审计日志。归档含口令哈希、
  发布 Token 与审计日志，请按敏感文件保管。

对应接口：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/admin/backups` | 归档列表 + 最近任务 + 待恢复标记 |
| POST | `/api/admin/backups` | 触发备份，body `{"includeBlobs": true}` |
| POST | `/api/admin/backups/:file/ticket` | 签发一次性下载票据 |
| GET | `/api/admin/backups/:file/download?ticket=…` | 流式下载 |
| POST | `/api/admin/backups/restore-check` | 上传归档做校验（只读，不写库） |
| POST | `/api/admin/backups/:file/apply-on-restart` | 标记「下次重启应用」 |
| DELETE | `/api/admin/backups/restore-pending` | 取消待应用的恢复 |
| DELETE | `/api/admin/backups/:file` | 删除归档 |

### 恢复为什么不能在线做

数据库对数据目录是**独占**的，而 store 在启动时构造一次、被路由/管理端/发布计划执行器/回源代理
全进程持有——运行中替换整套存储等于在进程内重建服务，风险远大于收益。所以恢复是「半自动」：

1. 上传或选择一个归档 → **校验**（只读：格式、行数、制品 sha256）；
2. 点「重启时应用」→ 服务端写一个标记文件（`<dataDir>/.restore-pending`）；
3. **重启服务**，启动流程在打开数据库**之前**执行替换：
   - 现库与 `blobs/` 先挪到 `<dataDir>/.pre-restore-<时间戳>/`；
   - 解压归档并校验；
   - **任何失败自动回滚**：删掉半成品、把旧数据挪回、清掉标记，然后以旧数据正常启动。
4. 成功则删掉标记，`.pre-restore-*` 留档供人工回滚。

停机时间 = 一次普通重启。

## 1. 完整备份（命令行，适合脚本/定时任务）

```shell
# 停服
docker compose stop

# 宿主机二进制直接操作同一份 data 目录（默认包含 blobs/ 制品内容）
./target/release/bin/ystyle::cjreg admin backup \
  -d ./data \
  --out ./backup/cjreg-$(date +%F).tar.gz

# 只备数据库与制品清单（产物小，恢复后下载会 404，适合纯元数据灾备）
./target/release/bin/ystyle::cjreg admin backup -d ./data --out ./backup/db-only.tar.gz --no-blobs

docker compose start
```

容器内执行也可以（把备份目录也挂进去）：

```shell
docker compose stop
docker compose run --rm -v "$PWD/backup:/backup" cjreg \
  admin backup -d /data --out /backup/cjreg-$(date +%F).tar.gz
docker compose start
```

### 归档格式

`tar.gz`，内含：

| 条目 | 内容 |
|---|---|
| `manifest.json` | `format=cjreg-backup/1`、生成时间、总行数、每表行数/字节数、是否含制品、制品统计 |
| `blobs.manifest.jsonl` | 每行一个制品：`{"sha256": "...", "size": N}` |
| `<table>.jsonl` | 每表一个文件，**每行一个原始 JSON 文档**（主键在文档里） |
| `blobs/<sha256>` | 制品内容（仅完整备份；`--no-blobs` 没有这部分） |

命令结束会打印每张表的行数、制品数量与字节数。

## 2. 从备份恢复

```shell
# 目标目录必须是空目录（或只有 cjreg.toml）
cjreg admin restore -d ./restored --from ./backup/cjreg-2026-10-22.tar.gz
```

语义与护栏：

- **目标目录已有 `cjreg.db` 时拒绝**；确需覆盖加 `--force`（会先删目标里的 `cjreg.db` 与 `blobs/`，保留 `cjreg.toml`）；
- 数据按**原 id/token** 写回（保留发布者、下载数、时间等全部字段），索引由 bstorm 正常维护；
- 恢复前先校验 `manifest.json` 格式；恢复后**行数必须与 manifest 一致**，否则报错；
- 归档里的每个 `blobs/<sha256>` 落盘前都会**校验内容 sha256 与文件名一致**；
- 恢复完统计「包文档引用了但 `blobs/` 里没有」的制品数并提示（`--no-blobs` 备份会出现这种情况，
  这些包下载会 404，其余功能正常）；
- 归档里出现当前版本不认识的表 → **直接报错拒绝**，不会静默丢数据。

只校验、不写任何文件（适合定期检查备份可用性）：

```shell
cjreg admin restore -d ./empty --from ./backup/cjreg-2026-10-22.tar.gz --check-only
```

恢复后建议验证：`cjreg serve -d ./restored` → `GET /api/health`、管理员登录、包列表数量、随便下载一个包。

## 3. 只读导出（升级前后 diff）

```shell
# 先停服
cjreg admin dump -d ./data --out ./dump-before
# 升级/迁移后
cjreg admin dump -d ./data --out ./dump-after

# 数据行没变时，两份目录里同名 .jsonl 应逐字节相同
diff -r --exclude=manifest.json ./dump-before ./dump-after && echo "数据一致"
```

- **只读**：直接扫原始 key，不登记 schema、不触发索引迁移、不改任何数据行，v1 旧库也能直接导；
- 输出：每表一个 `<table>.jsonl`（每行一个原始 JSON 文档）+ `manifest.json`（行数/字节数/制品目录统计）；
- 内部 key（`__schema:` / `__idx:` / `__uniq:` 等）不导出；
- 适合：升级前的数据快照、升级后逐表 diff、把数据交给别的工具处理。

## 4. 备份策略建议

- **频率**：数据量小（几十 MB 级）可以按日备份；有制品时归档 ≈ `cjreg.db` + `blobs/` 总量，
  blobs 会随发布增长，先观察实际大小再定保留份数；
- **位置**：备份文件放另一台机器/对象存储，不要只留在服务端数据盘上；
- **验证**：定期跑一次 `--check-only`；每季度做一次「恢复到一个临时空目录 + `serve` 冒烟」演练；
- **升级前必做**：停服 → `admin backup`（或 dump）→ 再换二进制，回滚时恢复备份即可；
- **迁移换机器**：`admin backup` 生成归档 → 新机器 `admin restore`；或直接拷整个 `data/` 目录
  （两种方式等价，`restore` 额外有行数与制品校验）。

## 5. 常见问题

**恢复后下载 404？**
备份用了 `--no-blobs`，或备份时 `blobs/` 本身缺文件。恢复日志会打印缺失制品数量；需要制品就做完整备份。

**`restore` 报「目标目录已有数据库」？**
换成空目录，或加 `--force`（会删除目标目录现有的 `cjreg.db` 与 `blobs/`）。

**`restore` 报「备份格式不认识 / 备份里缺少 manifest.json」？**
归档不是 cjreg 的备份文件，或文件损坏。用 `--check-only` 先验证；必要时重新备份。

**能不能不停服备份？**
不能。Badger 独占数据目录，`admin backup`/`dump` 打开数据库会失败并提示先停服。
需要「热备」的极端场景只能依赖底层 LSM 的 SST 快照能力，目前不在支持范围内。

**备份文件能跨版本恢复吗？**
恢复侧按当前版本的 `@Model` 解码 JSON：同版本肯定可以；跨大版本（如 bstorm v1 → v2）数据格式兼容时也可以，
但建议升级后立即恢复演练一次再删旧备份。
