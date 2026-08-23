# 普通用户门户设计（方案 v1）

> 背景：cjreg 目前只有管理端（requireAdmin）与发布 API；普通用户（有 publish Token 的 cjpm 发布者）没有登录入口、看不到自己的包与 Token。本设计新增「普通用户」角色门户，复用现有用户体系（User + session/publish token + 团队权限模型）与 cjxt 组件（阶段 0-3 已完成），发布链路零改动（403/401 已就绪）。

## 1. 角色与认证

| 角色 | 登录入口 | 权限 |
|---|---|---|
| 管理员 | `/admin/login`（现有） | 一切（含用户/组织/团队/上游/计划管理） |
| 普通用户 | **`/user/login`（新）** | 仅门户功能；发布走 cjpm + Token（服务端 401/403 已兜底） |
| 未登录 | — | 公开页 |

- **复用**：cjxt session token 恢复登录机制（现在只有 `restoreAdminSession`；新增 `restoreUserSession` 等价守卫）；User.token 已在库里（session 与 publish 双类型）
- **守卫**：新增 `requireUser`（登录即可，不要求 isAdmin）；`requireAdmin` 不变

## 2. 页面

### 2.1 `/user/login`（新）
复用登录页组件化后的表单（FormItem + required），与管理员登录共用 AuthService.login；成功 → `/me`。

### 2.2 `/me` 个人门户（新，3 个区块）
1. **我的发布 Token**：Token 展示（只显后 8 位 + 复制按钮）/ 重置按钮（`resetPublishToken`，重置后旧 Token 立即失效——与管理员 Token 对话框一致）；附 `cangjie-repo.toml` 发布配置示例（复制）
2. **我的包**：`Table<PackageDoc>` 按 `publisherId == me` 过滤（分页/搜索/详情跳转），复用 `Table<PackageDoc>` 泛型模式；空态引导"如何发布第一个包"
3. **我的团队与权限**：`Descriptions`/简易表列出我所属团队 → 每团队权限（read/write/overwrite）+ 关联组织/包列表（只读）；发布权限模式（open/team）提示行（"当前为内部开放模式，发布无需团队授权"或"团队模式：需 write 及以上"）

## 3. API（新增，均要求 user session）

| 端点 | 方法 | 说明 |
|---|---|---|
| `/api/user/me` | GET | 当前用户信息（username/email）+ publishToken 掩码 + permissionMode |
| `/api/user/me/publish-token` | POST | 重置发布 Token |
| `/api/user/me/packages` | GET | 我的包列表（page/size/搜索，服务端分页） |
| `/api/user/me/teams` | GET | 我的团队+权限+关联（组织/包） |

管理员 API（`/api/admin/*`）不动；安全：所有 `/api/user/*` 经 user 守卫（session token 校验 + 用户存在/启用）。

## 4. 实现拆解（复用现有组件，工作量中等）

1. **auth_guard**：`requireUser`（登录即可，同 isAdminSession 反查用户存在/启用；管理员同样通过）
2. **页面**（`pages_user.cj`）：LoginPage（表单复用）+ UserPortalPage（3 区块，Table/Descriptions/FormItem 均现成）
3. **user_handler.cj**：4 个端点（复用 userStore/authService/adminData 查询；`packages` 走 pkgStore storm 按 publisherId 过滤）
4. **菜单/导航**：公开导航加"登录/我的"入口；管理端侧栏不变
5. **测试**：requireUser 守卫 3 用例；me/packages/teams handler 3 用例（纯逻辑抽出）；页面渲染沿用 agent-browser 冒烟

## 5. 明确不做（本期）

- 组织/团队自助加入（沿用管理员统配）
- 用户自助注册（发布者由管理员创建——现状保留）
- overwrite 覆盖发布 API（已排期后续）

## 6. 与已落地改动的关系

- 发布 401/403 校验已在服务端（上轮）；门户只是让用户**看得到** Token 与"我能发什么"
- `CJREG_PERMISSION_MODE=team` 时门户第 3 区块提示"需 write 权限"；open 时提示"内部开放模式"
