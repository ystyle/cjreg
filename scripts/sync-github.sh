#!/usr/bin/env bash
# 把 AtomGit 主仓库的 master 与 tag 手动同步到 GitHub 镜像。
#
# 背景：GitHub 仓库是 AtomGit 的**推送镜像**，正常情况下 tag/分支会自动同步过去，
# GitHub Actions（ci.yml / docs-deploy.yml / release.yml）据此触发。
# 但该镜像服务实测会长时间停滞（出现过 90 分钟不推进），此时 master 上的提交
# 在 GitHub 侧缺失，CI/文档站/Release 都不会跑 —— 用本脚本兜底。
#
# 用法：
#   bash scripts/sync-github.sh              # 同步 master + 所有本地 tag
#   bash scripts/sync-github.sh v0.1.0       # 只同步 master + 指定 tag
#   GH_SLUG=ystyle/cjreg bash scripts/sync-github.sh
#
# 特性：幂等（已一致时输出 up-to-date）、只做快进、绝不 force（不覆盖已发布的 tag）。
set -euo pipefail

GH_SLUG="${GH_SLUG:-ystyle/cjreg}"
BRANCH="${BRANCH:-master}"

if ! command -v gh >/dev/null 2>&1; then
  echo "错误：未找到 gh 命令（需要 gh auth login 后的 GitHub CLI）" >&2
  exit 1
fi
TOKEN="$(gh auth token 2>/dev/null || true)"
if [ -z "$TOKEN" ]; then
  echo "错误：gh 未登录，先执行 gh auth login" >&2
  exit 1
fi
URL="https://x-access-token:${TOKEN}@github.com/${GH_SLUG}.git"

cd "$(dirname "$0")/.."

echo "== 本地 =="
echo "分支 ${BRANCH} = $(git rev-parse --short "$BRANCH")"
echo "远程镜像 head = $(gh api "repos/${GH_SLUG}/commits" --jq '.[0].sha[0:7]' 2>/dev/null || echo '（读取失败）')"

# 沙箱/容器里 $HOME 可能只读，凭据助手会打印一行无害告警，这里静默掉。
export GIT_TERMINAL_PROMPT=0

# 推送一个 refspec，失败即中止；凭据助手告警不算失败。
push_ref() {
  local spec="$1" out
  if ! out="$(git push "$URL" "$spec" 2>&1)"; then
    printf '%s\n' "$out" | grep -v 'unable to get credential storage lock' >&2 || true
    return 1
  fi
  printf '%s\n' "$out" | grep -v 'unable to get credential storage lock' || true
  return 0
}

echo
echo "== 同步分支 ${BRANCH} =="
push_ref "${BRANCH}:${BRANCH}" || { echo "错误：分支 ${BRANCH} 推送失败（非快进？先确认主仓库与本地一致）" >&2; exit 1; }
echo "分支同步完成：$(git rev-parse --short "$BRANCH")"

if [ "$#" -gt 0 ]; then
  TAGS=("$@")
else
  mapfile -t TAGS < <(git tag --list 'v*' | sort -V)
fi

if [ "${#TAGS[@]}" -eq 0 ]; then
  echo
  echo "== 没有需要同步的 tag =="
else
  echo
  echo "== 同步 tag（${#TAGS[@]} 个）=="
  for t in "${TAGS[@]}"; do
    if [ "$(git rev-parse -q --verify "refs/tags/$t" 2>/dev/null)" = "" ]; then
      echo "  $t 跳过：本地不存在该 tag"
      continue
    fi
    local_sha="$(git rev-parse "refs/tags/$t^{commit}" 2>/dev/null || git rev-parse "refs/tags/$t")"
    remote_sha="$(gh api "repos/${GH_SLUG}/git/ref/tags/$t" --jq '.object.sha' 2>/dev/null || echo '')"
    if [ "$remote_sha" = "$local_sha" ]; then
      echo "  $t 已一致（$(git rev-parse --short "$local_sha")）"
      continue
    fi
    if ! push_ref "refs/tags/$t:refs/tags/$t"; then
      echo "  $t 推送失败：镜像侧已有同名 tag 且指向不同提交（本脚本不 force 覆盖已发布 tag）" >&2
      exit 1
    fi
    echo "  $t 已推送（$(git rev-parse --short "$local_sha")）"
  done
fi

echo
echo "== 校验 =="
echo "远程镜像 head = $(gh api "repos/${GH_SLUG}/commits" --jq '.[0].sha[0:7]' 2>/dev/null || echo '（读取失败）')"
echo "最近运行："
gh run list -R "$GH_SLUG" -L 5 --json databaseId,name,status,conclusion,headSha \
  --jq '.[] | "  \(.name) \(.status)/\(.conclusion // "-") \(.headSha[0:7])"' 2>/dev/null || true
