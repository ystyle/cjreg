<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import {
  ElCard,
  ElRow,
  ElCol,
  ElInput,
  ElButton,
  ElPagination,
  ElTag,
  ElEmpty,
  ElIcon,
  ElSkeleton,
  ElCheckbox,
  ElCheckboxGroup,
} from 'element-plus'
import { Search, Box, Grid } from '@element-plus/icons-vue'
import { getPackages, type Package } from '../api/public'

const router = useRouter()

const packages = ref<Package[]>([])
const loading = ref(false)

const searchQuery = ref('')
const selectedCategories = ref<string[]>([])
const currentPage = ref(1)
const pageSize = ref(20)
const total = ref(0)

// 官方分类列表
const CATEGORY_LIST = [
  { name: 'Network', label: '网络' },
  { name: 'Database Driver', label: '数据库驱动' },
  { name: 'Data Encapsulation and Transfer', label: '数据封装传递' },
  { name: 'Data Analysis', label: '数据解析' },
  { name: 'Database Framework', label: '数据库框架' },
  { name: 'Object Storage', label: '对象存储' },
  { name: 'Distributed', label: '分布式' },
  { name: 'Task Scheduling', label: '任务调度' },
  { name: 'Security', label: '安全类' },
  { name: 'Utility', label: '工具类' },
  { name: 'Logging', label: '日志类' },
  { name: 'Algorithm', label: '算法类' },
  { name: 'Audio and Video', label: '音视频' },
  { name: 'Character Encoding', label: '字符编码' },
  { name: 'Image Processing', label: '图像处理' },
  { name: 'Developer Tools', label: '开发者工具' },
  { name: 'Animation', label: '动画类' },
  { name: 'Infrastructure', label: '基础设施' },
  { name: 'Geographic Information', label: '地理信息' },
  { name: 'UI', label: 'UI 类' },
  { name: 'Scientific Computing', label: '科学计算' },
  { name: 'Programming Framework', label: '编程框架' },
  { name: 'Data Monitoring', label: '数据监控' },
  { name: 'Circuit Breaker and Downgrading', label: '熔断降级' },
  { name: 'Message Queue', label: '消息队列' },
]

const loadPackages = async () => {
  loading.value = true
  try {
    const data = await getPackages({
      page: currentPage.value,
      pageSize: pageSize.value,
      search: searchQuery.value,
      categories: selectedCategories.value.join(','),
    })
    packages.value = data.data || []
    total.value = data.total
  } catch (error) {
    console.error('Failed to load packages:', error)
    packages.value = []
  } finally {
    loading.value = false
  }
}

const handleSearch = () => {
  currentPage.value = 1
  loadPackages()
}

const handlePageChange = (page: number) => {
  currentPage.value = page
  loadPackages()
}

const handleCategoryChange = () => {
  currentPage.value = 1
  loadPackages()
}

const goToDetail = (pkg: Package) => {
  const packageIdentifier = pkg.organization ? `${pkg.organization}::${pkg.name}` : pkg.name
  router.push(`/packages/${packageIdentifier}`)
}

// 解析 JSON 数组字符串
const parseJSON = <T,>(jsonStr: string, defaultValue: T): T => {
  if (!jsonStr || jsonStr === '[]') {
    return defaultValue
  }
  try {
    return JSON.parse(jsonStr) as T
  } catch {
    return defaultValue
  }
}

// 获取包的分类
const getPackageCategories = (pkg: Package): string[] => {
  return parseJSON<string[]>(pkg.categories, [])
}

// 获取包的标签
const getPackageTags = (pkg: Package): string[] => {
  return parseJSON<string[]>(pkg.tags, [])
}

// 获取包的协议
const getPackageLicenses = (pkg: Package): string[] => {
  return parseJSON<string[]>(pkg.licenses, [])
}

// 格式化下载次数
const formatDownloadCount = (count: number): string => {
  if (count === 0) return '暂无下载'
  if (count >= 10000) return `${(count / 10000).toFixed(1)}万`
  if (count >= 1000) return `${(count / 1000).toFixed(1)}k`
  return count.toString()
}

onMounted(() => {
  loadPackages()
})
</script>

<template>
  <div class="packages-container">
    <!-- Search Section -->
    <section class="search-section">
      <div class="content-wrapper">
        <div class="section-header">
          <h1 class="section-title">发现仓颉包</h1>
          <p class="section-subtitle">浏览和搜索仓颉生态系统中的精彩包</p>
        </div>

        <div class="search-box">
          <el-input
            v-model="searchQuery"
            placeholder="搜索包名、描述，或使用 org::关键词 格式搜索组织包..."
            size="large"
            clearable
            class="search-input"
            @clear="handleSearch"
            @keyup.enter="handleSearch"
          >
            <template #prefix>
              <el-icon><Search /></el-icon>
            </template>
            <template #append>
              <el-button :icon="Search" @click="handleSearch">搜索</el-button>
            </template>
          </el-input>
        </div>
      </div>
    </section>

    <!-- Main Content with Sidebar -->
    <section class="packages-section">
      <div class="content-wrapper">
        <el-row :gutter="24">
          <!-- Left Sidebar - Categories -->
          <el-col :xs="24" :sm="24" :md="6" :lg="5">
            <div class="sidebar">
              <div class="sidebar-header">
                <el-icon><Grid /></el-icon>
                <span>分类筛选</span>
              </div>
              <el-checkbox-group
                v-model="selectedCategories"
                @change="handleCategoryChange"
                class="category-list"
              >
                <el-checkbox
                  v-for="cat in CATEGORY_LIST"
                  :key="cat.name"
                  :label="cat.name"
                  class="category-item"
                >
                  {{ cat.label }}
                </el-checkbox>
              </el-checkbox-group>
            </div>
          </el-col>

          <!-- Right Content - Package List -->
          <el-col :xs="24" :sm="24" :md="18" :lg="19">
            <div v-if="total > 0" class="results-info">
              <span class="count">{{ total }}</span> 个包
              <span v-if="searchQuery || selectedCategories.length" class="filters-info">
                <span v-if="searchQuery">包含 "{{ searchQuery }}"</span>
                <span v-if="selectedCategories.length > 0">
                  分类: {{ selectedCategories.map(cat => CATEGORY_LIST.find(c => c.name === cat)?.label).join(', ') }}
                </span>
              </span>
            </div>

            <el-skeleton v-if="loading" :loading="loading" animated>
              <template #template>
                <el-row :gutter="24">
                  <el-col v-for="i in 8" :key="i" :xs="24" :sm="12" :md="8" :lg="6">
                    <el-skeleton-item variant="rect" style="height: 280px; border-radius: 16px; margin-bottom: 24px;" />
                  </el-col>
                </el-row>
              </template>
            </el-skeleton>

            <el-empty v-else-if="packages.length === 0" description="没有找到匹配的包" />

            <el-row v-else :gutter="24">
              <el-col
                v-for="pkg in packages"
                :key="pkg.id"
                :xs="24"
                :sm="12"
                :md="12"
                :lg="8"
                class="package-col"
              >
                <div class="package-card" @click="goToDetail(pkg)">
                  <div class="package-content">
                    <div class="package-header">
                      <h3 class="package-name">{{ pkg.organization ? `${pkg.organization}::${pkg.name}` : pkg.name }}</h3>
                      <div class="package-tags">
                        <el-tag size="small" type="success" class="version-tag">
                          {{ pkg.version }}
                        </el-tag>
                      </div>
                    </div>
                    <p class="package-description">{{ pkg.description || '暂无描述' }}</p>
                    <div class="package-stats">
                      <span class="download-stat">
                        <el-icon><Download /></el-icon>
                        {{ formatDownloadCount(pkg.download_count || 0) }}
                      </span>
                    </div>
                    <div class="package-meta">
                      <!-- 类型标签 -->
                      <el-tag size="small" :type="pkg.artifact_type === 'src' ? 'info' : 'warning'">
                        {{ pkg.artifact_type === 'src' ? '源码' : '二进制' }}
                      </el-tag>
                      <el-tag v-if="pkg.executable" size="small" type="danger">
                        可执行
                      </el-tag>

                      <!-- 协议标签 -->
                      <el-tag
                        v-for="license in getPackageLicenses(pkg).slice(0, 1)"
                        :key="license"
                        size="small"
                        type="primary"
                        class="license-tag"
                      >
                        {{ license }}
                      </el-tag>

                      <!-- 分类标签 -->
                      <el-tag
                        v-for="category in getPackageCategories(pkg).slice(0, 1)"
                        :key="category"
                        size="small"
                        class="category-tag"
                      >
                        {{ CATEGORY_LIST.find(c => c.name === category)?.label || category }}
                      </el-tag>

                      <!-- 标签 -->
                      <el-tag
                        v-for="tag in getPackageTags(pkg).slice(0, 2)"
                        :key="tag"
                        size="small"
                        type="info"
                        class="tag-item"
                      >
                        {{ tag }}
                      </el-tag>
                    </div>
                  </div>
                </div>
              </el-col>
            </el-row>

            <!-- Pagination -->
            <div v-if="total > 0" class="pagination-wrapper">
              <el-pagination
                v-model:current-page="currentPage"
                v-model:page-size="pageSize"
                :page-sizes="[12, 24, 48, 96]"
                :total="total"
                layout="total, sizes, prev, pager, next, jumper"
                background
                @current-change="handlePageChange"
                @size-change="loadPackages"
              />
            </div>
          </el-col>
        </el-row>
      </div>
    </section>
  </div>
</template>

<style scoped>
.packages-container {
  width: 100%;
  min-height: 100vh;
  background: #f5f7fa;
}

/* Search Section */
.search-section {
  background: white;
  padding: 40px 20px 30px;
  box-shadow: 0 2px 12px rgba(0, 0, 0, 0.08);
}

.section-header {
  text-align: center;
  margin-bottom: 30px;
}

.section-title {
  font-size: 32px;
  font-weight: 700;
  color: #303133;
  margin: 0 0 12px 0;
}

.section-subtitle {
  font-size: 16px;
  color: #909399;
  margin: 0;
}

.content-wrapper {
  max-width: 1400px;
  margin: 0 auto;
}

.search-box {
  display: flex;
  gap: 16px;
  align-items: center;
  flex-wrap: wrap;
}

.search-input {
  flex: 1;
  min-width: 300px;
}

.search-input :deep(.el-input__wrapper) {
  border-radius: 12px 0 0 12px;
  border-top-right-radius: 0;
  border-bottom-right-radius: 0;
  box-shadow: 0 2px 12px rgba(0, 0, 0, 0.08);
  padding: 8px 16px;
}

.search-input :deep(.el-input__wrapper:hover),
.search-input :deep(.el-input__wrapper.is-focus) {
  box-shadow: 0 4px 20px rgba(102, 126, 234, 0.2);
}

/* Sidebar - Category Filter */
.sidebar {
  background: white;
  border-radius: 12px;
  padding: 20px;
  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.06);
  position: sticky;
  top: 20px;
  max-height: calc(100vh - 120px);
  overflow-y: auto;
}

.sidebar-header {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 16px;
  font-weight: 600;
  color: #303133;
  margin-bottom: 16px;
  padding-bottom: 12px;
  border-bottom: 1px solid #ebeef5;
}

.category-list {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.category-item {
  width: 100%;
  margin: 0;
  padding: 8px 12px;
  border-radius: 8px;
  transition: all 0.2s ease;
  display: flex;
  align-items: center;
}

.category-item:hover {
  background: #f5f7fa;
}

.category-item :deep(.el-checkbox__label) {
  width: 100%;
  padding-left: 8px;
  display: flex;
  align-items: center;
  font-size: 14px;
  font-weight: 500;
  color: #303133;
}

.category-item :deep(.el-checkbox__input) {
  flex-shrink: 0;
}

/* Packages Section */
.packages-section {
  padding: 40px 20px 60px;
}

.results-info {
  margin-bottom: 24px;
  font-size: 15px;
  color: #606266;
}

.count {
  font-weight: 600;
  color: #2563eb;
  font-size: 18px;
}

.filters-info {
  color: #909399;
  margin-left: 8px;
}

.package-col {
  margin-bottom: 24px;
}

.package-card {
  background: white;
  border-radius: 16px;
  padding: 24px;
  cursor: pointer;
  transition: all 0.3s ease;
  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.06);
  height: 100%;
  display: flex;
  flex-direction: column;
  position: relative;
  overflow: hidden;
}

.package-card::before {
  content: '';
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  height: 3px;
  background: linear-gradient(90deg, #2563eb 0%, #3b82f6 100%);
  transform: scaleX(0);
  transition: transform 0.3s ease;
}

.package-card:hover {
  transform: translateY(-4px);
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.12);
}

.package-card:hover::before {
  transform: scaleX(1);
}

.package-content {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.package-header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  gap: 12px;
}

.package-name {
  font-size: 18px;
  font-weight: 600;
  color: #303133;
  margin: 0;
  line-height: 1.4;
}

.package-tags {
  display: flex;
  gap: 8px;
  flex-shrink: 0;
}

.package-description {
  font-size: 14px;
  color: #606266;
  line-height: 1.6;
  margin: 0;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}

.package-stats {
  display: flex;
  align-items: center;
  gap: 16px;
  margin: 8px 0;
}

.download-stat {
  display: flex;
  align-items: center;
  gap: 4px;
  font-size: 13px;
  color: #909399;
}

.download-stat .el-icon {
  font-size: 16px;
}

.version-tag {
  background: linear-gradient(135deg, #43e97b 0%, #38f9d7 100%);
  border: none;
  color: white;
  font-weight: 500;
}

.org-tag {
  background: linear-gradient(135deg, #fa709a 0%, #fee140 100%);
  border: none;
  color: white;
  font-weight: 500;
}

.package-meta {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
  margin-top: 4px;
}

.license-tag {
  background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
  border: none;
  color: white;
  font-weight: 500;
}

.category-tag {
  background: linear-gradient(135deg, #f093fb 0%, #f5576c 100%);
  border: none;
  color: white;
  font-weight: 500;
}

.tag-item {
  background: #f0f2f5;
  border: none;
  color: #606266;
  font-weight: 500;
}

/* Pagination */
.pagination-wrapper {
  margin-top: 40px;
  display: flex;
  justify-content: center;
  padding: 20px 0;
}

.pagination-wrapper :deep(.el-pagination) {
  gap: 8px;
}

.pagination-wrapper :deep(.el-pagination.is-background .el-pager li) {
  border-radius: 8px;
  font-weight: 500;
}

.pagination-wrapper :deep(.el-pagination.is-background .btn-next),
.pagination-wrapper :deep(.el-pagination.is-background .btn-prev) {
  border-radius: 8px;
}

/* Responsive */
@media (max-width: 768px) {
  .page-title {
    font-size: 28px;
  }

  .title-icon {
    font-size: 28px;
  }

  .page-subtitle {
    font-size: 16px;
  }

  .search-box {
    flex-direction: column;
    align-items: stretch;
  }

  .search-input {
    min-width: 100%;
  }
}
</style>
