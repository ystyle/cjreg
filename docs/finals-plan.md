# 决赛迭代计划（初赛版本 → 决赛版本）

> 用途：① 锁定**初赛基线**，作为决赛「相比初赛版本的提升」的对照；② 规划决赛迭代项（含验收口径与演示脚本）；
> ③ 决赛提交材料与「差异性说明」的模板。
>
> 赛程：初赛作品提交 **2026-10-07 23:59:59** / 决赛名单公示 10-16 / 决赛作品提交 **2026-10-23 23:59:59** / 线上路演 10-24。
> 计分：最终综合成绩 = 初赛得分 × 30% + 决赛得分 × 70%；决赛维度中「核心功能演示 30 分」「决赛阶段迭代成果 15 分」权重最高。

---

## 1. 初赛基线（提交时锁定）

### 1.1 打 tag

```shell
git tag -a v0.1.0-submission -m "仓颉生态创新开发挑战赛 · 初赛提交版本"
git push origin v0.1.0-submission     # 决赛写差异说明时以此 tag 为对照
```

### 1.2 基线度量表（提交时回填实测值）

| 度量 | 口径 / 采集命令 | 初赛基线值 |
|---|---|---|
| 单元测试用例数 | `cjpm test -j 16 --no-progress \| grep "Summary: TOTAL"` | **154**（24 个测试文件） |
| 源文件行覆盖率 | `cjpm test --coverage` + `cjcov -i "$PWD/src" -e "*_test.cj"` | **39.3%**（纯逻辑层 85%–97%） |
| 双仓 e2e | `bash tests/e2e.sh` | ✅ 6 包发布 → 拓扑 → 6/6 推送 → 目标仓校验 |
| 权限矩阵 e2e | 见 `docs/verification.md` §3.4 | ✅ 15+ 分支符合规格 |
| **大包发布上限** | 逐档 +1 MiB 二分，取首次失败体积 | **≤32 MiB 稳定；48–50 MiB 偶发 OOM** |
| **发布峰值内存** | 发布 20 MiB 时 `/proc/<pid>/status` 的 `VmHWM` | 待测（预期 ≈ 包体 3 倍） |
| 索引延迟 | 200 次 `GET /index` | p50 **0.47 ms** / p95 **1.55 ms** |
| 下载吞吐 | 20 MiB 制品 × 10（loopback 页缓存热） | **~941 MB/s** |
| 发布耗时 | 2/5/10/20 MiB | 6 / 7 / 17 / 90 ms |
| 静态二进制体积 | `ls -lh target/release/bin/ystyle::cjreg` | 待记录 |
| 提交数 | `git rev-list --count HEAD` | 91+ |

> 采集脚本建议固化为 `scripts/bench.sh`（决赛时同一脚本出 before/after 两组数字）。

---

## 2. 决赛迭代项

每项给出：目标 → 方案要点 → 验收标准 → 度量口径 → 演示方式。

### 迭代 1 ★：发布链路流式化（大包稳定 + 内存 O(1)）

**现状与根因**（有实测支撑，见 `docs/verification.md` §5.1）

- `POST /pkg` 将**整个请求体读入内存**（`bodyRaw()`），再按段切片（meta + 制品）、计算 SHA-256、最后写 blob；
  峰值内存 ≈ 包体 **2–3 倍**。
- 仓颉运行时 **GC 堆上限默认 256 MB**（`cjHeapSize`）：40 MiB 以上的包在默认配置下可能触顶；
  实测 ≤32 MiB 稳定、48–50 MiB 偶发 `Out of memory`（与当时堆占用相关，非体积阈值、非 cgroup 限制）。
- 另需注意 badger-cj 的 MemTable arena（bstorm 默认 `memTableSize` 16 MB → arena 32 MB，属原生内存）。
- 影响：官方协议允许**单段 500 MB**，当前实现无法兑现；`max_request_bytes`（默认 500 MiB）形同虚设。

**方案（不改 tang/cjxt，仓内完成）**

- 关键 API：`TangHttpContext.request` 是 public prop → `request.body: InputStream`、`request.bodySize: Option<Int64>`。
- 解析流程改为流式：
  1. 读第 1 段头（5 B：version + LE32 size）→ meta 段体积小，读入内存并解析出 `index.sha256sum`（**校验目标值先到手**）；
  2. 读第 2 段头 → 得到制品长度；随后按固定块（如 1 MiB）循环读：
     - 每块同时喂 `SHA256.update()` 与写入**临时文件** `blobs/.tmp-<ulid>`；
     - 累计长度超过 meta 声明值或段头声明值 → 直接 `BadRequest`（拒绝放大攻击）；
  3. 读满后 `SHA256.finish()` 与 meta 的 `sha256sum` 比对：
     - 一致 → `rename(tmp, blobs/<sha>)`（**原子可见**，内容寻址去重天然幂等）；长度上限校验沿用 `MAX_FILE_SIZE`；
     - 不一致 → 删除临时文件并返回 `ShaMismatch`（400/409，语义与现状一致）。
  4. 任何异常/客户端中断 → `finally` 删除临时文件（保证不残留半成品 blob；孤儿临时文件在启动时可清理）。
- 覆盖/幂等裁决**不变**：仍是「新包认领 / 新版本 write / 覆盖需 overwrite」，只是制品不再整包驻留内存。
- 流式计算：`stdx.crypto.digest.SHA256` 的 `write/update` 可按块喂（现有 `sha256Hex(Array<Byte>)` 之外新增 `HashStream` 用法）。

**验收标准**

1. 默认 `cjHeapSize`（256 MB）下，**200 MiB 包发布成功**，进程 `VmHWM` < 200 MB；
2. 500 MiB 包在 `cjHeapSize=2GB` 下发布成功（协议上限）；
3. 48 / 100 / 200 MiB 三档进入 **e2e 脚本**（`scripts/big-package-e2e.sh`），重复 5 轮无 OOM；
4. sha 不符 / 长度不符 / 中断传输 三个异常路径各有单测：临时文件被清理、库内无残留 blob、返回码正确；
5. 既有 154 例单测 + 双仓 e2e 全绿（回归零破坏）。

**度量口径与演示**

- 指标：最大可发布体积、单次发布 `VmHWM` 峰值、耗时（三档体积 before/after 表）。
- 演示：现场发布 200 MiB 包，同时显示内存采样曲线（before：撞 256 MB 堆上限失败 / after：平稳通过）。

### 迭代 2：发布计划六态 + SSE 进度流

- 目标：item 状态补齐 `publishing` / `waiting_index` / `skipped`；新增 `GET /api/admin/publish-plans/:id/events`（SSE）实时推送进度，保留轮询兜底。
- 验收：中断/恢复演练（kill 进程后计划置 `pending`）、等待索引确认（版本出现**且 SHA256 一致**）用例、SSE 事件序列单测。
- 演示：管理端发起计划，页面实时滚动进度；手动跳过某一项。

### 迭代 3：容器化增强与 CI 完善（基础版已提前到初赛交付）

**初赛已交付**：`Dockerfile`（archlinux + liburing/tzdata/ca-certificates，非 root uid 1000，宿主构建/镜像打包）、
`docker-compose.yml`（卷 `./data:/data`、`CJREG_PORT`/`CJREG_HEAP_SIZE` 等环境变量、`stop_grace_period: 30s`、
健康检查）、`scripts/docker-deploy.sh` 一键脚本；本地已实测「init → up → 健康 → `docker compose stop` 优雅关闭 → 重启数据留存」。

**决赛增强**：
- **自包含构建**：`Dockerfile.build` 多阶段（仓颉工具链镜像 + cjxt 源码/中心仓版本），使评审无需本地工具链即可构建；
- **多架构镜像**：`linux/amd64` + `linux/arm64`（buildx + QEMU，或原生 arm runner）；
- **镜像瘦身**：底座换 `debian:slim`（`liburing2`）/ distroless，记录体积对比（当前 ~500 MB）；
- **发布流水线**：Release 触发 → 二进制 tar.gz + 推 `ghcr.io/<owner>/cjreg:<tag>`；CI 增加 Docker 冒烟（已就绪）；
- **部署文档**：反向代理（Nginx/Caddy）+ HTTPS 示例、K8s 清单（可选）；
- **文档站自动部署已提前完成**：`docs-deploy.yml` → GitHub Pages + 华为云 CDN 刷新
  （发布地址 <https://ystyle.top/cjreg/>），决赛可做多语言/版本化文档。

- 验收：`ghcr.io` 镜像 `docker run` 即用；两种架构均可运行；镜像体积与初赛对比有量化下降。
- 演示：`docker compose up -d --build` → 浏览器访问 → `docker compose stop`（优雅关闭日志）。

### 迭代 4：正式性能基准报告

- 目标：`scripts/bench.sh` 产出可复现数据：索引**缓存命中 vs 回源**延迟、并发吞吐（wrk/自研压测）、发布/下载吞吐、静态二进制与镜像体积、内存占用（含 badger arena）。
- 验收：报告含测试环境、数据规模、指标口径、原始输出与结论；与初赛基线逐项对比。
- 演示：现场跑一遍 bench，展示缓存命中的数量级差异。

### 迭代 5：测试覆盖 90%+（质量维度）

- 目标：为 HTTP handler 层补 handler 级测试、为公开页补 `serializeSubtree` 渲染测试（已有先例），把 `src/` 行覆盖率从 39.3% 提到 **≥90%**（按包统计 + 覆盖率报告留档）。
- 验收：`cjcov` 报告 + `docs/verification.md` 更新；新增用例纳入 CI。
- 演示：展示覆盖率报告 before/after。

### 迭代 6：团队所有者（owner 自助）

- 目标：落地 `docs/user-portal-design.md` §7.4 路线 A —— `TeamDoc.ownerId`、`isTeamOwner` 守卫、owner 可在门户 `/me/teams` 管理本队成员（服务端守卫优先），管理员始终是超集。
- 验收：5 条约束（服务端守卫 / 下放边界 / 生命周期 / owner≠自动 write / 入口与审计）各有单测；越权用例被拒。
- 演示：owner 在门户加人 → 该成员可发布 → 移出后 403。

---

## 3. 决赛提交材料与「差异性说明」模板

**决赛提交材料**：最终仓库链接（tag `v0.2.0` 或 `v1.0.0`）、测试与验证材料（`docs/verification.md` 更新版）、决赛演示材料、**最终版本与初赛作品的差异性说明**。

**差异性说明模板**（按评审五维度组织，每项给出 before → after 数字）：

```markdown
## 相比初赛版本（v0.1.0-submission）的提升

### 功能
- 发布计划六态 + SSE：<新增能力>；团队所有者自助：<新增能力>
### 性能
- 大包发布：最大可发布体积 32 MiB → 500 MiB；200 MiB 发布峰值内存 <x> MB → <y> MB
- 索引缓存命中延迟：<before> → <after>（回源对比）
### 测试
- 单测用例 154 → <n>；src 行覆盖率 39.3% → <m>%；新增大数据包 e2e / 并发压测
### 稳定性
- 消除大包发布 OOM（根因：GC 堆 256MB + 整包驻留）；中断/残留临时文件清理；容器优雅关闭演练
### 文档与工程质量
- VitePress 文档站、Docker/CI、性能基准报告、CHANGELOG/README.OpenSource
```

---

## 4. 初赛前必做（与决赛项区分）

> 原则：**初赛优先补「申报书已声称、但实现缺失且成本低」的项**（直接影响「实现完成度 10 分」与可信度）；
> 需较大重构或有明确"提升故事"的项（流式化、六态+SSE、Docker/CI）留给决赛。

| 项 | 关联评分 | 状态 |
|---|---|---|
| 审计日志：发布日志写入（IP/UA/详情）+ 管理日志查询/清理端点 + 管理端日志页 | 安全 / 完成度 | ✅ 已完成（`docs/audit-log.md`，单测 + e2e 第 5 步） |
| 公开只读 API：`/api/stats`、`/api/packages`、`/api/packages/:name`、`/api/packages/:name/:version`、`/api/organizations` | 完成度 / 实用性 | ✅ 已完成（`docs/public-api.md`，单测 9 组 + e2e 第 6 步） |
| 组织 CRUD REST | 完成度 | 待做 |
| 上游连通性测试端点 `POST /api/admin/upstreams/:id/test` | 完成度 | ✅ 已完成（单测 5 组 + e2e 第 7 步） |
| ~~公开只读 API~~ | 完成度 / 实用性 | ✅ 已完成 |
| 包三级删除闭环（恢复 / 硬删入口 + 审计） | 完成度 | ✅ 已完成（单测 5 组 + e2e 第 8 步：软删/恢复/硬删 + 制品清理 + 计划项联动） |
| VitePress 文档站 | 文档完善度 15 分 | ✅ 已完成（docs-site/，构建通过） |
| Docker / Compose 部署 + 一键脚本 + CI/Release 工作流 | 完成度 / 可复现性 | ✅ 已完成（本地容器冒烟通过；Docker 增强留决赛迭代 3） |
| 演示视频（核心功能 + 使用链路）、统一作品提交模板（已提交） | 质量门槛（缺则不合格） | 待录 |
| 覆盖率报告 + 低成本测试补强（handler / 公开页渲染） | 代码质量 30 分 | 待做 |

> 说明：整包驻留内存与 `cjHeapSize` 的关系已在 `README.md`「内存与优雅关闭」与 `docs/verification.md` §5.1 如实说明，
> 并明确「流式解析」列入决赛迭代 —— 既避免初赛被记为"未完成"，也为决赛留下可量化的提升点。
