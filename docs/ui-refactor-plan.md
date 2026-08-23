# cjreg 管理界面组件化重构计划

> 背景：cjreg 的 15 个页面中，控件级（Button/Tag/Input/Select/Switch/Dialog/Empty）复用充分，但组合级组件（Table/Form/Pagination）大量手写：8 个列表为手写 div 表格（`admin-table/tr/td`，约 500+ 行重复样板），所有 Dialog 表单为手写 label 布局（无校验），布局（侧边导航/卡片/统计卡）也全部手写。根因分析见与用户的初审报告。
> 原则：**TDD**（每个 API 先写失败用例）、每阶段独立提交、向后兼容（cjxt 只新增 API 不破坏现有签名）、按 cjxt/cjreg 的 git 分支规范进行。

---

## 阶段 0 — cjxt 能力补齐（前置）

**目标**：扫清 cjreg 无法使用 Table/Form 的三个能力缺口。全部为**新增 API，不修改现有签名**。

### 0.1 TableColumn.render（自定义单元格渲染）

- 位置：`cjxt/src/components/Table.cj`
- 新增字段：`var _render: Option<(HashMap<String, String>, Int64) -> IComponent> = None`
- 新增方法：`public func render(fn: (HashMap<String, String>, Int64) -> IComponent): TableColumn`
- 行为：`buildDefaultCell` 中当 `_render` 为 Some 时，调用 `fn(row, index)` 得到 IComponent 并作为该列 cell 的内容（替代纯文本/formatter 路径）；返回的组件节点（如 Tag/Button/div）由 `expandTree` 正常展开，handler id 走既有路径派生稳定化机制。
- 与 `formatter` 并存：render 优先于 formatter。

### 0.2 Table.onRowClick（行点击回调）

- 位置：`Table.cj`
- 新增字段：`var _onRowClick: Option<(HashMap<String, String>, Int64) -> PatchResult> = None`
- 新增方法：`public func onRowClick(fn: (HashMap<String, String>, Int64) -> PatchResult): Table`
- 行为：`renderRow` 中当设置时给 `<tr>` 绑定 click handler（`{ ctx => fn(row, index) }`）；与 `highlight()`（仅设置 currentRow）并存，互不影响。

### 0.3 FormItem.bindValue（通用取值 getter）

- 位置：`cjxt/src/components/Form.cj`
- 新增方法：`public func bindValue(getter: () -> String): FormItem`（写入既有 `_getValue` 字段）
- 目的：`Signal<Int64>`/`Signal<Bool>` 等非 String 信号也能接入 `FormRule`/`validate()`，调用方用 `{ => signal.get().toString() }` 包装。

### 0.4 测试（TDD，先写失败用例）

- 新增 `cjxt/src/table_test.cj`：
  - `testColumnRenderInsertsComponent`：Table + render 回调返回 Tag/文本组件，`RenderContext.expandTree` 后断言自定义内容出现在对应单元格。
  - `testColumnRenderPriorityOverFormatter`：render 与 formatter 同时设置时 render 生效。
  - `testOnRowClickBindsRowAction`：设置 onRowClick 后展开树中 `<tr>` 带 `data-action-click` 且 handler 可达；未设置时无该属性。
- 新增 `cjxt/src/form_test.cj`：
  - `testFormItemBindValueRequired`：bindValue 返回空 → `validate()` false + errorSet；返回非空 → true。
  - `testFormItemBindValuePattern`：pattern 校验经 bindValue 生效。
- 运行：`cjpm test`（全量）通过；`cjpm build` 通过。

### 0.5 提交（cjxt）

- 分支：`feat/table-cell-render`（含 0.1/0.2），`feat/form-bind-value`（含 0.3），各自 squash merge 回 master（或按功能合并为一个分支两次提交，提交信息注明）。
- 注意：`cjpm` path 依赖会缓存编译产物，cjreg 侧改动前清理 `cjreg/target/release/cjxt/` 缓存。

---

## 阶段 1 — cjreg 管理列表迁移（用户/组织/团队/上游/发布计划）

**目标**：5 个管理列表页从手写 div 表格迁移到 `Table` + `TableColumn.render` + `Pagination`；对应 Dialog 表单迁移到 `Form` + `FormItem`。

### 1.1 UsersPage（`pages_org.cj`）

- 列表：`Table`，列 = ID/用户名/邮箱/角色/状态/操作；角色、状态用 `render` 返回 `Tag`；操作列 `render` 返回按钮组（Token/禁用|启用/删除），数据仍走 `HashMap<String, String>`（id 等字段 `Int64.parse` 转换）。
- 分页：接入 `Pagination`（外置 `currentPage`/`pageSize`/`total` Signal），过滤条件（无）直接分页。
- 表单：新增用户 Dialog → `Form` + `FormItem.label(...)` + `rule(FormRule(required: true, ...))`；`submitCreate` 先 `form.validate()` 再提交（保留 `msg` 反馈）。
- Token/删除确认 Dialog 保持 Dialog + Form（简单内容）。

### 1.2 OrganizationsPage

- 同上：列表 Table + render（默认/普通 Tag、编辑/删除按钮）+ Pagination；新增/编辑 Dialog → Form + 校验（组织名 required）；删除确认保留。

### 1.3 TeamsPage

- 列表 Table + render（权限 Tag、成员/组织/包计数、编辑/组织/包/成员/删除按钮组）+ Pagination。
- 基础表单 Dialog → Form；组织关联 Dialog 的多选 Select、包/成员关联的搜索列表继续使用（包/成员关联列表可保留简易表格或微型 Table）。

### 1.4 UpstreamsPage

- 列表 Table + render（官方/镜像、启用/禁用 Tag、编辑/禁用|启用/删除按钮）+ Pagination。
- 新增/编辑 Dialog → Form + 校验（名称/URL required；优先级/缓存 InputNumber；Token password）。

### 1.5 PublishPlansPage

- 列表 Table + render（状态 Tag、详情/删除按钮）+ Pagination。

### 1.6 测试与验证

- 抽分页/过滤/行数据组装的纯逻辑为顶层函数并加仓颉单测（`src/ui/` 下可测试性：与 cjxt 示例一致，页面类可直接实例化 + `RenderContext.expandTree` 验证结构；简单场景断言渲染输出）。
- `cjpm test` 全量通过；`agent-browser` 冒烟（登录 → 各页面 CRUD 操作各一次）。

### 1.7 提交（cjreg）

- 分支：`feat/ui-table-form-migrate`；每页迁移一个提交，最后合并回 master。

---

## 阶段 2 — 公开页 + 向导/详情

### 2.1 PublicPackages

- 列表 → Table（含描述列），行点击 → `onRowClick` 跳详情（替代"详情"按钮或保留按钮）。
- 保留搜索/组织筛选 + Pagination；移除手写 `renderList` 样板。

### 2.2 PackagesPage（管理端包管理）

- 列表 → Table + render（状态 Tag、版本/删除按钮）；保持搜索/组织筛选 + Pagination。
- 版本对话框保持 Table（已有）。

### 2.3 PublishPlanCreatePage

- 表单 → `Form` + `FormItem`（计划名/目标上游/轮询间隔/超时，含规则校验）；包选择列表 → `Table` + render（选择/取消选择按钮），或 VirtualList（包多时）。

### 2.4 PublishPlanDetailPage

- 计划信息卡片 → `Descriptions`（cjxt 已有）；发布项 → `Table` + render（状态 Tag、错误文本）。

### 2.5 PublicPackageDetail

- 包信息 → `Descriptions`；版本历史保持 Table；README → `Markdown` 组件（cjxt 已有，替代 code-block 纯文本）；依赖展示 → Table 或 Descriptions。

### 2.6 测试与验证

- 同阶段 1（纯逻辑单测 + 全量测试 + agent-browser 冒烟）。

---

## 阶段 3 — 布局组件化与清理

### 3.1 布局

- `layout.cj`：`adminCard` → `Card` 组件；`adminSidebar` → `Menu`/`MenuItem`（active 参数已有）；`publicNav` → 简化/保留（公开导航风格可自定义，视 Menu 效果决定）。
- `pages_manage.cj`：`statCard`/`quickLink` → `Statistic` 组件（dashboard 用）。
- `login.cj`：修正 Form 用法——`FormItem` 作为 `Form` 直接 children，label 用 `.label()`，rules 校验（用户名/密码 required）；移除 `div.dialog-form-label` 包裹。

### 3.2 样式清理

- `admin.css`：删除被替换的样式段（`admin-table`、`admin-tr`、`admin-th`、`admin-td`、`admin-actions`、`dialog-form*`、`stat-card`/`stat-value`/`stat-label` 等），保留布局骨架（sidebar/main/hero/公开页）与必要微调，预期砍掉一半以上。

### 3.3 测试与验证

- 全量 `cjpm test` + `agent-browser` 全页面截图冒烟（登录/公开 4 页/管理 8 页）。

---

## 验收标准

1. cjreg 全部列表页使用 `Table`（或明确说明保留手写的页面与理由）；全部列表页接入 `Pagination`。
2. 所有表单 Dialog 使用 `Form`/`FormItem` + 规则校验，无手写 `dialog-form-label`。
3. `admin.css` 手写样式减少 ≥50%。
4. cjxt 新增 API 全部带单元测试；cjreg 迁移涉及的新纯逻辑均有单测。
5. cjxt / cjreg 构建与全量测试通过；管理端 agent-browser 冒烟通过。

## 风险与注意

- cjxt 改动影响 harness-cj 等下游消费者：只新增 API，无签名破坏；改动后先跑 cjxt 全量测试再动 cjreg。
- cjreg 依赖的 cjxt 是 path 依赖：修改 cjxt 后需清理 `cjreg/target/release/cjxt/` 缓存并重新构建。
- `Table` 数据模型为 `HashMap<String, String>`：render 回调内需要数值转换（现有代码已有先例）；后续可评估泛型化（不在本期范围）。
- 页面级测试以纯逻辑 + 渲染结构断言为主，交互经 agent-browser 冒烟。
