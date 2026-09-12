#!/usr/bin/env bash
# cjreg 一键 Docker 部署：宿主编译 → 构建镜像 → 初始化数据目录（首次）→ 启动 → 健康检查
#
# 用法：
#   bash scripts/docker-deploy.sh                    # 端口 8060；首次交互可传 init 口令
#   CJREG_PORT=8060 ADMIN_USER=admin ADMIN_PASS='<强口令>' bash scripts/docker-deploy.sh
#
# 说明：镜像只打包宿主构建产物（见 Dockerfile 顶部说明），因此本脚本必须与仓颉工具链同机运行。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

PORT="${CJREG_PORT:-8060}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-}"
DATA_DIR="$ROOT/data"

echo "==> 1/5 加载仓颉环境并编译"
if command -v cjvs >/dev/null 2>&1; then
  eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"
fi
cjpm build -j 16

BIN="target/release/bin/ystyle::cjreg"
[ -x "$BIN" ] || { echo "构建产物缺失：$BIN"; exit 1; }

echo "==> 2/5 首次初始化数据目录（$DATA_DIR）"
mkdir -p "$DATA_DIR"
# 容器内以 uid 1000 运行：宿主目录属主不是 1000 时 init/写入会 Permission denied
if [ "$(id -u)" != "1000" ]; then
  if command -v sudo >/dev/null 2>&1; then
    sudo chown -R 1000:1000 "$DATA_DIR" 2>/dev/null || true
  else
    chown -R 1000:1000 "$DATA_DIR" 2>/dev/null || true
  fi
  if [ "$(stat -c %u "$DATA_DIR" 2>/dev/null || echo 0)" != "1000" ]; then
    echo "    ⚠ 数据目录属主非 1000，容器可能无法写入；请执行：sudo chown -R 1000:1000 \"$DATA_DIR\""
  fi
fi
if [ ! -f "$DATA_DIR/cjreg.db" ] && [ ! -d "$DATA_DIR/blobs" ]; then
  if [ -z "$ADMIN_PASS" ]; then
    echo "首次部署需要管理员口令：ADMIN_PASS='<强口令>' bash scripts/docker-deploy.sh"
    exit 1
  fi
  # 用镜像内的二进制做 init，保证与运行环境一致（挂载目标目录）
  docker build -q -t cjreg:latest \
    --build-arg CJREG_BIN="$BIN" . >/dev/null
  docker run --rm -v "$DATA_DIR:/data" cjreg:latest \
    /app/cjreg init -d /data --username "$ADMIN_USER" --password "$ADMIN_PASS"
else
  echo "    已初始化，跳过"
fi

echo "==> 3/5 构建/更新镜像"
docker compose build

echo "==> 4/5 启动服务（端口 $PORT）"
CJREG_PORT="$PORT" docker compose up -d

echo "==> 5/5 等待健康检查"
for i in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
    echo "    ✓ http://127.0.0.1:${PORT}/api/health"
    echo
    echo "门户：   http://127.0.0.1:${PORT}/"
    echo "管理后台：http://127.0.0.1:${PORT}/admin"
    echo "配置：   $DATA_DIR/cjreg.toml（改完 docker compose restart 生效）"
    exit 0
  fi
  sleep 1
done

echo "启动超时，请查看日志：docker compose logs -f cjreg"
exit 1
