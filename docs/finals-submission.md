# 决赛提交材料（仓颉生态创新开发挑战赛 · 技术课题：私有中心仓）

> 赛事规则口径：决赛提交 4 项 —— ① 最终版本作品与仓库链接；② 测试与验证材料；
> ③ 决赛演示材料；④ **最终版本与初赛作品的差异性说明**。
> 截止 **2026-10-23 23:59:59（北京时间）**，**2026-10-24 线上路演**（介绍 + 核心功能演示 + 答辩）。
>
> 与初赛的区别：初赛要求的「统一作品提交模板 PDF」+ 视频在决赛**不再作为提交项**；
> 决赛以**路演当天的现场演示与答辩**为主，提交的仓库与材料用于评委查阅和真实性核验。

## 1. 最终版本与仓库链接

| 项 | 内容 |
|---|---|
| 主仓库（AtomGit） | <https://atomgit.com/ystyle/cjreg> |
| 镜像（GitHub） | <https://github.com/ystyle/cjreg> |
| 最终版本 | **tag `v0.3.0`**（2026-10-20） |
| 二进制产物 | GitHub Release：`cjreg_v0.3.0_linux_amd64.tar.gz`、`cjreg_v0.3.0_public.tar.gz`、单文件 `cjreg` |
| 容器镜像 | `ghcr.io/ystyle/cjreg:v0.3.0`（`:latest` 同版本） |
| 在线文档站 | <https://ystyle.top/cjreg/> |
| 初赛对照基线 | tag `v0.2.0`（2026-10-06，初赛截止前最后发布的版本） |

## 2. 测试与验证材料

| 材料 | 位置 | 规模/结果 |
|---|---|---|
| 全量验证报告（实验过程/验证方法/数据/结论） | [`docs/verification.md`](verification.md) | 12 类验证、含每项复现命令 |
| 单元测试 | `cjpm test -j 16 --no-progress` | **1002 个用例，全部通过** |
| 覆盖率报告 | `cjpm test --coverage` + `cjcov`（HTML；CI artifact `coverage`） | **91.3%**（11241/12312 行、90 个源文件） |
| 性能基准 | [`docs/benchmark.md`](benchmark.md) + `scripts/bench.sh`（桩上游 + k6，一键复现） | 索引命中 2.74 ms（回源 16.16 ms，5.9×）；发布 200 MiB = 0.618 s / VmHWM 291 MiB；并发拐点 16 VU（414 req/s） |
| 双仓 e2e | `bash tests/e2e.sh` | 9 步：发布 6 包 → 拓扑推送 → 公开 API → 上游连通 → 三级删除 → 组织 CRUD，全部通过 |
| CI 记录 | GitHub Actions（构建 + 单测 + 覆盖率 + 双仓 e2e + 文档站 + 容器冒烟） | 每次 push/tag 全流程留痕 |

## 3. 决赛演示材料

- **现场演示脚本**：[`docs/demo-video.md`](demo-video.md)（九段分镜：部署 → 发布 → 多仓代理 → 权限 → 门户 → 审计/公开 API → 三级删除 → 版本与镜像）
- **一键演示环境**：`bash scripts/demo-data.sh`（起 A/B 双仓 + 演示组织/用户/包 + 发布计划推送，可重置）
  / `bash scripts/demo-live.sh {prepare|status|clean}`（生产主站 + 演示空站实景）
- **路演结构**（10 分钟，按评分维度配时间）：
  1. 定位与痛点（1 分钟）—— 私有仓解决「内网/离线/预演」刚需，官方中心仓不可覆盖、同步不可控
  2. **核心功能现场演示**（4 分钟）—— 发布大包 → 索引/下载 → 多仓回源与解析诊断 → 发布计划推送 + 实时进度
  3. 技术方案与关键难点（2 分钟）—— 流式发布/下载（O(1) 内存）、bstorm/badger 存储、cjxt 声明式 UI + WS、
     双栈权限模型（owner/团队）、六态 + SSE
  4. 决赛迭代成果（1.5 分钟）—— 见 §4 的数字对比
  5. 限制、取舍与后续（1 分钟）—— 见 §4.5
  6. 答辩（按现场安排）
- **演示预案**（现场网络/环境异常时）：
  - 主用：生产实例 `http://192.168.3.6:8066` + 本机双仓（`scripts/demo-data.sh`）
  - 备用：`docker run` 现成镜像（`ghcr.io/ystyle/cjreg:v0.3.0`）+ 预置数据目录
  - 兜底：本地录制片段 + 截图（`docs/verification.md` 与 `benchmark.md` 的原始输出）

## 4. 最终版本与初赛作品的差异性说明

### 4.1 总览

| 维度 | 初赛 `v0.2.0`（10-06） | 决赛 `v0.3.0`（10-20） | 变化 |
|---|---|---|---|
| 单测用例 | 154 | **1002** | ×6.5 |
| 源文件行覆盖率 | 39.3%（35 文件 / 6033 行） | **91.3%**（90 文件 / 12312 行） | +52.0pp |
| 最大可发布包体 | ≤32 MiB 稳定，48–50 MiB 偶发 OOM | **200 MiB 稳定**（请求体上限 500 MiB 可配） | ×6 以上 |
| 发布峰值内存（VmHWM） | ≈ 包体 2–3 倍，200 MiB 必失败 | **恒定 ~291 MiB，与包体无关** | 与包体解耦 |
| 200 MiB 下载 | `Out of memory` | **成功且 sha256 一致** | 可用 |
| 发布吞吐（2/32/200 MiB） | 6/17/90 ms（20 MiB 为 90 ms） | **74 / 278 / 324 MiB/s** | 见 benchmark |
| 发布计划 | 四项状态（pending/running/completed/failed）、HTTP 轮询 | **六态 + SSE 实时进度 + 手动跳过 + 索引 SHA256 校验** | 新增能力 |
| 团队管理 | 仅管理员维护 | **owner 自助**（成员/转移/关联，门户弹窗） | 新增能力 |
| 构建与交付 | 宿主构建 → 镜像 | 追加 **自包含多阶段构建**（`Dockerfile.build`，评审无需本地工具链） | 新增能力 |
| 工程结构 | `admin_handler.cj` 1358 行、UI 单包 | 拆分到 122 行；UI 按站点面分子包、一页一文件；响应体统一 DTO | 可维护性 |
| 提交数 | 278 | 358（+80） | — |

> 口径：用例数与覆盖率取 `cjpm test` / `cjcov` 输出；内存与吞吐取 `scripts/bench.sh` 的
> `VmHWM` / 计时（同一台机器、同一脚本，before/after 可复现）。初赛数字见
> `git show v0.2.0:docs/verification.md`。

### 4.2 按决赛评分维度对应

**核心功能演示（30 分）** —— 现场可一条龙跑通：`init` → `serve` → 发布（含 200 MiB 大包）→ 索引/下载 →
多仓回源与解析诊断 → 发布计划拓扑推送（SSE 实时进度）→ 门户取 Token → 审计查询 → 三级删除 → 公开只读 API。

**技术方案与实现说明（20 分）**

- 架构：`protocol`（官方二进制协议）/ `index`（NDJSON）/ `store`（bstorm 文档层）/ `server`（服务与裁决）/
  `ui`（cjxt 声明式页面 + WS 补丁）分层；路由与 handler 拆分，响应体 DTO 序列化
- 关键难点 ①：**流式发布**（边读边算 sha256、直接落临时文件）+ 流式下载/回源 → 内存与包体解耦
- 关键难点 ②：**权限双栈**（平台管理员 / 包 owner / 团队 write|overwrite）与首次发布者 owner 模型
- 关键难点 ③：**索引等待**（版本出现 **且 sha256 一致** 才判完成）+ 六态 + SSE
- 工具链：Cangjie 1.2.0 构建（`cjpm.toml` 声明 `cjc-version = 1.1.3`，本项目为可执行程序，
  不向中心仓发布库制品；`v0.2.0` 及以前的二进制由 STS 1.1.3 构建）

**实用价值与生态贡献（15 分）** —— 私网/离线环境可自建中心仓；预演仓（发布不可逆、中心仓同步不可控）；
多仓体系与一键推送官方/私有仓；公开只读 API 便于 CI 与门户集成。

**决赛阶段迭代成果（15 分）** —— 见 §4.1 与 §4.3（每个数字都有脚本与文档可复现）。

**项目掌握程度与答辩表现（15 分）** —— 代码按职责分层、关键路径均有单测与 e2e 覆盖，
已知限制与取舍在 §4.5 如实列出。

**路演完整性与时间控制（5 分）** —— 见 §3 的 10 分钟时间分配与演示预案。

### 4.3 决赛六个迭代（逐项证据）

| 迭代 | 交付 | 证据 |
|---|---|---|
| 1 流式发布/下载/回源 | 内存 O(1)，200 MiB 稳定 | `docs/benchmark.md` §7；`docs/verification.md` §3.8/§5.1 |
| 2 六态 + SSE | `publishing`→`running` / `waiting_index` / `skipped` + `GET /api/admin/publish-plans/:id/events` | `src/server/publish_plan_events_test.cj`，handler 级 SSE 用例 |
| 3 自包含构建 | `Dockerfile.build`（多阶段 + dev target） | 构建产物可 `docker run`；两阶段同基础镜像保证 glibc 一致 |
| 4 性能基准 | `scripts/bench.sh` + `docs/benchmark.md` | 索引 5.9×、并发拐点、发布/下载内存曲线 |
| 5 质量 90%+ | 154 → 1002 用例，39.3% → 91.3% | cjcov HTML（CI artifact）；进程内 HTTP 夹具 + 页面渲染测试 |
| 6 团队 owner 自助 | 成员/转移/关联管理 + `admin delete-user` 孤儿守卫 | `docs/team-owner-plan.md`，三层单测（纯函数/handler/渲染） |

### 4.4 优秀实践倡导的核验材料（不单独计分，供评委参考）

- **测试完备性**：覆盖率 91.3% ≥ 90%；`tests/` + `src/**/*_test.cj` 全量测试目录；
  `cjcov` HTML 报告与 CI 记录均可查；逻辑层（protocol/config/auth/index/semver/store）85%–95%
- **性能达成率**：`scripts/bench.sh` 一键复现；与原「整包驻留」实现相比，发布 200 MiB 从**失败**到
  **0.618 s / 291 MiB**；索引缓存命中较回源快 **5.9×**（桩计数证明重查轮零回源）

### 4.5 未实现功能与已知限制（如实说明）

| 项 | 状态 | 重要程度 |
|---|---|---|
| 多架构镜像（arm64） | 未做（仅 amd64） | 中——影响 ARM 环境直接部署 |
| 镜像瘦身 | 未做（507 MB，archlinux + 运行时） | 低——影响拉取体积，不影响功能 |
| 镜像预热/周期同步（`serve --sync-interval`） | 未做 | 低——首次回源有冷启动延迟 |
| K8s 清单 | 未做（提供 docker compose） | 低 |
| 大包上限 | 受 `max_request_bytes`（默认 500 MiB）与堆上限约束，200 MiB 已实测 | — |
| 计划的 `publishing` 细分态 | 以 `running` 表达 | 低 |

## 5. 复现说明（评审自证）

```shell
# 1) 单测（1002 例）+ 覆盖率
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"
cd cjreg && cjpm test -j 16 --no-progress
cjpm test --coverage -j 16 --no-progress && cjcov --root=./ -o coverage --html-details -i "$PWD/src" -e "*_test.cj"

# 2) 双仓 e2e（9 步，自动 init/起双仓/清理）
bash tests/e2e.sh

# 3) 一键演示环境（A/B 双仓 + 演示组织/用户/包 + 发布计划推送）
CJREG_DEMO_PORT=18080 CJREG_DEMO_RESET=1 bash scripts/demo-data.sh

# 4) 性能基准（桩上游 + k6）
bash scripts/bench.sh

# 5) 现成镜像
docker pull ghcr.io/ystyle/cjreg:v0.3.0 && docker run --rm ghcr.io/ystyle/cjreg:v0.3.0 --help
```

## 6. 决赛待办（按优先级）

- [ ] 打 tag `v0.3.0` → Release 出二进制 + ghcr 镜像，回填 §1 的产物链接
- [ ] 路演 PPT（按 §3 结构，10 分钟配时）
- [ ] 现场演示彩排（含 §3 的三档预案）
- [ ] 覆盖率报告与 benchmark 原始输出归档为可点击材料
- [ ] （可选）arm64 镜像、镜像瘦身
