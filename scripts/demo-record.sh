#!/usr/bin/env bash
# cjreg 演示录制脚手架
#
# 两条轨道（都不需要桌面会话）：
#   web  轨：agent-browser record（headless Chromium 自带录制，WebM，固定 10fps）
#   终端 轨：asciinema 录 .cast → agg 渲染 gif → ffmpeg 出 mp4
#
# 用法：
#   bash scripts/demo-record.sh prepare               # 演示环境就绪（清空演示上游站 + 幂等造数）
#   bash scripts/demo-record.sh term 02-deploy        # 录一格终端（脚本 .demo/shots/term-<shot>.sh）
#   bash scripts/demo-record.sh web 03-portal http://127.0.0.1:8066/ 8   # 录一格 web（秒数可省，默认 8）
#   bash scripts/demo-record.sh web-admin 03-pkgs /admin/packages 8      # 录后台页（先注入管理员登录态）
#   bash scripts/demo-record.sh web-user 06-me /me 8 alice AlicePass1    # 录用户门户（先注入该用户登录态）
#   bash scripts/demo-record.sh convert               # 全部 webm/cast → mp4
#   bash scripts/demo-record.sh timeline              # 生成配音时间轴表（docs/demo-record-timeline.md）
#   bash scripts/demo-record.sh list                  # 列出已录素材
#
# 产物：.demo/recordings/*.webm|.cast|.mp4；工具在 .tools/（asciinema venv + agg 静态二进制）
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
REC="$ROOT/.demo/recordings"
SHOTS="$ROOT/scripts/demo-shots"
TOOLS=/home/ystyle/Projects/Cangjie/.tools
ASCIINEMA="$TOOLS/venv/bin/asciinema"
AGG="$TOOLS/bin/agg"
MAIN="${CJREG_REC_MAIN:-http://127.0.0.1:8066}"
export AGENT_BROWSER_SOCKET_DIR="${AGENT_BROWSER_SOCKET_DIR:-$ROOT/.qa-shots/ab-socket}"
export AGENT_BROWSER_SESSION_NAME="${AGENT_BROWSER_SESSION_NAME:-cjreg-demo}"
mkdir -p "$REC" "$SHOTS" "$AGENT_BROWSER_SOCKET_DIR"

agg_run()    { env -u LD_LIBRARY_PATH "$TOOLS/bin/agg" "$@"; }
ffmpeg_run() { env -u LD_LIBRARY_PATH ffmpeg "$@"; }

say()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

login_token() {  # login_token <user> <pass>
  curl -s -m 8 -X POST "$MAIN/api/admin/login" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$1\",\"password\":\"$2\"}" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))" 2>/dev/null
}

shot_term() {  # shot_term <shot>  —— 例：term 02-deploy
  local shot="$1" script="$SHOTS/term-$1.sh"
  [ -f "$script" ] || die "镜头脚本不存在：$script"
  [ -x "$ASCIINEMA" ] || die "asciinema 缺失：$ASCIINEMA（装法见 docs/demo-video.md）"
  say "终端轨 $shot → $(.demo/recordings 2>/dev/null; echo "term-$shot.cast")"
  ( cd "$ROOT" && eval "$(cjvs env zsh)" >/dev/null 2>&1 && eval "$(cjvs stdx-env zsh)" >/dev/null 2>&1; \
    "$ASCIINEMA" rec --overwrite --quiet --cols "${CJREG_REC_COLS:-120}" --rows "${CJREG_REC_ROWS:-30}" \
      --command "bash '$script'" "$REC/term-$shot.cast" )
  say "渲染 mp4"
  agg_run --font-size "${CJREG_REC_FONT:-22}" --speed "${CJREG_REC_SPEED:-1.0}" --quiet \
    "$REC/term-$shot.cast" "$REC/term-$shot.gif" 2>/dev/null
  ffmpeg_run -y -v error -i "$REC/term-$shot.gif" -movflags +faststart -pix_fmt yuv420p \
    -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" "$REC/term-$shot.mp4"
  say "完成：$REC/term-$shot.mp4"
}

shot_web() {  # shot_web <kind: web|web-admin|web-user> <shot> <path> [secs] [user] [pass]
  local kind="$1" shot="$2" path="$3" secs="${4:-8}" user="${5:-}" pass="${6:-}"
  local out="$REC/web-$shot.webm" url
  case "$kind" in
    web-admin) url="$MAIN/admin$path"; user="${user:-admin}"; pass="${pass:-__REDACTED__}" ;;
    web-user)  url="$MAIN$path" ;;   # 门户页在根路径（/me），只有登录页在 /user/login
    *)         url="$MAIN$path" ;;
  esac
  # 允许直接给完整 URL（例如演示上游站在另一个端口）
  case "$path" in http://*|https://*) url="$path" ;; esac
  # 视口是会话级设置：不设会退回 1280x578
  agent-browser set viewport "${CJREG_REC_W:-1920}" "${CJREG_REC_H:-1080}" >/dev/null 2>&1 || true
  say "web 轨 $shot → $url（${secs}s）"
  rm -f "$out"
  # 顺序很关键（实测踩过两次）：
  #   ① record start 带 url 会新开 context → 注入的登录态不生效 → 录成登录页；
  #   ② 注入必须在页面**加载之前**（cjxt 是加载时读 localStorage 建 WS），
  #      所以先开录、再注入、再导航——录制里正好是「登录页 → 后台页」的真实过程。
  agent-browser open "$url" >/dev/null 2>&1
  sleep 1
  agent-browser record start "$out" >/dev/null 2>&1 || die "agent-browser record 启动失败"
  sleep 1
  if [ -n "$user" ]; then
    local tok; tok=$(login_token "$user" "$pass")
    [ -n "$tok" ] || warn "登录失败（$user），页面可能停在登录页"
    agent-browser eval "localStorage.setItem('cjxt_token','$tok')" >/dev/null 2>&1
    agent-browser open "$url" >/dev/null 2>&1
    sleep 4
  fi
  sleep 2
  # 轻微滚动让画面有动感（不改变页面语义）
  agent-browser scroll down 500 >/dev/null 2>&1 || true
  sleep 2
  agent-browser scroll up 500 >/dev/null 2>&1 || true
  sleep $(( secs > 4 ? secs - 4 : 1 ))
  agent-browser record stop >/dev/null 2>&1
  [ -s "$out" ] || die "录制产物为空：$out"
  say "转 mp4（10fps → 30fps 容器，便于后期配音对齐）"
  ffmpeg_run -y -v error -i "$out" -c:v libx264 -pix_fmt yuv420p -r 30 "$REC/web-$shot.mp4"
  say "完成：$REC/web-$shot.mp4"
}

shot_web_login() {  # <shot> <login-path> <target-path> <user> <pass> [secs]
  # 录"真实登录"过程：填表 → 提交 → 进入目标页。比注入 token 更贴近演示，
  # 也不依赖某个端点的 token 语义（普通用户走 /api/admin/login 拿不到会话）。
  local shot="$1" lpath="$2" tpath="$3" user="$4" pass="$5"
  local out="$REC/web-$shot.webm" lurl="$MAIN$lpath" turl="$MAIN$tpath"
  agent-browser set viewport "${CJREG_REC_W:-1920}" "${CJREG_REC_H:-1080}" >/dev/null 2>&1 || true
  say "web 轨（真实登录）$shot → $lurl ⇒ $turl"
  rm -f "$out"
  agent-browser open "$lurl" >/dev/null 2>&1; sleep 2
  agent-browser record start "$out" >/dev/null 2>&1 || die "agent-browser record 启动失败"
  sleep 1
  # 选择器实测：Element Plus 的 label 没有 for 关联（find label 定位不到），
  # 而页面上的「管理员登录入口」按钮文本也含「登录」——用 find role button 会点错。
  # 可靠组合：type 选择器填表 + 回车提交 + 主按钮 CSS。
  agent-browser fill 'input[type=text]' "$user" >/dev/null 2>&1 || warn "用户名填写失败"
  agent-browser fill 'input[type=password]' "$pass" >/dev/null 2>&1 || warn "密码填写失败"
  sleep 1
  agent-browser press Enter >/dev/null 2>&1 || true
  sleep 2
  agent-browser click 'button.el-button--primary' >/dev/null 2>&1 || true
  sleep 3
  agent-browser open "$turl" >/dev/null 2>&1
  sleep 3
  agent-browser scroll down 400 >/dev/null 2>&1 || true
  sleep 2
  agent-browser record stop >/dev/null 2>&1
  [ -s "$out" ] || die "录制产物为空：$out"
  env -u LD_LIBRARY_PATH ffmpeg -y -v error -i "$out" -c:v libx264 -pix_fmt yuv420p -r 30 "$REC/web-$shot.mp4"
  say "完成：$REC/web-$shot.mp4"
}

cmd_prepare() {
  say "演示环境：清空演示上游站 + 幂等造数"
  bash "$ROOT/scripts/demo-live.sh" reset-upstream
  CJREG_LIVE_ADMIN_PASS="${CJREG_LIVE_ADMIN_PASS:-__REDACTED__}" bash "$ROOT/scripts/demo-live.sh" prepare | tail -20
}

cmd_convert() {
  local n=0
  for f in "$REC"/*.webm; do
    [ -f "$f" ] || continue
    local o="${f%.webm}.mp4"; [ -f "$o" ] && continue
    ffmpeg_run -y -v error -i "$f" -c:v libx264 -pix_fmt yuv420p -r 30 "$o" && n=$((n+1))
  done
  for f in "$REC"/*.cast; do
    [ -f "$f" ] || continue
    local o="${f%.cast}.mp4"; [ -f "$o" ] && continue
    agg_run --font-size "${CJREG_REC_FONT:-22}" --quiet "$f" "${f%.cast}.gif" 2>/dev/null
    ffmpeg_run -y -v error -i "${f%.cast}.gif" -movflags +faststart -pix_fmt yuv420p \
      -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" "$o" && n=$((n+1))
  done
  say "新转换 $n 个 mp4"
}

cmd_timeline() {
  local out="$ROOT/docs/demo-record-timeline.md"
  {
    echo "# 演示录制素材与配音时间轴"
    echo
    echo "> 由 \`bash scripts/demo-record.sh timeline\` 生成；时长用 ffprobe 实测。"
    echo "> 配音：按每格的起止时间对着 \`docs/demo-video.md\` §3 的解说词念即可。"
    echo
    echo "| 镜头 | 轨 | 素材 | 时长(s) | 画面内容 | 配音提示（demo-video.md §3） |"
    echo "|---|---|---|---|---|---|"
    local label
    for f in "$REC"/*.mp4; do
      [ -f "$f" ] || continue
      local base; base=$(basename "$f" .mp4)
      local dur; dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null | cut -d. -f1)
      local track="终端"; case "$base" in web-*) track="Web 界面";; esac
      local shot; shot=$(printf '%s' "$base" | sed 's/^[a-z]*-//')
      case "$shot" in
        02-deploy)  label="部署（容器健康 / 数据卷 / 重启策略）" ;;
        03-portal)  label="门户首页与内置帮助" ;;
        03-publish) label="发布 demo::mathUtils@1.0.0" ;;
        03-pkgs)    label="管理后台：仪表盘 / 包管理" ;;
        04-upstreams) label="后台上游管理（official 与 demo-upstream）" ;;
        04-multirepo) label="解析诊断 + 发布计划推送" ;;
        04-target)  label="演示空站（推送后）" ;;
        05-org)     label="组织与团队管理" ;;
        05-permission) label="越权发布被 403 拒绝" ;;
        06-me)      label="用户门户 /me（发布 Token / 我的包）" ;;
        07-logs)    label="管理后台审计日志" ;;
        07-audit-api) label="公开只读 API + 审计" ;;
        08-delete)  label="三级删除（软删 404 / 恢复 200）" ;;
        *)          label="$shot" ;;
      esac
      echo "| $shot | $track | \`$(realpath --relative-to="$ROOT" "$f")\` | $dur | $label | 见 §3 对应镜头 |"
    done
  } > "$out"
  say "已生成 $out"
}

cmd_list() { ls -la "$REC" 2>/dev/null | tail -n +2; }

case "${1:-help}" in
  prepare)  cmd_prepare ;;
  term)     shot_term "${2:?usage: term <shot>}" ;;
  web-login) shot_web_login "${2:?usage: web-login <shot> <login-path> <target-path> <user> <pass>}" "${3:?}" "${4:?}" "${5:?}" "${6:?}" ;;
  web|web-admin|web-user) shot_web "$1" "${2:?usage: $1 <shot> <path> [secs] [user] [pass]}" "${3:?path required}" "${4:-8}" "${5:-}" "${6:-}" ;;
  convert)  cmd_convert ;;
  timeline) cmd_timeline ;;
  list)     cmd_list ;;
  *)        sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
