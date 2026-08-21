<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import {
  ElCard,
  ElRow,
  ElCol,
  ElStatistic,
  ElTable,
  ElTableColumn,
  ElTag,
  ElButton,
  ElIcon,
  ElMessage,
  ElEmpty,
} from 'element-plus'
import {
  Collection,
  User,
  Download,
  Upload,
  Refresh,
  Box,
  Flag,
} from '@element-plus/icons-vue'
import { getDashboardStats } from '../../api/admin'

const router = useRouter()

const stats = ref({
  packages: 0,
  versions: 0,
  users: 0,
  activeUsers: 0,
  storageSize: 0,
  publishSuccess: 0,
  publishFailed: 0,
})

const loading = ref(false)

const loadStats = async () => {
  loading.value = true
  try {
    const data = await getDashboardStats()
    stats.value = data
  } catch (error: any) {
    ElMessage.error(error.message || '加载统计数据失败')
  } finally {
    loading.value = false
  }
}

const formatSize = (bytes: number) => {
  if (bytes === 0) return '0 B'
  const k = 1024
  const sizes = ['B', 'KB', 'MB', 'GB']
  const i = Math.floor(Math.log(bytes) / Math.log(k))
  return Math.round((bytes / Math.pow(k, i)) * 100) / 100 + ' ' + sizes[i]
}

onMounted(() => {
  loadStats()
})
</script>

<template>
  <div class="dashboard-container">
    <div class="page-header">
      <h1>
        <el-icon :size="28"><Collection /></el-icon>
        管理后台
      </h1>
      <el-button :icon="Refresh" @click="loadStats">刷新</el-button>
    </div>

    <!-- 统计卡片 -->
    <el-row :gutter="20" class="stats-row">
      <el-col :xs="12" :sm="6">
        <el-card v-loading="loading" shadow="hover">
          <el-statistic title="包总数" :value="stats.packages">
            <template #prefix>
              <el-icon :size="20" color="#409eff"><Box /></el-icon>
            </template>
          </el-statistic>
        </el-card>
      </el-col>
      <el-col :xs="12" :sm="6">
        <el-card v-loading="loading" shadow="hover">
          <el-statistic title="版本总数" :value="stats.versions">
            <template #prefix>
              <el-icon :size="20" color="#67c23a"><Collection /></el-icon>
            </template>
          </el-statistic>
        </el-card>
      </el-col>
      <el-col :xs="12" :sm="6">
        <el-card v-loading="loading" shadow="hover">
          <el-statistic title="用户总数" :value="stats.users">
            <template #prefix>
              <el-icon :size="20" color="#e6a23c"><User /></el-icon>
            </template>
          </el-statistic>
        </el-card>
      </el-col>
      <el-col :xs="12" :sm="6">
        <el-card v-loading="loading" shadow="hover">
          <el-statistic title="活跃用户" :value="stats.activeUsers">
            <template #prefix>
              <el-icon :size="20" color="#f56c6c"><Download /></el-icon>
            </template>
          </el-statistic>
        </el-card>
      </el-col>
    </el-row>

    <!-- 第二行统计 -->
    <el-row :gutter="20" class="stats-row">
      <el-col :xs="12" :sm="8">
        <el-card v-loading="loading" shadow="hover">
          <el-statistic title="存储使用" :value="formatSize(stats.storageSize)">
            <template #prefix>
              <el-icon :size="20" color="#909399"><Upload /></el-icon>
            </template>
          </el-statistic>
        </el-card>
      </el-col>
      <el-col :xs="12" :sm="8">
        <el-card v-loading="loading" shadow="hover">
          <el-statistic title="发布成功" :value="stats.publishSuccess">
            <template #prefix>
              <el-icon :size="20" color="#67c23a"><Box /></el-icon>
            </template>
          </el-statistic>
        </el-card>
      </el-col>
      <el-col :xs="12" :sm="8">
        <el-card v-loading="loading" shadow="hover">
          <el-statistic title="发布失败" :value="stats.publishFailed">
            <template #prefix>
              <el-icon :size="20" color="#f56c6c"><Collection /></el-icon>
            </template>
          </el-statistic>
        </el-card>
      </el-col>
    </el-row>

    <!-- 快捷入口 -->
    <el-row :gutter="20" class="actions-row">
      <el-col :xs="24" :sm="8">
        <el-card shadow="hover" class="action-card" @click="router.push('/admin/packages')">
          <div class="action-content">
            <el-icon :size="32" color="#409eff"><Box /></el-icon>
            <div>
              <h3>包管理</h3>
              <p>查看和管理所有包</p>
            </div>
          </div>
        </el-card>
      </el-col>
      <el-col :xs="24" :sm="8">
        <el-card shadow="hover" class="action-card" @click="router.push('/admin/teams')">
          <div class="action-content">
            <el-icon :size="32" color="#67c23a"><User /></el-icon>
            <div>
              <h3>团队管理</h3>
              <p>管理团队和成员权限</p>
            </div>
          </div>
        </el-card>
      </el-col>
      <el-col :xs="24" :sm="8">
        <el-card shadow="hover" class="action-card" @click="router.push('/admin/publish-plans')">
          <div class="action-content">
            <el-icon :size="32" color="#e6a23c"><Flag /></el-icon>
            <div>
              <h3>发布计划</h3>
              <p>批量发布包到上游</p>
            </div>
          </div>
        </el-card>
      </el-col>
    </el-row>
  </div>
</template>

<style scoped>
.dashboard-container {
  padding: 20px;
}

.page-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 30px;
}

.page-header h1 {
  font-size: 28px;
  color: #303133;
  margin: 0;
  display: flex;
  align-items: center;
  gap: 10px;
}

.stats-row {
  margin-bottom: 30px;
}

.stats-row .el-card {
  text-align: center;
  padding: 20px;
}

.actions-row {
  margin-bottom: 30px;
}

.action-card {
  cursor: pointer;
  transition: all 0.3s ease;
}

.action-card:hover {
  transform: translateY(-4px);
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.12) !important;
}

.action-content {
  display: flex;
  align-items: center;
  gap: 16px;
}

.action-content h3 {
  font-size: 16px;
  font-weight: 600;
  color: #303133;
  margin: 0 0 4px 0;
}

.action-content p {
  font-size: 13px;
  color: #909399;
  margin: 0;
}

@media (max-width: 768px) {
  .page-header {
    flex-direction: column;
    gap: 15px;
    align-items: flex-start;
  }

  .page-header h1 {
    font-size: 22px;
  }

  .stats-row .el-col {
    margin-bottom: 15px;
  }

  .action-content {
    flex-direction: column;
    text-align: center;
  }
}
</style>
