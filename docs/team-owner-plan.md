# 迭代 6：团队所有者（owner 自助）实施方案

> 依据：`docs/user-portal-design.md` §7.4 路线 A。分支：`feat/team-owner`（基于 master `7e08a06`）。
> 范围：**完整路线 A**，逐条满足 §7.4 的五条约束。
> 验证：**三种**——① 仓颉单元测试（含 handler 级真实 HTTP 测试与页面渲染测试）；② 界面集成测试（真实浏览器操作门户）；③ 生产/演示实例上实际使用。

## 0. 现状侦察结论（动工前已核实）

| 事实 | 位置 | 对方案的影响 |
|---|---|---|
| `TeamDoc` 只有 `permission`（read/write/overwrite），**无 `ownerId`** | `src/store/admin_data.cj:29` | 需新增字段（bstorm 反序列化缺键走字段默认值 → 存量团队 ownerId=0，安全） |
| `TeamMemberDoc` 只有 `teamId`/`userId`，**无角色** | `admin_data.cj:61` | owner 身份不放成员表，改放 `TeamDoc.ownerId`（单一来源，避免两处不一致） |
| 团队管理**没有 HTTP API**，只有 cjxt 组件直接调 store | `server.cj` 无 teams 路由；`ui/admin/teams_page.cj:368` | 「服务端守卫」的落点是**门户页 action**（action 在服务端 cjxt WS handler 内执行）+ 新增 HTTP API 亦走同一裁决函数 |
| 门户 action 的身份来自**服务端注入的会话上下文** | `ui/state.cj:59 userSession(ctx)`（`ctx.getContext().get("uid")`） | 客户端无法伪造 uid → 守卫建在这上面即可满足「服务端守卫」 |
| 审计已有 `LogKind.Admin` + `uiAudit`/`uiAuditAs` | `ui/state.cj`、`admin_data.cj:439` | owner 操作写 `AddLog`（actor = owner），复用现成能力 |
| `OrgDoc.ownerId` 是死字段（建组织时写 0，无人读） | `admin_data.cj:21` | 本期**保留不动**（与 owner 自助无关，删除属另一笔改动，避免混入风险） |
| `checkPublishPermission` 以**团队**为权限单元 | `publish_service.cj` | **不改动**（§7.4 明确要求），owner 自助只影响「谁能改团队成员」 |
| 已落地的 `effectivePermission`：admin=3 > publisher=2 > 团队权限 | `publish_service.cj` | owner ≠ 自动 write（见约束 4）：不给 owner 任何隐式发布权 |

## 1. 五条约束 → 落地设计

### 约束 1：服务端守卫（UI 隐藏不算安全）

- 新增纯函数 `isTeamOwner(adminData, uid, teamId): Bool`：`TeamDoc.ownerId == uid && uid > 0 && team 未删`。
- 新增**统一裁决函数** `canManageTeam(adminData, user, teamId): TeamManageVerdict`：
  - `isAdmin` → 允许（**管理员永远是超集**，不被 owner 削弱）；
  - `isTeamOwner` 且团队 `selfService == true` → 允许；
  - 否则拒绝（含「是 owner 但 selfService 关」）。
- 门户页每个 owner 自助 action 的**第一件事**就是调它，拒绝即返回并写审计（`status=failed`）。
- 同时新增 HTTP API（`/api/user/me/teams/:id/members` 等），走**同一个** `canManageTeam` —— 避免两套口径。

### 约束 2：明确下放边界（selfService 默认关）

- `TeamDoc.selfService: Bool = false`：**默认关**，域名 owner 也不能自助，必须管理员在 `/admin/teams` 显式开启。
- 管理员创建/编辑团队时可切换 `selfService`（管理端表单加开关）；owner 自己**不能**开自己的开关（否则等于自授权，边界失效）。
- 拒绝对应明确文案：`自助未开启，请联系管理员`（与「不是 owner」区分，便于排障）。

### 约束 3：生命周期

- `transferTeamOwner(teamId, newOwnerId, actorId, now)`：
  - 新 owner 必须是**该团队成员**（否则「有管理权但无发布权」，与约束 4 呼应）；
  - 自动把新 owner 写入 `TeamMember`（若尚不是成员）；
  - 旧 owner 保留成员身份（转让 ≠ 移除）；
  - 转让仅 admin 或**当前 owner**（且 selfService 开）可发起。
- 删除/禁用 owner 前处理孤儿：
  - 删除用户时若其为某团队 owner → **阻止**（`409`，提示先转让），与「最后一个管理员不可降级」同构；
  - 团队被软删 → 其 owner 自助入口自然消失（`listTeams` 已过滤软删）。
- `isAdmin` 对所有团队是超集：`canManageTeam` 第一分支即 admin 放行。

### 约束 4：owner ≠ 自动获得 write

- **不**在转让/创建时改 `TeamDoc.permission`，**不**写 `publisherId`；
- 单测明确断言：owner 只加人不改团队权限 → 成员权限仍取自 `TeamDoc.permission`；
- 反向断言：owner 本人若不在团队包/组织关联内，`effectivePermission` 仍不因 owner 身份提升。

### 约束 5：入口与审计

- owner 自助入口放**门户** `/me/teams`（`ui/public/user_portal.cj` 的团队区块加「管理成员」按钮，仅 owner 且 selfService 开时可见——但可见性只是体验，真正的门是约束 1 的守卫）。
- `/admin/teams` **保持 admin-only**（不稀释 `requireAdmin` 语义）。
- owner 的每次操作写 `AddLog`（kind=admin，actor=owner）：`add_team_member` / `remove_team_member` /
  `transfer_team_owner` / `update_team_links`，detail 带 `teamId`、`selfService`。

## 2. 改动清单（按依赖顺序）

| # | 文件 | 改动 | 对应约束 |
|---|---|---|---|
| 1 | `src/store/admin_data.cj` | `TeamDoc` 加 `ownerId`/`selfService`；`createTeam` 加参数；新增 `setTeamOwner`/`setTeamSelfService`/`isTeamOwnerAt` | 1,2,3 |
| 2 | `src/server/team_owner_service.cj`（新） | `canManageTeam` 裁决 + 白名单校验（成员必须是存在且启用的用户）+ 孤儿检查 | 1,3,4 |
| 3 | `src/server/admin_teams.cj`（新，`extend AdminService`） | 管理端团队 API：列表/创建(带 selfService)/改/删 + `.../owner` 转让 + 成员读写 | 1,2,3 |
| 4 | `src/server/user_handler.cj` | 门户 API `/api/user/me/teams/:id/members`（GET/POST/DELETE）+ transfer，全部过 `canManageTeam` | 1,5 |
| 5 | `src/server/audit.cj` | owner 操作的 action 常量与 detail 口径 | 5 |
| 6 | `src/ui/public/user_portal.cj` | 团队区块加 owner 管理面板（加/移成员、转让），入口按 owner+selfService 显示 | 5 |
| 7 | `src/ui/admin/teams_page.cj` | 表单加 `selfService` 开关 + owner 显示/设置 | 2,3 |
| 8 | 各 `*_test.cj` | 见下节 | 全部 |

## 3. 验证计划（三种）

### ① 单元测试（必须全绿）

- **纯函数层**：`isTeamOwner` 边界（uid=0 / 团队已删 / 非成员 / owner 本人）、`canManageTeam` 六态
  （admin×selfService、owner×selfService、owner×关、非 owner、未登录、团队不存在）。
- **store 层**：`setTeamOwner` 幂等/不存在；`selfService` 默认值；**存量团队反序列化后 ownerId=0/selfService=false**（兼容性）。
- **handler 层（真实 HTTP，复用 `http_env_test.cj`）**：
  - 门户 API 的**越权用例必须被拒**：非 owner 403、owner 但 selfService 关 403、匿名 401；
  - admin 走同一 API 必须**可以**（超集）；
  - 加人/移人/转让成功后，成员资格与 ownerId 落库正确；
  - 转让给非成员 → 400；转让给不存在用户 → 404；
  - 删除 owner 用户 → 409（先转让）。
- **UI 渲染层**：门户团队区块的 owner 面板可见性三态（owner+开 / owner+关 / 非 owner）；
  管理端表单 `selfService` 开关渲染与提交。
- **回归**：`cjpm test` 全量 1002 例 0 FAILED / 0 ERROR，覆盖率 91.3%（≥90%）。

### ② 界面集成测试（真实浏览器）

用 `agent-browser`（沙箱注意事项见 `cjreg/AGENTS.md`：`AGENT_BROWSER_SOCKET_DIR` 指到可写目录、
注入 `cjxt_token` 恢复登录态、截图存工作区）：

1. 起本机实例（`.smoke/` 数据目录，`CJREG_SEED_DEMO=1`）；
2. 管理员在 `/admin/teams` 建团队 + 勾 selfService + 指定 owner；
3. 以 **owner** 身份打开 `/me/teams` → 面板可见 → 加一个成员 → 列表出现该成员；
4. 关掉 selfService → 面板消失（体验层），且直接调 API 仍被 403（安全层）；
5. owner 转让给另一成员 → ownerId 变化、双方成员身份保留；
6. 全程截图留档。

### ③ 实际使用（生产/演示实例）

在 `~/docker/cjreg`（生产，8066）与 `~/docker/cjreg-demo`（8067）上：

1. 生产建一个演示团队（**不碰既有 470 个包与既有上游**）；
2. 造三个真实用户，分别扮演 **owner / 成员 / 非成员**：
   - owner：门户自助加人 → 成功；
   - 成员：以 owner 授予的发布权实际发一个包 → 成功（证明 owner 加人真的带来了发布能力）；
   - 非成员：尝试自助管理该团队 → 403 被拒（证明越权无效）；
3. 三种角色的结果都从**服务端**核对（API + 审计日志），不只看界面；
4. 收尾清理演示痕迹（团队与演示包），确认生产数据与操作前一致（除审计）。

## 4. 明确不做

- 路线 B（逐成员权限 `TeamMemberDoc.permission`）—— 触发条件未满足，且要改发布主链路。
- 「申请 → 管理员审批」流 —— 本期用 `selfService` 开关表达下放边界即可。
- `OrgDoc.ownerId` 死字段的去留 —— 与本迭代无关，单独决定。
- `checkPublishPermission` 的任何改动 —— §7.4 明确要求不动。


---

## 5. 验证结果（三种，全部实跑）

### ① 单元测试：1002 例全绿

`cjpm test -j 16 --no-progress --parallel 1` → **TOTAL 1002 / PASSED 1002 / FAILED 0 / ERROR 0**
（本迭代新增 66 例：纯函数 31 + handler HTTP 17 + 门户渲染 20 + CLI 3。整体覆盖率 **91.3%**。）

| 层 | 文件 | 例数 | 守住什么 |
|---|---|---|---|
| 纯函数 | `src/server/team_owner_service_test.cj` | 31 | canManageTeam 六态、自助写操作规则、owner 不带来权限、关联→权限串联 |
| handler HTTP | `src/server/team_owner_handler_test.cj` | 17 | ★越权（非 owner / 自助关 / 匿名）、管理员超集、审计留痕 |
| 门户渲染 | `src/ui/public/cov_team_owner_portal_test.cj` | 20 | 入口三态、面板交互，以及**绕过按钮直接调 action 仍被服务端守卫拒绝** |
| CLI | `src/main_test.cj` | 3 | admin delete-user 的返回码与守卫 |

### ② 界面集成测试：真实浏览器（agent-browser）

环境：本机实例（`.smoke/owner-qa`，端口 18088），owner=`brian`。
截图留档：`.qa-shots/owner/01–06-*.png`。

| 步骤 | 结果 |
|---|---|
| owner 打开 `/me` | 团队表格出现「管理成员」按钮 ✅ |
| 点开管理面板 | 成员列表显示 `brian [owner]`、操作列提示「需先转让」✅ |
| 输入 `carl` → 加入团队 | 界面出现 carl；**服务端 API 核对**成员已落库 ✅ |
| 管理员关闭 selfService | 按钮消失、改显「owner·自助未开」；**直连 API 返回 403** + 文案「未开启」✅ |
| 转让所有权 | 确认框渲染；确认后 ownerId=3(carl)，brian 保留成员身份 ✅ |
| 转让后换 brian 打开 | 看不到管理入口（仍能看到团队）；换 carl 打开 → 有入口 ✅ |

### ③ 实际使用：生产实例 + 演示实例，三种角色

生产 `~/docker/cjreg`（8066，470 包真实数据）。为不污染数据，用 `qa-*` 演示对象，验完清理。

| 角色 | 操作 | 结果 |
|---|---|---|
| ① **owner** | 门户自助改关联（团队绑 `qaorg`） | ✅ 200「已更新关联组织（1 个）」 |
| ② **成员** | 发布 `qaorg::qa-demo@1.0.0`（真实 200） | ✅ **HTTP 200，包 id 477 落库**；`/api/user/me/packages` 显示 `isOwner=true` |
| ③ **非成员** | 发布同一组织下的包 | ✅ **HTTP 403** `no permission to publish` |

三者对照证明：owner 自助**真的把发布权授予了成员**，且非成员拿不到 —— 权限链完整生效。
审计留痕（`/api/admin/logs/admin?keyword=team`）：

```
set_team_links   actor=qa-owner  status=ok  detail=via=owner teamId=1 outcome=ok
add_team_member  actor=qa-owner  status=ok  detail=via=owner teamId=1 outcome=ok
create_team      actor=admin     status=ok  detail=id=1 ownerId=5 selfService=true
```

**收尾**：演示团队/组织/包已删除，演示用户用本次新增的 `admin delete-user` 清除；
生产回到基线（470 包 / 4 个原有用户 / 无团队 / 上游不变）。

## 6. 本迭代过程中发现并修掉的缺口

1. **「owner 可改关联」缺失**（③ 阶段发现）：§7.4 要求 owner 可改本队成员**与关联**，
   但初版只做了成员管理；团队-组织/包关联只有 cjxt 组件在写、没有 API ——
   而「加人 = 授予发布权」正由关联范围决定（`effectivePermission` 按关联命中给权限）。
   已补 `GET|PUT .../teams/:id/links`（管理端 + 门户各一套，共用 `canManageTeam`）与面板 UI。
2. **没有可脚本化的用户删除**：管理端只有创建/改角色，删除用户只有 UI 路径。
   已补 `cjreg admin delete-user`，并带上「团队 owner 需先转让」「最后一个管理员不可删」两道守卫。

## 7. 与设计的差异（有意为之）

- `TeamMemberDoc` **未加 `role` 字段**：owner 身份只放 `TeamDoc.ownerId`（单一来源），
  避免「成员表说是 owner、团队表说不是」的两处不一致。
- 额外加了 `selfService` 开关（§7.4 只写了「如需收敛，加开关」）：
  默认关意味着**不开就不下放**，比默认开放更安全。
- `OrgDoc.ownerId` 死字段**保留未动**：与本迭代无关，单独决定。
