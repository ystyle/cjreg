# 关于 cjreg

**cjreg** 是仓颉生态的私有中心仓与多仓体系：从服务端到 Web 界面 **100% 仓颉实现**，
与官方中心仓协议互通（`cjpm` 客户端零改动），静态编译为单个二进制交付。

## 技术栈

| 层 | 选型 |
|---|---|
| 语言 / 工具链 | 仓颉（Cangjie）1.1.3 + cjpm |
| 存储 | [bstorm](https://atomgit.com/ystyle/badger-storm)（嵌入式 JSON 文档库）+ [badger-cj](https://atomgit.com/ystyle/badger-cj)（LSM KV）+ 内容寻址 blob |
| HTTP 服务端 | [tang](https://atomgit.com/ystyle/tang) |
| Web 界面 | [cjxt](https://atomgit.com/ystyle/cjxt)（服务端驱动 UI，Signal + 组件库，零 JS 构建链） |
| 配置 / 认证 | [tomlcj](https://atomgit.com/ystyle/tomlcj) · [pbkdf2](https://atomgit.com/ystyle/pbkdf2-cj) · [gjson](https://atomgit.com/ystyle/gjson-cj) |
| 依赖分析 | cjdep（发布计划的拓扑排序与四分类） |

## 与先行版（Go 版 cjrepo）的关系

cjreg 是作者 Go 先行版 cjrepo 的仓颉重写与能力超集：多上游 priority 代理与索引缓存、
可解释的 resolve 诊断、SHA-256 三重校验、`targetUpstream` 真实生效的发布计划、全栈仓颉 Web 界面。

## 许可与仓库

- 许可：MIT（见 `LICENSE`）；第三方组件清单见 `README.OpenSource`
- 仓库：[atomgit.com/ystyle/cjreg](https://atomgit.com/ystyle/cjreg)
- 变更记录：`CHANGELOG.md`；验证报告：`docs/verification.md`

## 本作品参加

仓颉生态创新开发挑战赛（技术课题）：**仓颉私有中心仓与多仓体系**。
