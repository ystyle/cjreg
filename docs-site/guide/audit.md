# 审计日志

cjreg 记录**谁、何时、从哪个 IP、用什么客户端**做了**什么**、结果如何。覆盖发布、认证、管理三类操作，
并提供管理员查询/清理端点与后台「审计日志」页面。

## 记录什么

| 类型 | 触发操作 | 记录字段要点 |
|---|---|---|
| `publish` | `POST /pkg/:name` 发布 | 操作者、`org/name@version`、包大小、成功/失败原因、IP、User-Agent |
| `auth` | 管理员登录 / 注销 | 成功：用户 id + `isAdmin`；失败：尝试的用户名 + 原因（**不记口令**） |
| `admin` | 用户、组织、团队、上游、包、发布计划推送、日志清理等管理动作 | 操作者、被操作对象、补充信息、失败原因（推送计划含目标仓地址与 `success=N/M`，**不记 `target_token`**） |

字段：`kind`（类型）、`actorId` / `actorName`（操作者）、`action`（动作，下划线风格）、`status`（`ok`/`failed`）、
`target`（操作对象）、`detail`（补充）、`error`（失败原因）、`ipAddr`、`userAgent`、`createdAt`（毫秒时间戳）。

匿名或校验失败的请求记为 `actorId=0`、`actorName=""`、`status=failed`，且**不记录 Token 明文**。

## IP 与 User-Agent

```
X-Forwarded-For（取第一段）→ X-Real-IP → TCP 对端地址
User-Agent → 截断 200 字节；缺失为空串
```

反向代理部署时请让代理**追加** `X-Forwarded-For`，否则首个地址可被客户端伪造。
管理后台页面（cjxt WS）内的操作没有 HTTP 上下文，IP/UA 记为 `admin-ui` / `cjxt-admin-ui`。

## 查询日志

```bash
TOKEN=$(curl -s -X POST http://127.0.0.1:8060/api/admin/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"<口令>"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')

# 最近的发布日志（失败优先看 error 字段）
curl -s "http://127.0.0.1:8060/api/admin/logs/publish?limit=20" \
  -H "Authorization: Bearer $TOKEN"

# 关键字 + 结果 + 时间范围 + 分页
curl -s "http://127.0.0.1:8060/api/admin/logs/all?keyword=demo&status=failed&from=1789000000000&offset=0&limit=50" \
  -H "Authorization: Bearer $TOKEN"
```

`kind` 可取 `publish` / `admin` / `auth` / `all`；`keyword` 命中操作、对象、操作者、错误、详情任一字段；
响应 `{"total":N,"offset":..,"limit":..,"items":[...]}`，其中 `total` 是命中总数（用于分页），条目按时间倒序。

## 清理日志

```bash
# 清空发布日志
curl -s -X POST http://127.0.0.1:8060/api/admin/logs/clean \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"kind":"publish"}'

# 删除某个时间点之前的全部日志
curl -s -X POST http://127.0.0.1:8060/api/admin/logs/clean \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"before":1789000000000}'
```

清理动作本身也会写一条 `clean_logs` 审计（`admin` 类型），删除条数记在 `detail`。

## 管理后台

管理后台 → **审计日志**（`/admin/logs`）：关键字搜索、类型/结果筛选、分页，表格含时间、类型、操作者、操作、
对象、结果、IP、User-Agent、错误信息；「清理日志」弹窗可选清理范围并显示删除条数。

## 说明

- 日志与业务数据同库（bstorm `log` 集合），随数据目录一起备份即可；
- 目前无自动轮转/保留期，条数增长靠手动清理；
- 日志写入失败不影响主流程（不改变业务响应）。
