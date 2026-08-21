# 仓颉中央库 - 前端管理后台

Vue 3 + TypeScript + Element Plus 管理后台

## 技术栈

- **框架**: Vue 3 (Composition API)
- **语言**: TypeScript
- **UI 组件库**: Element Plus
- **状态管理**: Pinia
- **路由**: Vue Router
- **HTTP 客户端**: Axios
- **构建工具**: Vite

## 项目结构

```
frontend/
├── src/
│   ├── api/                # API 封装
│   │   ├── index.ts        # axios 实例配置
│   │   ├── public.ts       # 公开 API
│   │   └── admin.ts        # 管理 API
│   ├── views/              # 页面组件
│   │   ├── Home.vue        # 首页
│   │   ├── Packages.vue    # 包列表
│   │   ├── PackageDetail.vue # 包详情
│   │   ├── Docs.vue        # 帮助文档
│   │   └── admin/          # 管理后台
│   │       ├── Dashboard.vue  # 仪表盘
│   │       ├── Packages.vue   # 包管理
│   │       ├── Users.vue      # 用户管理
│   │       └── Logs.vue       # 操作日志
│   ├── router/             # 路由配置
│   │   └── index.ts
│   ├── stores/             # Pinia 状态管理
│   ├── App.vue             # 根组件
│   └── main.ts             # 入口文件
├── package.json
├── vite.config.ts
└── tsconfig.json
```

## 开发

### 安装依赖

```bash
npm install
```

### 启动开发服务器

```bash
npm run dev
```

开发服务器将在 `http://localhost:5173` 启动

### 构建生产版本

```bash
npm run build
```

构建产物将输出到 `dist/` 目录

### 类型检查

```bash
npm run type-check
```

### 代码格式化

```bash
npm run format
```

## 功能说明

### 公开页面

1. **首页** (`/`)
   - 显示统计数据（总包数、下载量、组织数等）
   - 快速导航

2. **包列表** (`/packages`)
   - 浏览所有包
   - 搜索和筛选
   - 分页显示

3. **包详情** (`/packages/:name`)
   - 查看包的详细信息
   - 安装说明

4. **帮助文档** (`/docs`)
   - 快速开始指南
   - 配置说明
   - 常见问题

### 管理后台

1. **仪表盘** (`/admin/dashboard`)
   - 统计概览
   - 最近发布的包
   - 最近注册的用户

2. **包管理** (`/admin/packages`)
   - 查看所有包
   - 删除包

3. **用户管理** (`/admin/users`)
   - 查看所有用户
   - 创建新用户
   - 重置用户 Token

4. **操作日志** (`/admin/logs`)
   - 查看操作历史
   - 筛选和搜索

## API 配置

API 基础路径配置在 `src/api/index.ts`：

```typescript
const request: AxiosInstance = axios.create({
  baseURL: '/api',  // API 基础路径
  timeout: 10000,
})
```

### Token 认证

管理后台需要 Token 认证，Token 存储在 `localStorage` 中，key 为 `admin_token`。

在开发环境中，可以先手动设置：
```javascript
localStorage.setItem('admin_token', 'your-token-here')
```

## 与后端集成

确保后端服务正在运行并监听正确的端口。开发环境的代理配置可以在 `vite.config.ts` 中设置：

```typescript
export default defineConfig({
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

## 推荐的 IDE 设置

[VS Code](https://code.visualstudio.com/) + [Vue (Official)](https://marketplace.visualstudio.com/items?itemName=Vue.volar) (并禁用 Vetur)

## 浏览器支持

- Chrome >= 87
- Firefox >= 78
- Safari >= 14
- Edge >= 88

## 开发注意事项

1. 所有 API 请求都使用 `/api/` 前缀
2. 管理后台页面需要 Token 认证
3. 使用 TypeScript 类型定义确保类型安全
4. 遵循 Vue 3 Composition API 最佳实践
5. 使用 Element Plus 组件保持 UI 一致性

## 故障排除

### API 请求失败

1. 检查后端服务是否运行
2. 检查 API 代理配置
3. 检查浏览器控制台的网络请求

### Token 认证失败

1. 确认 Token 已正确存储在 `localStorage`
2. 检查 Token 格式是否正确（应该是 `Bearer {token}`）
3. 使用管理后台创建新用户获取新 Token

### 构建失败

1. 清除 `node_modules` 重新安装
2. 检查 Node.js 版本是否符合要求（>= 20.19.0 或 >= 22.12.0）
3. 运行 `npm run type-check` 检查类型错误
