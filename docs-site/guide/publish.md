# 发布包

## 发布协议

`POST /pkg/:name[?organization=]`，请求体为官方二进制拼接格式：

```
[meta 段] version(1B)=1 + size(4B, LE) + meta-data.json 字节
[tar  段] version(1B)=1 + size(4B, LE) + .cjp 制品字节
```

认证：`Authorization: <发布 Token>`（裸 token，兼容 `Bearer <token>` 写法）。

服务端会校验：段版本、段长度（单段 ≤ 500 MB）、`meta-data.json` 与 URL 的 name/org 一致、
制品 SHA-256 与 meta 的 `index.sha256sum` 一致；元数据 15 字段全量入库，索引条目原样透传依赖
（`dependencies` / `test-dependencies` / `script-dependencies` 与 `target` / `type` / `output-type`）。

## 发布要求

- 模块名 / 组织名长度 `[3, 64]`，不能是仓颉关键字；组织名不能为 `default`
- `cjpm.toml` 需包含 `description`
- 包根目录需包含 `README.md` 或 `README_zh.md`

## 返回码语义

| 码 | 含义 |
|---|---|
| 200 | 成功（新包 / 新版本 / 覆盖成功 / 同 sha 幂等） |
| 400 | 参数、二进制格式或 meta 解析错误 |
| 401 | 缺少或无效的发布 Token |
| 403 | 无发布权限（团队模式下的裁决结果） |
| 409 | 同版本已存在且内容不同（sha 不同），且当前模式不支持覆盖 |
| ≥500 | 服务端异常 |

## 覆盖（overwrite）

同版本、不同 sha 的重复发布：

- `open` 模式（默认）：返回 **409**，不静默覆盖；
- `team` 模式：需要对该包/组织具备 **overwrite** 权限 → 原地更新（保持 id/createdAt，刷新 updatedAt 与 sha）；
  **包名所有者（owner）本身没有覆盖权**，覆盖也不转移所有权。

## 大包发布

请求体上限由服务端配置 `max_request_bytes` 控制（默认 500 MiB）。当前实现会把整个请求体读入内存，
因此发布 30 MB 以上的包还需提高仓颉 GC 堆上限：

```shell
export cjHeapSize=2GB cjGCThreshold=1GB cjGCInterval=100ms
```

流式解析（边读边算 SHA-256、临时文件 + 原子 rename 落盘，内存 O(1)）已列入迭代计划，
详见[内存与优雅关闭](/guide/memory)。

## 删除与恢复（三级删除）

包版本采用**三级删除**模型，避免误删直接丢制品：

| 级别 | 操作 | 效果 | 可恢复 |
|---|---|---|---|
| 软删除 | 管理后台「包管理 → 软删除」或 `DELETE /api/admin/packages/:id` | 索引、下载、公开 API 立即不可见；**制品文件保留**；引用该版本的未完成发布计划项标记 `skipped` | ✅ 可恢复 |
| 恢复 | 「包管理 → 恢复」或 `PUT /api/admin/packages/:id/restore` | 版本重新可见可下载 | — |
| 硬删除 | 「包管理 → 硬删除」或 `DELETE /api/admin/packages/:id/hard` | 删除版本记录**并删除制品文件**，不可恢复 | ❌ |

约定：

- **恢复会校验制品仍在**：本地 blob 存在（或该版本来自上游、可重新回源）才允许恢复；
  制品已丢失时返回 `409`，避免恢复出一个「下载 404」的版本。
- **硬删除必须先软删除**：直接硬删返回 `409`（防止误操作一次性丢失制品）。
- 删除动作全部写入审计日志（`delete_package` / `restore_package` / `hard_delete_package`），
  可在「审计日志 → 管理」查看，`detail` 里有跳过的计划项数、是否删除制品等。
- 先拿到版本 `id`：`GET /api/admin/packages?organization=test&name=demo&includeDeleted=1`。

```bash
TOKEN=$(curl -s -X POST http://127.0.0.1:8060/api/admin/login -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"<口令>"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')

# 1) 查版本 id
curl -s "http://127.0.0.1:8060/api/admin/packages?organization=test&name=demo&includeDeleted=1" \
  -H "Authorization: Bearer $TOKEN"

# 2) 软删除（id=3）
curl -s -X DELETE "http://127.0.0.1:8060/api/admin/packages/3" -H "Authorization: Bearer $TOKEN"

# 3) 恢复
curl -s -X PUT "http://127.0.0.1:8060/api/admin/packages/3/restore" -H "Authorization: Bearer $TOKEN"

# 4) 硬删除（不可恢复）
curl -s -X DELETE "http://127.0.0.1:8060/api/admin/packages/3" -H "Authorization: Bearer $TOKEN"
curl -s -X DELETE "http://127.0.0.1:8060/api/admin/packages/3/hard" -H "Authorization: Bearer $TOKEN"
```
