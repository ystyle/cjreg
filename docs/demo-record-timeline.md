# 演示录制素材与配音时间轴

> 由 `bash scripts/demo-record.sh timeline` 生成；时长用 ffprobe 实测。
> 配音：按每格的起止时间对着 `docs/demo-video.md` §3 的解说词念即可。

| 镜头 | 轨 | 素材 | 时长(s) | 画面内容 | 配音提示（demo-video.md §3） |
|---|---|---|---|---|---|
| term-02-deploy | 终端 | `.demo/recordings/term-02-deploy.mp4` | 7 | 部署：容器 / 数据卷 / 重启策略 | 见 §3 对应镜头 |
| web-03-portal | Web 界面 | `.demo/recordings/web-03-portal.mp4` | 5 | 门户首页 | 见 §3 对应镜头 |
| web-03-packages | Web 界面 | `.demo/recordings/web-03-packages.mp4` | 5 | 包列表：浏览与搜索仓颉包 | 见 §3 对应镜头 |
| web-03-docs | Web 界面 | `.demo/recordings/web-03-docs.mp4` | 4 | 内置帮助文档 | 见 §3 对应镜头 |
| pip-03-publish | 同屏（画中画） | `.demo/recordings/pip-03-publish.mp4` | 6 | 发布（同屏）：仪表盘 ＋ 终端 cjpm publish | 见 §3 对应镜头 |
| web-03-pkgs-after | Web 界面 | `.demo/recordings/web-03-pkgs-after.mp4` | 7 | 发布结果：包管理里搜到 demo::mathUtils 1.0.0（正常） | 见 §3 对应镜头 |
| pip-04-resolve | 同屏（画中画） | `.demo/recordings/pip-04-resolve.mp4` | 10 | 多仓解析（同屏）：仪表盘 ＋ cjpm update 终端 | 见 §3 对应镜头 |
| web-04-upstreams | Web 界面 | `.demo/recordings/web-04-upstreams.mp4` | 5 | 上游管理：官方仓 / 演示空站 | 见 §3 对应镜头 |
| web-04-plan-list | Web 界面 | `.demo/recordings/web-04-plan-list.mp4` | 5 | 发布计划列表：状态 / 目标上游 / 进度 | 见 §3 对应镜头 |
| web-04-plan-create | Web 界面 | `.demo/recordings/web-04-plan-create.mp4` | 26 | 创建发布计划：选包 → 自动补依赖 → 版本对照 | 见 §3 对应镜头 |
| web-04-plan-run | Web 界面 | `.demo/recordings/web-04-plan-run.mp4` | 15 | 计划详情：开始执行 / 推送进度 | 见 §3 对应镜头 |
| web-04-target | Web 界面 | `.demo/recordings/web-04-target.mp4` | 5 | 演示空站：推送后的结果 | 见 §3 对应镜头 |
| web-05-org | Web 界面 | `.demo/recordings/web-05-org.mp4` | 5 | 组织与团队管理 | 见 §3 对应镜头 |
| pip-05-permission | 同屏（画中画） | `.demo/recordings/pip-05-permission.mp4` | 13 | 权限（同屏）：仪表盘 ＋ 终端越权发布被拒（403） | 见 §3 对应镜头 |
| web-06-me | Web 界面 | `.demo/recordings/web-06-me.mp4` | 13 | 用户门户：发布 Token / 我的包 / 我的团队 | 见 §3 对应镜头 |
| web-07-logs | Web 界面 | `.demo/recordings/web-07-logs.mp4` | 5 | 审计日志 | 见 §3 对应镜头 |
| pip-07-audit-api | 同屏（画中画） | `.demo/recordings/pip-07-audit-api.mp4` | 8 | 公开只读 API（同屏）：仪表盘 ＋ 终端 curl | 见 §3 对应镜头 |
| web-08-delete | Web 界面 | `.demo/recordings/web-08-delete.mp4` | 23 | 三级删除：软删除 → 状态可见 → 恢复 | 见 §3 对应镜头 |
