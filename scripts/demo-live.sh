#!/usr/bin/env bash
# cjreg 实时演示环境准备：生产主站 + 演示上游空站
#
# 与 scripts/demo-data.sh 的分工：
#   demo-data.sh  本机双仓全功能演示（A/B 两个本机进程，可 RESET）—— 开发自测与评审复现用
#   demo-live.sh  生产站（真实数据）当演示主站 + ~/docker/cjreg-demo 空站当上游/推送目标
#                 —— 录制「生产级」演示用：只做幂等造数，**绝不清空/重置主站**
#
# 用法：
#   bash scripts/demo-live.sh status          # 只读：两站健康 + 演示对象盘点
#   bash scripts/demo-live.sh prepare         # 造数：演示用户/组织、演示包目录、注册上游
#   bash scripts/demo-live.sh reset-upstream  # 清空重建演示上游站（它是演示专用实例）
#   bash scripts/demo-live.sh clean           # 从生产移除演示痕迹（上游 + demo::* 包）
#
# 凭据：主站管理员口令**不写在本仓**（仓库公开）。按优先级取：
#   CJREG_LIVE_ADMIN_PASS 环境变量，或 ~/.cjreg-live.env（chmod 600，脚本自动 source）：
#     CJREG_LIVE_ADMIN_PASS='<生产 admin 口令>'
#
# 可覆盖项：
#   CJREG_LIVE_MAIN=http://127.0.0.1:8066        主站（生产）
#   CJREG_LIVE_UPSTREAM=http://127.0.0.1:8067    演示上游站
#   CJREG_LIVE_UPSTREAM_DIR=~/docker/cjreg-demo  演示上游站的 compose 目录
#   CJREG_LIVE_UPSTREAM_NAME=demo-upstream       注册到主站的上游名
#   CJREG_LIVE_HOST_IP=192.168.3.6               宿主 LAN 地址（默认自动探测：生产 public_url → ip route）
#   CJREG_LIVE_UPSTREAM_FROM_MAIN=...            主站**容器内**访问演示上游站的地址（默认 http://$HOST_IP:<端口>）
#   CJREG_LIVE_PREPUBLISH=1                      顺带把 3 个演示包预发到主站（默认 0，留现场发）
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

MAIN="${CJREG_LIVE_MAIN:-http://127.0.0.1:8066}"
UP="${CJREG_LIVE_UPSTREAM:-http://127.0.0.1:8067}"

# 预发（CJREG_LIVE_PREPUBLISH=1）要用 cjpm：能加载 cjvs 环境就加载
if ! command -v cjpm >/dev/null 2>&1 && command -v cjvs >/dev/null 2>&1; then
  eval "$(cjvs env zsh)" >/dev/null 2>&1
  eval "$(cjvs stdx-env zsh)" >/dev/null 2>&1
fi

# 演示上游站有**两个视角**的地址，混用必然失败：
#   宿主视角（脚本、浏览器、curl）：$UP，如 http://127.0.0.1:8067
#   主站容器视角（发布计划推送、上游回源）：容器里的 127.0.0.1 是它自己的 loopback，
#     必须用宿主 LAN 地址，如 http://192.168.3.6:8067（端口映射对 LAN 开放）
detect_host_ip() {
  [ -n "${CJREG_LIVE_HOST_IP:-}" ] && { printf '%s' "$CJREG_LIVE_HOST_IP"; return; }
  local f="$HOME/docker/cjreg/data/cjreg.toml" h
  if [ -f "$f" ]; then
    h=$(sed -n 's/^public_url *= *"http:\/\/\([^":/]*\).*/\1/p' "$f" | head -1)
    case "$h" in ""|127.*|localhost) : ;; *) printf '%s' "$h"; return ;; esac
  fi
  h=$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)
  [ -n "$h" ] && { printf '%s' "$h"; return; }
  printf ''
}

HOST_IP=$(detect_host_ip)
UP_PORT=$(printf '%s' "$UP" | sed -n 's|.*:\([0-9][0-9]*\)$|\1|p')
UP_FROM_MAIN="${CJREG_LIVE_UPSTREAM_FROM_MAIN:-}"
if [ -z "$UP_FROM_MAIN" ] && [ -n "$HOST_IP" ] && [ -n "$UP_PORT" ]; then
  UP_FROM_MAIN="http://$HOST_IP:$UP_PORT"
fi

UP_DIR="${CJREG_LIVE_UPSTREAM_DIR:-$HOME/docker/cjreg-demo}"
UP_NAME="${CJREG_LIVE_UPSTREAM_NAME:-demo-upstream}"
MAIN_USER="${CJREG_LIVE_ADMIN_USER:-admin}"
UP_USER="${CJREG_LIVE_UP_ADMIN_USER:-admin}"
UP_PASS="${CJREG_LIVE_UP_ADMIN_PASS:-DemoPass1}"
ALICE_PASS="AlicePass1"
BOB_PASS="BobPass1"
PREPUBLISH="${CJREG_LIVE_PREPUBLISH:-0}"
PKG_SRC="$ROOT/tests/pkgs"
PKG_DIR="$ROOT/.demo/live-pkgs"
DEMO_PKGS=(mathUtils strUtils encryptUtils)

ENV_FILE="${CJREG_LIVE_ENV_FILE:-$HOME/.cjreg-live.env}"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
MAIN_PASS="${CJREG_LIVE_ADMIN_PASS:-}"

say()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# 只允许本机/内网：防止手滑把演示脚本指向公网或中心仓
guard_url() {
  case "$1" in
    http://127.0.0.1:*|http://localhost:*|http://192.168.*|http://10.*|http://172.1[6-9].*|http://172.2[0-9].*|http://172.3[01].*)
      : ;;
    *)
      die "只允许指向本机/内网地址，拒绝：$1（要演示别的地址请改脚本护栏）" ;;
  esac
}

wait_health() {
  local base="$1" tries="${2:-30}"
  for _ in $(seq 1 "$tries"); do
    curl -sf "$base/api/health" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# login <base> <user> <pass> → 会话 token（失败输出空串）
login() {
  curl -s -m 8 -X POST "$1/api/admin/login" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$2\",\"password\":\"$3\"}" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))" 2>/dev/null
}

pub_token() {  # pub_token <base> <session> → 该用户的发布 Token
  curl -s -m 8 "$1/api/admin/me" -H "Authorization: Bearer $2" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('publishToken',''))" 2>/dev/null
}

need_main_auth() {
  [ -n "$MAIN_PASS" ] || die "缺少主站管理员口令。任选一种：
      CJREG_LIVE_ADMIN_PASS='<口令>' bash scripts/demo-live.sh ${1:-prepare}
      # 或写入不进 git 的凭据文件：
      printf 'CJREG_LIVE_ADMIN_PASS=%s\n' \"'<口令>'\" > $ENV_FILE && chmod 600 $ENV_FILE"
  TOKEN_MAIN=$(login "$MAIN" "$MAIN_USER" "$MAIN_PASS")
  [ -n "$TOKEN_MAIN" ] || die "主站登录失败：$MAIN（用户 $MAIN_USER）"
  H_MAIN="Authorization: Bearer $TOKEN_MAIN"
}

# ---------- 子命令：status ----------
cmd_status() {
  guard_url "$MAIN"; guard_url "$UP"
  printf '主站     %-28s ' "$MAIN"
  curl -sf -m 5 "$MAIN/api/health" >/dev/null 2>&1 && echo "健康 ✓" || echo "不可达 ✗"
  printf '演示上游 %-28s ' "$UP"
  curl -sf -m 5 "$UP/api/health" >/dev/null 2>&1 && echo "健康 ✓" || echo "不可达 ✗"
  if [ -n "$MAIN_PASS" ]; then
    need_main_auth status
    echo "--- 主站演示对象 ---"
    curl -s -m 8 "$MAIN/api/admin/packages?organization=demo&status=all&pageSize=200" -H "$H_MAIN" \
      | python3 -c "import sys,json;d=json.load(sys.stdin);print('demo::* 版本数:',d['total'])"
    curl -s -m 8 "$MAIN/api/admin/upstreams" -H "$H_MAIN" | python3 -c "
import sys,json
us=json.load(sys.stdin)
hit=[u for u in us if u['name']=='$UP_NAME']
print('上游 %s: %s' % ('$UP_NAME', ('id=%s %s' % (hit[0]['id'], hit[0]['url'])) if hit else '未注册'))
print('全部上游:', [u['name'] for u in us])
"
    curl -s -m 8 "$MAIN/api/admin/users" -H "$H_MAIN" | python3 -c "
import sys,json
names=[u['username'] for u in json.load(sys.stdin)]
print('演示用户 alice/bob:', [n for n in ('alice','bob') if n in names] or '未创建')
"
  else
    warn "未提供主站口令，跳过主站对象盘点（只报健康状态）"
  fi
}

# ---------- 子命令：prepare ----------
cmd_prepare() {
  guard_url "$MAIN"; guard_url "$UP"
  say "0/5 连通性检查"
  wait_health "$MAIN" 5 || die "主站不可达：$MAIN"
  wait_health "$UP" 5 || die "演示上游站不可达：$UP（先起它：cd $UP_DIR && docker compose up -d）"
  echo "    主站 ✓ $MAIN    演示上游 ✓ $UP"
  need_main_auth prepare

  say "1/5 演示用户与组织（幂等：已存在则跳过）"
  have_users=$(curl -s -m 8 "$MAIN/api/admin/users" -H "$H_MAIN" \
    | python3 -c "import sys,json;print(' '.join(u['username'] for u in json.load(sys.stdin)))")
  for u in "alice:$ALICE_PASS" "bob:$BOB_PASS"; do
    name="${u%%:*}"; pass="${u##*:}"
    if [[ " $have_users " == *" $name "* ]]; then
      echo "    用户 $name 已存在，跳过"
    else
      curl -s -o /dev/null -X POST "$MAIN/api/admin/users" -H "$H_MAIN" -H 'Content-Type: application/json' \
        -d "{\"username\":\"$name\",\"password\":\"$pass\",\"isAdmin\":false}"
      echo "    用户 $name 已创建"
    fi
  done
  have_orgs=$(curl -s -m 8 "$MAIN/api/admin/organizations" -H "$H_MAIN" \
    | python3 -c "import sys,json;d=json.load(sys.stdin);items=d if isinstance(d,list) else d.get('items',[]);print(' '.join(o.get('name','') for o in items))")
  if [[ " $have_orgs " == *" demo "* ]]; then
    echo "    组织 demo 已存在，跳过"
  else
    curl -s -o /dev/null -X POST "$MAIN/api/admin/organizations" -H "$H_MAIN" -H 'Content-Type: application/json' \
      -d '{"name":"demo","displayName":"演示组织","description":"录屏演示用组织","isDefault":true}'
    echo "    组织 demo 已创建"
  fi

  say "2/5 准备演示包目录（组织 test → demo，仓库指向主站）"
  command -v cjpm >/dev/null 2>&1 || echo "    （未加载 cjpm：包目录照常准备，现场发布请在已加载 cjvs 环境的终端里做）"
  MAIN_PUB=$(pub_token "$MAIN" "$TOKEN_MAIN")
  [ -n "$MAIN_PUB" ] || warn "取主站发布 Token 失败，包目录里的 token 会为空"
  mkdir -p "$PKG_DIR"
  for p in "${DEMO_PKGS[@]}"; do
    rm -rf "$PKG_DIR/$p"
    cp -r "$PKG_SRC/$p" "$PKG_DIR/$p"
    rm -rf "$PKG_DIR/$p/.cache" "$PKG_DIR/$p/target" "$PKG_DIR/$p/cjpm.lock"
    # 组织改 demo（cjpm.toml / 源码 package 声明 / 依赖里的 test:: 同步改写），
    # 并写入主站地址与发布 Token——否则 cjpm 会报「源码里的包名与 cjpm.toml 不一致」
    python3 - "$PKG_DIR/$p" "$MAIN" "$MAIN_PUB" <<'PY'
import io, os, re, sys
d, base, pub = sys.argv[1], sys.argv[2], sys.argv[3]

def rewrite(path):
    s = io.open(path, encoding='utf-8').read()
    s = s.replace('organization = "test"', 'organization = "demo"')
    s = s.replace('"test::', '"demo::')
    s = s.replace('package test::', 'package demo::')
    s = s.replace('import test::', 'import demo::')
    io.open(path, 'w', encoding='utf-8').write(s)

rewrite(os.path.join(d, 'cjpm.toml'))
for root, _, files in os.walk(os.path.join(d, 'src')):
    for f in files:
        if f.endswith('.cj'):
            rewrite(os.path.join(root, f))
io.open(os.path.join(d, 'cangjie-repo.toml'), 'w', encoding='utf-8').write(
    '[repository.cache]\n    path = "./.cache"\n\n[repository.home]\n'
    '    registry = "%s"\n    token = "%s"\n' % (base, pub))
PY
    echo "    $PKG_DIR/$p ✓"
  done

  say "3/5 注册演示上游（幂等；priority=50 低于 official 的 0，不影响真实回源）"
  [ -n "$UP_FROM_MAIN" ] || die "无法确定主站容器内可达的宿主地址：请设 CJREG_LIVE_HOST_IP 或 CJREG_LIVE_UPSTREAM_FROM_MAIN"
  echo "    上游地址用主站容器视角：$UP_FROM_MAIN（宿主/浏览器视角是 $UP）"
  read -r UP_ID UP_URL UP_ASTARGET <<<"$(curl -s -m 8 "$MAIN/api/admin/upstreams" -H "$H_MAIN" | python3 -c "
import sys,json
for u in json.load(sys.stdin):
    if u['name']=='$UP_NAME':
        print(u['id'], u['url'], u.get('asTarget', True)); break
")"
  if [ -n "${UP_ID:-}" ] && [ "${UP_URL:-}" != "$UP_FROM_MAIN" ]; then
    echo "    上游 $UP_NAME 地址需修正（$UP_URL → $UP_FROM_MAIN），删除后重建"
    curl -s -o /dev/null -X DELETE "$MAIN/api/admin/upstreams/$UP_ID" -H "$H_MAIN"
    UP_ID=""
  fi
  if [ -z "${UP_ID:-}" ]; then
    # 演示上游要能被发布计划选中：显式给 as_target=true（新建上游默认是 false）
    UP_ID=$(curl -s -m 8 -X POST "$MAIN/api/admin/upstreams" -H "$H_MAIN" -H 'Content-Type: application/json' \
      -d "{\"name\":\"$UP_NAME\",\"url\":\"$UP_FROM_MAIN\",\"priority\":\"50\",\"as_target\":true}" \
      | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
    [ -n "$UP_ID" ] && echo "    已注册 $UP_NAME → $UP_FROM_MAIN（id=$UP_ID，asTarget=true）" || warn "上游注册失败（可能重名），请在管理后台确认"
  elif [ "${UP_ASTARGET:-True}" != "True" ]; then
    # 它得能被发布计划选中，否则演示时下拉里没有目标仓
    curl -s -o /dev/null -X PUT "$MAIN/api/admin/upstreams/$UP_ID" -H "$H_MAIN" -H 'Content-Type: application/json' \
      -d '{"asTarget":true}'
    echo "    上游 $UP_NAME 已存在（id=$UP_ID），已打开「可作目标仓」"
  else
    echo "    上游 $UP_NAME 已存在且地址/开关正确（id=$UP_ID），跳过"
  fi
  [ -n "$UP_ID" ] && curl -s -o /dev/null -X POST "$MAIN/api/admin/upstreams/$UP_ID/test?name=mathUtils&organization=demo" -H "$H_MAIN" \
    && echo "    已跑一次连通性测试（上游管理页可见结果，同时留一条审计）"

  if [ "$PREPUBLISH" = "1" ] && command -v cjpm >/dev/null 2>&1; then
    say "4/5 预发 3 个演示包到主站（CJREG_LIVE_PREPUBLISH=1）"
    for p in "${DEMO_PKGS[@]}"; do
      if (cd "$PKG_DIR/$p" && cjpm publish > "$ROOT/.demo/live-publish-$p.log" 2>&1); then
        echo "    demo::$p ✓"
      else
        warn "demo::$p 发布失败：$(tail -1 "$ROOT/.demo/live-publish-$p.log")"
      fi
    done
  else
    say "4/5 跳过预发（默认 0：3 个包留给录制时现场 cjpm publish）"
  fi

  UP_PUB=$(pub_token "$UP" "$(login "$UP" "$UP_USER" "$UP_PASS")")
  say "5/5 演示环境就绪"
  cat <<EOF

  主站（生产，真实数据）: $MAIN
     管理后台: $MAIN/admin          账号 $MAIN_USER / <CJREG_LIVE_ADMIN_PASS>
     用户门户: $MAIN/user/login     alice / $ALICE_PASS、bob / $BOB_PASS
  演示上游站（空站，可重建）: $UP       账号 $UP_USER / $UP_PASS
     宿主/浏览器视角: $UP
     主站容器视角（发布计划/回源要用这个）: $UP_FROM_MAIN
     发布计划推送目标: target_url=$UP_FROM_MAIN
                       target_token=${UP_PUB:-（取 Token 失败，去 $UP/admin 个人门户取）}
  演示包目录: $PKG_DIR/{${DEMO_PKGS[*]}}（现场发布：cd 进去 cjpm publish）
  上游: 主站已注册 $UP_NAME → $UP_FROM_MAIN（priority=50）

  演示流程见 docs/demo-video.md（分镜 + 解说词）；录完清理：bash scripts/demo-live.sh clean
EOF
}

# ---------- 子命令：reset-upstream ----------
cmd_reset_upstream() {
  [ -d "$UP_DIR" ] || die "演示上游站目录不存在：$UP_DIR"
  guard_url "$UP"
  say "1/5 停止演示上游站"
  (cd "$UP_DIR" && docker compose down) 2>&1 | tail -2
  say "2/5 清空数据目录（容器内 root，顺带把属主交给 uid 1000）"
  # 数据目录可能被 docker 以 root 创建过：用镜像内的 root 清理，避免宿主权限问题
  docker run --rm --user root -v "$UP_DIR/data:/data" cjreg:latest sh -c 'rm -rf /data/*; chown -R 1000:1000 /data' \
    || die "清空失败（检查 docker 与镜像 cjreg:latest 是否存在）"
  say "3/5 重新初始化（$UP_USER / $UP_PASS）"
  (cd "$UP_DIR" && docker compose run --rm cjreg /app/cjreg init -d /data --username "$UP_USER" --password "$UP_PASS") 2>&1 | tail -2
  python3 - "$UP_DIR/data/cjreg.toml" "$UP" <<'PY'
import io, re, sys
p, base = sys.argv[1], sys.argv[2]
s = io.open(p, encoding='utf-8').read()
s = re.sub(r'public_url = "[^"]*"', 'public_url = "%s"' % base, s)
s = re.sub(r'permission_mode = "[^"]*"', 'permission_mode = "team"', s)
io.open(p, 'w', encoding='utf-8').write(s)
PY
  say "4/5 启动"
  (cd "$UP_DIR" && docker compose up -d) 2>&1 | tail -2
  wait_health "$UP" 30 || die "演示上游站健康检查失败（cd $UP_DIR && docker compose logs）"
  say "5/5 关闭它自身对官方仓的回源（真空站：被探测时不代理、不落库）"
  UP_SESS=$(login "$UP" "$UP_USER" "$UP_PASS")
  if [ -n "$UP_SESS" ]; then
    OFF_ID=$(curl -s -m 8 "$UP/api/admin/upstreams" -H "Authorization: Bearer $UP_SESS" | python3 -c "
import sys,json
for u in json.load(sys.stdin):
    if u['name']=='official':
        print(u['id']); break
")
    if [ -n "$OFF_ID" ]; then
      # init 建出来的 official 默认参与回源；空站要的是「本地为空就是空」——
      # 否则别人来探测它的索引，它会替对方回源官方仓、把索引落进自己库里
      curl -s -o /dev/null -X PUT "$UP/api/admin/upstreams/$OFF_ID" -H "Authorization: Bearer $UP_SESS" \
        -H 'Content-Type: application/json' -d '{"proxyEnabled":false}'
      echo "    official(proxyEnabled=false)：不走回源，探测它只会拿到 404"
    else
      warn "没找到 official 上游，跳过（该站可能不是 cjreg 默认初始化）"
    fi
  else
    warn "登录演示上游站失败，跳过回源开关设置（可在它的「上游管理」里手工关）"
  fi
  echo "    演示上游站已重建为空站：$UP（$UP_USER / $UP_PASS）"
}

# ---------- 子命令：clean ----------
cmd_clean() {
  guard_url "$MAIN"
  need_main_auth clean
  say "1/2 移除演示上游（$UP_NAME）"
  UP_ID=$(curl -s -m 8 "$MAIN/api/admin/upstreams" -H "$H_MAIN" | python3 -c "
import sys,json
for u in json.load(sys.stdin):
    if u['name']=='$UP_NAME':
        print(u['id']); break
")
  if [ -n "$UP_ID" ]; then
    curl -s -o /dev/null -X DELETE "$MAIN/api/admin/upstreams/$UP_ID" -H "$H_MAIN" && echo "    已删除 id=$UP_ID"
  else
    echo "    未注册，跳过"
  fi
  say "2/2 硬删除主站上的 demo::* 演示包（先软删再硬删）"
  IDS=$(curl -s -m 8 "$MAIN/api/admin/packages?organization=demo&status=all&pageSize=200" -H "$H_MAIN" \
    | python3 -c "import sys,json;print(' '.join(str(i['id']) for i in json.load(sys.stdin)['items']))")
  if [ -z "$IDS" ]; then
    echo "    没有 demo::* 包，跳过"
  else
    for id in $IDS; do
      curl -s -o /dev/null -X DELETE "$MAIN/api/admin/packages/$id" -H "$H_MAIN"
      curl -s -o /dev/null -X DELETE "$MAIN/api/admin/packages/$id/hard" -H "$H_MAIN"
      echo "    已硬删 id=$id"
    done
  fi
  echo "    演示用户 alice/bob 与组织 demo 保留（无害；要一并清理请在管理后台删）"
}

case "${1:-prepare}" in
  prepare)        cmd_prepare ;;
  status)         cmd_status ;;
  reset-upstream) cmd_reset_upstream ;;
  clean)          cmd_clean ;;
  -h|--help|help)
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)
    die "未知子命令：$1（可用：prepare / status / reset-upstream / clean）" ;;
esac
