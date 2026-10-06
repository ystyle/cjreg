#!/usr/bin/env bash
# 镜头 4｜多仓：解析诊断 + 发布计划推送到演示空站
set -u
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
MAIN=http://127.0.0.1:8066
UP=http://127.0.0.1:8067
TOKEN=$(curl -s -X POST "$MAIN/api/admin/login" -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"__REDACTED__"}' | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
say "多仓解析诊断：demo::mathUtils >= 1.0.0 由哪个仓提供"
printf '  $ curl -s "%s/api/admin/resolve?name=mathUtils&organization=demo&require=>=1.0.0"\n' "$MAIN"
curl -s "$MAIN/api/admin/resolve?name=mathUtils&organization=demo&require=%3E%3D1.0.0" \
  -H "Authorization: Bearer $TOKEN" | python3 -m json.tool | head -24
sleep 3
UP_PUB=$(curl -s -H "Authorization: Bearer $(curl -s -X POST "$UP/api/admin/login" -H 'Content-Type: application/json' -d '{"username":"admin","password":"DemoPass1"}' | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")" "$UP/api/admin/me" | python3 -c "import sys,json;print(json.load(sys.stdin)['publishToken'])")
say "发布计划：把 demo::encryptUtils（含 2 个依赖）一次推到演示空站"
printf '  target_url 用宿主 LAN 地址（推送由主站容器发起，容器里的 127.0.0.1 不通）\n'
curl -s -X POST "$MAIN/api/admin/publish-plans/execute" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"packages\":[{\"organization\":\"demo\",\"name\":\"encryptUtils\",\"version\":\"1.0.0\"}],\"target_url\":\"http://192.168.3.6:8067\",\"target_token\":\"$UP_PUB\"}" \
  | python3 -m json.tool
sleep 2
say "演示空站现有包（按依赖拓扑一次到位）"
curl -s "$UP/api/packages?size=50" | python3 -c "import sys,json;d=json.load(sys.stdin);print('  包数:',d['total']);[print('   ',i.get('organization'),i.get('name')) for i in d.get('items',[])]"
sleep 1
