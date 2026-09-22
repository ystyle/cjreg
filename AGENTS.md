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
- ⚠️ **宿主机 glibc 升级后要先拉基础镜像**：基础镜像是 `archlinux:latest`（本地那份可能很旧），二进制动态依赖
  `libm.so.6`，宿主 glibc 一升级就会报 `/app/cjreg: /usr/lib/libm.so.6: version 'GLIBC_2.44' not found`
  → 容器**反复重启**、healthcheck 永远不 healthy。处置：`docker pull archlinux:latest` 后重新
  `docker compose build && up -d`（2026-09-22 实测：宿主 glibc 2.44、本地基础镜像还是 2.43，拉了新的才起来）。
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

## 后台：包管理（左主右子）/ 单版本详情 / 上游重拉

**包管理页是「左主（包）右子（版本）」主子表**：左栏是聚合行（一个 `org::name` 一行，显示版本数 /
最新版本 / 下载合计），选中一行右栏即时列出该包的版本；版本表字段：ID / 版本 / **来源**（本地发布 or
`回源 · <上游名>`）/ **大小** / **sha256**（缩写）/ **时间**（本地发布=发布时刻，回源=收录时刻）/
下载 / 状态 / 操作（详情 · 重拉 · 软删 | 恢复 · 硬删）。

- **重拉**只对**回源镜像**版本出现（`upstreamId != 0`）；本地发布的版本本地才是权威，后端直接 409。
- **单版本详情**仍是弹窗（README 正文长，塞进右栏会把版本表挤没）：全字段 + SHA256 全量 + 来源上游 +
  **README 全文**（Markdown 渲染，正文区独立滚动）。
- 两者都有管理 API（给脚本/CI 用）：
  - `GET  /api/admin/packages/:id` → 详情 JSON（含 `readme`/`readmeLength`/`upstreamName`/`artifactPresent`）
  - `POST /api/admin/packages/:id/refetch[?force=1]` → 重拉并覆盖本地缓存

### 列表页的「输入即过滤」写法（改这些页面前必读）

管理端所有列表的搜索/筛选都是**信号派生**，不是动作触发（`src/ui/list_binding.cj` 的 `bindRows` /
`bindPaged` / `bindVisible`）：cjxt 的 `Table.data()` 只接受 `Signal<ArrayList<T>>`，过滤结果只能由信号
承载。

- **输入框/下拉只 bind，绝不挂 `on("input")` 动作**：前端对同一元素是**先 action 后 bind**
  （`public/js/cangjie-ui.js:333` 立即发 action，`:490` 的 bind 有 300ms 防抖），那个 action 立刻换来一次
  补丁，而补丁应用完会无条件清掉焦点元素的 `bindDirty` 守卫（`:710`），随后 `applyAttrs` 把输入框的值
  退回服务端旧值（`:309`）——300ms 后才发出的 bind 读到的是**空串**，写回信号等于没搜。
  实测症状：**浏览器里打字完全没反应**（单测里直接 set 信号是好的，所以单测抓不到）。
- **过滤条件变化时不要回写页码信号**：cjxt `Pagination` 的 `total` 是**创建时的快照**，页码一变它自己就
  变脏，同一批补丁里旧实例会重渲一次、且排在页面补丁**之后** → 把刚算好的「共 N 条」顶回上一次的值。
  页越界交给本地钳制（服务端分页退到最后一页重查；`bindPaged` 只影响切片，`Pagination.render` 会把
  显示页夹进有效范围）。
- **空态提示与表格并存，槽位固定**（`layout.cj` 的 `listBody`）：不要按"有没有行"在提示与表格之间换
  节点类型——同批补丁里父（页面）与子（表格）都会变脏，子补丁后应用，会把中文提示顶成空表格的
  "No Data"。表格自带的空文案用 `Table.emptyText("暂无数据")`。
- 动作只写信号，**页面上必须有人读它**，否则组件不会变脏、服务端不下发补丁（"点一下没反应"）；
  单选类状态（如"当前选中的包"）要做成**信号**并在渲染里读，不能留普通字段。
- **表格里的浮层（单元格内下拉菜单）会被 EP 的表格容器裁掉/压住**，三处都要放开，缺一不可：
  ① `.cell`（`overflow:hidden`，面板的包含块 `div.el-dropdown` 在它里面）；
  ② `.el-table__body-wrapper` / `.el-table__inner-wrapper`（`position:relative` + `overflow:hidden`，在面板包含块链上）；
  ③ `td.el-table__cell` 的 `z-index:1`（给每个 td 建了层叠上下文，**后面几行会把面板盖住**）。
  做法见 `src/admin.css` 的 `.version-table-wrap` 一组规则（用**属性选择器**匹配 EP 类名，
  因为本仓 CSS 管线会给每个 `.class` 加哈希后缀；与 EP 同分的选择器靠 `!important` 压过）。
  表格自带的 `Table.emptyText("暂无数据")` 同属这类"EP 默认样式不适用"的收口。
- store 不是信号：写库后 `bump()` 一个 `dataVersion` 信号让派生重算（`refreshXxx()` 现在就干这个）。
- 派生绑定必须 `onMount` 重建、`onUnmount` 释放：页面实例是路由注册期创建、跨请求复用的。
- 回归测试：`list_binding_test.cj`、`pages_manage_render_test.cj`、`pages_users_render_test.cj`、
  `pages_plan_render_test.cj`、`logs_search_test.cj`、`team_dialog_search_test.cj`
  （含"输入框没有挂 input 动作"、"改条件不动页码且条数跟着变"、"空态提示与表格并存"、
  "选中/开关会标脏"这几条结构性断言，它们守的正是单测最容易漏掉的补丁行为）。

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
