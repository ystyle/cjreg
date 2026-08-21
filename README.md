# cjreg — 仓颉私有中心仓与多仓工具

用仓颉实现私有中心仓与多仓体系：多仓配置与优先级查找、依赖解析/冲突/版本强制替换、私有仓一键部署、镜像/代理/仓库同步。

课题：仓颉中心仓多仓配置与私有化体系建设。

## 命令

```
cjreg <command> [options]

  serve      启动私有中心仓 HTTP 服务（发布/下载/索引 + 管理 API）
  init       初始化数据目录（管理员/组织/上游），生成 docker 配置
  config     查看/校验多仓配置（cangjie-repo.toml）
  resolve    多仓解析一个包（按优先级，输出来源/版本/冲突）
  proxy      代理模式：请求回源上游并缓存
  mirror     镜像模式：全量/增量同步上游索引 + 制品
  sync       仓库间同步（源→目标，索引 diff）
```

## 构建与测试

```bash
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"
cjpm build -j 16
cjpm test -j 16 --no-progress
./target/release/bin/main
```

> `--static` 静态编译；`cangjie-repo.toml` 缓存到项目本地（沙箱只读 `~/.cjpm` 场景）。

## 技术选型

- 存储：**bstorm**（badger-cj + gjson 的 JSON 文档库，path `../storm-cj`）
- HTTP 服务端：**tang**（path `../tang`，内置 multipart，用于包上传）
- HTTP 客户端：`stdx.net.http`（上游回源）
- 配置解析：`tomlcj`；版本匹配：`semver` + `semver_range`

## 文档

- 设计：[docs/design.md](docs/design.md)
- 可行性评估（仓颉重写 cjrepo）：`../cjdep/docs/eval-cjrepo-cangjie.md`
