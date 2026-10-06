# 演示录制素材与配音时间轴

> 由 `bash scripts/demo-record.sh timeline` 生成；时长用 ffprobe 实测。
> 配音：按每格的起止时间对着 `docs/demo-video.md` §3 的解说词念即可。

| 镜头 | 轨 | 素材 | 时长(s) | 画面内容 | 配音提示（demo-video.md §3） |
|---|---|---|---|---|---|
| diag | 终端 | `.demo/recordings/diag.mp4` |  | diag | 见 §3 对应镜头 |
| all | 终端 | `.demo/recordings/preview-all.mp4` | 109 | all | 见 §3 对应镜头 |
| window-frame | 终端 | `.demo/recordings/sample-window-frame.mp4` | 5 | window-frame | 见 §3 对应镜头 |
| 02-deploy | 终端 | `.demo/recordings/term-02-deploy.mp4` | 7 | 部署（容器健康 / 数据卷 / 重启策略） | 见 §3 对应镜头 |
| 03-publish | 终端 | `.demo/recordings/term-03-publish.mp4` | 6 | 发布 demo::mathUtils@1.0.0 | 见 §3 对应镜头 |
| 04-multirepo | 终端 | `.demo/recordings/term-04-multirepo.mp4` | 14 | 解析诊断 + 发布计划推送 | 见 §3 对应镜头 |
| 05-permission | 终端 | `.demo/recordings/term-05-permission.mp4` | 13 | 越权发布被 403 拒绝 | 见 §3 对应镜头 |
| 07-audit-api | 终端 | `.demo/recordings/term-07-audit-api.mp4` | 8 | 公开只读 API + 审计 | 见 §3 对应镜头 |
| 08-delete | 终端 | `.demo/recordings/term-08-delete.mp4` | 14 | 三级删除（软删 404 / 恢复 200） | 见 §3 对应镜头 |
| 03-docs | Web 界面 | `.demo/recordings/web-03-docs.mp4` | 4 | 03-docs | 见 §3 对应镜头 |
| 03-pkgs | Web 界面 | `.demo/recordings/web-03-pkgs.mp4` | 5 | 管理后台：仪表盘 / 包管理 | 见 §3 对应镜头 |
| 03-portal | Web 界面 | `.demo/recordings/web-03-portal.mp4` | 5 | 门户首页与内置帮助 | 见 §3 对应镜头 |
| 04-target | Web 界面 | `.demo/recordings/web-04-target.mp4` | 5 | 演示空站（推送后） | 见 §3 对应镜头 |
| 04-upstreams | Web 界面 | `.demo/recordings/web-04-upstreams.mp4` | 5 | 后台上游管理（official 与 demo-upstream） | 见 §3 对应镜头 |
| 05-org | Web 界面 | `.demo/recordings/web-05-org.mp4` | 5 | 组织与团队管理 | 见 §3 对应镜头 |
| 06-me | Web 界面 | `.demo/recordings/web-06-me.mp4` | 13 | 用户门户 /me（发布 Token / 我的包） | 见 §3 对应镜头 |
| 07-logs | Web 界面 | `.demo/recordings/web-07-logs.mp4` | 5 | 管理后台审计日志 | 见 §3 对应镜头 |
