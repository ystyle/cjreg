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
