#!/usr/bin/env bash
# 镜头 3｜发布一个包：客户端零改动，只填仓库地址 + Token
set -u
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || echo /home/ystyle/Projects/Cangjie/cjreg)"
say "客户端配置 cangjie-repo.toml（registry 指向私有仓）"
printf '  $ cat .demo/live-pkgs/mathUtils/cangjie-repo.toml\n'
sed -n '1,8p' .demo/live-pkgs/mathUtils/cangjie-repo.toml | sed 's/^/  /'
sleep 2
say "发布：cjpm publish"
cd .demo/live-pkgs/mathUtils
cjpm publish
sleep 1
