# 演示视频脚本（初赛/决赛通用）

> 目标时长 **4:30–5:00**，1920×1080 / 30fps，中文解说 + 中文字幕。
> 一条命令准备演示环境：`bash scripts/demo-data.sh`（细节见 §2）。

## 0. 视频要传达的三件事

1. **它是真能用的私有中心仓**：与官方协议互通（`cjpm publish` / 下载 / 索引）、静态单二进制 + Docker 一键部署；
2. **它解决了多仓问题**：上游代理与优先级查找、解析诊断、发布计划按依赖拓扑推送到目标仓；
3. **它按私有化安全要求做全了**：认证与权限双路径裁决、审计日志（IP/UA）、包三级删除、公开只读 API。

叙述顺序：**部署 → 发一个包 → 多仓 → 权限 → 门户 → 审计/API → 删除 → 收尾**。
每一段都先「操作」后「结果」，避免长时间停在空页面上。

## 1. 录制前检查清单

| 项 | 要求 |
|---|---|
| 分辨率 | 1920×1080（≥1600×900），浏览器缩放 **100%**；窗口尽量铺满 |
| 终端 | 字号 ≥ 16px，深色主题，提示符简短（`PS1='\w $ '`），历史清空避免泄露 |
| 浏览器 | 只开演示标签页；管理后台先登录一次，避免录制时输密码；关闭通知 |
| 敏感信息 | Token/口令在解说里不当众朗读；终端里可先把 `token = "…"` 改成一个假值再演示，或用 `sed` 打码 |
| 声音 | 用脚本录旁白（推荐先录音再配画面），或录屏时对着 §3 台词念 |
| 备用 | 提前跑一遍全流程，把耗时操作（`cjpm publish`、docker 构建）的输出留好，必要时用剪辑拼接 |

## 2. 演示环境准备（一条命令）

```bash
# 宿主机准备：仓颉 1.1.3 + stdx（cjvs 管理）、Docker
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"

# 1) 构建（约 1 分钟）
cjpm build -j 16

# 2) 一键造演示数据：起 A 仓（team 模式，:18080）与 B 仓（:18081），
#    建用户 alice/bob、组织 demo、发布 demo::mathUtils|strUtils|encryptUtils，
#    把 B 注册为上游并把包推过去，最后造一批审计记录
CJREG_DEMO_PORT=18080 CJREG_DEMO_RESET=1 bash scripts/demo-data.sh
```

脚本产出（结束时终端会打印同样的清单）：

| 对象 | 地址 / 账号 |
|---|---|
| A 仓（演示主仓，team 模式） | `http://127.0.0.1:18080` |
| 管理后台 | `http://127.0.0.1:18080/admin` — `admin` / `AdminPass1` |
| 用户门户 | `http://127.0.0.1:18080/user/login` — `alice` / `AlicePass1`、`bob` / `BobPass1` |
| B 仓（镜像/目标仓） | `http://127.0.0.1:18081` — `admin` / `AdminPass1` |
| 演示包源码 | `.demo/pkgs/{mathUtils,strUtils,encryptUtils}`（组织已改成 `demo`） |

停止：`bash scripts/demo-data.sh stop`。

> **Docker 版演示**（若想用容器录部署段）：`ADMIN_PASS='<口令>' bash scripts/docker-deploy.sh`，
> 然后在容器里 `cjreg init` 的那份数据上重复上面的建用户/组织/发布步骤（脚本里的 curl 段可直接复用，换端口即可）。

## 3. 分镜与解说词

> 下面的命令与页面地址按 §2 的端口写（A 仓 `18080`、B 仓 `18081`）；若录 Docker 段，端口换成 `8060` 即可。
> 每个镜头都给了可直接照做的命令，旁白可以后期配音，也可以边说边操作。

### 镜头 1｜片头 0:00–0:18

- **画面**：标题卡（可后加）：`cjreg —— 纯仓颉实现的私有中心仓与多仓体系`，下一行小字 `官方协议互通 · 多仓代理 · 权限与审计 · 一键部署`
- **解说**：
  > 「cjreg 是用仓颉从零实现的私有中心仓。它对上兼容官方中心仓协议，能直接用 `cjpm` 发布和拉取；
  > 同时提供多仓代理、发布计划、权限裁决与审计，交付物是一个静态二进制和一套 Docker 镜像。」

### 镜头 2｜一键部署 0:18–0:55

- **操作**：终端执行
  ```bash
  ADMIN_PASS='Demo-Pass-2026' bash scripts/docker-deploy.sh
  ```
  （或者切到本机二进制：`./target/release/bin/ystyle::cjreg serve -d .demo/data-a`）
- **画面重点**：脚本五步输出（编译 → 构建镜像 → 首次 init → 启动 → 健康检查），最后一行 `✓ http://127.0.0.1:8060/api/health`；再补一个 `curl -s .../api/health` 与 `docker ps` 的镜头
- **解说**：
  > 「部署只有一条命令：宿主机编译出二进制，镜像只做打包，容器以非 root 运行、数据目录挂卷持久化。
  > 首次启动会自动建管理员、注册官方上游、生成配置文件。健康检查通过即可用。」

### 镜头 3｜发布一个包 0:55–1:45

- **操作**：
  1. 浏览器打开 `http://127.0.0.1:8060/`（门户首页）与 `http://127.0.0.1:8060/docs`（内置帮助）各停留 3 秒；
  2. 终端展示客户端配置（`cat .demo/pkgs/mathUtils/cangjie-repo.toml`）；
  3. 终端执行 `cd .demo/pkgs/mathUtils && cjpm publish`，停在 `cjpm publish success`；
  4. 切到管理后台 **仪表盘**（包数/版本数/下载数变化）与 **包管理**（新增 `demo::mathUtils@1.0.0`）。
- **解说**：
  > 「客户端只需要在 `cangjie-repo.toml` 里填上私有仓地址和发布 Token，
  > `cjpm publish` 就走通官方二进制协议：meta 段 + 制品段、SHA-256 校验、版本冲突判定。
  > 管理后台立刻能看到这个包、版本、制品大小和发布者。」

### 镜头 4｜多仓与代理 1:45–2:35

- **操作**：
  1. 管理后台 **上游管理**：展示 `official`（官方仓）与 `mirrorB`（演示用第二私有仓），点 **连通性测试**；
  2. 终端执行解析诊断：
     ```bash
     curl -s "http://127.0.0.1:8060/api/admin/resolve?name=mathUtils&organization=demo&require=>=1.0.0" \
       -H "Authorization: Bearer $TOKEN" | python3 -m json.tool | head -30
     ```
  3. 终端执行发布计划推送（也可在 UI 的「发布计划」页做）：
     ```bash
     curl -s -X POST http://127.0.0.1:8060/api/admin/publish-plans/execute \
       -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
       -d '{"packages":[{"organization":"demo","name":"encryptUtils","version":"1.0.0"}],
            "target_url":"http://127.0.0.1:8061","target_token":"<B 仓发布 Token>"}'
     ```
  4. 打开 B 仓 `http://127.0.0.1:8061/api/packages?size=50`，展示包已到位（含依赖）。
- **解说**：
  > 「多仓是本项目的重点：上游按优先级依次回源，索引与制品都会缓存到本地；
  > `resolve` 端点把候选版本、SHA 冲突和裁决过程全部摊开，便于排障。
  > 发布计划会先算依赖拓扑并四分类，再按序把包推到目标仓——刚才 3 个包（含 2 个依赖）一次推完。」

### 镜头 5｜权限：组织与团队 2:35–3:15

- **操作**：
  1. **组织管理**：展示 `demo` 组织（默认标记），新增一个 `tools` 组织演示创建/校验；
  2. **团队管理**：新建团队 `demo-writers`，权限选 `write`，关联组织 `demo`，成员加 `bob`；
  3. 终端演示越权被拒 → 加入团队后成功：
     ```bash
     # bob 的发布 Token 在门户 /me 领取（或用 POST /api/user/me/publish-token 重置）
     # 注意：必须发一个「新版本」（如 1.0.1）——同版本同 sha 是幂等的，不会触发权限检查
     cp -r .demo/pkgs/strUtils /tmp/bob-pkg && cd /tmp/bob-pkg
     sed -i 's/version = "1.0.0"/version = "1.0.1"/' cjpm.toml
     sed -i "s/^    token = .*/    token = \"<bob 的发布 Token>\"/" cangjie-repo.toml
     cjpm publish
     # 预期输出（实测）：
     #   Error: strUtils-1.0.1 to organization 'demo' publish failed with status 403: permission denied
     ```
  4. 切回管理后台 **审计日志 → 发布**：能看到 `bob / demo/strUtils / 失败 / forbidden: no permission to publish`；
     再把 bob 加入 `demo-writers`（write）团队后重试同一命令 → `cjpm publish success`，审计多一条成功记录。
- **解说**：
  > 「发布权限走双路径裁决：包的所有者（首个发布者）默认有写权限；
  > 其他人必须通过团队授权，团队可以关联到组织或具体包，权限分 read、write、overwrite 三级。
  > 刚才 bob 未授权时发布被 403 拒绝，加入 write 团队后立即生效。」

### 镜头 6｜用户门户 3:15–3:45

- **操作**：`http://127.0.0.1:8060/user/login` 用 `alice` 登录 → `/me` 页面自上而下滚动：发布 Token（只显示自己的）、我的包（含 owner 标记）、我的团队与权限、`cangjie-repo.toml` 示例。
- **解说**：
  > 「普通用户有独立门户：领取/重置自己的发布 Token、查看自己发布过的包和所属团队权限，
  > 页面里的示例配置直接读服务端配置，复制即用——不需要管理员代为配置。」

### 镜头 7｜审计与公开 API 3:45–4:15

- **操作**：
  1. 管理后台 **审计日志**：类型切「发布」看成功记录（含 IP/UA），再切「认证」看一次失败登录，演示关键字筛选与「清理日志」弹窗（可取消）；
  2. 终端：
     ```bash
     curl -s http://127.0.0.1:8060/api/stats | python3 -m json.tool
     curl -s "http://127.0.0.1:8060/api/packages?q=demo::&size=5" | python3 -m json.tool | head -25
     ```
- **解说**：
  > 「所有发布、认证和管理操作都落审计：操作者、对象、结果、IP 和 User-Agent，支持按类型、结果、关键字和时间过滤，也能按范围清理。
  > 另外提供公开只读 API：统计数据、包列表与详情、组织列表，方便对接门户或监控。」

### 镜头 8｜三级删除 4:15–4:40

- **操作**：在 **包管理 → 版本** 弹窗里对 `demo::strUtils@1.0.0`：
  1. 点「软删除」→ 终端 `curl -o /dev/null -w '%{http_code}' .../pkg/strUtils/1.0.0?organization=demo` 返回 **404**；
  2. 点「恢复」→ 同一条命令返回 **200**；
  3. 再「软删除」→「硬删除」→ 终端 `ls data-a/blobs | grep <sha>` 已无该制品。
- **解说**：
  > 「删除分三级：软删除只标记，索引和下载立刻不可见但制品保留，可随时恢复——恢复时还会校验制品是否还在；
  > 硬删除需要先软删，会同时删掉制品文件，并写进审计。这样既防误删，也能真正释放空间。」

### 镜头 9｜收尾 4:40–5:00

- **画面**：GitHub Release 页（`v0.1.0` 的三个产物）+ ghcr 镜像页 + 文档站 `https://ystyle.top/cjreg/`，最后一屏文字卡：
  `静态单二进制 · Docker/Compose · 179 项单测 · 9 步端到端验证 · MIT`
- **解说**：
  > 「项目以 tag 驱动发版：推一个 tag 就产出二进制、GitHub Release 和容器镜像；
  > 仓库带 179 项单元测试和 9 步双仓端到端脚本，文档站有完整指南与 API 说明。谢谢观看。」

## 4. 可裁剪 / 可加长的段落

| 情况 | 建议 |
|---|---|
| 只有 3 分钟 | 删镜头 4 的 resolve 诊断、镜头 5 的组织创建、镜头 8 的「恢复」演示；保留部署→发布→推送→权限→审计主线 |
| 可到 6 分钟 | 加：发布计划四分类输出（`analyze` 完整 JSON）、上游缓存命中（第二次下载走本地）、`/api/admin/packages/:id/restore` 的 409 制品丢失守卫、容器优雅关闭（`docker stop` 日志） |
| 决赛加料 | 加：发布计划 item 六态与进度流（SSE）、大包流式发布（内存曲线）、多架构镜像 `linux/arm64` |

## 5. 录后自检

- [ ] 时长 4:30–5:00，分辨率 1080p，音量一致（无爆音/底噪）
- [ ] 中文字幕与解说同步；专有名词统一：**中心仓**、**团队**、**审计日志**、**发布计划**、**三级删除**
- [ ] 无敏感信息（真实 Token、口令、内网地址、其他项目）
- [ ] 视频文件命名：`cjreg-演示视频-v0.1.0.mp4`；同时导出 封面图 `cover.png`
- [ ] 配合统一作品提交模板 PDF：把本脚本 §2 的复现命令、§3 的时间轴、`docs/verification.md` 的实测数据一并附上（技术课题要求「实验过程 / 验证方法 / 数据或结果 / 复现说明」）

## 6. 复现说明（给评审看）

```bash
# 环境：Linux x86_64、仓颉 1.1.3（cjc/cjpm）+ stdx、Docker 24+
git clone https://atomgit.com/ystyle/cjreg && cd cjreg
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"

cjpm test -j 16 --no-progress          # 179 项单元测试
bash tests/e2e.sh                      # 9 步双仓端到端（含审计、公开 API、三级删除、组织 CRUD）
CJREG_DEMO_PORT=18080 CJREG_DEMO_RESET=1 bash scripts/demo-data.sh   # 本视频的演示环境

# 或直接用发布镜像
docker pull ghcr.io/ystyle/cjreg:v0.1.0
```
