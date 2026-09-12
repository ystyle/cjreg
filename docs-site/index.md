---
layout: home

hero:
  name: cjreg
  text: 仓颉私有中心仓与多仓体系
  tagline: 纯仓颉实现 · 与官方中心仓协议互通 · cjpm 客户端零改动 · 静态单二进制
  actions:
    - theme: brand
      text: 快速开始
      link: /guide/
    - theme: alt
      text: API 一览
      link: /api/
    - theme: alt
      text: 部署指南
      link: /deploy/

features:
  - title: 官方协议互通
    details: 实现 POST /pkg（官方二进制格式）、GET /pkg/:name/:version、GET /index/:mo/:du/:name；cjpm 只需把 registry 指向本服务，客户端零改动。
  - title: 认证与权限双路径
    details: pbkdf2 用户名密码 + 会话/发布双 Token；权限 = max(包名所有者, 团队权限)，支持 read / write / overwrite 与私有化读鉴权开关。
  - title: 多上游代理与缓存
    details: 上游数据表 + priority 多仓体系，按需回源（索引/制品）并按 cacheTtl 缓存；官方仓自动识别且受保护；resolve 诊断给出逐仓命中链路。
  - title: 发布计划引擎
    details: 复用 cjdep 依赖拓扑排序，四分类（need_publish/version_optional/already_exists/conflict）；按序推送目标仓并校验 SHA-256；重启自动恢复。
  - title: 全栈仓颉 Web 界面
    details: 管理后台（用户/组织/团队/包/上游/发布计划/日志）与公开门户（首页/包列表/包详情/文档/个人门户）均由自研 cjxt 渲染，零 JS 构建链。
  - title: 一个二进制即完整仓库
    details: 嵌入式 bstorm（badger-cj）替代外部数据库，数据目录即数据；备份=拷贝目录，迁移=换机器；静态编译、优雅关闭。
---

## 60 秒上手

```shell
# 1) 初始化（创建首个管理员 + 默认官方上游 + 生成 cjreg.toml）
cjreg init -d ./data --username admin --password '<强口令>'

# 2) 启动（HTTP + 管理 API + Web 界面，单端口）
cjreg serve -d ./data

# 3) 浏览器
#   用户门户 http://localhost:8060/    管理后台 http://localhost:8060/admin
```

客户端只需在项目根目录写 `cangjie-repo.toml`（Token 从门户「我的」页面获取）：

```toml
[repository.home]
registry = "http://localhost:8060"
token = "<发布 Token>"
```

然后 `cjpm publish` 即可发布，`cjpm.toml` 中按 `'org::name' = "1.0.0"` 依赖本仓的包。
