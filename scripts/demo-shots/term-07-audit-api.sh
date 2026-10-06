#!/usr/bin/env bash
# 镜头 7｜审计与公开只读 API
set -u
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
MAIN=http://127.0.0.1:8066
say "公开统计（无需认证）"
printf '  $ curl -s %s/api/stats\n' "$MAIN"
curl -s "$MAIN/api/stats" | python3 -m json.tool
sleep 2
say "公开包列表（只读 API）"
printf '  $ curl -s "%s/api/packages?q=demo::&size=5"\n' "$MAIN"
curl -s "$MAIN/api/packages?q=demo::&size=5" | python3 -m json.tool | head -20
sleep 2
say "管理审计日志（按类型过滤，含 IP / User-Agent）"
ADMIN_PASS="${CJREG_LIVE_ADMIN_PASS:-}"
[ -n "$ADMIN_PASS" ] || { echo "缺少 CJREG_LIVE_ADMIN_PASS（生产管理员口令，不入仓）" >&2; exit 1; }
TOKEN=$(curl -s -X POST "$MAIN/api/admin/login" -H 'Content-Type: application/json' -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PASS\"}" | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
curl -s "$MAIN/api/admin/logs/admin?kind=admin&page=1&pageSize=4" -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys,json,datetime
d=json.load(sys.stdin)
print('  记录数:',d.get('total'))
for it in d.get('items',[])[:4]:
    ts=it.get('createdAt',0)/1000
    t=datetime.datetime.fromtimestamp(ts).strftime('%H:%M:%S') if ts else '-'
    print('   %s %-22s %-7s %-24s %s' % (t, it.get('action'), it.get('status'), it.get('target'), it.get('ipAddr') or ''))
"
sleep 1
