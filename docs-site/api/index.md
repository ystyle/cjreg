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
| `/api/admin/resolve` | GET | 多仓解析诊断（`name` / `organization` / `require` / `strict`） |
| `/api/admin/publish-plans/analyze` | POST | 依赖拓扑 + 四分类 |
| `/api/admin/publish-plans/execute` | POST | 按序推送到目标仓（`target_url` / `target_token`） |

Header：`Authorization: Bearer <会话 Token>`。

## 用户 API（`/api/user/*`，任意登录用户）

| 端点 | 方法 | 说明 |
|---|---|---|
| `/api/user/me` | GET | 当前用户 + 掩码 Token + 权限模式与提示 |
| `/api/user/me/publish-token` | POST | 重置自己的发布 Token（旧 Token 立即失效） |
| `/api/user/me/packages` | GET | 我发布过版本的包（`page`/`size`/`q`，含 owner 标记） |
| `/api/user/me/teams` | GET | 我所属团队 + 权限 + 关联组织/包 |

## 约定

- 统一错误响应体：`{"error": "<message>"}`；
- 返回码：`200` 成功 / `400` 参数或格式错误 / `401` 未认证 / `403` 无权限 / `404` 不存在 / `409` 冲突；
- 发布 Token 为**裸 token**（兼容 `Bearer <token>`），管理/用户 API 用 `Bearer <会话 Token>`。

## 规划中

公开只读 API（`/api/stats`、`/api/packages`、`/api/packages/:name`、`/api/organizations`）、
审计日志查询端点（`/api/admin/logs/*`）、上游连通性测试端点等，见仓库 `docs/gap-analysis.md`。
