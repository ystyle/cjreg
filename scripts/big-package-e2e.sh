#!/usr/bin/env bash
# 大包发布 e2e：验证发布链路是**流式**的（进程内存占用与包体无关）。
#
# 背景：官方协议允许单段 500 MB，而"整包读入内存"的实现下，峰值内存 ≈ 包体 2–3 倍；
# 仓颉运行时 GC 堆默认上限 256 MB，40 MiB 以上的包就可能触顶（见 docs/verification.md §5.1）。
#
# 用法：
#   bash scripts/big-package-e2e.sh            # 默认 48 100 200 MiB
#   bash scripts/big-package-e2e.sh 48 500     # 自定义档位
#
# 输出：每档的 HTTP 结果与发布进程的 VmHWM（峰值物理内存），并给出通过/失败判定：
#   - 每档都必须发布成功（HTTP 200）
#   - VmHWM 必须**明显低于包体**（流式生效；整包驻留时会 ≥ 包体）
#
# 数据目录固定在仓内 .smoke/（生产数据在 ~/docker，本脚本不接触）。
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
PORT="${BIGPKG_PORT:-18077}"
WORK="$ROOT/.smoke/bigpkg"
DATA="$WORK/data"
BIN="$ROOT/target/release/bin/ystyle::cjreg"
USERNAME=admin
PASSWORD='BigPkgPass1'
SIZES=("$@")
[ ${#SIZES[@]} -gt 0 ] || SIZES=(48 100 200)

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; }

[ -x "$BIN" ] || { fail "未找到可执行文件 $BIN（先 cjpm build -j 16）"; exit 1; }

say "准备数据目录 $DATA"
rm -rf "$WORK"
mkdir -p "$DATA"
"$BIN" init -d "$DATA" --username "$USERNAME" --password "$PASSWORD" >/dev/null 2>&1 || { fail "init 失败"; exit 1; }

# 请求体 = 制品 + meta 段 + 10 字节段头，必然略大于制品本身；而 max_request_bytes 默认 500 MiB，
# 正好卡住「500 MiB 制品」这一协议上限档 —— 按最大档位留 25% 余量。
MAX_MIB=0
for m in "${SIZES[@]}"; do [ "$m" -gt "$MAX_MIB" ] && MAX_MIB="$m"; done
MAXREQ=$(( MAX_MIB * 5 / 4 * 1024 * 1024 ))
if [ -f "$DATA/cjreg.toml" ] && grep -q '^max_request_bytes' "$DATA/cjreg.toml"; then
  sed -i "s/^max_request_bytes.*/max_request_bytes = $MAXREQ/" "$DATA/cjreg.toml"
else
  printf '[server]\nmax_request_bytes = %s\n' "$MAXREQ" >> "$DATA/cjreg.toml"
fi
say "max_request_bytes = $MAXREQ（按最大档位 ${MAX_MIB} MiB 留余量）"

# 不设 cjHeapSize：走运行时默认 GC 堆上限（256 MB）—— 这正是要验证的苛刻条件
say "启动服务（端口 $PORT，cjHeapSize=${cjHeapSize:-默认 256MB}）"
"$BIN" serve -d "$DATA" -p "$PORT" >"$WORK/server.log" 2>&1 &
SRV=$!
cleanup() {
  kill "$SRV" 2>/dev/null
  wait "$SRV" 2>/dev/null
}
trap cleanup EXIT

for i in $(seq 1 40); do
  curl -s -m 2 "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -s -m 3 "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1 || { fail "服务未就绪（见 $WORK/server.log）"; exit 1; }

TOKEN=$(curl -s -X POST "http://127.0.0.1:$PORT/api/admin/login" -H 'Content-Type: application/json' \
  -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))")
[ -n "$TOKEN" ] || { fail "登录失败"; exit 1; }
PUB=$(curl -s -X POST "http://127.0.0.1:$PORT/api/user/me/publish-token" -H "Authorization: Bearer $TOKEN" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('publishToken',''))")
[ -n "$PUB" ] || { fail "取发布 Token 失败"; exit 1; }

rc=0
BASE_HWM=""
printf '\n%-8s %-10s %-14s %-14s %s\n' "档位" "包体" "HTTP" "服务 VmHWM" "判定"
for mib in "${SIZES[@]}"; do
  TAR="$WORK/tar-$mib.bin"
  BODY="$WORK/body-$mib.bin"
  say "生成 ${mib} MiB 制品并组包"
  head -c $((mib * 1024 * 1024)) /dev/zero > "$TAR"
  SHA=$(sha256sum "$TAR" | cut -d' ' -f1)
  python3 - "$TAR" "$BODY" "$mib" "$SHA" <<'PY'
import io, struct, sys
tar_path, body_path, mib, sha = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
meta = ('{"organization":"bigpkg","name":"blob%s","version":"1.0.0",'
        '"cjc-version":"1.1.3","description":"big package e2e","artifact-type":"src",'
        '"index":{"sha256sum":"%s","index-version":1}}') % (mib, sha)
mb = meta.encode()
out = io.open(body_path, 'wb')
out.write(bytes([1]) + struct.pack('<I', len(mb)) + mb)
tar_size = io.open(tar_path, 'rb').seek(0, 2)
out.write(bytes([1]) + struct.pack('<I', tar_size))
with io.open(tar_path, 'rb') as f:
    while True:
        chunk = f.read(1024 * 1024)
        if not chunk:
            break
        out.write(chunk)
out.close()
PY

  BEFORE_HWM=$(awk '/VmHWM/{print $2}' "/proc/$SRV/status" 2>/dev/null || echo 0)
  CODE=$(curl -s -o "$WORK/resp-$mib.json" -w '%{http_code}' -X POST \
    "http://127.0.0.1:$PORT/pkg/blob$mib?organization=bigpkg" \
    -H "Authorization: $PUB" -H 'Content-Type: application/octet-stream' \
    --data-binary "@$BODY" -m 900)
  HWM=$(awk '/VmHWM/{print $2}' "/proc/$SRV/status" 2>/dev/null || echo 0)
  HWM_MB=$((HWM / 1024))
  BODY_MB=$((mib * 1024))
  # 流式判据：峰值内存**不随包体增长**（与最小档相比增量 < 64 MiB）。
  # 注意不能用「峰值 < 包体」——小包时进程常驻内存（GC 堆 + badger arena）本就高于包体，
  # 真正要证的是"包体变大、内存不变"。
  if [ -z "$BASE_HWM" ]; then
    BASE_HWM="$HWM_MB"
    DELTA=0
  else
    DELTA=$((HWM_MB - BASE_HWM))
  fi
  if [ "$CODE" != "200" ]; then
    VERDICT="失败：HTTP $CODE（$(head -c 200 "$WORK/resp-$mib.json")）"
    rc=1
  elif [ "$DELTA" -lt 64 ]; then
    VERDICT="通过（较最小档 +${DELTA} MiB）"
  else
    VERDICT="失败：峰值比最小档高 ${DELTA} MiB（内存随包体增长）"
    rc=1
  fi
  printf '%-8s %-10s %-14s %-14s %s\n' "$mib" "${mib} MiB" "$CODE" "${HWM_MB} MiB" "$VERDICT"
done

echo
if [ "$rc" = "0" ]; then
  say "全部档位通过：发布链路为流式（峰值内存不随包体增长）"
else
  fail "存在未通过档位"
fi
exit "$rc"
