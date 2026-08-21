#!/bin/bash
# cjreg 双仓发布计划 e2e 验证
# 用 6 个测试包（tests/pkgs）验证：
#   A(:18060 源) 发布 → analyze 拓扑 → execute 推送到 B(:18070 目标) → 验证 B 收包
#
# 用法: ./tests/e2e.sh
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/target/release/bin/ystyle::cjreg"
PORTA=18060
PORTB=18070
ADMIN_USER="admin"
ADMIN_PASS="AdminPass1"

cd "$ROOT"
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"

# 清理并构建
rm -rf .smoke/A .smoke/B tests/pkgs/*/.cache tests/pkgs/*/target
mkdir -p .smoke/A .smoke/B

# 1. init 双仓
"$BIN" init -d .smoke/A/data --username $ADMIN_USER --password $ADMIN_PASS >/dev/null
"$BIN" init -d .smoke/B/data --username $ADMIN_USER --password $ADMIN_PASS >/dev/null

# 2. 启动双仓（后台）
"$BIN" serve -p $PORTA -d .smoke/A/data > .smoke/A.log 2>&1 &
PA=$!
"$BIN" serve -p $PORTB -d .smoke/B/data > .smoke/B.log 2>&1 &
PB=$!
trap "kill $PA $PB 2>/dev/null || true" EXIT

# 等待健康
for i in $(seq 1 20); do
  curl -sf "http://localhost:$PORTA/api/health" >/dev/null 2>&1 && break
  sleep 0.5
done
for i in $(seq 1 20); do
  curl -sf "http://localhost:$PORTB/api/health" >/dev/null 2>&1 && break
  sleep 0.5
done

echo "=== 1. 按依赖顺序发布 6 包到 A ==="
for p in mathUtils strUtils netUtils encryptUtils dataUtils app; do
  (cd tests/pkgs/$p && cjpm publish >/dev/null 2>&1)
  echo "  published $p ✓"
done

echo "=== 2. analyze app（应展开 6 包拓扑）==="
TOKEN=$(curl -s -X POST http://localhost:$PORTA/api/admin/login \
  -H 'Content-Type: application/json' -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
ORDER=$(curl -s -X POST http://localhost:$PORTA/api/admin/publish-plans/analyze \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"packages":[{"organization":"test","name":"app","version":"1.0.0"}]}')
echo "$ORDER" | python3 -c "
import sys, json
d = json.load(sys.stdin)
names = [x['name'] for x in d['publish_order']]
assert len(names) == 6, f'应 6 包, got {names}'
# 依赖必须在其依赖者之前
order_idx = {n: i for i, n in enumerate(names)}
deps = {'encryptUtils':['mathUtils','strUtils'],'dataUtils':['mathUtils','netUtils'],'app':['encryptUtils','dataUtils']}
for dep, need in deps.items():
    for n in need:
        assert order_idx[n] < order_idx[dep], f'{n} 应在 {dep} 之前: {names}'
print(f'  拓扑正确: {names}')
"

echo "=== 3. 执行发布计划 A → B ==="
RES=$(curl -s --max-time 60 -X POST http://localhost:$PORTA/api/admin/publish-plans/execute \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"packages\":[{\"organization\":\"test\",\"name\":\"app\",\"version\":\"1.0.0\"}],\"target_url\":\"http://localhost:$PORTB\"}")
echo "$RES" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['success'] == 6 and d['total'] == 6 and not d['errors'], f'应 6/6 成功: {d}'
print('  6/6 推送成功 ✓')
"

echo "=== 4. 验证 B 收到全部包 ==="
BTOKEN=$(curl -s -X POST http://localhost:$PORTB/api/admin/login \
  -H 'Content-Type: application/json' -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
curl -s "http://localhost:$PORTB/index/ap/p/app?organization=test" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['name'] == 'app', d
assert len(d['dependencies']) == 2, d
print('  B 索引完整（含依赖）✓')
"
curl -s -o /tmp/cjreg_app.cjp -w "%{http_code}" "http://localhost:$PORTB/pkg/app/1.0.0?organization=test" | grep -q 200
echo "  B 制品下载 200 ✓"
curl -s "http://localhost:$PORTB/index/ma/th/mathUtils?organization=test" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['name'] == 'mathUtils', d
print('  B 底层包索引 ✓')
"

echo ""
echo "=== 双仓 e2e 全部通过 ✓ ==="
