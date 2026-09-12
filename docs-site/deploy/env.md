# 服务端配置（`cjreg.toml`）

配置只有一处来源：数据目录下的 **`cjreg.toml`**（`cjreg init` 会生成带注释的模板），
也可用 `-c/--config <file>` 指定其它路径；文件不存在时全部走默认值。

优先级：**命令行（`-p`）> 配置文件 > 默认值**。除调试开关 `CJREG_SEED_DEMO=1` 外没有环境变量配置项。

```toml
[server]
# 对外访问地址（含协议与端口）——用户门户与帮助文档里的 registry 示例用它
public_url = "https://pkg.example.com"

# 监听端口（命令行 -p/--port 优先）
port = 8060

# 发布权限模式
#   open = 有效发布 Token 即可发布（默认，适合内部先跑）
#   team = 双路径裁决：包名所有者 / 团队成员 + read|write|overwrite
permission_mode = "open"

# 下载 / 索引是否需要有效 Token + read 权限（私有仓建议 true）
require_auth = false

# HTTP 请求体上限（字节）。stdx 默认仅 2MB，会让大包发布被拒（413/连接重置）
# 默认 500MiB 对齐官方「单段 ≤ 500MB」规格；-1 = 不限制
# 注意：发布 30MB 以上的包还需提高仓颉 GC 堆（默认 256MB）：
#   export cjHeapSize=2GB cjGCThreshold=1GB cjGCInterval=100ms
max_request_bytes = 524288000
```

## 环境变量

| 变量 | 作用 |
|---|---|
| `cjHeapSize` / `cjGCThreshold` / `cjGCInterval` / `cjBackupGCInterval` | 仓颉运行时 GC 堆相关（**非 cjreg 自有配置**，由运行时读取）；大包发布/高写入负载时调大 |
| `CJREG_SEED_DEMO=1` | 开发调试开关：启动时向空库注入演示包 |

## 数据目录布局

见[安装与运行](/guide/install#数据目录)。
