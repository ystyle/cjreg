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
# 仓颉环境：本机用 cjvs；CI（GitHub Actions + setup-cangjie）已就绪，可跳过
if command -v cjvs >/dev/null 2>&1; then
  eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"
fi

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

# 1.5 取两端发布 token：A 仓写入各测试包 cangjie-repo.toml；B 仓作为推送目标鉴权
ATOKEN=$(curl -s -X POST http://localhost:$PORTA/api/admin/login \
  -H 'Content-Type: application/json' -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
PUBTOKEN=$(curl -s http://localhost:$PORTA/api/admin/me -H "Authorization: Bearer $ATOKEN" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['publishToken'])")
BTOKEN_SESS=$(curl -s -X POST http://localhost:$PORTB/api/admin/login \
  -H 'Content-Type: application/json' -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['token'])")
BPUBTOKEN=$(curl -s http://localhost:$PORTB/api/admin/me -H "Authorization: Bearer $BTOKEN_SESS" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['publishToken'])")
for p in mathUtils strUtils netUtils encryptUtils dataUtils app; do
  cat > tests/pkgs/$p/cangjie-repo.toml <<EOF
[repository.cache]
    path = "./.cache"

[repository.home]
    registry = "http://localhost:$PORTA"
    token = "$PUBTOKEN"
EOF
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
  -d "{\"packages\":[{\"organization\":\"test\",\"name\":\"app\",\"version\":\"1.0.0\"}],\"target_url\":\"http://localhost:$PORTB\",\"target_token\":\"$BPUBTOKEN\"}")
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
echo "=== 5. 审计日志（发布登记 + IP/UA + 查询/清理）==="
# 5.1 A 仓 6 次发布均登记成功日志（操作者/目标含版本/IP/UA）
curl -s "http://localhost:$PORTA/api/admin/logs/publish?limit=100" -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['total'] >= 6, d
ok = [x for x in d['items'] if x['status'] == 'ok']
assert len(ok) >= 6, [(x['target'], x['status']) for x in d['items']]
for x in ok[:6]:
    assert x['kind'] == 'publish', x
    assert x['actorName'] == 'admin', x
    assert '@1.0.0' in x['target'], x
    assert x['ipAddr'], x
    assert 'cjpm' in x['userAgent'] or x['userAgent'], x
print('  发布审计 %d 条（操作者/版本/IP/UA 齐全）✓' % d['total'])
"
# 5.2 非法令牌发布 → 记 failed（匿名操作者 + 错误原因 + 自定义 UA）
curl -s -o /dev/null -X POST "http://localhost:$PORTA/pkg/hackPkg?organization=test" \
  -H 'Authorization: bad-token' -H 'Content-Type: application/octet-stream' \
  -H 'User-Agent: audit-e2e/1.0' --data-binary 'not-a-cangjie-package'
curl -s "http://localhost:$PORTA/api/admin/logs/publish?status=failed&keyword=hackPkg" -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['total'] == 1, d
x = d['items'][0]
assert x['status'] == 'failed' and x['actorName'] == '' and x['actorId'] == 0, x
assert x['error'], x
assert x['userAgent'] == 'audit-e2e/1.0', x
assert x['ipAddr'], x
print('  失败发布审计（匿名 + 原因 + UA）✓')
"
# 5.3 登录审计：auth 类记录 + 自定义 UA 命中
curl -s -o /dev/null -X POST http://localhost:$PORTA/api/admin/login \
  -H 'Content-Type: application/json' -H 'User-Agent: audit-login/9' \
  -d "{\"username\":\"$ADMIN_USER\",\"password\":\"wrong-pass\"}"
curl -s -o /dev/null -X POST http://localhost:$PORTA/api/admin/login \
  -H 'Content-Type: application/json' -H 'User-Agent: audit-login/9' \
  -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}"
curl -s "http://localhost:$PORTA/api/admin/logs/auth?limit=50" -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys, json
d = json.load(sys.stdin)
fail = [x for x in d['items'] if x['status'] == 'failed' and x['userAgent'] == 'audit-login/9']
ok = [x for x in d['items'] if x['status'] == 'ok' and x['action'] == 'login' and x['userAgent'] == 'audit-login/9']
assert fail, d
assert all(x['error'] for x in fail), fail   # 失败必须带原因
assert ok and all(x['actorName'] == 'admin' for x in ok), d
assert all(x['ipAddr'] for x in fail + ok), d
print('  登录审计：%d 次成功 / %d 次失败（含原因 + IP）✓' % (len(ok), len(fail)))
"
# 关键字命中操作者字段
curl -s "http://localhost:$PORTA/api/admin/logs/auth?keyword=$ADMIN_USER&limit=5" -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['total'] >= 1 and all('admin' in (x['actorName'] + x['target'] + x['action'] + x['error'] + x['detail']) for x in d['items']), d
print('  关键字过滤命中 %d 条 ✓' % d['total'])
"
# 5.4 分页 + 清理（清理动作本身也入审计）
P1=$(curl -s "http://localhost:$PORTA/api/admin/logs/all?limit=2&offset=0" -H "Authorization: Bearer $TOKEN" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['total'],len(d['items']))")
python3 -c "
import sys
total, n = '$P1'.split()
assert int(total) >= 8 and int(n) == 2, ('$P1',)
print('  分页：total=%s 本页 %s 条 ✓' % (total, n))
"
DEL=$(curl -s -X POST "http://localhost:$PORTA/api/admin/logs/clean" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"kind":"publish"}')
echo "$DEL" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['deleted'] >= 7, d
print('  清理 publish 日志 %d 条 ✓' % d['deleted'])
"
curl -s "http://localhost:$PORTA/api/admin/logs/publish" -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['total'] == 0 and d['items'] == [], d
print('  清理后 publish 日志为空 ✓')
"
curl -s "http://localhost:$PORTA/api/admin/logs/admin" -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert any(x['action'] == 'clean_logs' for x in d['items']), d
print('  清理动作自身入审计 ✓')
"
# 5.5 未鉴权访问日志端点 → 401
CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORTA/api/admin/logs/all")
[ "$CODE" = "401" ] || { echo "未鉴权应 401，实际 $CODE"; exit 1; }
echo "  未鉴权查询日志被拒（401）✓"

echo ""
echo "=== 双仓 e2e 全部通过 ✓ ==="
