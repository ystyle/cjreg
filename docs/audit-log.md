# 审计日志

cjreg 的审计日志记录**谁、何时、从哪个 IP、用什么客户端**做了**什么**、结果如何。
覆盖发布、认证、管理三类操作，并提供管理端查询/清理端点与后台页面。

## 1. 数据模型

```cangjie
LogDoc {
  id: Int64            // 自增（实例内计数器 + 启动时从库内恢复最大值）
  kind: String         // publish | admin | auth
  actorId: Int64       // 操作者用户 id（匿名/失败前置校验时 0）
  actorName: String    // 操作者用户名（匿名时为空；登录失败时为「尝试的用户名」）
  action: String       // 操作动词（下划线风格，见下表）
  status: String       // ok | failed
  target: String       // 操作对象（org/name@version、用户名、团队名、all …）
  detail: String       // 补充信息（包大小、isAdmin、批量条数…）
  error: String        // 失败原因（仅 failed 时非空）
  ipAddr: String       // 客户端 IP
  userAgent: String    // User-Agent（截断 200 字节）
  createdAt: Int64     // 毫秒时间戳（UTC）
}
```

存储在同一 badger/bstorm 库（`log` 集合），与业务数据同生命周期。
`AdminDataStore` 是**单实例**：`main.cj` 创建后同时注入 HTTP handler（`buildServer(adminData:)`）与 cjxt 状态，
避免两个实例各自递增 id 造成相互覆盖。

## 2. 记录范围与动作词表

| kind | 触发点 | action | 说明 |
|---|---|---|---|
| `publish` | `POST /pkg/:name` | `publish` | 成功记 `detail=size=<字节>`；失败记 401/403/400/409 各自原因 |
| `auth` | `POST /api/admin/login` | `login` | 成功记 `detail=isAdmin=…`；失败（含缺字段）记 `error`，操作者为尝试的用户名 |
| `auth` | `POST /api/admin/logout` | `logout` | 仅登录态下记录 |
| `admin` | `POST /api/admin/users` | `create_user` | 冲突记 `failed` + `user already exists` |
| `admin` | `PUT /api/admin/users/:id/admin` | `grant_admin` / `revoke_admin` | 触碰「最后一个启用管理员」保护时记 `failed` |
| `admin` | `POST /api/admin/upstreams` · `DELETE /api/admin/upstreams/:id` | `add_upstream` / `delete_upstream` | 目标为上游名，detail 记 url/priority；官方仓删除保护记 `failed` |
| `admin` | `POST /api/admin/publish-plans/execute` | `execute_publish_plan` | target 为目标仓地址，detail 记 `success=N/M roots=… explicitToken=true|false`（**不落 target_token**），有错误时 `error` 记首条 |
| `admin` | `POST /api/admin/logs/clean` | `clean_logs` | 清理动作自身入审计（target = 清理范围） |
| `admin` | 管理端页面操作 | `create_user` `disable_user` `enable_user` `reset_publish_token` `delete_user` `create_org` `update_org` `delete_org` `create_team` `update_team` `delete_team` `set_team_orgs` `add_team_member` `remove_team_member` `add_upstream` … | 见 §5 |

匿名/前置校验失败的请求（无 token、token 无效）：`actorId=0`、`actorName=""`、`status=failed`，**不记录 token 明文**。

## 3. IP 与 User-Agent 提取

```
X-Forwarded-For（取第一段） → X-Real-IP → TCP 对端地址（ctx.ip()，去掉 :port）
User-Agent → 截断 200 字节，缺失为空串
```

TCP 对端形如 `127.0.0.1:38184`，入库前去掉端口（`[::1]:38184` → `::1`；裸 IPv6 `2001:db8::1` 不截断）。

反向代理部署时请确保代理**追加**（而非覆盖）`X-Forwarded-For`，否则首个地址可被客户端伪造。
UI（cjxt WS）侧操作没有 HTTP 请求上下文，`ipAddr` 记为 `admin-ui`、`userAgent` 记为 `cjxt-admin-ui`。

## 4. 查询 / 清理端点

### `GET /api/admin/logs/:kind`

`kind` ∈ `publish` | `admin` | `auth` | `all`（未知值等同 `all`）；需管理员会话 Token。

| 查询参数 | 说明 |
|---|---|
| `keyword` | 命中 操作/对象/操作者/错误/详情 任一字段（子串匹配，空 = 不过滤） |
| `status` | `ok` / `failed`（空 = 不过滤） |
| `from` / `to` | 毫秒时间戳区间（闭区间；0 = 不限） |
| `offset` / `limit` | 分页；`limit` 默认 50、上限 500 |

响应（按时间倒序，`total` 为**命中总数**而非本页条数）：

```json
{
  "total": 11, "offset": 0, "limit": 2,
  "items": [
    {"id": 11, "kind": "auth", "actorId": 1, "actorName": "admin", "action": "login",
     "status": "ok", "target": "admin", "detail": "isAdmin=true", "error": "",
     "ipAddr": "127.0.0.1", "userAgent": "curl/8.5.0", "createdAt": 1789000000000}
  ]
}
```

未带/无效 Token → `401`（`{"error":"not authenticated"}` 或 `missing token`）。

### `POST /api/admin/logs/clean`

body（可省略，省略即清空全部）：`{"kind": "publish|admin|auth|all", "before": <毫秒>}`
— `before` 只删该时间戳**之前**的记录（0 = 不限）。响应 `{"deleted": N}`，并写一条 `clean_logs` 审计。

## 5. 管理端页面

管理后台 → **审计日志**（`/admin/logs`）：

- 工具栏：关键字搜索（即时过滤）、类型选择（全部/发布/管理/认证）、结果选择（全部/成功/失败）、筛选、清理日志；
- 表格列：时间、类型、操作者、操作、对象、结果（标签着色）、IP、User-Agent、错误信息（长内容 tooltip）；
- 分页：`total, prev, pager, next, sizes`（默认 20 条/页）；
- 清理：弹窗内选择范围（全部/仅发布/仅管理/仅认证），确认后显示删除条数；清理动作本身也会出现在「管理」类日志里。

## 6. 验证

- 单元测试：`src/store/admin_data_test.cj`（过滤/排序/分页/按 kind 与 before 清理）、`src/server/audit_test.cj`（目标串、类型解析、JSON 转义、截断）
- 集成测试：`tests/e2e.sh` 第 5 步覆盖「6 次发布登记成功日志（操作者/版本/IP/UA 齐全）→ 非法令牌发布记 failed（匿名 + 原因 + 自定义 UA）→ 登录成功/失败审计 → 关键字过滤 → 分页 total 语义 → 按 kind 清理并验证清理动作入审计 → 未鉴权查询 401」
- 手工验证（agent-browser）：管理端 `/admin/logs` 的表格九列（时间/类型/操作者/操作/对象/结果/IP/UA/错误信息）、
  清空范围弹窗（范围下拉 + 取消/确认）渲染与交互正常；沙箱内 agent-browser 无法向 cjxt 输入框注入 `input` 事件
  （cjxt 表单已知限制），关键字/类型/结果过滤改由 `queryLogs` 单测与 e2e API 断言覆盖

## 7. 已知边界

- UI 写入（管理端页面）无 HTTP 上下文，IP/UA 为来源标记而非真实地址（HTTP API 侧为真实值）；
- 日志无自动轮转/保留期：条数增长靠手动清理（后续可加保留天数配置）；
- 日志写入失败不影响主流程（写入异常不改变响应）。
