#!/usr/bin/env bash
# cjreg 性能基准（正式报告的数据来源）
#
# 测量口径（全部在本机 loopback，只反映服务端开销，不是容量规划数字）：
#   A 索引：回源 vs 本地命中 —— 「命中」不只看延迟变小，还要用桩服务的计数证明**没有回源**
#   B 制品下载：回源 vs 本地 blob（内容寻址命中）
#   C 发布吞吐：2 / 32 / 200 MiB（含进程 VmHWM，用于对照"内存与包体无关"）
#   D 并发：k6 打索引接口，1 / 4 / 16 / 64 并发
#   E 生命周期：启动 → healthy、优雅关闭（SIGTERM → exit 0）耗时
#   F 正确性护栏：压测后发布数 = 可下载数、sha 一致（避免"跑分好看但丢数据"）
#
# 上游隔离：**不碰真实中心仓**。桩服务（bench-stub-upstream.py）代替上游，
# 并把 official 的读路径开关 proxy_enabled 关掉，因此所有回源只可能落到桩上。
#
# 用法：
#   bash scripts/bench.sh              # 标准档（默认）
#   bash scripts/bench.sh quick        # 快速档（次数与体积都缩小）
#
# 输出：.smoke/bench/results/（原始输出 + summary.tsv），并打印环境信息供报告引用。
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
MODE="${1:-full}"
PORT="${BENCH_PORT:-18080}"
STUB_PORT="${BENCH_STUB_PORT:-18081}"
WORK="$ROOT/.smoke/bench"
DATA="$WORK/data"
RES="$WORK/results"
BIN="$ROOT/target/release/bin/ystyle::cjreg"
ADMIN_USER=admin
ADMIN_PASS='BenchPass1'
BASE="http://127.0.0.1:$PORT"
STUB="http://127.0.0.1:$STUB_PORT"

if [ "$MODE" = "quick" ]; then
  ITER=30; DL_ITER=10; PUB_SIZES=(2 32); CONC=(1 4 16); STUB_ART=$((2 * 1024 * 1024))
else
  ITER=100; DL_ITER=30; PUB_SIZES=(2 32 200); CONC=(1 4 16 64); STUB_ART=$((2 * 1024 * 1024))
fi

say()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
row()  { printf '%-28s %s\n' "$1" "$2"; }
fail() { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; }

[ -x "$BIN" ] || { fail "未找到 $BIN（先 cjpm build -j 16）"; exit 1; }
mkdir -p "$RES"

# ── 0. 环境 ─────────────────────────────────────────────────────────────────
say "环境信息"
{
  echo "cpu_cores=$(nproc)"
  echo "cpu_model=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
  echo "mem_gib=$(free -g | awk '/^Mem:/{print $2}')"
  echo "disk=$(df -h "$ROOT" | awk 'NR==2{print $1" "$2}')"
  echo "kernel=$(uname -sr)"
  echo "binary_bytes=$(stat -c%s "$BIN")"
  echo "mode=$MODE iter=$ITER dl_iter=$DL_ITER"
  echo "date=$(date -Is)"
} | tee "$RES/env.txt" | sed 's/^/    /'

# ── 1. 起桩上游 + bench 实例 ────────────────────────────────────────────────
say "启动桩上游（:$STUB_PORT）与 bench 实例（:$PORT）"
rm -rf "$WORK"; mkdir -p "$DATA" "$RES"

# 桩上游：制品 2 MiB，索引与制品各带 5ms 固定延迟，代表"上游有网络往返"
STUB_DELAY_MS="${STUB_DELAY_MS:-5}" STUB_ARTIFACT_BYTES="$STUB_ART" \
  python3 "$ROOT/scripts/bench-stub-upstream.py" --port "$STUB_PORT" \
    --packages "$(python3 -c "print(','.join('bench-p%03d' % i for i in range($ITER)))"),bench-dl" \
    --artifact-bytes "$STUB_ART" \
  >"$RES/stub.log" 2>&1 &
STUB_PID=$!

"$BIN" init -d "$DATA" --username "$ADMIN_USER" --password "$ADMIN_PASS" >/dev/null 2>&1 || { fail "init 失败"; exit 1; }
# 请求体上限：发布档位最大 200 MiB（制品 + meta + 段头），留 25% 余量
python3 - "$DATA/cjreg.toml" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
line = 'max_request_bytes = %d' % (300 * 1024 * 1024)
if 'max_request_bytes' in s:
    s = '\n'.join((line if l.startswith('max_request_bytes') else l) for l in s.split('\n'))
    io.open(p, 'w', encoding='utf-8').write(s)
PY

START_T0=$(date +%s.%N)
"$BIN" serve -d "$DATA" -p "$PORT" >"$RES/server.log" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 60); do
  curl -s -m 2 "$BASE/api/health" >/dev/null 2>&1 && break
  sleep 0.25
done
START_T1=$(date +%s.%N)
curl -s -m 3 "$BASE/api/health" >/dev/null 2>&1 || { fail "服务未就绪（见 $RES/server.log）"; exit 1; }
STARTUP=$(python3 -c "print('%.3f' % ($START_T1 - $START_T0))")
row "启动→可服务（秒）" "$STARTUP"

cleanup() {
  kill "$SRV_PID" 2>/dev/null
  wait "$SRV_PID" 2>/dev/null
  kill "$STUB_PID" 2>/dev/null
  wait "$STUB_PID" 2>/dev/null
}
trap cleanup EXIT

TOKEN=$(curl -s -X POST "$BASE/api/admin/login" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$ADMIN_USER\",\"password\":\"$ADMIN_PASS\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))")
[ -n "$TOKEN" ] || { fail "登录失败"; exit 1; }
PUB=$(curl -s -X POST "$BASE/api/user/me/publish-token" -H "Authorization: Bearer $TOKEN" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('publishToken',''))")
[ -n "$PUB" ] || { fail "取发布 Token 失败"; exit 1; }

# ── 2. 上游隔离：加桩上游 + 关掉 official 的读路径 ──────────────────────────
say "配置上游（桩上游 + 关闭 official 回源）"
curl -s -X POST "$BASE/api/admin/upstreams" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"name\":\"bench-stub\",\"url\":\"$STUB\",\"priority\":100,\"proxy_enabled\":true,\"as_target\":false}" \
  >"$RES/upstream-add.json"
# GET 返回 isOfficial / proxyEnabled（camelCase），PUT 也只接受 camelCase
OFFICIAL_ID=$(curl -s "$BASE/api/admin/upstreams" -H "Authorization: Bearer $TOKEN" \
  | python3 -c "
import sys,json
for u in json.load(sys.stdin):
    if u.get('isOfficial'): print(u['id']); break
")
if [ -n "$OFFICIAL_ID" ]; then
  curl -s -X PUT "$BASE/api/admin/upstreams/$OFFICIAL_ID" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d '{"proxyEnabled":false,"enabled":false}' >"$RES/upstream-disable-official.json"
fi
curl -s "$BASE/api/admin/upstreams" -H "Authorization: Bearer $TOKEN" >"$RES/upstreams.json"
python3 - "$RES/upstreams.json" <<'PY' | tee -a "$RES/env.txt" | sed 's/^/    /'
import io, json, sys
bad = []
for u in json.load(io.open(sys.argv[1], encoding='utf-8')):
    print("upstream %-12s url=%-28s proxy=%-5s target=%-5s priority=%s"
          % (u['name'], u['url'], u.get('proxyEnabled'), u.get('asTarget'), u.get('priority')))
    # official 若还开着回源，请求会先打到真实中心仓（有网络往返与重试）→ 数据被污染
    if u.get('isOfficial') and u.get('proxyEnabled'):
        bad.append(u['name'])
if bad:
    print("FATAL: 这些官方上游仍开着回源，真实中心仓会污染测量: %s" % ",".join(bad))
    raise SystemExit(3)
PY
[ "${PIPESTATUS[0]}" = "3" ] && { fail "上游隔离未生效，终止（不要用被污染的数据出报告）"; exit 1; }

# ── A. 索引：回源 / 同 org 重查 / 本地发布命中 ──────────────────────────────
say "A 索引三档（各 $ITER 次）"
stats() {  # stdin: 毫秒值 → p50 p95 p99 avg
  python3 -c "
import sys
v = sorted(float(x) for x in sys.stdin.read().split() if x.strip())
if not v: print('0 0 0 0'); raise SystemExit
def q(p): return v[min(len(v)-1, int(len(v)*p))]
print('%.2f %.2f %.2f %.2f' % (q(0.50), q(0.95), q(0.99), sum(v)/len(v)))
"
}
index_ms() {  # $1=org 前缀 $2=包名 $3=轮数
  python3 - "$BASE" "$ITER" "$1" "$2" <<'PY'
import sys, time, urllib.request
base, n, orgpfx, pkg = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
out = []
for i in range(n):
    # 每轮换一个包名：本地都没有 → 每次都真回源（同一包第二次就已经落库，测到的是命中）
    p = "%s%03d" % (pkg, i)
    suffix = ("?organization=%s%d" % (orgpfx, i)) if orgpfx else ""
    url = "%s/index/%s/%s/%s%s" % (base, p[0:2], p[2:4], p, suffix)
    t = time.perf_counter()
    try: urllib.request.urlopen(url, timeout=60).read()
    except Exception: pass
    out.append("%.3f" % ((time.perf_counter() - t) * 1000))
print("\n".join(out))
PY
}
stub_counts() { curl -s "$STUB/__stats" | python3 -c "import sys,json;print(json.load(sys.stdin)['index'])"; }

curl -s -X POST "$STUB/__reset" >/dev/null 2>&1
BEFORE=$(stub_counts)
COLD_MS=$(index_ms "" bench-p)                    # 100 个不同包，每个首次 → 每次都真回源
MID=$(stub_counts)
WARM_MS=$(index_ms "" bench-p)                    # 同样 100 个包再查一遍 → 应全部命中本地
AFTER=$(stub_counts)
echo "$COLD_MS" > "$RES/index-cold-ms.txt"; echo "$WARM_MS" > "$RES/index-warm-ms.txt"

row "索引 回源(本地无) p50/p95/p99/avg" "$(echo "$COLD_MS" | stats)"
row "索引 重查(同 org) p50/p95/p99/avg" "$(echo "$WARM_MS" | stats)"
row "桩计数 回源轮/重查轮" "$BEFORE→$MID→$AFTER（重查轮增量 $((AFTER - MID))）"

# ── B. 制品下载：回源 vs 本地 blob ──────────────────────────────────────────
say "B 制品下载：回源 vs 本地 blob（各 $DL_ITER 次，制品 $((STUB_ART / 1024 / 1024)) MiB）"
DL_PKG_BEFORE=$(curl -s "$STUB/__stats" | python3 -c "import sys,json;print(json.load(sys.stdin)['pkg'])")
DL_COLD=$(python3 - "$BASE" "$DL_ITER" <<'PY'
import sys, time, urllib.request
base, n = sys.argv[1], int(sys.argv[2])
out = []
for i in range(n):
    url = "%s/pkg/bench-dl/1.0.0" % base   # 首次 → 回源
    t = time.perf_counter()
    try: urllib.request.urlopen(url, timeout=120).read()
    except Exception: pass
    out.append("%.3f" % ((time.perf_counter() - t) * 1000))
print("\n".join(out))
PY
)
echo "$DL_COLD" > "$RES/download-cold-ms.txt"
DL_HIT=$(python3 - "$BASE" "$DL_ITER" <<'PY'
import sys, time, urllib.request
base, n = sys.argv[1], int(sys.argv[2])
out = []
for i in range(n):
    url = "%s/pkg/bench-dl/1.0.0" % base   # 同上 → 应命中本地 blob
    t = time.perf_counter()
    try: urllib.request.urlopen(url, timeout=120).read()
    except Exception: pass
    out.append("%.3f" % ((time.perf_counter() - t) * 1000))
print("\n".join(out))
PY
)
echo "$DL_HIT" > "$RES/download-hit-ms.txt"
row "下载 回源 p50/p95/p99/avg (ms)" "$(echo "$DL_COLD" | stats)"
DL_PKG_AFTER=$(curl -s "$STUB/__stats" | python3 -c "import sys,json;print(json.load(sys.stdin)['pkg'])")
row "下载 命中 p50/p95/p99/avg (ms)" "$(echo "$DL_HIT" | stats)"
row "桩 pkg 计数（回源轮后/命中轮后）" "$DL_PKG_BEFORE → 回源轮后 $((DL_PKG_BEFORE + 1)) → 命中轮后 $DL_PKG_AFTER"

# ── C. 发布吞吐 + VmHWM ─────────────────────────────────────────────────────
say "C 发布吞吐（${PUB_SIZES[*]} MiB）与进程 VmHWM"
: > "$RES/publish.tsv"
for mib in "${PUB_SIZES[@]}"; do
  TAR="$WORK/tar-$mib.bin"; BODY="$WORK/body-$mib.bin"
  head -c $((mib * 1024 * 1024)) /dev/zero > "$TAR"
  SHA=$(sha256sum "$TAR" | cut -d' ' -f1)
  python3 - "$TAR" "$BODY" "$mib" "$SHA" <<'PY'
import io, struct, sys
tar_path, body_path, mib, sha = sys.argv[1:5]
meta = ('{"organization":"benchpub","name":"pub%s","version":"1.0.0",'
        '"cjc-version":"1.1.3","description":"bench","artifact-type":"src",'
        '"index":{"sha256sum":"%s","index-version":1}}') % (mib, sha)
mb = meta.encode()
with io.open(body_path, 'wb') as out:
    out.write(bytes([1]) + struct.pack('<I', len(mb)) + mb)
    out.write(bytes([1]) + struct.pack('<I', io.open(tar_path, 'rb').seek(0, 2)))
    with io.open(tar_path, 'rb') as f:
        while True:
            c = f.read(1024 * 1024)
            if not c: break
            out.write(c)
PY
  T0=$(date +%s.%N)
  CODE=$(curl -s -o "$WORK/pub-$mib.json" -w '%{http_code}' -X POST \
    "$BASE/pkg/pub$mib?organization=benchpub" -H "Authorization: $PUB" \
    -H 'Content-Type: application/octet-stream' --data-binary "@$BODY" -m 900)
  T1=$(date +%s.%N)
  SECS=$(python3 -c "print('%.3f' % ($T1 - $T0))")
  HWM=$(awk '/VmHWM/{print int($2/1024)}' "/proc/$SRV_PID/status" 2>/dev/null || echo 0)
  MBPS=$(python3 -c "print('%.1f' % ($mib / max(0.001, $SECS)))")
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$mib" "$CODE" "$SECS" "$HWM" "$MBPS" "$SHA" >> "$RES/publish.tsv"
  row "发布 ${mib} MiB" "HTTP $CODE · ${SECS}s · ${MBPS} MiB/s · VmHWM ${HWM} MiB"
done

# 本地发布命中：本地发布的包走 indexSvc.generate，不触上游
LOCAL_MS=$(python3 - "$BASE" "$ITER" <<'PY'
import sys, time, urllib.request
base, n = sys.argv[1], int(sys.argv[2])
out = []
for i in range(n):
    url = "%s/index/pu/b2/pub2?organization=benchpub" % base
    t = time.perf_counter()
    try: urllib.request.urlopen(url, timeout=60).read()
    except Exception: pass
    out.append("%.3f" % ((time.perf_counter() - t) * 1000))
print("\n".join(out))
PY
)
echo "$LOCAL_MS" > "$RES/index-local-ms.txt"
LOCAL_AFTER=$(stub_counts)
row "索引 本地发布命中 p50/p95/p99/avg" "$(echo "$LOCAL_MS" | stats)"
row "本地命中轮 桩计数增量" "$((LOCAL_AFTER - AFTER))（应为 0）"

# ── D. 并发（k6）────────────────────────────────────────────────────────────
if command -v k6 >/dev/null 2>&1; then
  say "D 并发：k6 打索引（命中态）VU=${CONC[*]}"
  : > "$RES/concurrency.txt"
  for vu in "${CONC[@]}"; do
    k6 run --quiet --summary-export="$RES/k6-$vu.json" --vus "$vu" --duration 10s \
      -e BASE="$BASE" "$ROOT/scripts/bench-index.js" >/dev/null 2>&1
    read -r REQS P95 <<<"$(python3 -c "
import json
m = json.load(open('$RES/k6-$vu.json'))['metrics']
print(int(m['http_reqs']['count']), round(m['http_req_duration']['p(95)'], 2))
" 2>/dev/null || echo '? ?')"
    printf '%s\t%s\t%s\n' "$vu" "$REQS" "$P95" >> "$RES/concurrency.txt"
    row "并发 ${vu} VU（10s）" "请求 $REQS · p95 ${P95} ms · ≈$((REQS / 10)) req/s"
  done
else
  say "D 跳过：未安装 k6"
fi

# ── F. 正确性护栏 ───────────────────────────────────────────────────────────
say "F 正确性护栏：发布过的包都能下载且 sha 一致"
GUARD=$(python3 - "$BASE" "$RES/publish.tsv" <<'PY'
import hashlib, io, sys, urllib.request
base, tsv = sys.argv[1], sys.argv[2]
rows = [l.rstrip('\n').split('\t') for l in io.open(tsv, encoding='utf-8') if l.strip()]
ok, total, notes = 0, 0, []
for r in rows:
    if len(r) < 3:
        continue
    mib, code, _secs, _hwm, _mbps, sha = (r + [''] * 6)[:6]
    total += 1
    # 发布成功就必须能原样下回来：内容 sha 与发布时一致才算数
    try:
        data = urllib.request.urlopen(
            "%s/pkg/pub%s/1.0.0?organization=benchpub" % (base, mib), timeout=90).read()
        got = hashlib.sha256(data).hexdigest()
        if got == sha:
            ok += 1
        else:
            notes.append("pub%s sha 不符" % mib)
    except Exception as e:
        notes.append("pub%s 下载失败(%s)" % (mib, type(e).__name__))
print("%d/%d 下载且 sha 一致%s" % (ok, total, ("；" + "；".join(notes)) if notes else ""))
PY
)
row "护栏" "$GUARD"

# ── E. 优雅关闭 ─────────────────────────────────────────────────────────────
say "E 优雅关闭（SIGTERM）"
K0=$(date +%s.%N)
kill -TERM "$SRV_PID" 2>/dev/null
SRV_RC=0
wait "$SRV_PID" || SRV_RC=$?
K1=$(date +%s.%N)
SHUT=$(python3 -c "print('%.3f' % ($K1 - $K0))")
row "关闭耗时 / exit code" "${SHUT}s / $SRV_RC"
SRV_PID=""   # 已退出，避免 cleanup 重复 wait

# ── 汇总 ────────────────────────────────────────────────────────────────────
say "汇总 → $RES/summary.tsv"
{
  printf '指标\t值\n'
  printf 'startup_seconds\t%s\n' "$STARTUP"
  printf 'index_cold_ms_p50_p95_p99_avg\t%s\n' "$(echo "$COLD_MS" | stats)"
  printf 'index_warm_ms_p50_p95_p99_avg\t%s\n' "$(echo "$WARM_MS" | stats)"
  printf 'index_local_ms_p50_p95_p99_avg\t%s\n' "$(echo "$LOCAL_MS" | stats)"
  printf 'stub_index_counts_cold_mid_warm\t%s -> %s -> %s\n' "$BEFORE" "$MID" "$AFTER"
  printf 'stub_index_delta_warm\t%s\n' "$((AFTER - MID))"
  printf 'stub_index_delta_local\t%s\n' "$((LOCAL_AFTER - AFTER))"
  printf 'download_cold_ms_p50_p95_p99_avg\t%s\n' "$(echo "$DL_COLD" | stats)"
  printf 'download_hit_ms_p50_p95_p99_avg\t%s\n' "$(echo "$DL_HIT" | stats)"
  printf 'shutdown_seconds\texit=%s\n' "$SRV_RC"
  printf 'shutdown_time\t%s\n' "$SHUT"
  printf 'guard\t%s\n' "$GUARD"
  printf 'publish_mib_code_secs_vmhwm_mbps\n'
  sed 's/^/\t/' "$RES/publish.tsv"
} | tee "$RES/summary.tsv"
say "原始输出在 $RES/"
