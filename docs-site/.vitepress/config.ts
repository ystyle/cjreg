import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'cjreg',
  description: '仓颉私有中心仓与多仓体系 —— 纯仓颉实现、与官方中心仓协议互通',
  // 部署在 https://ystyle.top/cjreg/（GitHub Pages + 华为云 CDN）；本地 pnpm dev 同样走该前缀
  base: process.env.DOCS_BASE || '/cjreg/',
  lang: 'zh-CN',
  ignoreDeadLinks: true,
  themeConfig: {
    nav: [
      { text: '首页', link: '/' },
      { text: '指南', link: '/guide/' },
      { text: 'API', link: '/api/' },
      { text: '部署', link: '/deploy/' },
      { text: '关于', link: '/about/' },
    ],
    sidebar: {
      '/guide/': [
        { text: '开始使用', items: [
          { text: '快速开始', link: '/guide/' },
          { text: '安装与运行', link: '/guide/install' },
          { text: '客户端配置', link: '/guide/client' },
        ]},
        { text: '核心能力', items: [
          { text: '发布包', link: '/guide/publish' },
          { text: '权限模型', link: '/guide/permission' },
          { text: '团队与组织', link: '/guide/teams' },
          { text: '上游代理与多仓', link: '/guide/upstream' },
          { text: '发布计划', link: '/guide/publish-plan' },
        ]},
        { text: '运维', items: [
          { text: '服务端配置', link: '/deploy/env' },
          { text: '内存与优雅关闭', link: '/guide/memory' },
          { text: '审计日志', link: '/guide/audit' },
          { text: '常见问题', link: '/guide/faq' },
        ]},
      ],
      '/deploy/': [
        { text: '部署', items: [
          { text: '部署指南', link: '/deploy/' },
          { text: 'Docker 部署', link: '/deploy/docker' },
          { text: '服务端配置', link: '/deploy/env' },
        ]},
      ],
      '/api/': [
        { text: 'API', items: [
          { text: 'API 一览', link: '/api/' },
        ]},
      ],
      '/about/': [
        { text: '关于', items: [
          { text: '关于 cjreg', link: '/about/' },
        ]},
      ],
    },
    search: { provider: 'local' },
    outline: { level: [2, 3], label: '本页目录' },
    docFooter: { prev: '上一篇', next: '下一篇' },
    socialLinks: [
      { icon: 'github', link: 'https://atomgit.com/ystyle/cjreg' },
    ],
    footer: {
      message: '基于 MIT 协议开源',
      copyright: 'Copyright © 2026 ystyle',
    },
  },
})
