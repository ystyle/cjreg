# 快速开始

**cjreg** 是仓颉私有中心仓与多仓体系：一个静态二进制同时提供「官方协议互通的服务端 + 管理后台 + 公开门户 + 个人门户」。

## 1. 安装

从发布页下载对应平台的静态二进制（Linux x86_64 / aarch64 等），或自行构建：

```shell
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"
cjpm build -j 16
./target/release/bin/ystyle::cjreg --help
```

## 2. 初始化

```shell
cjreg init -d ./data --username admin --password '<强口令>'
```

`init` 会：创建首个管理员（空数据目录的信任模型，无 HTTP bootstrap 端点）、写入默认官方上游，并生成一份带注释的
`data/cjreg.toml` 配置模板（已存在则不覆盖）。

## 3. 启动

```shell
cjreg serve -d ./data          # 端口默认 8060，可在 cjreg.toml 或 -p 指定
```

- 用户门户：`http://localhost:8060/`（登录后 `/me` 领取发布 Token）
- 管理后台：`http://localhost:8060/admin`
- 健康检查：`GET /api/health`

## 4. 发布第一个包

1. 用管理员在后台「用户管理」创建发布者账号（或直接用门户登录）；
2. 该用户在 `/me` 复制自己的发布 Token；
3. 项目根目录写 `cangjie-repo.toml`（`registry` + `token`，见[客户端配置](/guide/client)）；
4. `cjpm publish`。

## 5. 让别的项目依赖它

```toml
# cjpm.toml
[dependencies]
'myorg::mylib' = "1.0.0"     # 有组织包
'plainlib' = "0.9.0"          # 无组织包
```

客户端 `cangjie-repo.toml` 指向本仓即可解析（多仓/代理策略全部在服务端收敛，不改 cjpm 解析规则）。

## 下一步

- [安装与运行](/guide/install) · [客户端配置](/guide/client) · [发布包](/guide/publish)
- [权限模型](/guide/permission) · [团队与组织](/guide/teams)
- [上游代理与多仓](/guide/upstream) · [发布计划](/guide/publish-plan)
- [服务端配置](/deploy/env) · [内存与优雅关闭](/guide/memory) · [常见问题](/guide/faq)
