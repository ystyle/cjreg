<script setup lang="ts">
import { computed } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import {
  ElMenu,
  ElMenuItem,
} from 'element-plus'
import { House, Box, Document } from '@element-plus/icons-vue'
import { siteName } from '../stores/site'
import CjBox from '../components/CjBox.vue'

const router = useRouter()
const route = useRoute()

const activeMenu = computed(() => {
  if (route.path === '/') return '1'
  if (route.path === '/packages' || route.path.startsWith('/packages/')) return '2'
  if (route.path.startsWith('/docs/')) return '3'
  return '1'
})

const goToHome = () => {
  router.push('/')
}

const openDocs = () => {
  window.open('/docs/guide/', '_self')
}
</script>

<template>
  <div class="public-layout">
    <!-- 顶部导航栏 -->
    <header class="top-header">
      <div class="header-content">
        <div class="logo" @click="goToHome">
          <div class="logo-icon">
            <CjBox />
          </div>
          <span class="logo-text">{{ siteName }}</span>
        </div>
        <el-menu
          :default-active="activeMenu"
          mode="horizontal"
          router
          class="top-menu"
        >
          <el-menu-item index="/">
            <el-icon><House /></el-icon>
            <span>首页</span>
          </el-menu-item>
          <el-menu-item index="/packages">
            <el-icon><Box /></el-icon>
            <span>包列表</span>
          </el-menu-item>
          <el-menu-item index="/docs-guide" @click="openDocs">
            <el-icon><Document /></el-icon>
            <span>帮助文档</span>
          </el-menu-item>
        </el-menu>
      </div>
    </header>

    <!-- 主内容区域 -->
    <main class="main-content">
      <router-view />
    </main>
  </div>
</template>

<style scoped>
.public-layout {
  min-height: 100vh;
  display: flex;
  flex-direction: column;
}

/* 顶部导航栏 */
.top-header {
  background: white;
  box-shadow: 0 2px 12px rgba(0, 0, 0, 0.08);
  position: sticky;
  top: 0;
  z-index: 1000;
}

.header-content {
  max-width: 1400px;
  margin: 0 auto;
  padding: 0 20px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  height: 64px;
}

.logo {
  display: flex;
  align-items: center;
  gap: 12px;
  font-size: 20px;
  font-weight: 700;
  color: #303133;
  text-decoration: none;
  cursor: pointer;
  transition: all 0.3s ease;
  padding: 8px;
  margin: -8px;
  border-radius: 8px;
}

.logo:hover {
  background: #f5f7fa;
}

.logo-icon {
  width: 32px;
  height: 32px;
  flex-shrink: 0;
}

.logo-text {
  background: linear-gradient(135deg, #2563eb 0%, #3b82f6 100%);
  -webkit-background-clip: text;
  -webkit-text-fill-color: transparent;
  background-clip: text;
}

.top-menu {
  border: none;
  background: transparent;
  flex: 1;
  justify-content: flex-end;
  padding-right: 20px;
}

:deep(.el-menu-item) {
  font-size: 16px;
  font-weight: 500;
  color: #606266;
  padding: 0 20px;
  height: 64px;
  line-height: 64px;
  border-bottom: 2px solid transparent;
}

:deep(.el-menu-item:hover) {
  background: transparent;
  color: #2563eb;
}

:deep(.el-menu-item.is-active) {
  background: transparent;
  color: #2563eb;
  border-bottom-color: #2563eb;
}

:deep(.el-menu-item .el-icon) {
  margin-right: 6px;
}

/* 主内容区域 */
.main-content {
  flex: 1;
  display: flex;
  flex-direction: column;
}

/* 响应式 */
@media (max-width: 768px) {
  .header-content {
    padding: 0 15px;
  }

  .logo-icon {
    width: 28px;
    height: 28px;
  }

  .logo-text {
    display: none;
  }

  :deep(.el-menu-item span) {
    font-size: 14px;
  }

  :deep(.el-menu-item) {
    padding: 0 12px;
  }
}
</style>
