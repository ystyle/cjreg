# cjreg — 仓颉中心仓（registry）

## 测试凭据（管理端）

仅用于本地开发/冒烟/浏览器 QA 环境，**禁止**用于任何生产部署。

| 环境 | 数据目录 | 用户名 | 密码 |
| --- | --- | --- | --- |
| 本地 smoke/QA 服务 | `.smoke/auth-data`（`cjreg serve -d .smoke/auth-data -p 18062`，可加 `CJREG_SEED_DEMO=1` 注入演示包） | `admin` | `admin123` |
| `tests/e2e.sh` 双仓脚本 | `.smoke/A/data`、`.smoke/B/data`（`cjreg init` 现场创建） | `admin` | `AdminPass1` |

说明：`admin` 是 `cjreg init --username admin` 创建的首个管理员，`isAdmin=true`，可登录管理端（`/admin/login`）并访问一切管理页。生产端密码必须用 `cjreg init --password <强口令>` 独立设置，不要复用本地测试口令。

## 启动本地服务

```shell
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)"
cjpm build -j 16
CJREG_SEED_DEMO=1 ./target/release/bin/ystyle::cjreg serve -d .smoke/auth-data -p 18062
```

## agent-browser 在沙箱的使用说明

本工作区（DSH sandbox）里 `$HOME` 只读，agent-browser 有几个坑必须绕过。以下均来自实测。

### 会话/登录态

- **socket/state 目录不可写**：默认写到 `$XDG_RUNTIME_DIR/agent-browser`（只读）会失败。必须用**自定义会话**把 socket 落到可写目录：
  ```shell
  export AGENT_BROWSER_SOCKET_DIR=/home/ystyle/Projects/Cangjie/.qa-shots/ab-socket
  export AGENT_BROWSER_SESSION_NAME=cjreg-auth   # 命名会话名
  ```
  session 名与 socket 目录组合（用户建议的 `@.agent-browser-...` 自定义会话即此思路）。不指定 SOCKET_DIR 时新进程会因只读目录起不来。

- **用持久终端管理**：`agent-browser` 是 daemon，页面状态（WS 渲染、token）在各独立 bash 调用间会漂移。用 `terminal_open` 开一个持久 shell，在那里统一 `export` 并连续操作，别每次 bash 单独调。

- **登录态恢复**：这个 cjxt 管理端用 WS + localStorage `cjxt_token` 恢复会话。表单填字/点击在 cjxt 的输入上容易因 `input` 事件不同步而失败。最稳做法是**先 curl 拿 token 再注入**：
  ```bash
  TOKEN=$(curl -s -X POST http://127.0.0.1:18062/api/admin/login -H 'Content-Type: application/json' \
    -d '{"username":"admin","password":"admin123"}' | python3 -c "import sys,json;print(json.load(sys.stdin).get('token',''))")
  agent-browser open http://127.0.0.1:18062/admin/login
  agent-browser eval "localStorage.setItem('cjxt_token','$TOKEN')"
  agent-browser open http://127.0.0.1:18062/admin   # WS 重连恢复会话
  ```

- **页面重新渲染后 ref 会失效**：snapshot 的 `@eN` 在页面变更后失效，需 re-snapshot。`open` 后先 `wait --text "..."` 等 WS 渲染完成再取 ref。

### 中文渲染为方框（tofu）—— 根因已修复

**根因**：Chrome/Chromium 用的 fontconfig（2.18，版本戳 `0x2011001`）检测到 `/var/cache/fontconfig` 里的缓存是**更新版 fontconfig（2.19+，版本戳 `0x2012001`）**生成的，于是**拒绝重新生成/读取**缓存，导致系统中文字体不被加载 → 中文渲染成方框。字体文件本身完好。

**修复**（需在宿主机 root 权限执行一次）：
```bash
sudo rm -rf /var/cache/fontconfig/*.cache-*
sudo fc-cache -f
```
清空重建后，`Chrome/Chromium` **完全重启**（`close --all` + `pkill -9 -f chrome-151`）即可正常渲染中文（`Fontconfig warning` 消失）。

排查要点：
- 页面 DOM `innerText` 中文始终正常，只有截图方框 → 是渲染引擎字体加载问题，非页面 bug。
- `fc-list :lang=zh` 能列出字体、`fc-match` 能命中，但渲染仍方框 → 查 fontconfig 缓存版本是否不匹配（`Fontconfig warning: ... newer version`）。
- `@font-face` 直接 `file://` 加载字体可正常渲染中文（绕过 fontconfig 缓存问题）。
- agent-browser 的 Chromium 启动时缓存字体列表，修缓存后需**完全重启浏览器**才生效。

### 其他

- 截图目录要用可写路径（`$HOME` 只读），存到 Workspace 下，如 `/home/ystyle/Projects/Cangjie/.qa-shots/`。`/tmp` 在本环境也可能跨调用不可见。
- 沙箱里 `sudo` 无法提权（no_new_privs），改密码/装系统包需用户在宿主机自行操作或提权工具。
