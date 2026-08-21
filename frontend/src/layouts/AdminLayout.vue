<script setup lang="ts">
import { ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import {
  ElContainer,
  ElAside,
  ElMenu,
  ElMenuItem,
  ElHeader,
} from 'element-plus'
import { House, Box, Document, DataAnalysis, User, Connection, Setting, InfoFilled, Key, Reading, Upload } from '@element-plus/icons-vue'
import { siteName } from '../stores/site'
import CjBox from '../components/CjBox.vue'
import AboutDialog from '../components/AboutDialog.vue'

const route = useRoute()
const router = useRouter()
const aboutDialogRef = ref<InstanceType<typeof AboutDialog>>()

const goHome = () => {
  router.push('/')
}

const openAbout = () => {
  aboutDialogRef.value?.open()
}

const openDocs = () => {
  window.open('/docs', '_blank')
}
</script>

<template>
  <el-container>
    <el-aside width="200px" class="admin-aside">
      <div class="logo">
        <div class="logo-icon">
          <CjBox />
        </div>
        <span>{{ siteName }}</span>
      </div>
      <el-menu
        :default-active="route.path"
        router
        class="admin-menu"
      >
        <el-menu-item index="/admin/dashboard">
          <el-icon><DataAnalysis /></el-icon>
          <span>仪表盘</span>
        </el-menu-item>
        <el-menu-item index="/admin/packages">
          <el-icon><Box /></el-icon>
          <span>包管理</span>
        </el-menu-item>
        <el-menu-item index="/admin/users">
          <el-icon><User /></el-icon>
          <span>用户管理</span>
        </el-menu-item>
        <el-menu-item index="/admin/organizations">
          <el-icon><Setting /></el-icon>
          <span>组织管理</span>
        </el-menu-item>
        <el-menu-item index="/admin/teams">
          <el-icon><Key /></el-icon>
          <span>团队管理</span>
        </el-menu-item>
        <el-menu-item index="/admin/upstreams">
          <el-icon><Connection /></el-icon>
          <span>上游管理</span>
        </el-menu-item>
        <el-menu-item index="/admin/publish-plans">
          <el-icon><Upload /></el-icon>
          <span>发布计划</span>
        </el-menu-item>
        <el-menu-item index="/admin/logs">
          <el-icon><Document /></el-icon>
          <span>操作日志</span>
        </el-menu-item>
      </el-menu>
      <el-menu class="bottom-menu">
        <el-menu-item @click="goHome">
          <el-icon><House /></el-icon>
          <span>返回首页</span>
        </el-menu-item>
        <el-menu-item @click="openDocs">
          <el-icon><Reading /></el-icon>
          <span>文档</span>
        </el-menu-item>
        <el-menu-item class="about-menu" @click="openAbout">
          <el-icon><InfoFilled /></el-icon>
          <span>关于</span>
        </el-menu-item>
      </el-menu>
    </el-aside>
    <el-container>
      <el-header class="admin-header">
        <h2>{{ route.meta.title || '管理后台' }}</h2>
      </el-header>
      <el-main class="admin-main">
        <router-view />
      </el-main>
    </el-container>
  </el-container>
  <AboutDialog ref="aboutDialogRef" />
</template>

<style scoped>
.admin-aside {
  background: #001529;
  color: white;
  height: 100vh;
  display: flex;
  flex-direction: column;
}

.admin-header {
  background: white;
  border-bottom: 1px solid #f0f0f0;
  display: flex;
  align-items: center;
  padding: 0 30px;
  height: 60px;
}

.admin-header h2 {
  margin: 0;
  font-size: 20px;
  color: #303133;
}

.admin-main {
  background: #f0f2f5;
  height: calc(100vh - 60px);
  overflow-y: auto;
}

.logo {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 20px;
  font-size: 18px;
  font-weight: bold;
  color: white;
  border-bottom: 1px solid rgba(255, 255, 255, 0.1);
}

.logo-icon {
  width: 28px;
  height: 28px;
  flex-shrink: 0;
}

.admin-menu {
  border: none;
  background: transparent;
  flex: 1;
  overflow-y: auto;
}

.bottom-menu {
  margin-top: auto;
  border: none;
  background: transparent;
}

.about-menu {
  cursor: pointer;
}

:deep(.el-menu) {
  background: transparent;
}

:deep(.el-menu-item) {
  color: rgba(255, 255, 255, 0.65);
}

:deep(.el-menu-item:hover) {
  background: rgba(255, 255, 255, 0.1);
  color: white;
}

:deep(.el-menu-item.is-active) {
  background: #1890ff;
  color: white;
}

@media (max-width: 768px) {
  .admin-aside {
    width: 64px !important;
  }

  .logo-icon {
    width: 24px;
    height: 24px;
  }

  .logo span {
    display: none;
  }

  :deep(.el-menu-item span) {
    display: none;
  }

  :deep(.el-menu-item) {
    padding: 0 20px;
  }

  .admin-header {
    padding: 0 15px;
  }

  .admin-header h2 {
    font-size: 18px;
  }
}
</style>
