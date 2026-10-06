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

shot_web() {  # <kind: web|web-admin|web-user> <shot> <path> [secs] [user] [pass]
  local kind="$1" shot="$2" path="$3" secs="${4:-8}" user="${5:-}" pass="${6:-}"
  local frames="$REC/frames-$shot" out="$REC/web-$shot.mp4" url port="${CJREG_REC_CDP_PORT:-9222}"
  case "$kind" in
    web-admin) url="$MAIN/admin$path"; user="${user:-admin}"; pass="${pass:-__REDACTED__}" ;;
    web-user)  url="$MAIN$path" ;;
    *)         url="$MAIN$path" ;;
  esac
  case "$path" in http://*|https://*) url="$path" ;; esac
  ensure_chrome
  say "web 轨（CDP PNG 无损）$shot → $url"
  if [ -n "$user" ]; then
    local tok; tok=$(login_token "$user" "$pass")
    [ -n "$tok" ] || warn "登录失败（$user），页面可能停在登录页"
    agent-browser --cdp "$port" open "$MAIN/admin/login" >/dev/null 2>&1
    agent-browser --cdp "$port" eval "localStorage.setItem('cjxt_token','$tok')" >/dev/null 2>&1
  fi
  agent-browser --cdp "$port" open "$url" >/dev/null 2>&1
  sleep 2
  "$TOOLS/venv/bin/python" "$ROOT/scripts/cdp-record.py" rec "$frames" \
    --port "$port" --interval "${CJREG_REC_INTERVAL:-100}" \
    > "$ROOT/.qa-shots/rec-$shot.log" 2>&1 &
  local rec_pid=$!
  sleep 1
  agent-browser --cdp "$port" scroll down 500 >/dev/null 2>&1 || true
  sleep 2
  agent-browser --cdp "$port" scroll up 500 >/dev/null 2>&1 || true
  sleep $(( secs > 6 ? secs - 6 : 1 ))
  kill -TERM "$rec_pid" 2>/dev/null; sleep 1; wait "$rec_pid" 2>/dev/null
  "$TOOLS/venv/bin/python" "$ROOT/scripts/cdp-record.py" mp4 "$frames" "$out" || die "合成失败：$frames"
  [ "${CJREG_REC_KEEP_FRAMES:-0}" = "1" ] || rm -rf "$frames"
  say "完成：$out"
}

shot_web_login() {  # <shot> <login-path> <target-path> <user> <pass> [secs]
  # 录"真实登录"过程：填表 → 提交 → 进入目标页。比注入 token 更贴近演示，
  # 也不依赖某个端点的 token 语义（普通用户走 /api/admin/login 拿不到会话）。
  local shot="$1" lpath="$2" tpath="$3" user="$4" pass="$5"
  local out="$REC/web-$shot.mp4" lurl="$MAIN$lpath" turl="$MAIN$tpath"
  local frames="$REC/frames-$shot" port="${CJREG_REC_CDP_PORT:-9222}"
  agent-browser set viewport "${CJREG_REC_W:-1920}" "${CJREG_REC_H:-1080}" >/dev/null 2>&1 || true
  say "web 轨（真实登录）$shot → $lurl ⇒ $turl"
  rm -f "$out"
  ensure_chrome
  agent-browser --cdp "$port" open "$lurl" >/dev/null 2>&1; sleep 2
  "$TOOLS/venv/bin/python" "$ROOT/scripts/cdp-record.py" rec "$frames" --port "$port" --interval "${CJREG_REC_INTERVAL:-100}" > "$ROOT/.qa-shots/rec-$shot.log" 2>&1 &
  local rec_pid=$!
  sleep 1
  # 选择器实测：Element Plus 的 label 没有 for 关联（find label 定位不到），
  # 而页面上的「管理员登录入口」按钮文本也含「登录」——用 find role button 会点错。
  # 可靠组合：type 选择器填表 + 回车提交 + 主按钮 CSS。
  agent-browser --cdp "$port" fill 'input[type=text]' "$user" >/dev/null 2>&1 || warn "用户名填写失败"
  agent-browser --cdp "$port" fill 'input[type=password]' "$pass" >/dev/null 2>&1 || warn "密码填写失败"
  sleep 1
  agent-browser --cdp "$port" press Enter >/dev/null 2>&1 || true
  sleep 2
  agent-browser --cdp "$port" click 'button.el-button--primary' >/dev/null 2>&1 || true
  sleep 3
  agent-browser --cdp "$port" open "$turl" >/dev/null 2>&1
  sleep 3
  agent-browser --cdp "$port" scroll down 400 >/dev/null 2>&1 || true
  sleep 2
  kill -TERM "$rec_pid" 2>/dev/null; sleep 1; wait "$rec_pid" 2>/dev/null
  "$TOOLS/venv/bin/python" "$ROOT/scripts/cdp-record.py" mp4 "$frames" "$out" || die "合成失败：$frames"
  [ "${CJREG_REC_KEEP_FRAMES:-0}" = "1" ] || rm -rf "$frames"
  say "完成：$out"
}

# 界面操作镜头：打开页面 → 开录 → 逐条执行 .demo/ops/<shot>.ops 里的 agent-browser 命令。
# ops 文件是纯命令行（# 注释、sleep N、其余原样交给 agent-browser），便于逐条改与复现。
shot_web_ops() {  # <shot> <path> [secs]
  local shot="$1" path="$2" secs="${3:-12}"
  local ops="$ROOT/.demo/ops/web-$shot.ops" frames="$REC/frames-$shot" out="$REC/web-$shot.mp4"
  local port="${CJREG_REC_CDP_PORT:-9222}" url
  case "$path" in http://*|https://*) url="$path" ;; *) url="$MAIN/admin$path" ;; esac
  [ -f "$ops" ] || die "缺少操作脚本：$ops"
  ensure_chrome
  say "web 轨（界面操作）$shot → $url"
  local tok; tok=$(login_token admin "${CJREG_LIVE_ADMIN_PASS:-__REDACTED__}")
  agent-browser --cdp "$port" open "$MAIN/admin/login" >/dev/null 2>&1
  agent-browser --cdp "$port" eval "localStorage.setItem('cjxt_token','$tok')" >/dev/null 2>&1
  agent-browser --cdp "$port" open "$url" >/dev/null 2>&1
  sleep 2
  "$TOOLS/venv/bin/python" "$ROOT/scripts/cdp-record.py" rec "$frames" \
    --port "$port" --interval "${CJREG_REC_INTERVAL:-100}" \
    > "$ROOT/.qa-shots/rec-$shot.log" 2>&1 &
  local rec_pid=$!
  sleep 1
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    [ -z "${line//[[:space:]]/}" ] && continue
    case "$line" in
      sleep\ *) sleep "${line#sleep }" ;;
      *) eval "agent-browser --cdp $port $line" >/dev/null 2>&1 || true ;;
    esac
  done < "$ops"
  sleep 1
  kill -TERM "$rec_pid" 2>/dev/null; sleep 1; wait "$rec_pid" 2>/dev/null
  "$TOOLS/venv/bin/python" "$ROOT/scripts/cdp-record.py" mp4 "$frames" "$out" || die "合成失败：$frames"
  [ "${CJREG_REC_KEEP_FRAMES:-0}" = "1" ] || rm -rf "$frames"
  say "完成：$out"
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
    local label shot order
    order="${CJREG_REC_ORDER:-term-02-deploy web-03-portal web-03-packages web-03-docs pip-03-publish web-04-upstreams web-04-plan-list web-04-plan-create web-04-plan-run web-04-target web-05-org pip-05-permission web-06-me web-07-logs term-07-audit-api web-08-delete}"
    for shot in $order; do
      local f="$REC/$shot.mp4"
      [ -f "$f" ] || continue
      local base="$shot"
      local dur; dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f" 2>/dev/null | cut -d. -f1)
      local track="终端"
      case "$base" in
        web-*) track="Web 界面" ;;
        pip-*) track="同屏（画中画）" ;;
      esac
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
        04-plan-list) label="发布计划列表（状态 / 目标上游 / 进度）" ;;
        04-plan-create) label="创建发布计划（选包 → 自动补依赖 → 版本对照）" ;;
        04-plan-run) label="计划详情：开始执行 / 推送进度" ;;
        pip-03-publish) label="发布同屏：终端 cjpm publish ＋ 后台包管理（画中画）" ;;
        pip-05-permission) label="越权同屏：组织管理 ＋ 终端 403（画中画）" ;;
        *)          label="$shot" ;;
      esac
      echo "| $shot | $track | \`$(realpath --relative-to="$ROOT" "$f")\` | $dur | $label | 见 §3 对应镜头 |"
    done
  } > "$out"
  say "已生成 $out"
}

# 画中画合成：浏览器画面为主，终端回放做右下角小窗（带标题栏）。
# 用于「终端操作 + 对应界面」的配对镜头，让观众同屏看到"命令生效了"。
cmd_pip() {  # <主镜头> <小窗镜头> <输出名> [小窗标题]
  local main="$1" pip="$2" out_shot="$3" title="${4:-终端}"
  local mf="$REC/$main.mp4" pf="$REC/$pip.mp4" out="$REC/$out_shot.mp4"
  [ -f "$mf" ] || die "缺主镜头素材：$mf"
  [ -f "$pf" ] || die "缺小窗素材：$pf"
  local font=/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc
  local title_esc="${title//:/\\:}"   # ffmpeg filter 里 : 是分隔符，标题必须转义
  say "画中画：$main（主） + $pip（右下小窗）→ $out_shot"
  ffmpeg_run -y -v error -i "$mf" -i "$pf" -filter_complex \
"[1:v]scale=720:-2,pad=752:ih+72:16:40:color=0x181825,\
drawbox=x=16:y=16:w=720:h=28:color=0x313244:t=fill,\
drawbox=x=30:y=24:w=9:h=9:color=0xf38ba8:t=fill,\
drawbox=x=45:y=24:w=9:h=9:color=0xf9e2af:t=fill,\
drawbox=x=60:y=24:w=9:h=9:color=0xa6e3a1:t=fill,\
drawbox=x=16:y=40:w=736:h=ih-24:color=0x585b70:t=2,\
drawtext=fontfile=$font:text='$title_esc':x=82:y=21:fontsize=16:fontcolor=0xcdd6f4[t];\
[0:v][t]overlay=W-w-40:H-h-40:shortest=1[out]" -map "[out]" \
    -c:v libx264 -crf 18 -pix_fmt yuv420p -movflags +faststart "$out" || die "画中画合成失败"
  [ -s "$out" ] || die "画中画产物为空：$out"
  say "完成：$out"
}

cmd_preview() {  # 按演示顺序拼接成片（各轨分辨率不同，统一 pad 到 1080p）
  local order="${CJREG_REC_ORDER:-term-02-deploy web-03-portal web-03-packages web-03-docs pip-03-publish web-04-upstreams web-04-plan-list web-04-plan-create web-04-plan-run web-04-target web-05-org pip-05-permission web-06-me web-07-logs term-07-audit-api web-08-delete}"
  local out="$REC/preview-all.mp4" args=() fc="" n=0
  for shot in $order; do
    [ -f "$REC/$shot.mp4" ] || { warn "缺素材：$shot.mp4（跳过）"; continue; }
    args+=(-i "$REC/$shot.mp4")
    fc="$fc[$n:v]scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1[v$n];"
    n=$((n+1))
  done
  [ "$n" -gt 0 ] || die "没有可拼接的素材"
  local labels=""; for i in $(seq 0 $((n-1))); do labels="$labels[v$i]"; done
  fc="${fc}${labels}concat=n=$n:v=1:a=0[out]"
  say "拼接 $n 格 → $out"
  ffmpeg_run -y -v error "${args[@]}" -filter_complex "$fc" -map "[out]" \
    -c:v libx264 -crf 18 -pix_fmt yuv420p -movflags +faststart "$out"
  say "完成：$out（$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out" | cut -d. -f1)s）"
}

cmd_list() { ls -la "$REC" 2>/dev/null | tail -n +2; }

case "${1:-help}" in
  prepare)  cmd_prepare ;;
  term)     shot_term "${2:?usage: term <shot>}" ;;
  web-ops)  shot_web_ops "${2:?usage: web-ops <shot> <admin-path> [secs]}" "${3:?}" "${4:-12}" ;;
  web-login) shot_web_login "${2:?usage: web-login <shot> <login-path> <target-path> <user> <pass>}" "${3:?}" "${4:?}" "${5:?}" "${6:?}" ;;
  web|web-admin|web-user) shot_web "$1" "${2:?usage: $1 <shot> <path> [secs] [user] [pass]}" "${3:?path required}" "${4:-8}" "${5:-}" "${6:-}" ;;
  convert)  cmd_convert ;;
  timeline) cmd_timeline ;;
  pip)      cmd_pip "${2:?usage: pip <main-shot> <pip-shot> <out-shot> [title]}" "${3:?}" "${4:?}" "${5:-终端}" ;;
  preview)  cmd_preview ;;
  list)     cmd_list ;;
  *)        sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
