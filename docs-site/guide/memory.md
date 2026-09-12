# 内存与优雅关闭

## 常驻内存构成

一个数据目录 = 一个 badger-cj 库：

| 项 | 默认 | 说明 |
|---|---|---|
| MemTable arena | 2 × memTableSize = **32 MB** | bstorm 默认 `memTableSize` 16 MB；arena 为原生内存（不计入 GC 堆） |
| 仓颉 GC 堆上限 | **256 MB** | 仓颉运行时默认值，所有托管对象都在此配额内 |

## 请求体上限与 GC 堆

- `POST /pkg` 的请求体上限由 `cjreg.toml` 的 `max_request_bytes` 控制（默认 **500 MiB**，`-1` 不限）；
  stdx 的默认值只有 2 MB，不调会导致大包被拒（413 / 连接重置）。
- 当前实现会把**整个请求体读入内存**（峰值 ≈ 包体 2–3 倍），所以发布 30 MB 以上的包还需要提高 GC 堆：

```shell
export cjHeapSize=2GB          # 提高 GC 堆上限（默认 256MB）
export cjGCThreshold=1GB       # 触发 GC 的堆阈值（配套）
export cjGCInterval=100ms      # GC 轮询间隔（配套）
```

> 环境变量名以当前仓颉运行时版本为准。**流式解析**（边读边算 SHA-256、临时文件 + 原子 `rename` 落盘，
> 峰值内存 O(1)）已列入迭代计划，落地后即可在默认堆上限下发布 500 MB 级别的包。

## 优雅关闭

`serve` / `admin-ui` 启动时注册 SIGINT/SIGTERM 处理：

```
信号到达 → 关闭钩子（停止 HTTP 服务）→ 关闭数据库（flush memtable 落盘为 SSTable）→ 进程退出（exit 0）
```

- `Ctrl+C`、`docker stop`、`systemctl stop` 都走这条路径（实测 `docker stop` 语义：exit 0 而非 143，数据完整）；
- 重复发送信号是幂等的；
- 兜底：数据库以 `syncWrites: true` 打开（每次写入 fsync），即使 `kill -9` 也不会丢已确认的写入。
