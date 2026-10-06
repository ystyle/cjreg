#!/usr/bin/env bash
# 镜头 2｜部署：生产实例已常驻（健康 / 端口 / 数据卷 / 重启策略）
set -u
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
say "已部署实例（docker compose 项目 cjreg）"
docker ps --filter name=cjreg --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
sleep 2
say "健康检查"
printf '  $ curl -s http://127.0.0.1:8066/api/health\n  '
curl -s http://127.0.0.1:8066/api/health; printf '\n'
sleep 2
say "数据卷 / 重启策略（生产目录 ~/docker/cjreg）"
docker inspect cjreg --format '  数据卷: {{range .Mounts}}{{.Source}} -> {{.Destination}}{{end}}'
docker inspect cjreg --format '  重启策略: {{.HostConfig.RestartPolicy.Name}}'
sleep 1
