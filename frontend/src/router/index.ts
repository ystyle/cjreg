import { createRouter, createWebHistory } from 'vue-router'
import AdminLayout from '../layouts/AdminLayout.vue'
import PublicLayout from '../layouts/PublicLayout.vue'

const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes: [
    // 公开页面（嵌套路由）
    {
      path: '/',
      component: PublicLayout,
      children: [
        {
          path: '',
          name: 'home',
          component: () => import('../views/Home.vue'),
        },
        {
          path: 'packages',
          name: 'packages',
          component: () => import('../views/Packages.vue'),
        },
        {
          path: 'packages/:name',
          name: 'package-detail',
          component: () => import('../views/PackageDetail.vue'),
        },

      ],
    },

    // 管理后台登录
    {
      path: '/admin/login',
      name: 'admin-login',
      component: () => import('../views/admin/Login.vue'),
      meta: { public: true },
    },

    // 管理后台（嵌套路由）
    {
      path: '/admin',
      name: 'admin',
      component: AdminLayout,
      meta: { requiresAuth: true },
      children: [
        {
          path: '',
          redirect: '/admin/dashboard',
        },
        {
          path: 'dashboard',
          name: 'admin-dashboard',
          component: () => import('../views/admin/Dashboard.vue'),
          meta: { title: '仪表盘' },
        },
        {
          path: 'packages',
          name: 'admin-packages',
          component: () => import('../views/admin/Packages.vue'),
          meta: { title: '包管理' },
        },
        {
          path: 'users',
          name: 'admin-users',
          component: () => import('../views/admin/Users.vue'),
          meta: { title: '用户管理' },
        },
        {
          path: 'logs',
          name: 'admin-logs',
          component: () => import('../views/admin/Logs.vue'),
          meta: { title: '操作日志' },
        },
        {
          path: 'upstreams',
          name: 'admin-upstreams',
          component: () => import('../views/admin/Upstreams.vue'),
          meta: { title: '上游管理' },
        },
        {
          path: 'organizations',
          name: 'admin-organizations',
          component: () => import('../views/admin/Organizations.vue'),
          meta: { title: '组织管理' },
        },
        {
          path: 'teams',
          name: 'admin-teams',
          component: () => import('../views/admin/Teams.vue'),
          meta: { title: '团队管理' },
        },
        {
          path: 'publish-plans',
          name: 'admin-publish-plans',
          component: () => import('../views/admin/PublishPlans.vue'),
          meta: { title: '发布计划' },
        },
        {
          path: 'publish-plans/create',
          name: 'admin-publish-plan-create',
          component: () => import('../views/admin/PublishPlanCreate.vue'),
          meta: { title: '新建发布计划' },
        },
        {
          path: 'publish-plans/:id',
          name: 'admin-publish-plan-detail',
          component: () => import('../views/admin/PublishPlanDetail.vue'),
          meta: { title: '发布计划详情' },
        },
      ],
    },

    // 404 页面
    {
      path: '/:pathMatch(.*)*',
      redirect: '/',
    },
  ],
})

// 路由守卫：检查管理后台的认证
router.beforeEach((to, from, next) => {
  const token = localStorage.getItem('admin_token')
  const requiresAuth = to.meta.requiresAuth

  if (requiresAuth && !token) {
    // 需要认证但没有 token，跳转到登录页
    next({
      name: 'admin-login',
      query: { redirect: to.fullPath },
    })
  } else if (to.name === 'admin-login' && token) {
    // 已登录用户访问登录页，跳转到 dashboard
    next({ name: 'admin-dashboard' })
  } else {
    next()
  }
})

export default router
