# 发版流程（tag 驱动）

cjreg 的发版以 **tag 为唯一事实来源**：主仓库在 AtomGit，`git push origin vX.Y.Z` 会把同一个 tag
同步到 GitHub 镜像，GitHub Actions 的 `Release` 工作流据此构建产物、自动生成 GitHub Release 并推送容器镜像。
这样不会出现「只在 GitHub 发 Release、AtomGit 侧没有对应 tag」的两边不一致。

## 1. 前置检查（打 tag 之前）

```bash
# 工作区干净、master 与远程一致
git status --short && git pull --ff-only
# 单测 + 双仓 e2e 全绿
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"
cjpm test -j 16 --no-progress
bash tests/e2e.sh
# 版本号一致（三处）
grep -n "version" cjpm.toml
grep -n "^## \[" CHANGELOG.md | head -3
grep -n "CJREG_SERVER_VERSION" src/server/public_service.cj
```

`CHANGELOG.md` 把 `## [Unreleased]` 的内容整理到 `## [X.Y.Z] - YYYY-MM-DD`，
并把 `src/server/public_service.cj` 的 `CJREG_SERVER_VERSION` 改成同一版本号（`GET /api/stats` 会输出它）。

## 2. 打 tag 并推送

```bash
git checkout master
git tag -a v0.2.0 -m "v0.2.0"
git push origin v0.2.0        # AtomGit（主仓库）
```

GitHub 镜像同步到该 tag 后，`Release` 工作流自动执行：

| job | 产物 |
|---|---|
| `linux-amd64` | `cjreg_vX.Y.Z_linux_amd64.tar.gz`（二进制）、`cjreg_vX.Y.Z_public.tar.gz`（Web 静态资源）→ 上传到自动创建的 GitHub Release |
| `container` | 镜像 `ghcr.io/ystyle/cjreg:vX.Y.Z` 与 `ghcr.io/ystyle/cjreg:latest` |

## 3. 校验

```bash
gh run list --repo ystyle/cjreg --workflow release.yml --limit 3
gh release view v0.2.0 --repo ystyle/cjreg          # 产物列表
docker pull ghcr.io/ystyle/cjreg:v0.2.0 && docker run --rm ghcr.io/ystyle/cjreg:v0.2.0 /app/cjreg --help
```

> ghcr 镜像默认继承仓库可见性（私有仓库 → 私有镜像）。需要公开拉取时在
> GitHub → Packages → `cjreg` → Package settings 里改为 public。
> 私有镜像拉取需 `docker login ghcr.io -u <用户名> -p <PAT>`（PAT 勾选 `read:packages`）。

## 4. 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| tag 推了但工作流没跑 | tag 未同步到 GitHub：检查 AtomGit→GitHub 的 tag 同步；必要时在 GitHub 侧补推同一个 tag（`git push github v0.2.0`），tag 名保持一致即可 |
| `Release` 报 `fail_on_unmatched_files` | 构建产物路径变化：确认 `cjreg/dist/*` 有文件（工作流里 `ls -lh dist` 的步骤会打印） |
| 镜像推 403 | 仓库 Settings → Actions → General 的 Workflow permissions 需要 Read and write，job 里已声明 `packages: write` |
| `GET /api/stats` 版本号不对 | 忘了改 `CJREG_SERVER_VERSION`（见 §1） |

## 5. 与 CI 的分工

- `ci.yml`：master 推送/PR → 构建 + 单测 + 覆盖率 + 双仓 e2e + 文档站 + **本地**镜像冒烟（不推送镜像）
- `docs-deploy.yml`：master 推送 → 文档站发布到 GitHub Pages + CDN 刷新
- `release.yml`：**tag 推送** → 二进制产物 + GitHub Release + ghcr 镜像推送

CI 里镜像冒烟的意义在于：容器能否启动、`/api/health` 是否健康、`docker stop` 是否走优雅关闭、重启后数据是否留存——
这些都在发布镜像之前就被验证过一遍。
