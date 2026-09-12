# 公开只读 API（C1–C5）

供门户、第三方工具与监控使用的**只读**端点，数据来自本地库（不触发回源），
与官方 `public.go` 的语义对齐、字段按 cjreg 的实际存储裁剪。

## 1. 端点一览

| 端点 | 对应 | 说明 |
|---|---|---|
| `GET /api/stats` | C1 | 包/版本/下载/组织/团队/用户数、存储字节、服务端版本、启动时间与运行时长（组织数与 `/api/organizations` 同口径：已登记 ∪ 有包） |
| `GET /api/packages` | C2 | 包列表：分页 + 搜索 + `org::name` 语法 + 分类 OR + 排序 |
| `GET /api/packages/:name` | C3 | 包详情：全部版本 + 聚合（版本数、最新版本、总下载）+ 最新版本 README（`?organization=`） |
| `GET /api/packages/:name/:version` | C4 | 版本详情：meta 全字段 + `sha256` + 制品字节 + 下载数 + 发布者 + 时间 |
| `GET /api/organizations` | C5 | 组织列表（含各组织的包/版本计数） |

## 2. 鉴权与可见性

| 配置 | `/api/stats`、`/api/organizations` | `/api/packages*` |
|---|---|---|
| `require_auth = false`（默认，内部开放仓） | 公开 | 公开 |
| `require_auth = true`（私有仓） | 需有效 Token；组织内无可读包时不下发该组织 | 需有效 Token + 该包 read 权限（403）；未登录 401 |

读权限裁决与下载/索引**同一函数**（`checkReadPermission`）：管理员恒可见，
owner（首个发布者）/团队授权（组织级或包级 read 及以上）可见；`require_auth=false` 时不裁决。

**软删版本对所有公开端点不可见**：`deletedAt != 0` 的版本不进列表、不进包详情、版本详情返回 404；
某包全部版本被软删后，该包从 `/api/packages` 消失。

## 3. 查询参数（C2）

| 参数 | 说明 |
|---|---|
| `q` | 关键字：名称/描述/组织子串；支持 `org::name` 语法（`test::demo`、`test::`、`::demo`） |
| `organization` | 组织过滤（与 `q` 的 `org::` 前缀取交集，冲突时结果为空） |
| `category` | 分类过滤，逗号分隔多值 **OR**（命中任一分即入选） |
| `sort` | `updated`（默认，最近更新在前）\| `downloads` \| `name` |
| `page` / `size` | 分页（`page` 从 1 起；`size` 默认 20、上限 100；越界页返回空 `items`，`total` 仍为命中总数） |

## 4. 响应示例

```json
// GET /api/stats
{"packages":6,"versions":6,"downloads":3,"organizations":1,"teams":0,"users":1,
 "storageBytes":20480,"serverVersion":"0.1.0","startedAt":1789190600000,"uptimeSeconds":612}

// GET /api/packages?q=test::app
{"total":1,"page":1,"size":20,"items":[
  {"organization":"test","name":"app","fullName":"test::app","versionCount":1,
   "latestVersion":"1.0.0","description":"…","downloads":0,"updatedAt":1789190637000,
   "categories":["…"],"license":["MIT"]}]}

// GET /api/packages/app/1.0.0?organization=test
{"version":"1.0.0","cjcVersion":"1.1.3","description":"…","artifactType":"src","executable":false,
 "authors":["…"],"repository":"","homepage":"","documentation":"","tag":[],"category":["…"],
 "license":["MIT"],"sha256":"…","tarballSize":1061,"downloads":0,"publisherName":"admin",
 "createdAt":1789190637000,"updatedAt":1789190637000}

// GET /api/organizations
{"total":1,"items":[{"id":1,"name":"test","displayName":"测试组织","description":"",
  "isDefault":true,"packageCount":6,"versionCount":6}]}
```

错误响应统一 `{"error":"…"}`；对应状态码 `401`（私有仓未带 Token）/ `403`（无 read 权限）/ `404`（包或版本不存在）。

## 5. 实现位置

| 层 | 文件 | 说明 |
|---|---|---|
| 读模型 + JSON | `src/server/public_service.cj` | 纯逻辑（不依赖 HTTP）：聚合、过滤、排序、分页、可见性、转义 |
| HTTP handler | `src/server/public_handler.cj` | 参数解析、鉴权、状态码；路由注册在 `src/server/server.cj` |
| 单元测试 | `src/server/public_service_test.cj` | 9 组用例：`org::` 语法、分页窗口、过滤排序、软删隐藏、统计、版本排序/取最新、组织计数、私有模式可见性、JSON 形状与转义 |
| 集成测试 | `tests/e2e.sh` 第 6 步 | 双仓现场发布 6 包后校验 5 个端点的真实响应 |

## 6. 验证记录

- `cjpm test --filter 'testSplitOrgQuery|…|testPublicJsonShapes'`：公开 API 9 组用例全绿（含软删隐藏与私有模式可见性）
- `tests/e2e.sh` 第 6 步（双仓 e2e）：
  - A 仓 `/api/stats`：6 包 / 6 版本 / 存储字节 > 0、`serverVersion` 与 `startedAt` 存在
  - A 仓 `/api/packages`：`total >= 6`，`test::app`、`test::mathUtils` 在列，聚合字段（`versionCount`/`latestVersion`/`license`）正确
  - `q=test::app` → 1 条；`organization=test&page=2&size=2&sort=name` → 2 条且 `page=2`
  - `/api/packages/app?organization=test` → 版本数与 `latestVersion=1.0.0`、`sha256`、`publisherName=admin`
  - `/api/packages/app/1.0.0` → `sha256`/`tarballSize`/`cjcVersion` 齐备；`9.9.9` → 404
  - `/api/organizations` → `test` 组织 `packageCount >= 6`
  - B 仓（A→B 推送后）公开列表同样可用
- 手工验证（`require_auth=true` + `permission_mode=team` 私有实例，`http://127.0.0.1:8071`）：

  | 请求 | 未带 Token | admin Token | bob Token（仅发布过 `test::strUtils`） |
  |---|---|---|---|
  | `/api/stats` | 401 | 200 | — |
  | `/api/packages` | 401 | 200（`test::netUtils`、`test::strUtils`） | 200（仅 `test::strUtils`） |
  | `/api/organizations` | 401 | 200 | 200（仅 `test`） |
  | `/api/packages/strUtils?organization=test` | 401 | 200 | 200 |
  | `/api/packages/netUtils?organization=test`（admin 发布） | 401 | 200 | **403** |

  即：私有仓下未登录一律 401；非管理员只见自己被授权（owner/团队 read）的包与组织；越权包详情 403（权限裁决先于存在性判断，不泄露包是否存在）。
