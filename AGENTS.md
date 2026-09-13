# cjreg — 仓颉中心仓（registry）

## 测试凭据（管理端）

仅用于本地开发/冒烟/浏览器 QA 环境，**禁止**用于任何生产部署。

| 环境 | 数据目录 | 用户名 | 密码 |
| --- | --- | --- | --- |
| 本地 smoke/QA 服务 | `.smoke/auth-data`（`cjreg serve -d .smoke/auth-data -p 18062`，可加 `CJREG_SEED_DEMO=1` 注入演示包） | `admin` | `admin123` |
| `tests/e2e.sh` 双仓脚本 | `.smoke/A/data`、`.smoke/B/data`（`cjreg init` 现场创建） | `admin` | `AdminPass1` |

说明：`admin` 是 `cjreg init --username admin` 创建的首个管理员，`isAdmin=true`，可登录管理端（`/admin/login`）并访问一切管理页。生产端密码必须用 `cjreg init --password <强口令>` 独立设置，不要复用本地测试口令。

## 启动本地服务

```shell
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"
cjpm build -j 16
CJREG_SEED_DEMO=1 ./target/release/bin/ystyle::cjreg serve -d .smoke/auth-data -p 18062
```

服务配置走 `<数据目录>/cjreg.toml`（或 `-c/--config`）：`[server] site_name / public_url / port / permission_mode / require_auth / max_request_bytes`；
权限模式与对外地址都改这个文件（没有环境变量配置项，`CJREG_SEED_DEMO` 只是开发调试开关）。

- **`site_name`（站点名称，默认 `cjreg`）**：一门两用——浏览器**标签标题**（cjxt 的 `AppConfig.title`，
  不配就是默认的「cjxt App」，很丑）+ 页面**品牌文字**（公开端导航、后台侧栏「X 管理」、登录页「X 管理控制台 / X 用户门户」）。
  运行时改配置 restart 即可生效；配成空白回落默认值（不会把品牌文字弄没）。
  有标题的页面（`@Page["/admin/packages", "包管理"]`）会把自己设为标签标题，其余页面用站点名称。

## 生产部署（docker，私有仓）

团队日常用的**私有中心仓**就是从本仓部署的（docker compose 项目 `cjreg`）：宿主 **8066** → 容器 8060，
数据卷 `cjreg/data` → `/data`，`restart: unless-stopped`，对外 `http://192.168.3.6:8066`。

> **凭据、客户端配置（`~/.cjpm/` 三文件切换）、发版闸门**统一记在工作区 `../AGENTS.md` 的「私有仓（cjreg）」章节
> ——刻意不写在本文件里：本文件受 git 跟踪，口令有被提交/推送的风险。

更新生产实例：

```shell
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"
cjpm build -j 16
CJREG_PORT=8066 docker compose build && CJREG_PORT=8066 docker compose up -d
```

- ⚠️ **必须显式传 `CJREG_PORT=8066`**：`docker-compose.yml` 是 `"${CJREG_PORT:-8060}:8060"`，不传会改成 8060。
- 镜像只打包**宿主编译产物**（`Dockerfile` 里 `COPY ${CJREG_BIN} /app/cjreg`），所以必须先 `cjpm build`。
- 部署后硬校验：`docker exec cjreg sha256sum /app/cjreg` 应等于 `sha256sum target/release/bin/ystyle::cjreg`。
- 重置管理员口令需先停容器独占数据目录：`docker compose stop` → `./target/release/bin/ystyle::cjreg admin reset-password -d data --username admin --password '<新口令>'` → `CJREG_PORT=8066 docker compose start`。

**发布权限模式**：生产实例用 `permission_mode = "team"`（`effectivePermission` 里平台管理员直通 overwrite=3），
所以**同一版本可以反复发**——这是预演发布必需的；`open` 模式对同版本不同 sha 会返 409 且不覆盖。

## 展示元数据与 README（制品提取）

**为什么服务端要解压制品**：官方发布协议是「meta-data.json 段 + .cjp 段」，README **不在** meta 里；
索引协议（NDJSON）只有 `name/version/deps/sha256sum/yanked`，`description/license/authors/repository/tag/category`
**都不在**索引里。于是「回源聚合落库」的包只有索引字段——列表页描述全空、详情页没有 README。
破解办法只有一个：制品（`.cjp` = gzip + tar）内部带着 `README.md` 与 `cjpm.toml`，解压即可拿到
（`src/protocol/artifact.cj`：gzip 走 `stdx.compress.zlib`，tar 走自研 `ystyle::tar`）。

三处入口（都只**填空字段**，绝不覆盖已有值；不改 `updatedAt`，免得搅乱「最近更新」排序）：

1. **发布/覆盖**（`publish_service.cj` 的 `readmeOf`）：从制品提 README 落 `doc.readme`。
   提取失败**绝不阻断发布**——只打日志按空 README 入库（这是硬约束）。
2. **下载/回源**（`server.cj` 的 `/pkg/:name/:version` → `enrichDocByVersion`）：制品流经本地时顺手补齐
   该版本的 README 与展示字段；已补齐的文档不再重复解压。
3. **存量回捞**（CLI）：`./target/release/bin/ystyle::cjreg admin sync-metadata -d data [--all]`
   - 默认只管**每个包的最新版本**（列表页展示用），`--all` 处理所有版本；
   - 制品优先取本地 blob，没有就回源下载（落 blob，供发布计划复用）；
   - 与 `reset-password` 一样**必须先停容器**（Badger 独占数据目录）：

     ```shell
     docker compose stop
     ./target/release/bin/ystyle::cjreg admin sync-metadata -d data
     CJREG_PORT=8066 docker compose start
     ```

   - 输出末尾给出余额（README/描述/协议仍缺几个）。`category`/`tag` 等**制作者在 cjpm.toml 里没写就是没有**，
     属于数据现状而非缺陷。

> 2026-09-13：生产数据首次回捞结果 = 66 个包、补齐 65 个（唯一没补的是本地测试包 `docker::dtest`，
> 它的制品是占位字节不是真 gzip）；公开列表描述从 1/66 变为 65/66。

补充：制品字节数（`tarballSize`）也在这个口径里（索引协议不带 size，只有下载/重拉后才知道），
所以「只缺 size」的版本同样会被 `sync-metadata` 再补一轮（本地有 blob 就不用回源）。

## 后台：包版本列表 / 单版本详情 / 上游重拉

**版本列表**（包管理页「版本」按钮）：ID / 版本 / **来源**（本地发布 or `回源 · <上游名>`）/ **大小** /
**sha256**（缩写）/ **时间**（本地发布=发布时刻，回源=收录时刻）/ 下载 / 状态 / 操作（详情 · 重拉 · 软删 | 恢复 · 硬删）。

- **重拉**只对**回源镜像**版本出现（`upstreamId != 0`）；本地发布的版本本地才是权威，后端直接 409。
- **单版本详情**弹窗：全字段 + SHA256 全量 + 来源上游 + **README 全文**（Markdown 渲染，正文区独立滚动）。
- 两者都有管理 API（给脚本/CI 用）：
  - `GET  /api/admin/packages/:id` → 详情 JSON（含 `readme`/`readmeLength`/`upstreamName`/`artifactPresent`）
  - `POST /api/admin/packages/:id/refetch[?force=1]` → 重拉并覆盖本地缓存

**重拉的语义与护栏**（`src/server/refetch_service.cj`）：

| 情况 | 结果 |
|---|---|
| 上游索引取不到 / 制品下载失败 | `502 unreachable`，本地不动 |
| 上游索引里已无该版本 | `404 upstream_missing` |
| 下载内容与上游索引 sha 不符（半截包） | `409 invalid`，丢弃、本地不动 |
| 上游同版本 sha 变了（上游换过内容） | `409 sha_changed`（带 old/new sha），**要 `force=1` 才覆盖** |
| 本地发布的版本 | `409 local_owned`（连上游都不问） |
| 正常 | `200 ok` + `changed=true/false` |

- 成功后更新 sha / 制品大小 / indexJson / README / 展示字段；**不改** id / 下载数 / createdAt / updatedAt
  （重拉是刷新缓存，不是发版）；旧 blob 仍被其它版本引用时不清理。
- 每次重拉（含失败）都写管理审计 `refetch_package`，detail 带 `upstream/old/new/changed/size/force`。
- 排查用：`curl -s "http://127.0.0.1:8066/api/admin/logs/admin?keyword=refetch" -H "Authorization: Bearer <session>"`。

**硬删除的制品保护**：blob 是内容寻址的，同一制品理论上可被多个版本共享；硬删前会检查
`shaReferencedByOthers`，仍被引用时**只删记录、保留制品**（提示语里会写「仍被 N 个其它版本引用」）。

## 时间显示：区分「发布于」与「收录于」

索引协议**不含任何时间字段**（上游发布时间拿不到），所以回源镜像版本没有「发布时间」可言：

- **回源落库**（`cacheIndexEntries`）写 `createdAt = updatedAt = now` —— 语义是「**本仓收录时间**」；
- **存量补**：`admin sync-metadata` 会给 `createdAt == 0` 的文档补收录时间（输出里有「补收录时间 N 个版本文档」），
  **只补 createdAt、不动 updatedAt**（否则「最近更新」排序会被回捞时刻全部顶乱）；
- **公开页文案按来源区分**（`pages_public.cj` 的 `versionTimeText`/`versionTimePrefix`）：
  本地发布（`upstreamId == 0`）→「发布于 …」；回源镜像 →「收录于 …」；都拿不到才「时间未知」。
  详情页头部优先「更新于 …」（真实更新事件），没有才退回版本时间文案。

> **TZ**：页面时间都走 `.inLocal()`，容器默认 UTC 会把 19:06 显示成 11:06。`docker-compose.yml`
> 已固定 `TZ: ${CJREG_TZ:-Asia/Shanghai}`（改完 `docker compose up -d` 重建容器即可生效）。

> **UI 坑（已踩）**：cjxt 的 `Dialog` 保留**首次渲染**的静态子节点与 `title`（只有自带订阅的组件如
> `Table` 才会更新）。所以对话框里的动态内容必须包在「组件 + 信号」里——本仓用 `SignalView`
> （`pages_manage.cj`）包一层；纯 `text(...)` 或 `Dialog.title(...)` 换数据后**不会刷新**。


## agent-browser 在沙箱的使用说明

本工作区（DSH sandbox）里 `$HOME` 只读，agent-browser 有几个坑必须绕过。以下均来自实测。

### 会话/登录态

- **socket/state 目录不可写**：默认写到 `$XDG_RUNTIME_DIR/agent-browser`（只读）会失败。必须用**自定义会话**把 socket 落到可写目录：
  ```shell
  export AGENT_BROWSER_SOCKET_DIR=/home/ystyle/Projects/Cangjie/.qa-shots/ab-socket
  export AGENT_BROWSER_SESSION_NAME=cjreg-auth   # 命名会话名
  ```
  session 名与 socket 目录组合（用户建议的 `@.agent-browser-...` 自定义会话即此思路）。不指定 SOCKET_DIR 时新进程会因只读目录起不来。

- **用持久终端管理**：`agent-browser` 是 daemon，页面状态（WS 渲染、token）在各独立 bash 调用间会漂移。用 `terminal_open` 开一个持久 shell，在那里统一 `export` 并连续操作，别每次 bash 单独调。

- **登录态恢复**：这个 cjxt 管理端用 WS + localStorage `cjxt_token` 恢复会话。表单填字/点击在 cjxt 的输入上容易因 `input` 事件不同步而失败。最稳做法是**先 curl 拿 token 再注入**：
  ```bash
  TOKEN=$(curl -s -X POST http://127.0.0.1:18062/api/admin/login -H 'Content-Type: application/json' \
    -d '{"username":"admin","password":"admin123"}' | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))")
  agent-browser open http://127.0.0.1:18062/admin/login
  agent-browser eval "localStorage.setItem('cjxt_token','$TOKEN')"
  agent-browser open http://127.0.0.1:18062/admin   # WS 重连恢复会话
  ```

- **页面重新渲染后 ref 会失效**：snapshot 的 `@eN` 在页面变更后失效，需 re-snapshot。`open` 后先 `wait --text "..."` 等 WS 渲染完成再取 ref。

### 中文渲染为方框（tofu）—— 根因已修复

**根因**：Chrome/Chromium 用的 fontconfig（2.18，版本戳 `0x2011001`）检测到 `/var/cache/fontconfig` 里的缓存是**更新版 fontconfig（2.19+，版本戳 `0x2012001`）**生成的，于是**拒绝重新生成/读取**缓存，导致系统中文字体不被加载 → 中文渲染成方框。字体文件本身完好。

**修复**（需在宿主机 root 权限执行一次）：
```bash
sudo rm -rf /var/cache/fontconfig/*.cache-*
sudo fc-cache -f
```
清空重建后，`Chrome/Chromium` **完全重启**（`close --all` + `pkill -9 -f chrome-151`）即可正常渲染中文（`Fontconfig warning` 消失）。

排查要点：
- 页面 DOM `innerText` 中文始终正常，只有截图方框 → 是渲染引擎字体加载问题，非页面 bug。
- `fc-list :lang=zh` 能列出字体、`fc-match` 能命中，但渲染仍方框 → 查 fontconfig 缓存版本是否不匹配（`Fontconfig warning: ... newer version`）。
- `@font-face` 直接 `file://` 加载字体可正常渲染中文（绕过 fontconfig 缓存问题）。
- agent-browser 的 Chromium 启动时缓存字体列表，修缓存后需**完全重启浏览器**才生效。

### 其他

- 截图目录要用可写路径（`$HOME` 只读），存到 Workspace 下，如 `/home/ystyle/Projects/Cangjie/.qa-shots/`。`/tmp` 在本环境也可能跨调用不可见。
- 沙箱里 `sudo` 无法提权（no_new_privs），改密码/装系统包需用户在宿主机自行操作或提权工具。
