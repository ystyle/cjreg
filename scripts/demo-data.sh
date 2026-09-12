#!/usr/bin/env bash
# cjreg 演示数据一键准备（录屏/线下演示/评审复现用）
#
# 做出来的场景：
#   A 仓（演示主仓，team 模式）：注册组织/用户 → 发布 3 个 demo::* 包 → 加 B 仓为上游
#     → 用发布计划把包推送到 B 仓 → 造审计（登录/发布/软删-恢复-硬删/上游连通测试）
#   B 仓（演示从仓/镜像）：仅初始化并保持运行，用于演示「多仓 + 一键推送」
#
# 用法：
#   bash scripts/demo-data.sh                 # 默认 A=8060、B=8061，数据在 .demo/
#   CJREG_DEMO_PORT=9060 bash scripts/demo-data.sh
#   CJREG_DEMO_RESET=1 bash scripts/demo-data.sh   # 先清空 .demo/ 再重建
#
# 结束后会打印：服务地址、账号、录屏检查清单。停止：bash scripts/demo-data.sh stop
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

PORT_A="${CJREG_DEMO_PORT:-8060}"
PORT_B="${CJREG_DEMO_PORT_B:-$((PORT_A + 1))}"
DATA_A="$ROOT/.demo/data-a"
DATA_B="$ROOT/.demo/data-b"
LOG_A="$ROOT/.demo/a.log"
LOG_B="$ROOT/.demo/b.log"
PID_A="$ROOT/.demo/a.pid"
PID_B="$ROOT/.demo/b.pid"
BIN="$ROOT/target/release/bin/ystyle::cjreg"

ADMIN_USER="admin"
ADMIN_PASS="AdminPass1"
ALICE_PASS="AlicePass1"
BOB_PASS="BobPass1"

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

wait_health() {
  local port="$1" tries="${2:-40}"
  for _ in $(seq 1 "$tries"); do
    curl -sf "http://127.0.0.1:${port}/api/health" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}

stop_all() {
  for f in "$PID_A" "$PID_B"; do
    if [ -f "$f" ]; then
      local pid; pid=$(cat "$f")
      if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        say "已停止 pid=$pid（$(basename "$f")）"
      fi
      rm -f "$f"
    fi
  done
}

if [ "${1:-}" = "stop" ]; then
  stop_all
  exit 0
fi

command -v curl >/dev/null 2>&1 || die "需要 curl"
[ -x "$BIN" ] || die "构建产物缺失：$BIN（先执行：eval \"\$(cjvs env zsh)\" && cjpm build -j 16）"
if command -v cjvs >/dev/null 2>&1; then
  eval "$(cjvs env zsh)" >/dev/null 2>&1
  eval "$(cjvs stdx-env zsh)" >/dev/null 2>&1
fi
command -v cjpm >/dev/null 2>&1 || warn "未找到 cjpm：发布步骤会跳过（演示时需手动发布）"

stop_all
if [ "${CJREG_DEMO_RESET:-0}" = "1" ]; then
  rm -rf "$ROOT/.demo"
fi
mkdir -p "$ROOT/.demo" "$ROOT/.demo/pkgs"

# ---------- 1. 初始化两个仓 ----------
say "1/7 初始化数据目录（A=$DATA_A，B=$DATA_B）"
[ -d "$DATA_A" ] || "$BIN" init -d "$DATA_A" --username "$ADMIN_USER" --password "$ADMIN_PASS" >/dev/null
[ -d "$DATA_B" ] || "$BIN" init -d "$DATA_B" --username "$ADMIN_USER" --password "$ADMIN_PASS" >/dev/null

# A 仓：team 模式（演示权限裁决）；对外地址与端口写进配置
python3 - "$DATA_A/cjreg.toml" "$PORT_A" <<'PY'
import io, re, sys
path, port = sys.argv[1], sys.argv[2]
s = io.open(path, encoding='utf-8').read()
s = re.sub(r'public_url = "[^"]*"', 'public_url = "http://127.0.0.1:%s"' % port, s)
s = re.sub(r'port = \d+', 'port = %s' % port, s)
s = re.sub(r'permission_mode = "[^"]*"', 'permission_mode = "team"', s)
io.open(path, 'w', encoding='utf-8').write(s)
PY
python3 - "$DATA_B/cjreg.toml" "$PORT_B" <<'PY'
import io, re, sys
path, port = sys.argv[1], sys.argv[2]
s = io.open(path, encoding='utf-8').read()
s = re.sub(r'public_url = "[^"]*"', 'public_url = "http://127.0.0.1:%s"' % port, s)
s = re.sub(r'port = \d+', 'port = %s' % port, s)
io.open(path, 'w', encoding='utf-8').write(s)
PY

# ---------- 2. 启动两仓 ----------
# 端口预检：被占用时给出明确提示（避免只看到「健康检查失败」）
port_free() {
  if command -v ss >/dev/null 2>&1; then
    ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1$"
  else
    return 0
  fi
}
for p in "$PORT_A" "$PORT_B"; do
  port_free "$p" || die "端口 $p 已被占用（换端口：CJREG_DEMO_PORT=18080 bash scripts/demo-data.sh）"
done

say "2/7 启动 A(:$PORT_A) 与 B(:$PORT_B)"
"$BIN" serve -d "$DATA_A" > "$LOG_A" 2>&1 &
echo $! > "$PID_A"
"$BIN" serve -d "$DATA_B" > "$LOG_B" 2>&1 &
echo $! > "$PID_B"
wait_health "$PORT_A" || { tail -5 "$LOG_A"; die "A 仓健康检查失败（日志：$LOG_A）"; }
wait_health "$PORT_B" || { tail -5 "$LOG_B"; die "B 仓健康检查失败（日志：$LOG_B）"; }

login() {  # login <port> <user> <pass> → 会话 token
  curl -s -X POST "http://127.0.0.1:$1/api/admin/login" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$2\",\"password\":\"$3\"}" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))"
}
TOKEN_A=$(login "$PORT_A" "$ADMIN_USER" "$ADMIN_PASS")
TOKEN_B=$(login "$PORT_B" "$ADMIN_USER" "$ADMIN_PASS")
[ -n "$TOKEN_A" ] || die "A 仓登录失败"
PUB_A=$(curl -s "http://127.0.0.1:$PORT_A/api/admin/me" -H "Authorization: Bearer $TOKEN_A" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['publishToken'])")
PUB_B=$(curl -s "http://127.0.0.1:$PORT_B/api/admin/me" -H "Authorization: Bearer $TOKEN_B" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['publishToken'])")

# ---------- 3. 用户与组织 ----------
say "3/7 创建演示用户（alice / bob）与组织（demo）"
for u in "alice:$ALICE_PASS" "bob:$BOB_PASS"; do
  name="${u%%:*}"; pass="${u##*:}"
  curl -s -o /dev/null -X POST "http://127.0.0.1:$PORT_A/api/admin/users" \
    -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$name\",\"password\":\"$pass\",\"isAdmin\":false}"
done
curl -s -o /dev/null -X POST "http://127.0.0.1:$PORT_A/api/admin/organizations" \
  -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
  -d '{"name":"demo","displayName":"演示组织","description":"录屏演示用组织","isDefault":true}'

# alice 的发布 token（用她自己的会话重置一次，便于演示「不同人发布」）
ALICE_TOKEN=$(login "$PORT_A" alice "$ALICE_PASS")
ALICE_PUB=""
if [ -n "$ALICE_TOKEN" ]; then
  ALICE_PUB=$(curl -s -X POST "http://127.0.0.1:$PORT_A/api/user/me/publish-token" \
    -H "Authorization: Bearer $ALICE_TOKEN" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('publishToken',''))")
fi

# ---------- 4. 发布演示包（demo::mathUtils / strUtils / encryptUtils）----------
say "4/7 发布 3 个演示包（组织 demo）"
if command -v cjpm >/dev/null 2>&1; then
  for p in mathUtils strUtils encryptUtils; do
    rm -rf "$ROOT/.demo/pkgs/$p"
    cp -r "$ROOT/tests/pkgs/$p" "$ROOT/.demo/pkgs/$p"
    rm -rf "$ROOT/.demo/pkgs/$p/.cache" "$ROOT/.demo/pkgs/$p/target" "$ROOT/.demo/pkgs/$p/cjpm.lock"
    # 组织改为 demo（cjpm.toml、源码 package 声明、依赖里的 test:: 全部同步改写），
    # 并写入演示仓地址与 admin 发布 token——否则 cjpm 构建会报「源码里的包名与 cjpm.toml 不一致」
    python3 - "$ROOT/.demo/pkgs/$p" "$PORT_A" "$PUB_A" <<'PY'
import io, os, sys
d, port, pub = sys.argv[1], sys.argv[2], sys.argv[3]

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
    '    registry = "http://127.0.0.1:%s"\n    token = "%s"\n' % (port, pub))
PY
    if (cd "$ROOT/.demo/pkgs/$p" && cjpm publish > "$ROOT/.demo/publish-$p.log" 2>&1); then
      echo "    published demo::$p ✓"
    else
      warn "publish demo::$p 失败（详见 .demo/publish-$p.log）：$(tail -1 "$ROOT/.demo/publish-$p.log")"
    fi
  done
else
  warn "已跳过发布（无 cjpm）"
fi

# ---------- 5. 多仓：B 作为 A 的上游 + 发布计划推送 ----------
say "5/7 注册 B 仓为上游，用发布计划把 demo::encryptUtils（含 2 个依赖）推送到 B"
UP_ID=$(curl -s -X POST "http://127.0.0.1:$PORT_A/api/admin/upstreams" \
  -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
  -d "{\"name\":\"mirrorB\",\"url\":\"http://127.0.0.1:$PORT_B\",\"priority\":\"5\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))")
[ -n "$UP_ID" ] && curl -s -o /dev/null -X POST "http://127.0.0.1:$PORT_A/api/admin/upstreams/$UP_ID/test?name=mathUtils&organization=demo" \
  -H "Authorization: Bearer $TOKEN_A"
curl -s -o /dev/null -X POST "http://127.0.0.1:$PORT_A/api/admin/publish-plans/execute" \
  -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
  -d "{\"packages\":[{\"organization\":\"demo\",\"name\":\"encryptUtils\",\"version\":\"1.0.0\"}],\"target_url\":\"http://127.0.0.1:$PORT_B\",\"target_token\":\"$PUB_B\"}"
B_PKGS=$(curl -s "http://127.0.0.1:$PORT_B/api/packages?size=50" | python3 -c "import sys,json;print(json.load(sys.stdin)['total'])")
echo "    B 仓现有包：$B_PKGS（推送成功则 ≥ 2：mathUtils/strUtils + encryptUtils）"

# ---------- 6. 造审计：登录失败/成功、软删-恢复-硬删、上游测试 ----------
say "6/7 造审计记录（登录失败/成功、软删→恢复→硬删、上游连通测试）"
curl -s -o /dev/null -X POST "http://127.0.0.1:$PORT_A/api/admin/login" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$ADMIN_USER\",\"password\":\"wrong-pass\"}"
SCRATCH_ID=$(curl -s "http://127.0.0.1:$PORT_A/api/admin/packages?organization=demo&name=strUtils&includeDeleted=1" \
  -H "Authorization: Bearer $TOKEN_A" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['items'][0]['id'] if d['total'] else 0)")
if [ "${SCRATCH_ID:-0}" != "0" ]; then
  curl -s -o /dev/null -X DELETE "http://127.0.0.1:$PORT_A/api/admin/packages/$SCRATCH_ID" -H "Authorization: Bearer $TOKEN_A"
  curl -s -o /dev/null -X PUT "http://127.0.0.1:$PORT_A/api/admin/packages/$SCRATCH_ID/restore" -H "Authorization: Bearer $TOKEN_A"
fi
curl -s -o /dev/null -X POST "http://127.0.0.1:$PORT_A/api/admin/upstreams/1/test?name=cordis_core&organization=ystyle" \
  -H "Authorization: Bearer $TOKEN_A"

# ---------- 7. 汇总 ----------
say "7/7 演示环境就绪"
cat <<EOF

  A 仓（演示主仓，team 模式）: http://127.0.0.1:$PORT_A
     管理后台: http://127.0.0.1:$PORT_A/admin      账号 $ADMIN_USER / $ADMIN_PASS
     用户门户: http://127.0.0.1:$PORT_A/user/login 账号 alice / $ALICE_PASS、bob / $BOB_PASS
  B 仓（镜像/目标仓）        : http://127.0.0.1:$PORT_B   （$ADMIN_USER / $ADMIN_PASS）

  演示包目录（组织 demo）：$ROOT/.demo/pkgs/{mathUtils,strUtils,encryptUtils}
  已注册上游 mirrorB → B 仓（管理后台「上游管理」可见，可点连通性测试）
  alice 的发布 Token（可用于演示「作为普通用户发布」）：${ALICE_PUB:-（重置失败，可在门户重置）}

  录屏前检查：
    1) 浏览器缩放 100%、窗口 1600x900 以上；终端字体 ≥16px
    2) 先访问 http://127.0.0.1:$PORT_A/ 与 /docs 让静态资源进缓存
    3) 打开审计日志页 /admin/logs（应已有数十条记录）
    4) 演示脚本见 docs/demo-video.md（分镜 + 解说词 + 时长）

  停止：bash scripts/demo-data.sh stop
EOF
