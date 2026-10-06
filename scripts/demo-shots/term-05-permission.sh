#!/usr/bin/env bash
# 镜头 5｜权限：bob 未加入团队 → 发布被 403 拒绝
set -u
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
MAIN=http://127.0.0.1:8066
ROOT=$(cd "$(dirname "$0")/../../.." && pwd); cd "$ROOT"
WORK=$(mktemp -d /tmp/bob-pkg-XXXX)
cp -r .demo/live-pkgs/strUtils "$WORK/strUtils"
cd "$WORK/strUtils"
sed -i 's/^  version = "1.0.0"/  version = "1.0.1"/' cjpm.toml
BOB_SESS=$(curl -s -X POST "$MAIN/api/admin/login" -H 'Content-Type: application/json' -d '{"username":"bob","password":"BobPass1"}' | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
BOB_PUB=$(curl -s -X POST "$MAIN/api/user/me/publish-token" -H "Authorization: Bearer $BOB_SESS" | python3 -c "import sys,json;print(json.load(sys.stdin)['publishToken'])")
python3 - "$BOB_PUB" <<'PY'
import io,sys
p='cangjie-repo.toml'; s=io.open(p,encoding='utf-8').read()
import re
s=re.sub(r'token = "[^"]*"', 'token = "%s"' % sys.argv[1], s)
io.open(p,'w',encoding='utf-8').write(s)
PY
say "bob 不是 demo 组织成员，尝试发布 strUtils 1.0.1"
printf '  $ cjpm publish\n'
cjpm publish || true
sleep 2
say "管理端审计里能看到这次拒绝"
ADMIN_PASS="${CJREG_LIVE_ADMIN_PASS:-}"
[ -n "$ADMIN_PASS" ] || { echo "缺少 CJREG_LIVE_ADMIN_PASS（生产管理员口令，不入仓）" >&2; exit 1; }
TOKEN=$(curl -s -X POST "$MAIN/api/admin/login" -H 'Content-Type: application/json' -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PASS\"}" | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
curl -s "$MAIN/api/admin/logs/admin?keyword=forbidden&page=1&pageSize=3" -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('  匹配记录:',d.get('total'))
for it in d.get('items',[])[:3]: print('   ', it.get('action'), it.get('status'), it.get('target'), (it.get('error') or '')[:60])
"
sleep 1
cd /; rm -rf "$WORK"
