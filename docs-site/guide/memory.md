# 内存与优雅关闭

## 常驻内存构成

一个数据目录 = 一个 badger-cj 库：

| 项 | 默认 | 说明 |
|---|---|---|
| MemTable arena | 2 × memTableSize = **32 MB** | bstorm 默认 `memTableSize` 16 MB；arena 为原生内存（不计入 GC 堆） |
| 仓颉 GC 堆上限 | **256 MB** | 仓颉运行时默认值，所有托管对象都在此配额内 |

## 请求体上限与内存占用

- `POST /pkg` 的请求体上限由 `cjreg.toml` 的 `max_request_bytes` 控制（默认 **500 MiB**，`-1` 不限）；
  stdx 的默认值只有 2 MB，不调会导致大包被拒（413 / 连接重置）。
- **发布、下载、回源都是流式的**：边读边算 SHA-256、直接写临时文件后原子 `rename` 落盘，下载与回源则边收边转发。
  峰值内存**与包体大小无关** —— 实测发布 2 / 32 / 200 MiB 时进程 `VmHWM` 恒定约 **291 MiB**，
  200 MiB 制品下载同样平稳（数据见 [性能基准](/guide/benchmark)）。
- 因此发布大包**不需要再调大堆上限**。只有在「高并发 + 大包」叠加、或需要更激进的回收策略时才考虑：

```shell
export cjHeapSize=2GB          # 提高 GC 堆上限（默认 256MB）
export cjGCThreshold=1GB       # 触发 GC 的堆阈值（配套）
```

> 环境变量名以当前仓颉运行时版本为准。

## 优雅关闭

`serve` / `admin-ui` 启动时注册 SIGINT/SIGTERM 处理：

```
信号到达 → 关闭钩子（停止 HTTP 服务）→ 关闭数据库（flush memtable 落盘为 SSTable）→ 进程退出（exit 0）
```

- `Ctrl+C`、`docker stop`、`systemctl stop` 都走这条路径（实测 `docker stop` 语义：exit 0 而非 143，数据完整）；
- 重复发送信号是幂等的；
- 兜底：数据库以 `syncWrites: true` 打开（每次写入 fsync），即使 `kill -9` 也不会丢已确认的写入。
