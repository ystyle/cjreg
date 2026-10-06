#!/usr/bin/env bash
# 镜头 8｜三级删除（可逆部分）：软删 → 下载 404 → 恢复 → 下载 200
set -u
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
MAIN=http://127.0.0.1:8066
ADMIN_PASS="${CJREG_LIVE_ADMIN_PASS:-}"
[ -n "$ADMIN_PASS" ] || { echo "缺少 CJREG_LIVE_ADMIN_PASS（生产管理员口令，不入仓）" >&2; exit 1; }
TOKEN=$(curl -s -X POST "$MAIN/api/admin/login" -H 'Content-Type: application/json' -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PASS\"}" | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
ID=$(curl -s "$MAIN/api/admin/packages?organization=demo&name=strUtils&status=all&pageSize=1" -H "Authorization: Bearer $TOKEN" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['items'][0]['id'] if d['total'] else 0)")
say "目标版本 id=$ID（demo::strUtils@1.0.0）"
sleep 1
say "① 软删除"
printf '  $ curl -X DELETE %s/api/admin/packages/%s\n' "$MAIN" "$ID"
curl -s -o /dev/null -w '  → %{http_code}\n' -X DELETE "$MAIN/api/admin/packages/$ID" -H "Authorization: Bearer $TOKEN"
sleep 1
say "② 下载立刻 404（索引/下载不可见，制品仍保留）"
curl -s -o /dev/null -w '  $ curl .../pkg/strUtils/1.0.0?organization=demo  → %{http_code}\n' "$MAIN/pkg/strUtils/1.0.0?organization=demo"
sleep 2
say "③ 恢复"
printf '  $ curl -X PUT %s/api/admin/packages/%s/restore\n' "$MAIN" "$ID"
curl -s -o /dev/null -w '  → %{http_code}\n' -X PUT "$MAIN/api/admin/packages/$ID/restore" -H "Authorization: Bearer $TOKEN"
sleep 1
say "④ 下载恢复 200（恢复时会校验制品仍在）"
curl -s -o /dev/null -w '  $ curl .../pkg/strUtils/1.0.0?organization=demo  → %{http_code}\n' "$MAIN/pkg/strUtils/1.0.0?organization=demo"
sleep 1
