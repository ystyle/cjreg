# 上游代理与多仓

cjreg 把上游做成**数据表 + priority 的多仓体系**（先行版只有单一上游），对客户端完全透明。

![上游管理：官方仓与私有上游（回源 / 可推送两个能力）](/images/upstreams.webp)

## 上游字段

| 字段 | 说明 |
|---|---|
| `name` | 唯一标识 |
| `url` | registry base（如 `https://pkg.cangjie-lang.cn/registry`） |
| `priority` | 越小越优先；解析按优先级依次查询 |
| `enabled` | **总闸**：关掉后既不回源、也不可作为发布目标 |
| `proxyEnabled` | **读路径**：是否参与回源 / 镜像 / 解析诊断 / 重拉 |
| `asTarget` | **写路径**：是否出现在发布计划的「目标仓」下拉里（默认关：推官方不可逆，需显式授权） |
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

## 一个实例对接多个仓（多仓体系）

「多仓」不是「一个实例托管多个仓」，而是**一个 cjreg 实例同时对接多个外部仓**，且分两条互不相干的路：

| 路径 | 判定 | 用途 |
|---|---|---|
| 读 | `enabled && proxyEnabled`（`proxySorted()`，按 `priority` 升序） | 回源索引/制品、解析诊断、重拉 |
| 写 | `enabled && asTarget`（`planTargets()`，同样按优先级） | 发布计划的推送目标 |

- 官方仓默认**参与回源**，但默认**不是**推送目标；
- 新建上游默认 `proxyEnabled = true`、`asTarget = false`（推送不可逆，目标仓要显式授权）；
- 旧文档缺这两个字段时按默认值 `true / true` 反序列化，升级后行为不变；但**新建**上游走 `true / false`。

## 解析诊断 vs 版本对照（别混）

- **解析诊断**回答「这个依赖能不能解析、从哪个上游解析到、版本与 sha 是多少」：按优先级遍历回源链、
  取索引、找满足 `require` 的最高版本、命中即停，每步写进 `trace`，并标出跨仓同版本不同 sha 的 `conflict`；
- **「该不该发、发到哪」由发布计划的版本对照回答**：创建计划时人先选目标仓，系统再去取目标仓索引，
  把每个包分成 `need_publish / already_exists / conflict / version_optional`；目标仓索引取不到时单独标
  `target_error`（不会假装"目标仓没有"）。

