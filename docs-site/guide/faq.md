# 常见问题

## 发布大包时报 413 / 连接重置？

请求体超过服务端上限。设置 `cjreg.toml` 的 `max_request_bytes`（默认 500 MiB，`-1` 不限）——
注意 stdx 的默认值只有 2 MB。

## 发布大包时服务端 OOM？

当前实现整包读入内存（峰值 ≈ 包体 2–3 倍），受仓颉 GC 堆默认上限 256 MB 约束。发布 30 MB 以上的包请先
`export cjHeapSize=2GB`（配套 `cjGCThreshold` / `cjGCInterval`）。流式解析已在迭代计划中。

## 覆盖已发布版本被拒（403）？

覆盖需要 **overwrite** 权限（团队权限），包名所有者本人也不行。`open` 模式下同版本重复发布会返回 409 而不是覆盖。

## 客户端需要改什么？

只改 `cangjie-repo.toml` 的 `registry` 与 `token`。`cjpm` 的解析规则、依赖写法都不变；多仓/代理策略在服务端收敛。

## 发布 Token 在哪里拿？

登录用户门户（`/`）→「我的」→ **我的发布 Token**；管理员也可以在后台「用户管理」查看/重置任意用户 Token。
重置后旧 Token 立即失效。

## 内网部署如何做到"下载也要鉴权"？

`cjreg.toml` 设 `require_auth = true`：`GET /pkg` 与 `GET /index` 需要有效 Token（会话或发布 Token）且对资源有 `read` 权限。

## 数据怎么备份/迁移？

整个数据目录（`cjreg.db` + `blobs/` + `cjreg.toml`）拷贝即可；换机器后直接 `serve`，索引与自增 id 会自动恢复。
建议停服后拷贝（或依赖 `syncWrites` + 优雅关闭）。

## 忘掉管理员口令 / 管理员被全部禁用？

```shell
cjreg admin reset-password -d ./data --username admin --password '<新口令>'
```

会重置口令并强制该用户为启用状态的管理员。
