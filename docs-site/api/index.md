# API 一览

## 官方协议端点（cjpm 使用）

| 端点 | 方法 | 鉴权 | 说明 |
|---|---|---|---|
| `/pkg/:name?organization=` | POST | 发布 Token | 发布（官方二进制格式） |
| `/pkg/:name/:version?organization=` | GET | 默认公开；`require_auth` 时需 Token + read | 下载制品（本地未命中回源上游） |
| `/index/:mo/:du/:name?organization=` | GET | 同上 | NDJSON 索引 |
| `/api/health` | GET | 公开 | 健康检查（自有端点，非官方协议） |

## 管理 API（`/api/admin/*`）

| 端点 | 方法 | 说明 |
|---|---|---|
| `/api/admin/login` | POST | 登录 → `{user, token, expiresAt}` |
| `/api/admin/logout` | POST | 注销会话 |
| `/api/admin/me` | GET | 当前用户（含发布 Token） |
| `/api/admin/users` | GET / POST | 用户列表 / 创建用户（`{username,password,isAdmin?,email?}`） |
| `/api/admin/users/:id/admin` | PUT | 提升/取消管理员（`{isAdmin}`；最后一个启用管理员 → 409） |
| `/api/admin/upstreams` | GET / POST | 上游列表 / 新增 |
| `/api/admin/upstreams/:id` | DELETE | 删除上游（官方仓受保护） |
| `/api/admin/upstreams/:id/test` | POST | 上游连通性测试（`name`/`organization` 可选；返回状态码/耗时/包名样本/中文摘要） |
| `/api/admin/resolve` | GET | 多仓解析诊断（`name` / `organization` / `require` / `strict`） |
| `/api/admin/publish-plans/analyze` | POST | 依赖拓扑 + 四分类 |
| `/api/admin/publish-plans/execute` | POST | 按序推送到目标仓（`target_url` / `target_token`） |
| `/api/admin/logs/:kind` | GET | 审计日志查询（`kind` = `publish`/`admin`/`auth`/`all`；`keyword`/`status`/`from`/`to`/`offset`/`limit`） |
| `/api/admin/logs/clean` | POST | 清理审计日志（`{kind?, before?}`，返回 `{"deleted":N}`） |
| `/api/admin/packages` | GET | 版本列表（`organization`/`name`/`includeDeleted`/`page`/`size`；含 `id`/`sha256`/`deletedAt`） |
| `/api/admin/packages/:id` | DELETE | **软删除**该版本（索引/下载/公开 API 立即不可见，制品保留，可恢复） |
| `/api/admin/packages/:id/restore` | PUT | **恢复**（校验制品仍在：本地 blob 或上游可回源；丢失则 409） |
| `/api/admin/packages/:id/hard` | DELETE | **硬删除**（需先软删，否则 409；删除记录 + 制品文件，不可恢复） |

Header：`Authorization: Bearer <会话 Token>`；审计日志字段见 [审计日志](/guide/audit)。

## 用户 API（`/api/user/*`，任意登录用户）

| 端点 | 方法 | 说明 |
|---|---|---|
| `/api/user/me` | GET | 当前用户 + 掩码 Token + 权限模式与提示 |
| `/api/user/me/publish-token` | POST | 重置自己的发布 Token（旧 Token 立即失效） |
| `/api/user/me/packages` | GET | 我发布过版本的包（`page`/`size`/`q`，含 owner 标记） |
| `/api/user/me/teams` | GET | 我所属团队 + 权限 + 关联组织/包 |

## 公开只读 API（C1–C5）

| 端点 | 方法 | 鉴权 | 说明 |
|---|---|---|---|
| `/api/stats` | GET | `require_auth=false` 时公开；`true` 时需 Token | 包/版本/下载/组织/团队/用户数、存储字节、服务端版本与运行时长 |
| `/api/packages` | GET | 同上 | 包列表：`q`（支持 `org::name`）、`organization`、`category`（逗号 OR）、`sort`、`page`/`size` |
| `/api/packages/:name` | GET | 同上 + 包级 read（私有仓） | 包详情：全部版本 + 聚合 + README（`?organization=`） |
| `/api/packages/:name/:version` | GET | 同上 | 版本详情：meta 全字段 + `sha256` + 制品字节 + 下载数 + 发布者 |
| `/api/organizations` | GET | 同上 | 组织列表（含包/版本计数；有包但未登记的组织也会出现，`id=0`） |

软删版本对所有公开端点不可见；私有仓下未登录 401、越权包 403。
字段与响应示例见 [公开只读 API](/guide/public-api)。

## 约定

- 统一错误响应体：`{"error": "<message>"}`；
- 返回码：`200` 成功 / `400` 参数或格式错误 / `401` 未认证 / `403` 无权限 / `404` 不存在 / `409` 冲突；
- 发布 Token 为**裸 token**（兼容 `Bearer <token>`），管理/用户 API 用 `Bearer <会话 Token>`。

## 规划中

组织 CRUD REST 端点、上游连通性测试端点等，见仓库 `docs/gap-analysis.md`。
