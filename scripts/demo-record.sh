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
  local ops="$ROOT/scripts/demo-ops/web-$shot.ops" frames="$REC/frames-$shot" out="$REC/web-$shot.mp4"
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
    order="${CJREG_REC_ORDER:-term-02-deploy web-03-portal web-03-packages web-03-docs term-03-resolve pip-03-publish web-04-upstreams web-04-plan-list web-04-plan-create web-04-plan-run web-04-target web-05-org pip-05-permission web-06-me web-07-logs term-07-audit-api web-08-delete}"
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
      local label; label=$(shot_label "$shot")
      echo "| $shot | $track | \`$(realpath --relative-to="$ROOT" "$f")\` | $dur | $label | 见 §3 对应镜头 |"
    done
  } > "$out"
  say "已生成 $out"
}

# 画中画合成：主画面（浏览器）定格，终端回放做右下角小窗。
#
# 主画面支持**两段**：<before> → <after>，切换点在 CJREG_PIP_SWITCH（默认 0.6 = 小窗 60% 处）。
# 为什么要两段：发布类镜头如果一上来主画面就有这个包，观众看到的是"先有结果后有操作"；
# 正确时序是「主画面：还没有这个包 → 小窗跑完发布 → 主画面：包出现了」。
# before 与 after 传同一个镜头名即为单段（普通同屏镜头）。
# 取某素材 60% 处的一帧（避开开头可能还在加载的画面）
pip_still() {  # <源> <输出png>
  local d; d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$1")
  local mid; mid=$(awk "BEGIN{printf \"%.2f\", $d*0.6}")
  ffmpeg_run -y -v error -ss "$mid" -i "$1" -frames:v 1 "$2"
}

cmd_pip() {  # <主画面before> <主画面after> <小窗镜头> <输出名> [小窗标题]
  local mb="$1" ma="$2" pip="$3" out_shot="$4" title="${5:-终端}"
  local mbf="$REC/$mb.mp4" maf="$REC/$ma.mp4" pf="$REC/$pip.mp4" out="$REC/$out_shot.mp4"
  [ -f "$mbf" ] || die "缺主画面素材：$mbf"
  [ -f "$maf" ] || die "缺主画面素材：$maf"
  [ -f "$pf" ] || die "缺小窗素材：$pf"
  local font=/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc
  local title_esc="${title//:/\\:}"   # ffmpeg filter 里 : 是分隔符，标题必须转义
  local dur; dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$pf")
  local win="[1:v]scale=720:-2,pad=752:ih+72:16:40:color=0x181825,\
drawbox=x=16:y=16:w=720:h=28:color=0x313244:t=fill,\
drawbox=x=30:y=24:w=9:h=9:color=0xf38ba8:t=fill,\
drawbox=x=45:y=24:w=9:h=9:color=0xf9e2af:t=fill,\
drawbox=x=60:y=24:w=9:h=9:color=0xa6e3a1:t=fill,\
drawbox=x=16:y=40:w=736:h=ih-24:color=0x585b70:t=2,\
drawtext=fontfile=$font:text='$title_esc':x=82:y=21:fontsize=16:fontcolor=0xcdd6f4[t];\
[0:v][t]overlay=W-w-40:H-h-40[out]"
  local sb="$REC/.pip-b-$out_shot.png" sa="$REC/.pip-a-$out_shot.png"
  pip_still "$mbf" "$sb" || die "抽 before 定帧失败"
  pip_still "$maf" "$sa" || die "抽 after 定帧失败"
  local t1; t1=$(awk "BEGIN{printf \"%.3f\", $dur*${CJREG_PIP_SWITCH:-0.6}}")
  local t2; t2=$(awk "BEGIN{printf \"%.3f\", $dur-$t1}")
  if [ "$mb" = "$ma" ]; then
    say "画中画（单段主画面）：$mb ＋ $pip → $out_shot"
    ffmpeg_run -y -v error -loop 1 -i "$sb" -i "$pf" -filter_complex "$win" -map "[out]" \
      -t "$dur" -r 30 -c:v libx264 -crf 18 -pix_fmt yuv420p -movflags +faststart "$out" || die "画中画合成失败"
  else
    say "画中画（主画面两段 $mb → $ma，切换点 ${t1}s）：＋ $pip → $out_shot"
    ffmpeg_run -y -v error -loop 1 -i "$sb" -i "$pf" -filter_complex "$win" -map "[out]" \
      -t "$t1" -r 30 -c:v libx264 -crf 18 -pix_fmt yuv420p "$REC/.pip-seg1.mp4" || die "段1 合成失败"
    ffmpeg_run -y -v error -loop 1 -i "$sa" -ss "$t1" -i "$pf" -filter_complex "$win" -map "[out]" \
      -t "$t2" -r 30 -c:v libx264 -crf 18 -pix_fmt yuv420p "$REC/.pip-seg2.mp4" || die "段2 合成失败"
    local xf=0.4 xo; xo=$(awk "BEGIN{printf \"%.3f\", $t1-$xf}")
    ffmpeg_run -y -v error -i "$REC/.pip-seg1.mp4" -i "$REC/.pip-seg2.mp4" \
      -filter_complex "[0:v][1:v]xfade=transition=fade:duration=$xf:offset=$xo[v]" -map "[v]" \
      -r 30 -c:v libx264 -crf 18 -pix_fmt yuv420p -movflags +faststart "$out" || die "两段拼接失败"
    rm -f "$REC/.pip-seg1.mp4" "$REC/.pip-seg2.mp4"
  fi
  rm -f "$sb" "$sa"
  [ -s "$out" ] || die "画中画产物为空：$out"
  say "完成：$out"
}

cmd_preview() {  # 按演示顺序拼接成片（各轨分辨率不同，统一 pad 到 1080p）
  local order="${CJREG_REC_ORDER:-term-02-deploy web-03-portal web-03-packages web-03-docs term-03-resolve pip-03-publish web-04-upstreams web-04-plan-list web-04-plan-create web-04-plan-run web-04-target web-05-org pip-05-permission web-06-me web-07-logs term-07-audit-api web-08-delete}"
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

# 镜头中文名（字幕条与时间轴共用一份）
shot_label() {
  local k="${1#web-}"; k="${k#term-}"    # 素材名带轨前缀（web-/term-），pip- 属于镜头名本身
  case "$k" in
    02-deploy)         echo "部署：容器 / 数据卷 / 重启策略" ;;
    03-portal)         echo "门户首页" ;;
    03-packages)       echo "包列表：浏览与搜索仓颉包" ;;
    03-docs)           echo "内置帮助文档" ;;
    03-resolve)        echo "多仓解析：cd 源码目录 → cjpm update（私有仓 + 官方仓分工）" ;;
    pip-03-publish)    echo "发布：终端 cjpm publish ＋ 后台包管理（同屏）" ;;
    04-upstreams)      echo "上游管理：官方仓 / 演示空站" ;;
    04-plan-list)      echo "发布计划列表：状态 / 目标上游 / 进度" ;;
    04-plan-create)    echo "创建发布计划：选包 → 自动补依赖 → 版本对照" ;;
    04-plan-run)       echo "计划详情：开始执行 / 推送进度" ;;
    04-target)         echo "演示空站：推送后的结果" ;;
    05-org)            echo "组织与团队管理" ;;
    pip-05-permission) echo "权限：终端越权发布被拒 ＋ 组织管理（同屏）" ;;
    06-me)             echo "用户门户：发布 Token / 我的包 / 我的团队" ;;
    07-logs)           echo "审计日志" ;;
    07-audit-api)      echo "公开只读 API" ;;
    08-delete)         echo "三级删除：软删除 → 状态可见 → 恢复" ;;
    *)                 echo "$k" ;;
  esac
}

# 正式成片：片头卡 + 每格字幕条 + 交叉淡化转场 + 末尾定格留白 + 静音音轨（配音后替换）
# 转场为什么用 xfade 而不是各自 fade：两个 fade 相邻会叠出近 1 秒黑场，
# 首格又是终端命令，观众正好在这段看不清；xfade 是前格淡出与后格淡入重叠进行，无黑场。
# 末尾 tpad 定格：命令结果刚输出完就切走会读不完，统一补一段静帧留白。
cmd_final() {  # [输出名]
  local out="$REC/${1:-final}.mp4" tmp="$REC/.final"
  local font=/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc
  local trans="${CJREG_FINAL_XFADE:-0.5}"
  local hold="${CJREG_FINAL_HOLD:-1.6}"
  local order="${CJREG_REC_ORDER:-term-02-deploy web-03-portal web-03-packages web-03-docs term-03-resolve pip-03-publish web-04-upstreams web-04-plan-list web-04-plan-create web-04-plan-run web-04-target web-05-org pip-05-permission web-06-me web-07-logs term-07-audit-api web-08-delete}"
  rm -rf "$tmp"; mkdir -p "$tmp"
  say "片头卡"
  ffmpeg_run -y -v error -f lavfi -i "color=c=0x11111b:s=1920x1080:d=3.5" -vf \
"drawtext=fontfile=$font:text='cjreg':x=(w-text_w)/2:y=(h-text_h)/2-90:fontsize=120:fontcolor=0xcdd6f4,\
drawtext=fontfile=$font:text='仓颉私有中心仓与多仓工具':x=(w-text_w)/2:y=(h-text_h)/2+40:fontsize=44:fontcolor=0x9399b2,\
drawtext=fontfile=$font:text='发布 · 多仓解析 · 权限 · 发布计划 · 审计 · 三级删除':x=(w-text_w)/2:y=(h-text_h)/2+120:fontsize=28:fontcolor=0x6c7086,\
fade=in:0:20,settb=AVTB,fps=30" -c:v libx264 -crf 18 -pix_fmt yuv420p "$tmp/00-intro.mp4"
  local i=1 shot label
  for shot in $order; do
    [ -f "$REC/$shot.mp4" ] || { warn "缺素材：$shot"; continue; }
    label=$(shot_label "$shot")
    label=${label//:/\\:}
    ffmpeg_run -y -v error -i "$REC/$shot.mp4" -vf \
"scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,\
tpad=stop_mode=clone:stop_duration=$hold,\
drawbox=x=0:y=992:w=1920:h=88:color=0x000000@0.62:t=fill,\
drawtext=fontfile=$font:text='$label':x=64:y=1016:fontsize=30:fontcolor=0xffffff,\
settb=AVTB,fps=30" -c:v libx264 -crf 18 -pix_fmt yuv420p "$tmp/$(printf '%02d' "$i")-$shot.mp4" || die "处理 $shot 失败"
    i=$((i+1))
  done
  say "片尾卡"
  ffmpeg_run -y -v error -f lavfi -i "color=c=0x11111b:s=1920x1080:d=3" -vf \
"drawtext=fontfile=$font:text='谢谢观看':x=(w-text_w)/2:y=(h-text_h)/2-30:fontsize=72:fontcolor=0xcdd6f4,\
drawtext=fontfile=$font:text='cjreg · 仓颉私有仓':x=(w-text_w)/2:y=(h-text_h)/2+70:fontsize=32:fontcolor=0x9399b2,\
fade=out:st=2.5:d=0.5,settb=AVTB,fps=30" -c:v libx264 -crf 18 -pix_fmt yuv420p "$tmp/99-outro.mp4"

  local -a parts=() durs=() args=()
  for f in "$tmp"/*.mp4; do
    parts+=("$f")
    durs+=("$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f")")
    args+=(-i "$f")
  done
  local n=${#parts[@]}
  local fc="" prev="0:v" off
  off=$(awk "BEGIN{printf \"%.3f\", ${durs[0]}-$trans}")
  local k
  for ((k=1; k<n; k++)); do
    fc="$fc[$prev][$k:v]xfade=transition=fade:duration=$trans:offset=$off[v$k];"
    prev="v$k"
    off=$(awk "BEGIN{printf \"%.3f\", $off+${durs[$k]}-$trans}")
  done
  say "交叉淡化拼接 $n 段"
  ffmpeg_run -y -v error "${args[@]}" -f lavfi -i anullsrc=r=48000:cl=stereo \
    -filter_complex "${fc}[$prev]null[vout]" -map "[vout]" -map "$n:a" -shortest \
    -c:v libx264 -crf 18 -pix_fmt yuv420p -c:a aac -b:a 128k -movflags +faststart "$out" || die "成片合成失败"
  rm -rf "$tmp"
  local total; total=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$out" | cut -d. -f1)
  say "完成：$out（${total}s）"
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
  pip)      cmd_pip "${2:?usage: pip <before-shot> <after-shot> <pip-shot> <out-shot> [title]}" "${3:?}" "${4:?}" "${5:?}" "${6:-终端}" ;;
  preview)  cmd_preview ;;
  final)    cmd_final "${2:-final}" ;;
  list)     cmd_list ;;
  *)        sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//' ;;
esac
