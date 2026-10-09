#!/usr/bin/env bash
# 路由守卫：从源码抽出全部 @Page 路径，逐个 HTTP 探测，任一 404 即失败。
#
# 为什么需要它：cjxt 的 @Page 是宏，注册代码落在**定义它的包**里；若该包没有被任何
# 包 import，其包初始化不会执行 —— 编译无警告、符号也在二进制里，但页面**静默 404**。
# ui 包已按站点面拆成子包（src/ui/、src/ui/public/、src/ui/admin/），这条守卫用来
# 盯住"新页面放进子包却忘了在 main.cj 引用"这类回归。
# 详见工作区 `docs/issue/2026-10-09-cjxt-subpackage-page-registration.md`。
#
# 用法：bash scripts/check-routes.sh            # 用默认端口 18099
#       PORT=18088 DATA=... bash scripts/check-routes.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${PORT:-18099}"
DATA="${DATA:-$ROOT/.smoke/auth-data}"
BIN="$ROOT/target/release/bin/ystyle::cjreg"
BASE="http://127.0.0.1:${PORT}"

[ -x "$BIN" ] || { echo "缺少二进制：$BIN（先 cjpm build）"; exit 2; }
[ -d "$DATA" ] || { echo "缺少数据目录：$DATA"; exit 2; }

# 源码是契约：页面写在哪个包都行，只要 @Page 路径能访问到
mapfile -t ROUTES < <(grep -rho '@Page\["[^"]*"' "$ROOT/src/ui" | sed 's/@Page\["//; s/"$//' | sort -u)
[ "${#ROUTES[@]}" -gt 0 ] || { echo "没有从源码抽到任何 @Page 路由"; exit 2; }
echo "从源码抽到 ${#ROUTES[@]} 条 @Page 路由"

"$BIN" serve -d "$DATA" -p "$PORT" >"/tmp/cjreg-route-check-${PORT}.log" 2>&1 &
SRV=$!
trap 'kill "$SRV" 2>/dev/null' EXIT

for _ in $(seq 1 40); do
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 2 "$BASE/api/health" || true)
    [ "$code" = "200" ] && break
    sleep 0.5
done
[ "${code:-}" = "200" ] || { echo "服务未就绪（health=$code），日志：/tmp/cjreg-route-check-${PORT}.log"; exit 2; }

fail=0
for r in "${ROUTES[@]}"; do
    # 占位符换成样例值：参数化路由也要能解析到（页面内部渲染"空态"同样是 200）
    path=$(printf '%s' "$r" | sed 's/\[name\]/demo/g; s/\[id\]/1/g')
    body=$(curl -s -m 10 "$BASE$path" || true)
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$BASE$path" || echo "000")
    # 路由级 404 的响应体固定是 "404 Not Found"；页面内部的"数据不存在"不走这里
    if [ "$code" = "404" ] || printf '%s' "$body" | grep -q '^404 Not Found'; then
        printf '  ❌ %-34s %s（页面未注册）\n' "$path" "$code"
        fail=$((fail + 1))
    else
        printf '  ✅ %-34s %s\n' "$path" "$code"
    fi
done

if [ "$fail" -gt 0 ]; then
    echo "路由守卫失败：$fail 条 404 —— 检查对应页面所在子包是否被 import（main.cj）"
    exit 1
fi
echo "路由守卫通过：${#ROUTES[@]} 条路由全部可达"
