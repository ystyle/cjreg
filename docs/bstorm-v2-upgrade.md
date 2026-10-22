# cjreg 升级到 bstorm v2（2.0.0）评估

> 2026-10-22 · 评估对象：`cjreg 0.3.0`（依赖 `bstorm 1.4.11`）→ `bstorm 2.0.0`
> 结论：**建议原地升级（换二进制），不需要 JSON 导出/恢复**；JSON 备份能力可作为独立灾备功能后续再做。

## 一、结论先行

1. **cjreg 的数据不需要迁移**。v2 只改了索引 key 编码，而 cjreg 全部 12 个 `@Model` **从未使用
   `@Index` / `@Unique` / `node()` / raw API**（查过全部 git 历史），生产库里没有索引项需要重建。
   数据行 key 格式 v1/v2 一致（`<table>:primary:<id>`），`@Model` 宏代码 v1.4.11 与 v2 **逐字节相同**，
   所以写入的 JSON 由 v2 读出来完全一致。
2. **升级动作 = 换二进制 + 重启**。v2 首次访问每张表时补写一条 schema 记录（12 条小记录），
   没有索引重建、没有数据搬迁。实测同一数据目录 v1 ↔ v2 互通（见 §三）。
3. cjreg 在 v2 依赖下 **编译零改动**（只需把 `bstorm` 版本升到 2.0.0，工作区统一 `cjc-version=1.2.0`），
   **1002 个单测全部通过**。
4. 用户提出的「导出 JSON 压缩包 → 新版本恢复」对**这次升级不必要**；它的价值在**通用灾备 /
   跨存储引擎迁移 / 升级前后内容比对**，建议作为独立功能排期（方案见 §五）。

## 二、为什么不用导出/恢复

| 兼容项 | v1.4.11 | v2.0.0 | 结论 |
|---|---|---|---|
| badger-cj（存储引擎） | 1.6.21 | 1.6.21 | 同一版本，SST/WAL 格式一致 |
| 数据行 key | `<table>:primary:<id>` | 同 | 完全一致，无需搬迁 |
| 索引项 | 无（cjreg 未用 `@Index`） | 无 | 无需重建 |
| `@Model` 序列化宏 | — | 与 v1 逐字节相同 | JSON 读写行为一致 |
| schema 记录 | 无 | v2 首次访问时补写 | 12 条小写入，毫秒级 |
| 事务/关闭钩子/`syncWrites` | 支持 | 支持（`Storm.open` 参数不变） | API 兼容 |

补充：cjreg 的数据目录里除了 `cjreg.db` 还有 `blobs/`（内容寻址，`blobs/{sha256}`，当前 453 个
文件 / 26MB）。导出/恢复方案必须同时处理 blobs，而原地升级**天然保持两者一致**。

## 三、实测证据（全部用 fake 数据，未触碰生产库）

1. **cjreg 全量测试**：在 `eval/bstorm-2` worktree 里把 `bstorm` 换成路径依赖
   `../storm-cj-v2/bstorm`，`cjpm build` 通过、`cjpm test` **1002/1002 通过**。
2. **旧库升级预演**：用 v1.4.11 造一份 cjreg 形状的库（UserDoc / UserTokenDoc / PackageDoc /
   UpstreamDoc，含 `ArrayList` 字段、中文、字符串主键，650 行），v2 打开：
   - `open + 4 张表 reindex` 98ms；
   - 行数、抽样字段、列表字段、字符串主键、新增字段默认值全部一致；
   - schema 登记成功，`nextId` 恢复（扫 max id）、改/删/增、reindex 幂等全部通过。
3. **二进制级演练**（`cjreg v1 init` → `v1 serve` → 停 → `v2 serve` 同一目录 → 停）：
   - v1：health=200，users=1，upstreams=1；
   - v2：health=200，**启动 268ms**，users/upstreams 数量一致，login/管理 API 正常；
   - v2 优雅退出 exit=0；
   - 反向也验证了：**v1 二进制能重新打开被 v2 升级过的目录**（v1 忽略 `__schema:` 记录），
     即二进制回退可用（更稳的回退仍是恢复目录备份）。

## 四、推荐升级路线（原地升级）

### 前置（✅ 已完成）
- bstorm 2.0.0 已发布：私有仓（预演，可覆盖）→ 中心仓（索引/制品均已同步，sha256 与预演制品一致），tag `v2.0.0`。
- cjreg 侧改动在分支 `feat/bstorm-2`：`"bstorm" = "2.0.0"` + `cjc-version` 1.2.0（编译验证需要，见 §三）；
  同时去掉各 store 构造函数里 12 次 `reindex`（v2 的 schema/索引已持久化，不再需要每次启动重建）。
- 构建新镜像并**保留旧镜像 tag**（回滚用）。

### 演练（生产数据副本，可提前做）
1. 停服（保证 memtable 落盘；cjreg 已注册 SIGTERM 优雅关闭）。
2. `cp -a data /backup/cjreg-data-YYYYmmdd`（34MB DB + 26MB blobs，秒级）。
3. 把副本拷到演练目录，用**新二进制** `serve -d <副本> -p 180xx`：
   - 校验 `/api/health`、管理员登录、用户/上游/包列表数量与抽查字段；
   - 走一次发布/下载/回源链路（可用 cjpm 对本机实例发一个测试包）。
4. 记录 v2 启动耗时与数据目录大小变化（schema 记录会让 DB 略增）。

### 正式升级（预计停机 < 1 分钟）
1. `docker compose stop`（或 systemd stop），确认进程退出。
2. 冷备 `data/`（`cp -a` 或 tar；建议保留最近 2 份）。
3. 换新镜像/新二进制启动。
4. 冒烟：health、登录、包列表、一次下载。
5. 观察：启动日志（schema 登记）、审计日志写入、发布/回源。

### 回滚
- 首选：停 → 恢复 `data/` 备份 → 旧二进制启动（干净回滚）。
- 备选：直接换回旧二进制（实测可读，但会留下 v2 写的 schema 记录，不推荐长期混跑）。

## 五、如果要做 JSON 备份/恢复（建议独立于本次升级）

### 定位
- **不是**这次升级的必需品；是**通用灾备 + 未来跨存储引擎迁移 + 升级前后 diff** 的工具。
- 优先级建议：P1 只读 dump（升级前 diff 用）；P2 完整 backup/restore。

### ✅ P1 已实现：`cjreg admin dump`
```shell
# 先停服务（Badger 独占数据目录），再导出：
./target/release/bin/ystyle::cjreg admin dump -d ./data --out /backup/dump-$(date +%F)
```
- 只读：直接扫原始 key，**不登记 schema、不触发索引迁移、不改数据行**，v1 旧库也能直接导；
- 输出：数据行按表拆成 `<table>.jsonl`（每行 `{"_id":"...","_json":<原始 JSON>}`）
  + `manifest.json`（导出时间、总行数、每表行数/字节数、blobs 目录与文件数）；内部族（`__schema:`/`__idx:` 等）不导；
- 用途：升级前后各 dump 一次，比较 JSONL 与 manifest 即可证明「数据行零变化」；也可作灾备快照的元数据部分。
- 实测（clean drill）：v1 建库（3 个演示包 + 1 用户 + 1 上游）→ v1 serve 停 → dump → v2 serve 迁移索引 → 停 →
  dump：`package_doc/upstream_doc/user_doc` 三个 JSONL **逐字节相同**，总行数 5→5，v2 启动 267ms。

### ✅ P2 已实现：`cjreg admin backup` / `restore`
```shell
# 停服务后：
./target/release/bin/ystyle::cjreg admin backup  -d ./data --out /backup/cjreg-$(date +%F).tar.gz
./target/release/bin/ystyle::cjreg admin restore -d ./empty-dir --from /backup/cjreg-2026-10-22.tar.gz
# 只校验、不写文件：
./target/release/bin/ystyle::cjreg admin restore -d ./empty-dir --from <file> --check-only
```
- **归档格式（tar.gz）**：`manifest.json`（format=`cjreg-backup/1`、时间、总行数、每表行数/字节、
  是否含制品）+ `blobs.manifest.jsonl`（每行 sha256/size）+ 每表 `<table>.jsonl`（每行原始 JSON）
  + `blobs/<sha256>`（制品内容，默认包含；`--no-blobs` 只备库与清单）；
- **恢复语义**：目标目录必须是空目录（或只有 `cjreg.toml`）；已有 `cjreg.db` 时拒绝，`--force` 会先删
  `cjreg.db` 与 `blobs/`；数据行按原 id/token 写入（JSON 自带主键），索引由 bstorm 维护；
  按 1000 行/事务批量写回（`syncWrites` 下逐条提交太慢）；
- **完整性**：manifest 行数必须与实际恢复行数一致；归档里每个 `blobs/<sha>` 落盘前先校验内容 sha256；
  恢复后统计「包文档引用了但 blobs 缺失」的制品数并提示（不阻断，下载时会 404）；
- **只读校验**：`--check-only` 走同一套解析/校验逻辑，但不打开数据库、不写任何文件；
- **实测（CLI 端到端）**：v2 建库（3 包 + 1 用户 + 1 上游 + 1 个内容寻址制品）→ backup（5 行，归档 1.3KB）
  → check-only 通过 → restore 到空目录（132ms）→ 恢复前后 dump 的 3 张表 JSONL **逐字节相同**、行数 5→5
  → 直接 `serve` 校验包/用户/上游数量一致；`--force` 覆盖非空目录也验证通过。

### 为什么不建议把备份做成「升级的必经步骤」
- 多一条要长期维护的代码路径与一个「恢复即改 id/顺序」的风险面；
- 34MB 的库做目录快照本来就够快、够可靠；
- 原地升级已验证零数据转换，导出/恢复反而引入人为错误。

## 五之二、顺带的查询改造（分支 `feat/bstorm-2`）

cjreg 原来几乎全靠 `all<T>()` 全表扫 + 内存过滤。借这次升级给热点加了索引（都是普通 `@Index`，
不加 `@Unique`，避免存量数据有重复时迁移失败）：

| 表 | 索引字段 | 改写的查询 |
|---|---|---|
| `user_doc` | `username` | 登录/注册/Token 刷新：`getUserByUsername` → `one()`（原来扫全表） |
| `package_doc` | `name` | 索引/下载/发布：`listVersions(org,name)` → `findBy("name")` + 组织过滤（结果按 id 排序，顺序与 v1 一致） |
| `upstream_doc` | `name` | 回源/上游按名查找：`getByName` → `one()` |
| `org_doc` | `name` | 组织按名查找：`findOrgByName`/`orgIdByName` → `findBy("name")` |
| `team_organization_doc` / `team_package_doc` / `team_member_doc` | `teamId` | 团队关联的列举/清理 |
| `plan_item_doc` | `planId` | 发布计划项列举 |

列表/分页/日志筛选这类「本来就要全表或读全量再排序」的查询保持原样；`LogDoc` 的时间范围+分页
未来可以再加 `createdAt` 索引 + `orderBy`，这次不做。

**升级代价**：首次用 v2 打开旧库时，这些索引会自动重建一次（扫表 + 写索引项；本机 34MB 库量级为秒级），
之后持久化，不再重复。cjreg 构造函数里的 `reindex` 已删除（否则每次启动都会重建）。

## 六、风险与注意事项

1. **cjreg 启动时对 12 张表调 `reindex`**：v2 之前会扫全表，已优化为「无索引表只清旧索引项、
   不扫数据」（bstorm v2 提交 `0113966`），升级后启动开销与 v1 相当或更小。
2. **JSON 字段演进**：cjreg 已有「旧文档缺字段按默认值」的约定（见 `upstream_store.cj` 注释），
   v2 宏与 v1 相同 → 行为不变；升级演练仍应抽查 `LogDoc` 等大表。
3. **大表启动/查询开销**：cjreg 大量使用 `all<T>()` 全表扫描（如 `listVersions`），v2 的 `all()`
   与 v1 同架构、实测略快（300k 行 1.47s vs 1.71s）；升级后观察列表页/审计页延迟。
4. **写入收益**：cjreg 每次下载会 `save` 计数、写审计日志，v2 批量写实测快 2.4 倍（300k 行基准），
   高并发下载场景会感受到。
5. **未来加索引的代价**：一旦给 cjreg 的模型加 `@Index`/`@Unique`，升级/改表会触发 v2 重建索引，
   唯一约束也会变成硬约束（v1 是静默覆盖）——那时需要单独设计。
6. **版本线选择**：cjreg 的收益主要来自「统一技术栈/维护线」，不是性能刚需；若只想拿修复
   （badgercj/关闭钩子），继续留 v1 也可行。升级的真正前置是 bstorm 2.0.0 发布。

## 七、待决策

- [x] 按本方案把 cjreg 切到 bstorm 2.0.0（分支 `feat/bstorm-2`；等 10.31 路演后再合并）。
- [x] bstorm 2.0.0 发布（私有仓 → 中心仓，已完成；v2 分支未合并到 master）。
- [x] P1 只读 dump 工具（已实现 `admin dump`，含单测与 clean drill 验证）。
- [x] P2 完整 backup/restore 已实现（`admin backup` / `admin restore`，含 `--check-only`、`--no-blobs`、`--force`）。
- [x] P3 管理端备份页（**在线备份，不需要停服**）+ 恢复「上传校验 → 标记 → 重启应用（失败自动回滚）」。
- [ ] 生产备份策略：按日 backup（含制品）留存几份、放哪台机器（blobs 会随发布增长，需观察归档大小）。
- [ ] 升级后部署到生产（等合并节奏；先在生产数据副本上按 §四演练一遍）。
