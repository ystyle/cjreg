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
2. **我的包**：`Table<PackageDoc>` 按 `publisherId == me` 过滤（= 我发布过版本的包，含协作发版；标注其中我是 **owner**（最早一条版本记录的发布者）的包）；分页/搜索/详情跳转复用 `Table<PackageDoc>` 泛型模式；空态引导"如何发布第一个包"
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

- 组织/团队自助加入与**团队所有者（team owner）**（沿用管理员统配——决策与 backlog 见 §7）
- 用户自助注册（发布者由管理员创建——现状保留）
- overwrite 覆盖发布 API（已排期后续）
- 逐成员权限（per-member permission）：团队权限仍为**团队级单一字段**

## 6. 与已落地改动的关系

- 发布 401/403 校验已在服务端（上轮）；门户只是让用户**看得到** Token 与"我能发什么"
- `CJREG_PERMISSION_MODE=team` 时门户第 3 区块提示"需 write 权限"；open 时提示"内部开放模式"

## 7. 团队管理：决策与 backlog（owner / 多管理员）

### 7.1 事实基线

| 项 | 现状 | 位置 |
|---|---|---|
| 团队所有者 | **无**（`TeamDoc` 只有 `permission`；`TeamMemberDoc` 只有 `(teamId, userId)`） | `src/store/admin_data.cj` |
| 权限粒度 | **团队级单一字段**（read/write/overwrite），全队成员同权 | `src/store/admin_data.cj`、`src/server/publish_service.cj` |
| 谁可管团队 | 管理员：UI `isAdminSession` / API `requireAdmin` | `src/ui/pages_org.cj`、`src/server/admin_handler.cj` |
| 对齐基线 cjrepo | **cjrepo 无 owner 概念**，团队 = `Team{...permission}` + 扁平 `TeamMember` | `docs/design.md` §5.4、`docs/ui-gap-report.md` |
| 遗留死字段 | `OrgDoc.ownerId` 存在但创建时硬编码 0，无人使用 | `src/store/admin_data.cj`、`src/ui/pages_org.cj` |
| 权限模式 | 默认 `open`，仅 `team` 模式做关联 + 权限校验 | `src/server/server.cj` |

### 7.2 决策（本期）

1. 团队管理**保持 admin-only**，不引入 team owner —— 对齐 cjrepo，零模型改动。
2. 不引入逐成员权限，团队权限继续为**团队级单一字段**。
3. 缓解「管理员瓶颈」用**多管理员**（`isAdmin` 布尔已支持），**不用 owner 替代**；两者语义不同：多管理员 = 多人全权（含删用户/改上游/执行发布计划/覆盖发布豁免），owner = 团队粒度自治。
4. 优先级：多管理员约束补丁 → team 模式权限链路（A1 `publisherId` 双路径 + read 校验）→ 路线 A owner → 按需评估路线 B。

### 7.3 多管理员约束（必守）

多管理员不是新功能，是把既有能力的口径与安全边界补齐：

- **始终保留 ≥1 个启用状态的管理员**：禁止禁用或降级「最后一个启用管理员」（`isAdminSession` 要求 `isAdmin && isActive`，否则管理端锁死）。
- **管理员身份变更必须写审计日志**（提升/降级/禁用，含操作者），与建用户/重置 Token 的现有日志口径一致。
- **UI 与 API 口径一致**：创建用户时 `isAdmin` 可指定（API 侧不得再硬编码 `false`）。
- **逃生通道**：`cjreg admin reset-password --username <u> --password <p>`（本地 CLI），语义为**重置口令 + 强制 `isAdmin=true` + `isActive=true`**，用于管理端锁死（管理员被禁用/降级）或口令丢失后的兜底；不创建新用户。

### 7.4 backlog：team owner（路线 A）

**触发条件**（满足其一再做，避免为不存在的问题加权限机器）：
- 团队负责人需要**自行加人/改关联**，而管理员不愿为此发放 `isAdmin` 全权；
- 团队数量增长到管理员成为审批瓶颈。

**范围**：`TeamDoc.ownerId`（可选 `TeamMemberDoc.role = owner|member`）；owner 仅可改**本队**成员与关联；`checkPublishPermission` **不改动**（团队仍是权限单元）。

**必须同时满足的约束**：
1. **服务端守卫**：变更端点 `requireUser + isTeamOwner(uid, teamId)`，UI 隐藏不算安全。
2. **明确下放边界**：owner 能加人 = 能把发布权授予任意人（团队已绑定组织/包）；如需收敛，加 `TeamDoc.selfService` 开关或「申请 → 管理员审批」，默认关。
3. **生命周期**：支持转让 owner；删除/禁用 owner 前处理孤儿团队；`isAdmin` 永远对所有团队是**超集**，不被 owner 削弱；`OrgDoc.ownerId` 死字段的去留同期决定。
4. **owner 与成员关系**：创建/转让时自动写入 `TeamMember`（避免「有管理权但无发布权」）；**owner ≠ 自动获得 write**（防隐式提权）。
5. **入口与审计**：owner 管理界面放门户 `/me/teams`，`/admin/teams` 保持 admin-only（不稀释 `requireAdmin` 语义）；owner 操作写 `AddLog`（actor = owner）。

### 7.5 路线 B（逐成员权限）——保留条件

- **表达**：`TeamMemberDoc.permission`，团队 `permission` 降级为「上限」，成员有效权限 = `min(成员权限, 团队上限)`。
- **成本**：改 `checkPublishPermission`、下载/索引的 read 检查、团队 UI 冲突提示，发布主链路回归面大。
- **触发条件**：同一团队内确实需要并存 read 与 overwrite 的人，且不愿为此拆分为多个团队。
