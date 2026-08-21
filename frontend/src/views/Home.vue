<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import {
  ElCard,
  ElRow,
  ElCol,
  ElStatistic,
  ElButton,
  ElIcon,
  ElSkeleton,
} from 'element-plus'
import { DataAnalysis, Download, Collection, Box, ArrowRight, Star, TrendCharts } from '@element-plus/icons-vue'
import { getStats } from '../api/public'
import { siteName } from '../stores/site'
import CjBox from '../components/CjBox.vue'

const router = useRouter()

const openDocs = () => {
  window.open('/docs/guide/', '_self')
}

const stats = ref({
  packages: 0,
  users: 0,
  versions: 0,
  downloads: 0,
})

const loading = ref(true)

const loadStats = async () => {
  try {
    const data = await getStats()
    stats.value = data
  } catch (error) {
    console.error('Failed to load stats:', error)
  } finally {
    loading.value = false
  }
}

onMounted(() => {
  loadStats()
})

// 格式化下载次数
const formatDownloadCount = (count: number): string => {
  if (count === 0) return '0'
  if (count >= 10000) return `${(count / 10000).toFixed(1)}万`
  if (count >= 1000) return `${(count / 1000).toFixed(1)}k`
  return count.toString()
}

const features = [
  {
    icon: Box,
    title: '包管理',
    description: '轻松发布、管理和发现仓颉语言包',
    color: '#409EFF',
  },
  {
    icon: Download,
    title: '快速下载',
    description: '高速下载，支持版本管理和依赖解析',
    color: '#67C23A',
  },
  {
    icon: DataAnalysis,
    title: '统计分析',
    description: '完整的统计信息和使用分析',
    color: '#E6A23C',
  },
  {
    icon: Collection,
    title: '版本控制',
    description: '支持多版本管理和回滚',
    color: '#F56C6C',
  },
]
</script>

<template>
  <div class="home-container">
    <!-- Hero Section -->
    <section class="hero-section">
      <div class="hero-content">
        <div class="hero-badge">
          <el-icon><Star /></el-icon>
          <span>{{ siteName }}</span>
        </div>

        <div class="hero-main">
          <div class="hero-left">
            <h1 class="hero-title">
              发现和使用<br>
              <span class="gradient-text">仓颉语言包</span>
            </h1>
            <p class="hero-description">
              统一的包管理和分发平台，让仓颉开发更简单
            </p>
            <div class="hero-actions">
              <el-button type="primary" size="large" @click="router.push('/packages')">
                <el-icon><Collection /></el-icon>
                浏览包
              </el-button>
              <el-button size="large" @click="openDocs">
                <el-icon><Download /></el-icon>
                快速开始
              </el-button>
            </div>
          </div>

          <div class="hero-right">
            <div class="hero-icon-wrapper">
              <CjBox />
            </div>
          </div>
        </div>
      </div>
    </section>

    <!-- Stats Section -->
    <section class="stats-section">
      <div class="content-wrapper">
        <div class="section-header">
          <h2 class="section-title">平台统计</h2>
          <p class="section-subtitle">实时数据展示平台活跃度</p>
        </div>

        <el-skeleton :loading="loading" animated>
          <template #template>
            <el-row :gutter="24">
              <el-col :xs="12" :sm="12" :md="6" :lg="6" v-for="i in 4" :key="i">
                <el-skeleton-item variant="rect" style="height: 120px; border-radius: 16px; margin-bottom: 24px;" />
              </el-col>
            </el-row>
          </template>

          <template #default>
            <el-row :gutter="24">
              <el-col :xs="12" :sm="12" :md="6" :lg="6">
                <div class="stat-card stat-packages">
                  <div class="stat-icon">
                    <el-icon><Collection /></el-icon>
                  </div>
                  <div class="stat-content">
                    <div class="stat-value">{{ stats.packages }}</div>
                    <div class="stat-label">包总数</div>
                  </div>
                </div>
              </el-col>

              <el-col :xs="12" :sm="12" :md="6" :lg="6">
                <div class="stat-card stat-versions">
                  <div class="stat-icon">
                    <el-icon><Box /></el-icon>
                  </div>
                  <div class="stat-content">
                    <div class="stat-value">{{ stats.versions }}</div>
                    <div class="stat-label">版本数</div>
                  </div>
                </div>
              </el-col>

              <el-col :xs="12" :sm="12" :md="6" :lg="6">
                <div class="stat-card stat-users">
                  <div class="stat-icon">
                    <el-icon><DataAnalysis /></el-icon>
                  </div>
                  <div class="stat-content">
                    <div class="stat-value">{{ stats.users }}</div>
                    <div class="stat-label">用户数</div>
                  </div>
                </div>
              </el-col>

              <el-col :xs="12" :sm="12" :md="6" :lg="6">
                <div class="stat-card stat-downloads">
                  <div class="stat-icon">
                    <el-icon><TrendCharts /></el-icon>
                  </div>
                  <div class="stat-content">
                    <div class="stat-value">{{ formatDownloadCount(stats.downloads) }}</div>
                    <div class="stat-label">下载量</div>
                  </div>
                </div>
              </el-col>
            </el-row>
          </template>
        </el-skeleton>
      </div>
    </section>

    <!-- Features Section -->
    <section class="features-section">
      <div class="content-wrapper">
        <div class="section-header">
          <h2 class="section-title">核心功能</h2>
          <p class="section-subtitle">强大的功能支持仓颉生态发展</p>
        </div>

        <el-row :gutter="24">
          <el-col :xs="24" :sm="12" :md="6" v-for="feature in features" :key="feature.title">
            <div class="feature-card">
              <div class="feature-icon" :style="{ backgroundColor: feature.color + '20' }">
                <el-icon :size="32" :color="feature.color">
                  <component :is="feature.icon" />
                </el-icon>
              </div>
              <h3 class="feature-title">{{ feature.title }}</h3>
              <p class="feature-description">{{ feature.description }}</p>
            </div>
          </el-col>
        </el-row>
      </div>
    </section>

    <!-- CTA Section -->
    <section class="cta-section">
      <div class="cta-content">
        <h2 class="cta-title">准备好开始了吗？</h2>
        <p class="cta-description">
          立即探索{{ siteName }}，发现精彩的仓颉语言包
        </p>
        <div class="cta-actions">
          <el-button type="primary" size="large" @click="router.push('/packages')">
            <el-icon><Collection /></el-icon>
            探索包
            <el-icon><ArrowRight /></el-icon>
          </el-button>
          <el-button size="large" plain @click="openDocs">
            <el-icon><Download /></el-icon>
            查看文档
          </el-button>
        </div>
      </div>
    </section>
  </div>
</template>

<style scoped>
.home-container {
  width: 100%;
  min-height: 100vh;
  background: #f5f7fa;
}

/* Hero Section */
.hero-section {
  background: linear-gradient(135deg, #2563eb 0%, #3b82f6 100%);
  padding: 80px 20px 60px;
  position: relative;
  overflow: hidden;
}

.hero-section::before {
  content: '';
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: url('data:image/svg+xml,<svg width="60" height="60" viewBox="0 0 60 60" xmlns="http://www.w3.org/2000/svg"><g fill="none" fill-rule="evenodd"><g fill="%23ffffff" fill-opacity="0.05"><path d="M36 34v-4h-2v4h-4v2h4v4h2v-4h4v-2h-4zm0-30V0h-2v4h-4v2h4v4h2V6h4V2h-4zM6 34v-4H4v4H0v2h4v4h2v-4h4v-2H6zM6 4V0H4v4H0v2h4v4h2V6h4V2H6z"/></g></g></svg>');
  opacity: 0.4;
  animation: pattern 20s linear infinite;
}

@keyframes pattern {
  0% {
    background-position: 0 0;
  }
  100% {
    background-position: 60px 60px;
  }
}

.hero-content {
  max-width: 1200px;
  margin: 0 auto;
  position: relative;
  z-index: 1;
}

.hero-main {
  display: flex;
  align-items: center;
  gap: 60px;
}

.hero-left {
  flex: 1;
}

.hero-right {
  flex-shrink: 0;
}

.hero-icon-wrapper {
  width: 200px;
  height: 200px;
  animation: float 3s ease-in-out infinite;
}

@keyframes float {
  0%, 100% {
    transform: translateY(0px);
  }
  50% {
    transform: translateY(-20px);
  }
}

.hero-badge {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 8px 16px;
  background: rgba(255, 255, 255, 0.2);
  backdrop-filter: blur(10px);
  border-radius: 20px;
  color: white;
  font-size: 14px;
  font-weight: 500;
  margin-bottom: 24px;
}

.hero-title {
  font-size: 48px;
  font-weight: 700;
  color: white;
  line-height: 1.2;
  margin-bottom: 20px;
}

.gradient-text {
  background: linear-gradient(90deg, #FFD700, #FFA500);
  -webkit-background-clip: text;
  -webkit-text-fill-color: transparent;
  background-clip: text;
}

.hero-description {
  font-size: 18px;
  color: rgba(255, 255, 255, 0.9);
  margin-bottom: 32px;
  max-width: 600px;
  line-height: 1.6;
}

.hero-actions {
  display: flex;
  gap: 16px;
  flex-wrap: wrap;
}

/* Stats Section */
.stats-section {
  padding: 60px 20px;
  background: white;
}

.content-wrapper {
  max-width: 1400px;
  margin: 0 auto;
}

.section-header {
  text-align: center;
  margin-bottom: 40px;
}

.section-title {
  font-size: 32px;
  font-weight: 700;
  color: #303133;
  margin-bottom: 12px;
}

.section-subtitle {
  font-size: 16px;
  color: #909399;
  margin: 0;
}

.stat-card {
  background: white;
  border-radius: 16px;
  padding: 24px;
  display: flex;
  align-items: center;
  gap: 20px;
  box-shadow: 0 2px 12px rgba(0, 0, 0, 0.08);
  transition: all 0.3s ease;
  cursor: pointer;
  height: 100%;
}

.stat-card:hover {
  transform: translateY(-4px);
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.12);
}

.stat-icon {
  width: 60px;
  height: 60px;
  border-radius: 12px;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 28px;
  flex-shrink: 0;
}

.stat-packages .stat-icon {
  background: linear-gradient(135deg, #2563eb 0%, #3b82f6 100%);
  color: white;
}

.stat-versions .stat-icon {
  background: linear-gradient(135deg, #f093fb 0%, #f5576c 100%);
  color: white;
}

.stat-users .stat-icon {
  background: linear-gradient(135deg, #4facfe 0%, #00f2fe 100%);
  color: white;
}

.stat-downloads .stat-icon {
  background: linear-gradient(135deg, #43e97b 0%, #38f9d7 100%);
  color: white;
}

.stat-content {
  flex: 1;
}

.stat-value {
  font-size: 32px;
  font-weight: 700;
  color: #303133;
  line-height: 1;
  margin-bottom: 4px;
}

.stat-label {
  font-size: 14px;
  color: #909399;
}

/* Features Section */
.features-section {
  padding: 60px 20px;
  background: #f5f7fa;
}

.feature-card {
  background: white;
  border-radius: 16px;
  padding: 32px 24px;
  text-align: center;
  transition: all 0.3s ease;
  height: 100%;
  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.06);
}

.feature-card:hover {
  transform: translateY(-8px);
  box-shadow: 0 12px 32px rgba(0, 0, 0, 0.12);
}

.feature-icon {
  width: 64px;
  height: 64px;
  border-radius: 16px;
  display: flex;
  align-items: center;
  justify-content: center;
  margin: 0 auto 20px;
}

.feature-title {
  font-size: 20px;
  font-weight: 600;
  color: #303133;
  margin-bottom: 12px;
}

.feature-description {
  font-size: 14px;
  color: #606266;
  line-height: 1.6;
  margin: 0;
}

/* CTA Section */
.cta-section {
  padding: 80px 20px;
  background: linear-gradient(135deg, #2563eb 0%, #3b82f6 100%);
  text-align: center;
}

.cta-content {
  max-width: 800px;
  margin: 0 auto;
}

.cta-title {
  font-size: 36px;
  font-weight: 700;
  color: white;
  margin-bottom: 16px;
}

.cta-description {
  font-size: 18px;
  color: rgba(255, 255, 255, 0.9);
  margin-bottom: 32px;
}

.cta-actions {
  display: flex;
  gap: 16px;
  justify-content: center;
  flex-wrap: wrap;
}

/* 响应式 */
@media (max-width: 768px) {
  .hero-main {
    flex-direction: column;
    text-align: center;
    gap: 30px;
  }

  .hero-icon-wrapper {
    width: 150px;
    height: 150px;
    margin: 0 auto;
  }

  .hero-title {
    font-size: 32px;
  }

  .hero-description {
    font-size: 16px;
  }

  .section-title {
    font-size: 24px;
  }

  .stat-value {
    font-size: 24px;
  }

  .cta-title {
    font-size: 28px;
  }

  .hero-actions,
  .cta-actions {
    flex-direction: column;
  }

  .hero-actions .el-button,
  .cta-actions .el-button {
    width: 100%;
  }
}
</style>
