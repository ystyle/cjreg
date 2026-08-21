# cjreg vs cjrepo 差距清单（子 agent 双面对比汇总）

- 对比基准：cjrepo 全量代码面（main.go/handlers/models/task/upstream/protocol/auth/middleware）+ cjrepo docs/ 全部规格与设计文档
  vs cjreg docs/design.md（当前设计）
- 已排除已知差异：认证模式（admin key+JWT vs pbkdf2 用户名密码）、Web 前端语言、发布计划 UI 形态
- 状态：**已筛选补入 design.md（commit e8db439）**；本清单保留完整记录与可选/超集项，供后续回溯

### 处理结果总览

- ✅ 已补入 design.md：A1-A4、B1-B4、C1-C5、D1-D3、E1-E2、F1、G1-G6、H1-H3、I1-I5、J3
- 🔒 保留可选（未补）：B5 README 提取、D4 email、E3 日志清理、F2 默认组织、I6 关键字/24 分类、J4 /depot、J5 version 子命令、J7 上游元数据接口、J8 workspace path→registry 替换
- ⭐ 超集增强（cjreg 已优于 cjrepo，保留）：G7 targetUpstream 生效、J1 索引缓存、J2 多上游 priority、J6 上游 test 真实实现

---

## A. 权限体系（最高优先）

| # | 差距项 | 来源 | 状态 | 建议 |
|---|---|---|---|---|
| A1 | **publisher_id 个人发布路径**：无组织包"谁发布谁可更新"——任意有效 token 可发新包并成为 publisher；新版本自动获得 write；覆盖拒绝（走团队路径） | permission-refinement.md「双路径权限模型」；#22 | 缺失（最严重） | Package 模型补 publisherId；§5.4.3 补双路径裁决 |
| A2 | **requireAuth 公开/私有开关**：索引/下载是否需认证可配置（私有化部署必需） | permission-refinement.md 权限矩阵；#26 | 缺失 | §5.1 补"本地仓读写鉴权开关" |
| A3 | **权限检查流程细节**：超管直通 → 包级 TeamPackage → 组织级 TeamOrganization；发布动态权限（新包=任意有效 token / 新版本=write / 覆盖=overwrite） | team-permission-design.md；publish.go；#14/#27 | 部分覆盖 | §5.4.3 补检查顺序与发布动态权限 |
| A4 | **用户-团队查询端点** `GET /api/admin/users/:id/teams` | team-permission-design.md | 缺失（小） | §5.4.2 补 |

## B. 包生命周期管理

| # | 差距项 | 来源 | 状态 | 建议 |
|---|---|---|---|---|
| B1 | **三级删除**：软删/恢复（校验 tarball）/硬删（删记录+文件+审计） | admin.go；PROTOCOL.md | 缺失 | §5 补删除模型 + deleted_at + 索引/缓存/发布计划联动 |
| B2 | **admin 包版本列表** `GET /api/admin/packages/versions/:name` + 筛选参数（search/org/artifactType/deleted） | admin.go | 缺失 | 随包管理端点补 |
| B3 | **下载计数** `download_count`（下载时自增） | models/package.go | 缺失 | 公开 stats 依赖 |
| B4 | **来源标记字段化** `upstream_id/upstream_name`（回源落库写入） | upstream/sync.go | 部分覆盖 | 明确字段归属（bstorm 文档 vs 入元数据） |
| B5 | README 提取入库（发布时从 tar.gz 解析 README_zh.md） | publish.go | 缺失 | 可选（包详情展示） |

## C. 公开 API 层（Web 前端/第三方数据源）

| # | 差距项 | 来源 | 状态 | 建议 |
|---|---|---|---|---|
| C1 | 公开统计 `GET /api/stats`（包/用户/版本/下载/存储/构建信息） | public.go | 部分覆盖 | 补 |
| C2 | 公开包列表 `GET /api/packages`（分页/搜索/`org::` 语法/多分类 OR） | public.go | 缺失 | 补 |
| C3 | 公开包详情 `GET /api/packages/:name`（全部版本） | public.go | 缺失 | 补 |
| C4 | 公开版本详情 `GET /api/packages/:name/:version` | public.go | 缺失 | 补 |
| C5 | 公开组织列表 `GET /api/organizations` | public.go | 缺失 | 补（低成本） |

## D. 用户管理

| # | 差距项 | 来源 | 状态 | 建议 |
|---|---|---|---|---|
| D1 | 用户列表 `GET /api/admin/users`（分页/搜索） | admin.go | 缺失 | 补 |
| D2 | 删除用户 `DELETE /api/admin/users/:id` | admin.go | 缺失 | 补 |
| D3 | 启用/禁用 `PUT /api/admin/users/:id/toggle` | admin.go | 部分覆盖（模型有 isActive） | 补端点 |
| D4 | 用户 email 字段 | models | 不一致 | 可选（cjcc 模式取舍） |

## E. 审计日志

| # | 差距项 | 来源 | 状态 | 建议 |
|---|---|---|---|---|
| E1 | 发布日志 PublishLog（org/name/version/status/error/IP/UA）+ `GET /api/admin/logs/publish` | models；admin.go | 部分覆盖（有 log 集合名） | 补字段/写入时机/查询端点 |
| E2 | 管理操作日志 AdminLog（action/target/details/IP/UA）+ `GET /api/admin/logs/admin` | admin_log.go | 缺失 | 补（课题强调安全） |
| E3 | 日志清理 `POST /api/admin/logs/clean` | admin.go | 缺失 | 可选 |

## F. 组织管理

| # | 差距项 | 来源 | 状态 | 建议 |
|---|---|---|---|---|
| F1 | 组织 CRUD（列表/创建/更新/删除，含成员数/包数统计） | organization.go | 缺失（有 org 集合无 API） | 补（团队引用 organizationId 需闭环） |
| F2 | 默认组织（CJREPO_DEFAULT_ORGANIZATION 自动创建置默认） | organization.go；main.go | 缺失 | 可选（单组织场景可省） |

## G. 发布计划细节

| # | 差距项 | 来源 | 状态 | 建议 |
|---|---|---|---|---|
| G1 | **item 状态枚举**：pending/publishing/**waiting_index**/completed/failed/**skipped** | publish-plan-design.md（6 状态） | 部分覆盖（未枚举） | §5.5 补枚举与跳过语义 |
| G2 | **重启恢复**：启动时 running → paused | task/publish_plan.go | 缺失 | §5.5.3 补 |
| G3 | analyze 请求/响应结构（`org::name@version` 入参、dependency_range/local_versions/remote_versions/recommended_version/publish_order 出参）+ 去重规则 | publish-plan-design.md | 部分覆盖 | §5.5 补 |
| G4 | 四分类判定条件（版本存在性 + SHA256 比对；推荐取最高符合版本） | publish-plan-design.md | 部分覆盖（依赖 cjdep） | 明确 |
| G5 | 轮询/超时默认值（30s/60s 文档自冲突需取定）+ max_concurrent + SSE 兜底轮询 | publish-plan-design.md / docs-site | 不一致 | 取定默认值 |
| G6 | 发布确认需「索引出现该版本 **且 SHA256 一致**」 | publish-plan-design.md | 部分覆盖 | 明确 |
| G7 | targetUpstream 生效性：cjrepo 实际忽略（取第一启用上游）；cjreg 设计生效 | #30 | 超集 | 保留，验收标注为增强 |

## H. 元数据 / 索引字段级处理

| # | 差距项 | 来源 | 状态 | 建议 |
|---|---|---|---|---|
| H1 | meta-data.json 全字段（15 字段）解析/校验/存储/索引生成 | 中心仓元数据规格.md | 部分覆盖（只 name/org/version/sha256） | §5.1 补字段级处理 |
| H2 | index 依赖条目 target/type/output-type + 三类依赖（dependencies/test/script）序列化 | 中心仓元数据规格.md | 部分覆盖 | 索引生成需原样透传 |
| H3 | semver 能力清单：无限区间 `(, 2.0.0]`、`(1.0.0, )`、多区间组合 | 制品包使用.md | 部分覆盖（vendored cjdep 应已具备） | 设计明确对齐 |

## I. 协议 / 兼容细节

| # | 差距项 | 来源 | 状态 | 建议 |
|---|---|---|---|---|
| I1 | 官方仓 URL 写法确认：`https://pkg.cangjie-lang.cn/registry`（cjreg 与 cjrepo 代码一致，与 cjrepo 设计文档不一致） | sync.go vs publish-plan-design.md | 不一致 | 定死 base URL 并写入 isOfficial 识别规则 |
| I2 | 健康检查定死 `/api/health`（cjrepo 是 /health） | #33 | 部分覆盖（"如有"含糊） | 定死 |
| I3 | 统一错误响应体 `{"error": "..."}` | main.go customErrorHandler | 部分覆盖（有返回码无 body） | 补 |
| I4 | 下载响应头 Content-Type/Content-Disposition | PROTOCOL.md | 缺失 | 补 |
| I5 | 包名/版本/org 格式校验 + 存储路径安全（防路径遍历） | PROTOCOL.md | 部分覆盖 | 补（bstorm 内容寻址可缓解，说明） |
| I6 | 模块名/组织名关键字校验、24 分类列表与大小写归一化 | 配置项.md | 缺失 | 可选（bundle 在客户端，服务端复检取舍） |

## J. 其他

| # | 差距项 | 来源 | 状态 | 建议 |
|---|---|---|---|---|
| J1 | 索引缓存（cjrepo 不缓存索引，cjreg 设计有 cache:index 集合） | #32 | 超集 | 保留，标注增强；cache-stats 口径含索引缓存 |
| J2 | 多上游 priority 遍历（cjrepo 单上游，cjreg 多上游） | #31 | 超集 | 保留（课题核心），验收标注增强 |
| J3 | **数据迁移策略**：bstorm JSON 文档结构演进/数据搬迁的版本化迁移 | #40 | 缺失 | 补（长期维护） |
| J4 | /depot 兼容路由（旧客户端 stub） | #34 | 缺失 | 可选 |
| J5 | version 子命令 + 构建信息 | #36 | 缺失 | 可选 |
| J6 | 上游 test 真实实现（cjrepo 是 TODO stub） | #38 | 设计已优于 | 实现真实连通测试 |
| J7 | 上游元数据接口 GET {upstream}/packages/{name} | #39 | 缺失 | 可选 |
| J8 | workspace path→registry 替换/restore/CI JSON 输出 | release-cli-design.md | 缺失 | 形态取舍：并入 cjdep 或显式排除 |

---

## 筛选建议（待用户确认后补入 design.md）

- **必补（课题/私有化刚需）**：A1 publisher_id、A2 requireAuth、A3 权限检查顺序、B1 三级删除、E1/E2 审计日志、F1 组织 CRUD、G2 重启恢复、I1 官方 URL 定死
- **建议补（管理面闭环）**：C1-C5 公开 API、D1-D3 用户管理端点、B2 版本列表、A4 用户-团队查询
- **细节明确**：G1 状态枚举、G3/G4/G5/G6 发布计划细节、H1/H2 字段级处理、I2/I3/I4/I5 协议细节
- **可选**：B5 README、D4 email、E3 日志清理、F2 默认组织、I6 关键字/分类、J4/J5/J7/J8
- **标注增强（已优于 cjrepo，保留）**：G7、J1、J2、J6
