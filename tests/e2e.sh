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
# 发布计划推送也入审计（目标仓地址 + 成功计数，token 不落库）
plan = [x for x in d['items'] if x['action'] == 'execute_publish_plan']
assert plan, d
p0 = plan[0]
# detail 是 `key=value` 串（success/skipped/failed/total/aborted/roots/explicitToken）。
# 早期断言写死 'success=6/6'，后来 detail 改成逐字段统计（多了 skipped/failed/total/aborted），
# 断言就再没匹配上 → CI 从那时起一直红。这里按字段解析，既不脆也不怕以后加字段。
fields = dict(kv.split('=', 1) for kv in p0['detail'].split() if '=' in kv)
assert p0['status'] == 'ok' and fields.get('success') == '6' and fields.get('total') == '6' \
    and fields.get('failed') == '0' and fields.get('aborted') == 'false', p0
assert '18070' in p0['target'], p0
assert 'target_token' not in json.dumps(p0) and p0['detail'].count('explicitToken=true') <= 1, p0
assert p0['ipAddr'] and p0['userAgent'], p0
print('  发布计划推送审计（目标/计数/不落 token）✓')
"
# 5.5 未鉴权访问日志端点 → 401
CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORTA/api/admin/logs/all")
[ "$CODE" = "401" ] || { echo "未鉴权应 401，实际 $CODE"; exit 1; }
echo "  未鉴权查询日志被拒（401）✓"

echo ""
echo "=== 6. 公开只读 API（C1–C5）==="
curl -s "http://localhost:$PORTA/api/stats" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['packages'] >= 6 and d['versions'] >= 6, d
assert d['serverVersion'] and d['startedAt'] > 0, d
assert d['storageBytes'] > 0, d
print('  /api/stats：%d 包 / %d 版本 / %d 下载 / %d 字节 ✓' % (d['packages'], d['versions'], d['downloads'], d['storageBytes']))
"
curl -s "http://localhost:$PORTA/api/packages?size=100" | python3 -c "
import sys, json
d = json.load(sys.stdin)
names = [x['fullName'] for x in d['items']]
assert d['total'] >= 6, d
assert 'test::app' in names and 'test::mathUtils' in names, names
row = [x for x in d['items'] if x['name'] == 'app'][0]
assert row['versionCount'] >= 1 and row['latestVersion'] == '1.0.0', row
assert row['updatedAt'] > 0 and isinstance(row['categories'], list) and isinstance(row['license'], list), row
print('  /api/packages：%d 包（含聚合字段）✓' % d['total'])
"
curl -s "http://localhost:$PORTA/api/packages?q=test::app" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['total'] == 1 and d['items'][0]['fullName'] == 'test::app', d
print('  q=org::name 语法 ✓')
"
curl -s "http://localhost:$PORTA/api/packages?organization=test&page=2&size=2&sort=name" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['total'] >= 6 and len(d['items']) == 2 and d['page'] == 2, d
print('  组织过滤 + 分页 + 排序 ✓')
"
curl -s "http://localhost:$PORTA/api/packages/app?organization=test" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['name'] == 'app' and d['fullName'] == 'test::app', d
assert d['versionCount'] >= 1 and d['latestVersion'] == '1.0.0', d
assert d['versions'][0]['sha256'], d
assert d['versions'][0]['publisherName'] == '$ADMIN_USER', d
print('  /api/packages/app：%d 版本 + sha256 + 发布者 ✓' % d['versionCount'])
"
curl -s "http://localhost:$PORTA/api/packages/app/1.0.0?organization=test" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['version'] == '1.0.0', d
assert d['sha256'] and d['tarballSize'] > 0, d
assert 'cjcVersion' in d and 'publisherName' in d and d['publisherName'] == '$ADMIN_USER', d
print('  /api/packages/app/1.0.0：版本详情 ✓')
"
CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORTA/api/packages/app/9.9.9?organization=test")
[ "$CODE" = "404" ] || { echo "不存在的版本应 404，实际 $CODE"; exit 1; }
curl -s "http://localhost:$PORTA/api/organizations" | python3 -c "
import sys, json
d = json.load(sys.stdin)
orgs = {x['name']: x for x in d['items']}
assert 'test' in orgs, d
assert orgs['test']['packageCount'] >= 6 and orgs['test']['versionCount'] >= 6, orgs['test']
print('  /api/organizations：%d 个组织（含包/版本计数）✓' % d['total'])
"
# B 仓（回源落库后的公开数据同样可用）
curl -s "http://localhost:$PORTB/api/packages?size=100" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['total'] >= 6, d
print('  B 仓公开包列表：%d 包 ✓' % d['total'])
"

echo ""
echo "=== 7. 上游连通性测试端点（POST /api/admin/upstreams/:id/test）==="
# B 作为 A 的上游加入（步骤 7 放在最后，不影响前面的回源/计划路径）
BID=$(curl -s -X POST http://localhost:$PORTA/api/admin/upstreams -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"mirrorB\",\"url\":\"http://localhost:$PORTB\",\"priority\":\"5\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
curl -s -X POST "http://localhost:$PORTA/api/admin/upstreams/$BID/test?name=app&organization=test" \
  -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['reachable'] and d['healthy'], d
assert d['status'] == 200 and d['bodyBytes'] > 0, d
assert d['upstreamName'] == 'mirrorB' and '$PORTB' in d['testedUrl'], d
assert 'app' in d['packages'], d
print('  可达上游：%s（%dms，%d 字节，样本 %s）✓' % (d['summary'], d['latencyMs'], d['bodyBytes'], d['packages']))
"
# 不存在的包：有响应（连通）但非健康
curl -s -X POST "http://localhost:$PORTA/api/admin/upstreams/$BID/test?name=nopeXYZ" \
  -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['reachable'] and not d['healthy'], d
assert d['status'] == 404 and 'nopeXYZ' in d['testedUrl'], d
print('  上游无此包：连通但非健康（404）✓')
"
# 不可达上游
DEADID=$(curl -s -X POST http://localhost:$PORTA/api/admin/upstreams -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"name":"deadUpstream","url":"http://127.0.0.1:9","priority":"9"}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
curl -s -X POST "http://localhost:$PORTA/api/admin/upstreams/$DEADID/test" -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert not d['reachable'] and d['status'] == 0 and d['error'], d
print('  不可达上游：reachable=false（原因已记录）✓')
"
# 清理：删除刚加的两个上游，避免影响后续手工验证
curl -s -o /dev/null -X DELETE "http://localhost:$PORTA/api/admin/upstreams/$BID" -H "Authorization: Bearer $TOKEN"
curl -s -o /dev/null -X DELETE "http://localhost:$PORTA/api/admin/upstreams/$DEADID" -H "Authorization: Bearer $TOKEN"
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:$PORTA/api/admin/upstreams/9999/test" \
  -H "Authorization: Bearer $TOKEN")
[ "$CODE" = "404" ] || { echo "不存在的上游应 404，实际 $CODE"; exit 1; }
# 探测动作入审计
curl -s "http://localhost:$PORTA/api/admin/logs/admin?keyword=test_upstream&limit=5" -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['total'] >= 3, d
acts = {x['target']: x['status'] for x in d['items']}
assert acts.get('mirrorB') == 'ok' and acts.get('deadUpstream') == 'failed', acts
print('  连通性测试入审计（成功/失败分别记录）✓')
"

echo ""
echo "=== 8. 包三级删除闭环（软删 / 恢复 / 硬删）==="
# 8.1 管理端版本列表拿到 id + sha（自动化入口）
INFO=$(curl -s "http://localhost:$PORTA/api/admin/packages?organization=test&name=mathUtils&includeDeleted=1" \
  -H "Authorization: Bearer $TOKEN")
PID=$(echo "$INFO" | python3 -c "import sys,json;d=json.load(sys.stdin);assert d['total']>=1,d;print(d['items'][0]['id'])")
SHA=$(echo "$INFO" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['items'][0]['sha256'])")
echo "  mathUtils id=$PID sha=${SHA:0:12}…"
[ -f ".smoke/A/data/blobs/$SHA" ] || { echo "  制品文件应存在：.smoke/A/data/blobs/$SHA"; exit 1; }

# 8.2 软删除：索引/下载/公开 API 立即不可见，制品保留
curl -s -X DELETE "http://localhost:$PORTA/api/admin/packages/$PID" -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['status'] == 'ok', d
print('  软删除：%s（跳过计划项 %d）✓' % (d['message'], d['skippedPlanItems']))
"
CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORTA/pkg/mathUtils/1.0.0?organization=test")
[ "$CODE" = "404" ] || { echo "  软删后制品下载应 404，实际 $CODE"; exit 1; }
CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORTA/index/ma/th/mathUtils?organization=test")
[ "$CODE" = "404" ] || { echo "  软删后索引应 404，实际 $CODE"; exit 1; }
curl -s "http://localhost:$PORTA/api/packages?q=test::mathUtils" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['total'] == 0, d
print('  软删后：下载 404 / 索引 404 / 公开 API 不可见 ✓')
"
[ -f ".smoke/A/data/blobs/$SHA" ] || { echo "  软删除不应删除制品文件"; exit 1; }

# 8.3 恢复（校验制品仍在）→ 索引/下载/公开 API 全部回来
curl -s -X PUT "http://localhost:$PORTA/api/admin/packages/$PID/restore" -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['status'] == 'ok' and d['artifactPresent'], d
print('  恢复：%s（制品存在=%s）✓' % (d['message'], d['artifactPresent']))
"
curl -s -o /dev/null -w "" "http://localhost:$PORTA/pkg/mathUtils/1.0.0?organization=test"
CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORTA/pkg/mathUtils/1.0.0?organization=test")
[ "$CODE" = "200" ] || { echo "  恢复后下载应 200，实际 $CODE"; exit 1; }
curl -s "http://localhost:$PORTA/api/packages?q=test::mathUtils" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['total'] == 1 and d['items'][0]['latestVersion'] == '1.0.0', d
print('  恢复后：下载 200 / 公开 API 可见 ✓')
"

# 8.4 硬删前置：未软删直接硬删 → 409
curl -s -o /dev/null -w "%{http_code}" -X DELETE "http://localhost:$PORTA/api/admin/packages/$PID/hard" \
  -H "Authorization: Bearer $TOKEN" | grep -q 409 || { echo "  未软删直接硬删应 409"; exit 1; }
echo "  未软删直接硬删被拒（409）✓"

# 8.5 硬删：删记录 + 制品文件
curl -s -o /dev/null -X DELETE "http://localhost:$PORTA/api/admin/packages/$PID" -H "Authorization: Bearer $TOKEN"
curl -s -X DELETE "http://localhost:$PORTA/api/admin/packages/$PID/hard" -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['status'] == 'ok' and d['blobRemoved'], d
print('  硬删除：%s（制品已删=%s）✓' % (d['message'], d['blobRemoved']))
"
[ -f ".smoke/A/data/blobs/$SHA" ] && { echo "  硬删除后制品文件应已删除"; exit 1; }
curl -s "http://localhost:$PORTA/api/admin/packages?organization=test&name=mathUtils&includeDeleted=1" \
  -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['total'] == 0, d
print('  硬删后记录消失 / 制品文件已清理 ✓')
"
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "http://localhost:$PORTA/api/admin/packages/$PID/restore" -H "Authorization: Bearer $TOKEN")
[ "$CODE" = "404" ] || { echo "  硬删后恢复应 404，实际 $CODE"; exit 1; }

# 8.6 审计：三种操作都有记录
curl -s "http://localhost:$PORTA/api/admin/logs/admin?limit=50" -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys, json
d = json.load(sys.stdin)
actions = {x['action'] for x in d['items']}
for a in ('delete_package', 'restore_package', 'hard_delete_package'):
    assert a in actions, (a, sorted(actions))
print('  审计：delete_package / restore_package / hard_delete_package 均已记录 ✓')
"

echo ""
echo "=== 9. 组织 CRUD REST（/api/admin/organizations）==="
# 9.1 创建（含非法名与重名守卫）
OID=$(curl -s -X POST "http://localhost:$PORTA/api/admin/organizations" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"name":"e2eOrg","displayName":"E2E 组织","description":"e2e 用"}' \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['status'] == 'ok' and d['id'] > 0, d
print(d['id'])
")
echo "  创建组织 e2eOrg（id=$OID）✓"
curl -s -o /tmp/org_dup.json -w "%{http_code}" -X POST "http://localhost:$PORTA/api/admin/organizations" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"name":"e2eOrg"}' | grep -q 409 \
  || { echo "  重名应 409"; exit 1; }
grep -q duplicate_name /tmp/org_dup.json || { echo "  重名错误码应为 duplicate_name"; exit 1; }
curl -s -o /tmp/org_bad.json -w "%{http_code}" -X POST "http://localhost:$PORTA/api/admin/organizations" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"name":"bad name"}' | grep -q 400 \
  || { echo "  非法名应 400"; exit 1; }
grep -q invalid_name /tmp/org_bad.json || { echo "  非法名错误码应为 invalid_name"; exit 1; }
echo "  重名 409 / 非法名 400 ✓"

# 9.2 列表 / 详情（含包/版本计数）
curl -s "http://localhost:$PORTA/api/admin/organizations" -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys, json
d = json.load(sys.stdin)
orgs = {o['name']: o for o in d['items']}
assert 'e2eOrg' in orgs and orgs['e2eOrg']['id'] == $OID, d
assert orgs['e2eOrg']['displayName'] == 'E2E 组织', orgs['e2eOrg']
assert orgs['e2eOrg']['packageCount'] == 0 and orgs['e2eOrg']['teamCount'] == 0, orgs['e2eOrg']
print('  列表：%d 个组织（e2eOrg 计数为 0）✓' % d['total'])
"
# 已登记且有包的 test 组织（包是直接发布的，组织由发布侧隐式存在）
curl -s -X POST "http://localhost:$PORTA/api/admin/organizations" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"name":"test","displayName":"测试组织"}' | grep -q '"status":"ok"' \
  || { echo "  登记 test 组织失败"; exit 1; }
TID=$(curl -s "http://localhost:$PORTA/api/admin/organizations" -H "Authorization: Bearer $TOKEN" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print([o['id'] for o in d['items'] if o['name']=='test'][0])")
curl -s "http://localhost:$PORTA/api/admin/organizations/$TID" -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['name'] == 'test', d
assert d['packageCount'] >= 5 and d['versionCount'] >= 5, d   # 第 8 步硬删了一个版本，剩 5 个包
print('  详情：test 组织 %d 包 / %d 版本 ✓' % (d['packageCount'], d['versionCount']))
"

# 9.3 更新（改显示名 + 设默认）与改名守卫
curl -s -X PUT "http://localhost:$PORTA/api/admin/organizations/$OID" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"displayName":"改后显示名","isDefault":true}' | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['status'] == 'ok', d
print('  更新显示名 + 设为默认 ✓')
"
curl -s "http://localhost:$PORTA/api/admin/organizations/$OID" -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['displayName'] == '改后显示名' and d['isDefault'], d
print('  更新已生效 ✓')
"
curl -s -o /tmp/org_rename.json -w "%{http_code}" -X PUT "http://localhost:$PORTA/api/admin/organizations/$TID" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{"name":"testRenamed"}' | grep -q 409 \
  || { echo "  有包的组织改名应 409"; exit 1; }
grep -q rename_with_packages /tmp/org_rename.json || { echo "  改名守卫错误码应为 rename_with_packages"; exit 1; }
curl -s -X PUT "http://localhost:$PORTA/api/admin/organizations/$TID" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"description":"仅改描述"}' | grep -q '"status":"ok"' \
  || { echo "  无改名时更新应成功"; exit 1; }
echo "  有包禁改名 409 / 仅改描述成功 ✓"

# 9.4 删除守卫与删除
curl -s -o /tmp/org_del.json -w "%{http_code}" -X DELETE "http://localhost:$PORTA/api/admin/organizations/$TID" \
  -H "Authorization: Bearer $TOKEN" | grep -q 409 || { echo "  有包的组织删除应 409"; exit 1; }
grep -q has_packages /tmp/org_del.json || { echo "  删除守卫错误码应为 has_packages"; exit 1; }
curl -s -X DELETE "http://localhost:$PORTA/api/admin/organizations/$OID" -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['status'] == 'ok', d
print('  有包 409 / 无包删除成功 ✓')
"
CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "http://localhost:$PORTA/api/admin/organizations/$OID" \
  -H "Authorization: Bearer $TOKEN")
[ "$CODE" = "404" ] || { echo "  重复删除应 404，实际 $CODE"; exit 1; }
echo "  重复删除 404 ✓"

# 9.5 公开组织列表同步 + 审计
curl -s "http://localhost:$PORTA/api/organizations" | python3 -c "
import sys, json
d = json.load(sys.stdin)
names = {o['name'] for o in d['items']}
assert 'test' in names, d
assert 'e2eOrg' not in names, d   # 已删除
print('  公开 /api/organizations 与登记状态一致（%d 个）✓' % d['total'])
"
curl -s "http://localhost:$PORTA/api/admin/logs/admin?limit=50" -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys, json
d = json.load(sys.stdin)
actions = {x['action'] for x in d['items']}
for a in ('create_org', 'update_org', 'delete_org'):
    assert a in actions, (a, sorted(actions))
fails = [x for x in d['items'] if x['action'] == 'delete_org' and x['status'] == 'failed']
assert fails, d
print('  审计：create/update/delete_org 已记录（含守卫失败）✓')
"

echo ""
echo "=== 双仓 e2e 全部通过 ✓ ==="
