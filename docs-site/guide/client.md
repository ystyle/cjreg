# 客户端配置

cjreg 与官方中心仓协议互通，**cjpm 客户端零改动**——只需把 registry 指向本服务。

## 1. 仓库配置 `cangjie-repo.toml`

放在项目根目录（与 `cjpm.toml` 同级）：

```toml
[repository.cache]
    path = "./.cache"

[repository.home]
    registry = "http://localhost:8060"
    token = "<发布 Token>"
```

- `registry`：本服务地址（门户 `/me` 页面里的示例会直接给出配置好的地址）
- `token`：**发布 Token**，登录门户后在「我的发布 Token」处查看/重置；下载/索引是否需要它取决于服务端 `require_auth`

## 2. 依赖配置 `cjpm.toml`

```toml
[dependencies]
'myorg::mylib' = "1.0.0"    # 有组织包（org::name）
'plainlib' = "0.9.0"         # 无组织包
```

解析行为与官方仓一致；多仓/代理/缓存策略全部在服务端收敛，客户端不需要任何额外配置。

## 3. 发布

```shell
cjpm publish
```

发布前请确认包满足官方元数据要求（模块名/组织名 `[3,64]`、`cjpm.toml` 含 `description`、根目录含
`README.md` 或 `README_zh.md`）。见[发布包](/guide/publish)。

## 4. 多仓（服务端能力）

客户端只配置**一个** registry；服务端可以再挂多个上游（官方仓、镜像仓、其它私有仓）并按 `priority` 回源，
对客户端完全透明。见[上游代理与多仓](/guide/upstream)。
