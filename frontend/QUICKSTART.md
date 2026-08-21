# 快速启动指南

## 1. 安装依赖

```bash
cd /home/ystyle/Code/Go/cjrepo/frontend
npm install
```

## 2. 配置 API 代理（重要！）

编辑 `vite.config.ts`，添加代理配置：

```typescript
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import vueJsx from '@vitejs/plugin-vue-jsx'

export default defineConfig({
  plugins: [vue(), vueJsx()],
  server: {
    proxy: {
      '/api': {
        target: 'http://localhost:8060',
        changeOrigin: true,
      },
    },
  },
})
```

## 3. 启动开发服务器

```bash
npm run dev
```

前端将在 `http://localhost:5173` 启动

## 4. 访问应用

### 公开页面
- 首页: http://localhost:5173/
- 包列表: http://localhost:5173/packages
- 帮助文档: http://localhost:5173/docs

### 管理后台
- 仪表盘: http://localhost:5173/admin/dashboard
- 包管理: http://localhost:5173/admin/packages
- 用户管理: http://localhost:5173/admin/users
- 操作日志: http://localhost:5173/admin/logs

## 5. 设置管理后台 Token

打开浏览器控制台（F12），执行：

```javascript
localStorage.setItem('admin_token', 'your-actual-token-here')
```

然后刷新页面即可访问管理后台。

## 6. 获取 Token

使用后端的 `add_user.go` 工具创建用户：

```bash
cd /home/ystyle/Code/Go/cjrepo
go run add_user.go testuser test@example.com
```

输出的 `Authorization: token-testuser-xxxxx` 中的 `token-testuser-xxxxx` 就是你的 Token。

## 7. 常见问题

### API 请求失败
- 确保后端服务正在运行（`./cjrepo`）
- 检查 `vite.config.ts` 中的代理配置

### 管理后台显示 401 错误
- 确认已设置 Token
- 检查 Token 格式是否正确

### 页面空白
- 打开浏览器控制台查看错误信息
- 运行 `npm run type-check` 检查类型错误

## 开发技巧

### 查看网络请求
打开浏览器开发者工具 -> Network 标签页，可以看到所有 API 请求。

### 修改 API 地址
编辑 `src/api/index.ts` 中的 `baseURL`。

### 调试单个组件
在 `.vue` 文件中添加 `debugger` 或使用 `console.log()`。

### 热重载不工作
重启开发服务器：`Ctrl+C` 然后 `npm run dev`。
