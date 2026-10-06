#!/usr/bin/env bash
# 镜头 3｜多仓解析：一个项目同时用「私有仓的包」与「官方仓的包」
set -u
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT/.demo/live-pkgs/demoClient" || exit 1
say "客户端项目（cd 到源码目录）"
printf '  $ pwd\n  %s\n' "$(pwd)"
sleep 1
say "依赖：私有仓的 demo 包 + 官方仓的 gjson"
printf '  $ cat cjpm.toml\n'
sed -n '/\[dependencies\]/,$p' cjpm.toml | sed 's/^/  /'
sleep 2
say "仓库配置：registry 指向私有仓"
printf '  $ cat cangjie-repo.toml\n'
sed -n '1,7p' cangjie-repo.toml | sed 's/^/  /'
sleep 2
say "解析依赖（多仓自动分工）"
printf '  $ cjpm update\n'
cjpm update 2>&1 | sed 's/^/  /'
sleep 1
say "锁文件：两个依赖各自来自哪个仓"
printf '  $ cat cjpm.lock\n'
grep -E 'mathUtils|gjson' cjpm.lock | sed 's/^/  /'
sleep 2
