# 上游代理与多仓

cjreg 把上游做成**数据表 + priority 的多仓体系**（先行版只有单一上游），对客户端完全透明。

## 上游字段

| 字段 | 说明 |
|---|---|
| `name` | 唯一标识 |
| `url` | registry base（如 `https://pkg.cangjie-lang.cn/registry`） |
| `priority` | 越小越优先；解析按优先级依次查询 |
| `enabled` | 是否参与回源 |
| `cacheTtl` | 索引缓存有效期（秒，默认 86400） |
| `authToken` | 回源认证 **与** 发布计划推送认证（裸 token） |
| `isOfficial` | 官方仓识别（URL 前缀匹配），受保护不可删除 |

## 回源与缓存

- `GET /index/...`、`GET /pkg/...` 本地未命中 → 按 `priority` 依次回源，成功后落库（索引进 `cache:index`，制品进 `blobs/`）；
- 索引按 `cacheTtl` 过期；命中缓存后**零公网往返**；
- 回源制品的来源会记录在包文档（`upstreamId` / `upstreamName`），可溯源；
- 官方仓自动识别，禁止删除，避免误操作把生态源删掉。

## 解析诊断 `GET /api/admin/resolve`

```
GET /api/admin/resolve?name=<包名>&organization=<组织>&require=<版本区间>&strict=true
```

返回：选中的候选仓与版本、候选列表（各仓命中情况）、冲突标记（同 name+version 不同 sha256sum）、
逐仓 `trace` 链路（例如 `official: index hit 1.1.0` / `backup: 404`）、以及 `module` 语义的
`[replace]` 替换结果（`replaced` / `replacedBy`）——回答"为什么解析到它 / 为什么找不到"。

## 私有上游

`authToken` 会在回源请求中作为 `Authorization` 头发送（裸 token，与官方规格一致），
因此可以直接对接需要认证的镜像仓/私有仓。

## 连通性测试

管理后台「上游管理」或 API 均可测试某个上游是否可用：

```bash
# 指定包（≥3 字符）：请求该上游的 NDJSON 索引端点
curl -s -X POST "http://127.0.0.1:8060/api/admin/upstreams/1/test?name=cordis_core&organization=ystyle" \
  -H "Authorization: Bearer <会话 Token>"

# 不指定包：只测基地址可达性
curl -s -X POST "http://127.0.0.1:8060/api/admin/upstreams/1/test" \
  -H "Authorization: Bearer <会话 Token>"
```

响应字段：`reachable`（是否拿到 HTTP 响应）、`healthy`（200 且索引非空）、`status`、`latencyMs`、
`bodyBytes`、`authUsed`、`packages`（索引里的包名样本，含依赖条目）、`error`、`summary`（中文摘要）。

判定语义：

| 情况 | reachable | healthy | error |
|---|---|---|---|
| 200 且索引非空 | ✓ | ✓ | — |
| 404（该上游未收录此包） | ✓ | ✗ | 该上游未收录此包（404） |
| 401 / 403 | ✓ | ✗ | 认证失败（401/403） |
| 5xx | ✓ | ✗ | 上游返回 5xx |
| 无响应（DNS/连接/超时） | ✗ | ✗ | 具体传输错误 |

探测动作会写入审计日志（`test_upstream`），可在「审计日志 → 管理」里查看历史结果。
