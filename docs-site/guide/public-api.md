# 公开只读 API

供门户、第三方工具与监控使用的只读端点，数据全部来自**本地库**（不触发回源）。
语义对齐官方仓 `public.go`，字段按 cjreg 的实际存储裁剪。

## 端点

| 端点 | 说明 |
|---|---|
| `GET /api/stats` | 包/版本/下载/组织/团队/用户数、存储字节、服务端版本、启动时间与运行时长（组织数与 `/api/organizations` 同口径） |
| `GET /api/packages` | 包列表：`q`（名称/描述/组织，支持 `org::name` 语法）、`organization`、`category`（逗号分隔多值 OR）、`sort`（`updated`\|`downloads`\|`name`）、`page`/`size`（默认 20，上限 100） |
| `GET /api/packages/:name` | 包详情：全部版本 + 聚合（版本数/最新版本/总下载）+ 最新版本 README（`?organization=`） |
| `GET /api/packages/:name/:version` | 版本详情：meta 全字段 + `sha256` + 制品字节 + 下载数 + 发布者 + 时间 |
| `GET /api/organizations` | 组织列表（含每个组织的包/版本计数） |

```bash
# 统计
curl -s http://127.0.0.1:8060/api/stats

# 搜索：org::name 语法 + 分类 OR + 分页
curl -s "http://127.0.0.1:8060/api/packages?q=test::demo&page=1&size=20"
curl -s "http://127.0.0.1:8060/api/packages?category=cli,web&sort=downloads"

# 包详情 / 版本详情（organization 参数指定组织）
curl -s "http://127.0.0.1:8060/api/packages/demo?organization=test"
curl -s "http://127.0.0.1:8060/api/packages/demo/1.0.0?organization=test"

# 组织列表
curl -s http://127.0.0.1:8060/api/organizations
```

## 鉴权与可见性

| 配置 | `/api/stats`、`/api/organizations` | `/api/packages*` |
|---|---|---|
| `require_auth = false`（默认，内部开放仓） | 公开 | 公开 |
| `require_auth = true`（私有仓） | 需有效 Token；组织内无可读包时不下发该组织 | 需有效 Token + 该包 read 权限（403）；未登录 401 |

读权限裁决与下载/索引**同一函数**：管理员恒可见；owner（首个发布者）与团队授权
（组织级或包级 read 及以上）可见。私有仓示例：普通用户只看到自己发布的包，
查询他人的包返回 403（裁决先于存在性判断，不泄露包是否存在）。

**软删版本对所有公开端点不可见**：不进列表、不进包详情，版本详情返回 404；
某包全部版本被软删后该包从 `/api/packages` 消失。

## 响应示例

```json
// GET /api/stats
{"packages":6,"versions":6,"downloads":9,"organizations":1,"teams":0,"users":1,
 "storageBytes":2372,"serverVersion":"0.1.0","startedAt":1789194400000,"uptimeSeconds":612}

// GET /api/packages?q=test::app
{"total":1,"page":1,"size":20,"items":[
  {"organization":"test","name":"app","fullName":"test::app","versionCount":1,
   "latestVersion":"1.0.0","description":"Test application","downloads":0,
   "updatedAt":1789194408339,"categories":[],"license":[]}]}

// GET /api/organizations
{"total":1,"items":[{"id":0,"name":"test","displayName":"","description":"",
  "isDefault":false,"packageCount":6,"versionCount":6}]}
```

错误响应统一 `{"error":"…"}`；状态码 `401`（私有仓未带 Token）/ `403`（无 read 权限）/ `404`（包或版本不存在）。

> 组织列表里 `id=0` 表示该组织**有包但未在组织表中登记**（发布不要求先建组织）——
> 在管理后台「组织管理」里创建同名组织后即会带上显示名与默认标记。
