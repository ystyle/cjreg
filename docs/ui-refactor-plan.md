# cjreg 管理界面组件化重构计划

> 背景：cjreg 的 15 个页面中，控件级（Button/Tag/Input/Select/Switch/Dialog/Empty）复用充分，但组合级组件（Table/Form/Pagination）大量手写：8 个列表为手写 div 表格（`admin-table/tr/td`，约 500+ 行重复样板），所有 Dialog 表单为手写 label 布局（无校验），布局（侧边导航/卡片/统计卡）也全部手写。根因分析见与用户的初审报告。
> 原则：**TDD**（每个 API 先写失败用例）、每阶段独立提交、向后兼容（cjxt 只新增 API 不破坏现有签名）、按 cjxt/cjreg 的 git 分支规范进行。

---

## 阶段 0 — cjxt 能力补齐（前置）✅ 已完成

**目标**：扫清 cjreg 无法使用 Table/Form 的三个能力缺口。全部为**新增 API，不修改现有签名**。

### 0.1 TableColumn.render（自定义单元格渲染）✅

- 位置：`cjxt/src/components/Table.cj`
- 新增字段：`var _render: Option<(HashMap<String, String>, Int64) -> IComponent> = None`
- 新增方法：`public func render(fn: (HashMap<String, String>, Int64) -> IComponent): TableColumn`
- 行为：`buildDefaultCell` 中当 `_render` 为 Some 时，调用 `fn(row, index)` 得到 IComponent 并作为该列 cell 的内容（替代纯文本/formatter 路径）；返回的组件节点（如 Tag/Button/div）由 `expandTree` 正常展开，handler id 走既有路径派生稳定化机制。
- 与 `formatter` 并存：render 优先于 formatter。

### 0.2 Table.onRowClick（行点击回调）✅

- 位置：`Table.cj`
- 新增字段：`var _onRowClick: Option<(HashMap<String, String>, Int64) -> PatchResult> = None`
- 新增方法：`public func onRowClick(fn: (HashMap<String, String>, Int64) -> PatchResult): Table`
- 行为：`renderRow` 中当设置时给 `<tr>` 绑定 click handler（`{ ctx => fn(row, index) }`）；与 `highlight()`（仅设置 currentRow）并存，互不影响。

### 0.3 FormItem.bindValue（通用取值 getter）✅

- 位置：`cjxt/src/components/Form.cj`
- 新增方法：`public func bindValue(getter: () -> String): FormItem`（写入既有 `_getValue` 字段）
- 目的：`Signal<Int64>`/`Signal<Bool>` 等非 String 信号也能接入 `FormRule`/`validate()`，调用方用 `{ => signal.get().toString() }` 包装。

### 0.4 测试（TDD，先写失败用例）✅

- 新增 `cjxt/tests/src/table_test.cj`（独立测试包 `cjxt/tests`，主包无法测 components 子包——cjpm 循环依赖）：
  - `testColumnRenderInsertsComponent` / `testColumnRenderPriorityOverFormatter` / `testOnRowClickBindsRowAction` / `testNoOnRowClickKeepsRowUntouched`（serializeSubtree JSON 断言）
- 新增 `cjxt/tests/src/form_test.cj`：
  - `testFormItemBindValueRequired` / `testFormItemBindValuePattern` / `testFormItemBindValueWithIntGetter`
- 运行：cjxt 主包 205 个测试 + tests 包 7 个测试全部通过。

### 0.5 提交（cjxt）✅

- `c79f6e2` feat: Table 自定义单元格渲染 render + 行点击 onRowClick
- `7d641c6` feat: FormItem.bindValue 通用取值 getter — 非 String 信号接入校验
- 注：`cjpm` path 依赖会缓存编译产物，cjreg 侧改动前清理 `cjreg/target/release/cjxt/` 缓存。

---

## 阶段 1 — cjreg 管理列表迁移（用户/组织/团队/上游/发布计划）✅ 已完成

**目标**：5 个管理列表页从手写 div 表格迁移到 `Table` + `TableColumn.render` + `Pagination`；对应 Dialog 表单迁移到 `Form` + `FormItem`。

共性模式（每个页面一致）：
- 新增 `rows/currentPage/pageSize/total` 信号 + `refresh()`（`pageWindow` 切片 + HashMap 行组装）
- 动作函数改 id 版（`showToken(id)`/`toggleActive(id)`/`askDelete(id)`/`toggleEnabled(id)` 等，经 store `getXxx(id)` 取实体）
- `renderList()` → `Table().data(rows).stripe().add(TableColumn()...render(...))`；空态 `emptyState`
- 表单 Dialog → `Form([FormItem([控件])...])` + `bindValue` + `rule(FormRule(...))` + `errorSignal`（表单实例存字段供 `submit` 时 `validate()`）
- `Pagination`（`layout("total, prev, pager, next, sizes")` + `onChange`）
- 新增 `src/ui/table_logic.cj`：`pageWindow`（分页窗口切片，page/size 钳制）+ `rowStr`，`table_logic_test.cj` 8 个单测

### 1.1 UsersPage ✅ / 1.2 OrganizationsPage ✅ / 1.3 TeamsPage ✅ / 1.4 UpstreamsPage ✅ / 1.5 PublishPlansPage ✅

- TeamsPage 额外：包/成员关联 Dialog 的搜索列表 → 微型 Table（`pkgRows`/`memberRows` 信号，toggle 后原地刷新）
- agent-browser 冒烟（独立命名会话）：每页表格/分页/Tag/操作按钮渲染、表单必填校验错误显示、创建/启停交互全链路通过

### 1.7 提交（cjreg）✅

- `b00a84c` 用户管理 / `f321ea9` 组织管理 / `9ed3b04` 团队管理 / `20ffb46` 上游管理 / `79b9535` 发布计划列表
- 96 个测试全过（88 原有 + 8 新增）

---

## 阶段 2 — 公开页 + 向导/详情 ✅ 已完成

### 2.1 PublicPackages ✅
- 列表 → Table（含描述列 showOverflowTooltip），行点击 → `onRowClick` 跳详情（回调含 `ctx`）；保留搜索/组织筛选 + Pagination。
- 前置：cjxt `Table.onRowClick` 增加 ActionContext 参数（`5ec63e0`）。

### 2.2 PackagesPage（管理端包管理）✅
- 列表 → Table + render（状态 Tag、版本/删除按钮）；保持搜索/组织筛选 + Pagination；行数据 deleted 改 "1"/"0"。

### 2.3 PublishPlanCreatePage ✅
- 表单 → `Form` + `FormItem`（计划名/目标上游 required 校验 + errorSignal；轮询/超时 InputNumber）
- 包选择列表 → `Table` + render（pkgRows 信号，搜索 on("input") 原地刷新）

### 2.4 PublishPlanDetailPage ✅
- 计划信息卡片 → `Descriptions`（border/column=2/labelWidth）
- 发布项 → `Table` + render（状态 Tag、错误列 showOverflowTooltip）；`itemRows` 信号在 pushUpdate 回调内刷新（异步进度实时更新）

### 2.5 PublicPackageDetail ✅
- 包信息 → `Descriptions`；版本历史保持 Table；README → `Markdown` 组件（演示包无 README 时走"无 README"分支）

验证：agent-browser 冒烟——公开包列表行点击跳详情、包管理 Tag/分页、创建向导校验错误、完整创建计划→详情页（Descriptions + 发布项 Table + 待执行 Tag）全链路通过。

---

## 阶段 3 — 布局组件化与清理 ✅ 已完成

### 3.1 布局 ✅
- `layout.cj`：`adminCard` → `Card` 组件（header）；`adminSidebar` → `Menu`/`MenuItem`（顺序稳定、active 高亮、路由跳转、退出登录菜单项）；`publicNav` 保留（公开页横向深色风格，Menu 为标准竖排不匹配）。
- `pages_manage.cj`：`statCard` → `Statistic` 组件（仪表盘）。
- `login.cj`：修正 Form 用法——FormItem 作为 Form 直接 children、`.label()` 设置、`rules` 校验（用户名/密码 required + errorSignal），移除 `div.form-item` 包裹。

### 3.2 样式清理 ✅
- `admin.css` 49 → 36 行：删除全部被组件替代的样式段（`admin-table/tr/th/td/actions`、`admin-card`、`form-item`、`stat-value`、`admin-tag-*`、`dialog-form-item`），保留布局骨架（sidebar/main/公开页/hero）与说明文案样式，新增 Menu 深色适配（el-menu 深色 + is-active 高亮）。

### 3.3 验证 ✅
- `cjpm test` 96 全过；agent-browser：登录页必填校验、仪表盘 Statistic ×7、Menu 高亮/跳转/退出登录全链路通过。

---

## 验收标准（完成情况）

1. ✅ 全部列表页使用 `Table`：用户/组织/团队/上游/发布计划/包管理/公开包列表/创建向导包选择/计划详情发布项/团队包·成员关联（10 处；Dialog 内迷你列表未分页，属合理保留）。
2. ✅ 全部主列表页接入 `Pagination`：用户/组织/团队/上游/发布计划/包管理/公开包列表（7 处）。
3. ✅ 所有表单 Dialog 使用 `Form`/`FormItem` + 规则校验：用户/组织/团队/上游/创建向导/登录页（6 处）；仅说明文案保留 `dialog-form-label`。
4. ⚠️ `admin.css` 手写样式段全部移除（被组件替代的 100% 清除），总行数 49 → 36（-26%，未到 50% 目标——剩余为布局骨架/公开页自绘样式，属必要保留）。
5. ✅ cjxt 新增/修改 API（TableColumn.render、Table.onRowClick+ctx、FormItem.bindValue）全部带单元测试（tests 包 7 个）；cjreg 新增纯逻辑 pageWindow/rowStr 8 个单测。
6. ✅ cjxt 主包 205 测试、cjreg 96 测试全过；管理端 + 公开页 agent-browser 冒烟全链路通过。

---

## 追加：阶段 G — Table<T> 泛型化 ✅ 已完成（2026-08-24）

用户质疑点：为什么 Table 数据模型是 `Signal<ArrayList<HashMap<String, String>>>`？因为 cjxt Table 组件早期设计就是字符串行模型（对齐 EP prop 字符串索引 + 前后端 JSON 直通 + 组件早期实现简化），导致每个页面都要手工做「实体 → HashMap」组装和 `Int64.parse` 转回。

**解决：Table/TableColumn 泛型化为 `Table<T>`**（cjxt `0014779`，cjreg `997fd00`）：

- `TableColumn<T>.accessor((T) -> String)`：文本列取值 + 排序依据；`formatter((String)->String)` 保留；`render((T,Int64) -> IComponent)` 优先
- `Table<T>.data(Signal<ArrayList<T>>)`、`rowKey((T)->String)`（选择/当前行唯一键）、`onRowClick((T,Int64,ActionContext)->PatchResult)`
- 排序抽出顶层纯函数 `sortByAccessor<T>`（13 个泛型测试 + showcase TableRow 演示）
- cjreg 11 处表格全部迁移：`Table<User>`/`Table<OrgDoc>`/`Table<TeamRow>`/`Table<Upstream>`/`Table<PlanRow>`/`Table<PackageDoc>`/`Table<PlanItemDoc>`/`Table<LogDoc>`/`Table<PkgRow>`/`Table<MemberRow>`/`Table<PkgChoice>`
- 行视图类型只保留实体外的派生字段（计数/上游名/关联标记），`m["x"]=...` 组装样板、`rowStr`/`Int64.parse` 转回全部删除（净 -42 行）
- 破坏性变更（Table 需类型参数），cjxt showcase/harness 无兼容负担；cjreg 单测 95 全过 + agent-browser 冒烟通过
