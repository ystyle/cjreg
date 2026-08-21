<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { useRouter, useRoute } from 'vue-router'
import {
  ElCard,
  ElRow,
  ElCol,
  ElDescriptions,
  ElTag,
  ElButton,
  ElLink,
  ElIcon,
  ElSkeleton,
  ElAlert,
  ElMessage,
  ElTabs,
  ElTabPane,
  ElEmpty,
} from 'element-plus'
import { Document, Download, Link, CopyDocument, Box } from '@element-plus/icons-vue'
import MarkdownIt from 'markdown-it'
import dayjs from 'dayjs'
import relativeTime from 'dayjs/plugin/relativeTime'
import 'dayjs/locale/zh-cn'
import { getPackageDetail, type PackageDetailResponse, type Package, type MetaData, type Dependency } from '../api/public'

// 配置 dayjs
dayjs.extend(relativeTime)
dayjs.locale('zh-cn')

const router = useRouter()
const route = useRoute()

const pkg = ref<PackageDetailResponse | null>(null)
const loading = ref(false)
const error = ref('')
const activeTab = ref('overview')
const dependencyTab = ref('source')

// Markdown 渲染器
const md = new MarkdownIt({
  html: true,
  linkify: true,
  typographer: true,
})

// 解析最新版本的 meta_data
const latestMetaData = computed<MetaData | null>(() => {
  if (!pkg.value?.versions?.length) return null
  const latest = pkg.value.versions[0]
  try {
    return JSON.parse(latest.meta_data)
  } catch {
    return null
  }
})

// 获取最新版本的组织
const latestOrganization = computed<string>(() => {
  if (!pkg.value?.versions?.length) return ''
  return pkg.value.versions[0].organization || ''
})

// 获取包的显示名称（org::name 格式）
const packageDisplayName = computed<string>(() => {
  if (!latestOrganization.value) {
    return pkg.value?.name || ''
  }
  return `${latestOrganization.value}::${pkg.value?.name || ''}`
})

// 获取最新版本的 README
const latestReadme = computed<string>(() => {
  if (!pkg.value?.versions?.length) return ''
  return pkg.value.versions[0].readme || ''
})

// 渲染后的 README HTML
const renderedReadme = computed<string>(() => {
  if (!latestReadme.value) return ''
  return md.render(latestReadme.value)
})

// 获取依赖列表
const dependencies = computed<Dependency[]>(() => {
  return latestMetaData.value?.index?.dependencies || []
})

// 获取测试依赖列表
const testDependencies = computed<Dependency[]>(() => {
  return latestMetaData.value?.index?.['test-dependencies'] || []
})

// 获取构建脚本依赖列表
const scriptDependencies = computed<Dependency[]>(() => {
  return latestMetaData.value?.index?.['script-dependencies'] || []
})

// 计算总下载次数（所有版本之和）
const totalDownloads = computed<number>(() => {
  if (!pkg.value?.versions?.length) return 0
  return pkg.value.versions.reduce((sum, v) => sum + (v.download_count || 0), 0)
})

// 格式化下载次数显示
const formatDownloadCount = computed<string>(() => {
  const count = totalDownloads.value
  if (count === 0) return '暂无下载'
  if (count >= 10000) return `${(count / 10000).toFixed(1)}万`
  if (count >= 1000) return `${(count / 1000).toFixed(1)}k`
  return count.toString()
})

// 构建依赖包的显示名称（org::name 格式）
const getDependencyDisplayName = (dep: Dependency) => {
  // 依赖也可能包含组织信息，从 meta-data 中解析
  // 这里简单处理，如果依赖名已经有 :: 就直接用
  if (dep.name.includes('::')) {
    return dep.name
  }
  // 否则只用包名（实际应该从依赖的 meta-data 中获取组织信息）
  return dep.name
}

// 构建依赖包的链接
const getDependencyLink = (dep: Dependency) => {
  const displayName = getDependencyDisplayName(dep)
  return `/packages/${displayName}`
}

// 获取依赖的 TOML 配置格式
const getDependencyTOML = () => {
  if (!pkg.value?.versions?.length) return ''
  const version = pkg.value.versions[0].version
  const org = latestOrganization.value
  const name = pkg.value.name

  // 有组织时使用引号：'org::package' = { version = 'x.x.x' }
  // 无组织时不使用引号：package = { version = 'x.x.x' }
  if (org) {
    return `'${org}::${name}' = { version = '${version}' }`
  } else {
    return `${name} = { version = '${version}' }`
  }
}

// 解析 JSON 数组字符串
const parseJSONArray = <T>(jsonStr: string, defaultValue: T): T => {
  if (!jsonStr || jsonStr === '[]') {
    return defaultValue
  }
  try {
    return JSON.parse(jsonStr) as T
  } catch {
    return defaultValue
  }
}

// 获取包的协议列表
const getPackageLicenses = () => {
  if (!pkg.value?.versions?.length) return []
  return parseJSONArray<string[]>(pkg.value.versions[0].licenses, [])
}

// 获取包的分类列表
const getPackageCategories = () => {
  if (!pkg.value?.versions?.length) return []
  return parseJSONArray<string[]>(pkg.value.versions[0].categories, [])
}

// 获取包的标签列表
const getPackageTags = () => {
  if (!pkg.value?.versions?.length) return []
  return parseJSONArray<string[]>(pkg.value.versions[0].tags, [])
}

// 获取包的作者列表
const getPackageAuthors = () => {
  if (!pkg.value?.versions?.length) return []
  return parseJSONArray<string[]>(pkg.value.versions[0].authors, [])
}

// 是否有依赖
const hasDependencies = computed(() => {
  return dependencies.value.length > 0 || testDependencies.value.length > 0 || scriptDependencies.value.length > 0
})

const loadPackage = async () => {
  const name = route.params.name as string
  if (!name) {
    error.value = '包名不能为空'
    return
  }

  loading.value = true
  error.value = ''

  try {
    pkg.value = await getPackageDetail(name)
  } catch (err: any) {
    error.value = err.message || '加载包详情失败'
  } finally {
    loading.value = false
  }
}

const formatDate = (date: string) => {
  if (!date) return '未知'
  const d = new Date(date)
  if (isNaN(d.getTime())) return '未知'
  return d.toLocaleString('zh-CN', {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit'
  })
}

// 格式化相对时间（如"3天前"）
const formatRelativeTime = (date: string) => {
  if (!date) return '未知'
  return dayjs(date).fromNow()
}

// 格式化文件大小
const formatFileSize = (bytes: number): string => {
  if (bytes === 0) return '0 B'
  const k = 1024
  const sizes = ['B', 'KB', 'MB', 'GB']
  const i = Math.floor(Math.log(bytes) / Math.log(k))
  return `${(bytes / Math.pow(k, i)).toFixed(i === 0 ? 0 : 2)} ${sizes[i]}`
}

const copyToClipboard = async (text: string, successMsg: string) => {
  try {
    await navigator.clipboard.writeText(text)
    ElMessage.success(successMsg)
  } catch (err) {
    ElMessage.error('复制失败')
  }
}

onMounted(() => {
  loadPackage()
})
</script>

<template>
  <div class="package-detail-container">
    <div class="content-wrapper">
      <!-- Skeleton Loading -->
      <div v-if="loading" class="skeleton-wrapper">
        <el-skeleton animated>
          <template #template>
            <el-row :gutter="24">
              <el-col :span="16">
                <el-skeleton-item variant="rect" style="height: 200px; border-radius: 16px; margin-bottom: 24px;" />
                <el-skeleton-item variant="rect" style="height: 300px; border-radius: 16px;" />
              </el-col>
              <el-col :span="8">
                <el-skeleton-item variant="rect" style="height: 400px; border-radius: 16px;" />
              </el-col>
            </el-row>
          </template>
        </el-skeleton>
      </div>

      <!-- Error Alert -->
      <el-alert
        v-else-if="error"
        type="error"
        :title="error"
        show-icon
        :closable="false"
        class="error-alert"
      />

      <!-- Package Detail -->
      <div v-else-if="pkg" class="package-detail">
        <!-- Header -->
        <div class="header-card">
          <div class="package-header-content">
            <div class="package-title-row">
              <h1 class="package-name">{{ packageDisplayName }}</h1>
              <el-tag size="large" type="success" class="version-badge">{{ pkg.versions[0]?.version }}</el-tag>
            </div>
            <p class="package-description">{{ pkg.description || '暂无描述' }}</p>

            <!-- 关键信息行 -->
            <div class="package-meta">
              <div class="meta-item">
                <span class="meta-label">更新于</span>
                <span class="meta-value">{{ formatRelativeTime(pkg.versions[0]?.updated_at) }}</span>
              </div>

              <div v-if="getPackageCategories().length > 0" class="meta-item">
                <span class="meta-label">分类</span>
                <div class="meta-value tags-inline">
                  <el-tag
                    v-for="category in getPackageCategories().slice(0, 3)"
                    :key="category"
                    size="small"
                    type="warning"
                    class="inline-tag"
                  >
                    {{ category }}
                  </el-tag>
                  <span v-if="getPackageCategories().length > 3" class="more-tags">
                    +{{ getPackageCategories().length - 3 }}
                  </span>
                </div>
              </div>

              <div v-if="getPackageTags().length > 0" class="meta-item">
                <span class="meta-label">标签</span>
                <div class="meta-value tags-inline">
                  <el-tag
                    v-for="tag in getPackageTags().slice(0, 3)"
                    :key="tag"
                    size="small"
                    type="info"
                    class="inline-tag"
                  >
                    {{ tag }}
                  </el-tag>
                  <span v-if="getPackageTags().length > 3" class="more-tags">
                    +{{ getPackageTags().length - 3 }}
                  </span>
                </div>
              </div>
            </div>
          </div>
        </div>

        <!-- Main Content Layout -->
        <el-row :gutter="24">
          <!-- Left: Tabs Content -->
          <el-col :xs="24" :lg="16">
            <el-tabs v-model="activeTab" class="package-tabs">
              <!-- Overview Tab -->
              <el-tab-pane label="概览" name="overview">
                <!-- README Card -->
                <div class="info-card">
                  <div v-if="latestReadme" class="readme-content" v-html="renderedReadme"></div>
                  <el-empty v-else description="暂无 README 文档" :image-size="80" />
                </div>
              </el-tab-pane>

              <!-- Dependencies Tab -->
              <el-tab-pane name="dependencies">
                <template #label>
                  <span>依赖</span>
                  <el-tag size="small" class="tab-count">
                    {{ dependencies.length + testDependencies.length + scriptDependencies.length }}
                  </el-tag>
                </template>

                <div class="info-card">
                  <el-tabs v-model="dependencyTab" class="dependency-tabs">
                    <!-- 源码依赖 -->
                    <el-tab-pane name="source">
                      <template #label>
                        <span>源码依赖</span>
                        <el-tag size="small" class="tab-count">{{ dependencies.length }}</el-tag>
                      </template>
                      <el-empty v-if="dependencies.length === 0" description="暂无源码依赖" :image-size="80" />
                      <div v-else class="dependencies-list">
                        <div
                          v-for="dep in dependencies"
                          :key="dep.name"
                          class="dependency-item"
                        >
                          <div class="dependency-main">
                            <el-link
                              :href="getDependencyLink(dep)"
                              class="dependency-name"
                              @click.prevent="router.push(getDependencyLink(dep))"
                            >
                              {{ getDependencyDisplayName(dep) }}
                            </el-link>
                            <el-tag size="small" type="info">{{ dep.require }}</el-tag>
                          </div>
                          <div v-if="dep.target || dep.type" class="dependency-meta">
                            <span v-if="dep.target" class="meta-tag">目标: {{ dep.target }}</span>
                            <span v-if="dep.type" class="meta-tag">类型: {{ dep.type }}</span>
                          </div>
                        </div>
                      </div>
                    </el-tab-pane>

                    <!-- 测试依赖 -->
                    <el-tab-pane name="test">
                      <template #label>
                        <span>测试依赖</span>
                        <el-tag size="small" class="tab-count">{{ testDependencies.length }}</el-tag>
                      </template>
                      <el-empty v-if="testDependencies.length === 0" description="暂无测试依赖" :image-size="80" />
                      <div v-else class="dependencies-list">
                        <div
                          v-for="dep in testDependencies"
                          :key="dep.name"
                          class="dependency-item"
                        >
                          <div class="dependency-main">
                            <el-link
                              :href="getDependencyLink(dep)"
                              class="dependency-name"
                              @click.prevent="router.push(getDependencyLink(dep))"
                            >
                              {{ getDependencyDisplayName(dep) }}
                            </el-link>
                            <el-tag size="small" type="info">{{ dep.require }}</el-tag>
                          </div>
                          <div v-if="dep.target || dep.type" class="dependency-meta">
                            <span v-if="dep.target" class="meta-tag">目标: {{ dep.target }}</span>
                            <span v-if="dep.type" class="meta-tag">类型: {{ dep.type }}</span>
                          </div>
                        </div>
                      </div>
                    </el-tab-pane>

                    <!-- 构建脚本依赖 -->
                    <el-tab-pane name="script">
                      <template #label>
                        <span>构建脚本依赖</span>
                        <el-tag size="small" class="tab-count">{{ scriptDependencies.length }}</el-tag>
                      </template>
                      <el-empty v-if="scriptDependencies.length === 0" description="暂无构建脚本依赖" :image-size="80" />
                      <div v-else class="dependencies-list">
                        <div
                          v-for="dep in scriptDependencies"
                          :key="dep.name"
                          class="dependency-item"
                        >
                          <div class="dependency-main">
                            <el-link
                              :href="getDependencyLink(dep)"
                              class="dependency-name"
                              @click.prevent="router.push(getDependencyLink(dep))"
                            >
                              {{ getDependencyDisplayName(dep) }}
                            </el-link>
                            <el-tag size="small" type="info">{{ dep.require }}</el-tag>
                          </div>
                          <div v-if="dep.target || dep.type" class="dependency-meta">
                            <span v-if="dep.target" class="meta-tag">目标: {{ dep.target }}</span>
                            <span v-if="dep.type" class="meta-tag">类型: {{ dep.type }}</span>
                          </div>
                        </div>
                      </div>
                    </el-tab-pane>
                  </el-tabs>
                </div>
              </el-tab-pane>

              <!-- Versions Tab -->
              <el-tab-pane name="versions">
                <template #label>
                  <span>版本历史</span>
                  <el-tag size="small" class="tab-count">{{ pkg.versions.length }}</el-tag>
                </template>

                <div class="versions-card">
                  <div class="version-list">
                    <div
                      v-for="version in pkg.versions"
                      :key="version.id"
                      class="version-item"
                    >
                      <div class="version-main">
                        <div class="version-info">
                          <span class="version-number">{{ version.version }}</span>
                          <el-tag v-if="version.id === pkg.versions[0]?.id" size="small" type="success">最新</el-tag>
                        </div>
                        <div class="version-meta">
                          <span class="version-date">发布于 {{ formatDate(version.created_at) }}</span>
                        </div>
                      </div>
                      <div class="version-actions">
                        <el-button
                          size="small"
                          :icon="CopyDocument"
                          @click="copyToClipboard(`'${packageDisplayName}' = { version = '${version.version}' }`, '配置已复制')"
                        >
                          复制配置
                        </el-button>
                      </div>
                    </div>
                  </div>
                </div>
              </el-tab-pane>
            </el-tabs>
          </el-col>

          <!-- Right: Sidebar -->
          <el-col :xs="24" :lg="8">
            <!-- Info Card -->
            <div class="sidebar-card">
              <h3 class="sidebar-title">包信息</h3>

              <div class="info-list">
                <div class="info-item">
                  <span class="info-label">最新版本</span>
                  <el-tag type="success">{{ pkg.versions[0]?.version }}</el-tag>
                </div>
                <div class="info-item">
                  <span class="info-label">更新时间</span>
                  <span class="info-value">{{ formatDate(pkg.versions[0]?.updated_at) }}</span>
                </div>
                <div v-if="getPackageCategories().length > 0" class="info-item">
                  <span class="info-label">分类</span>
                  <div class="info-value tags-wrapper">
                    <el-tag
                      v-for="category in getPackageCategories()"
                      :key="category"
                      size="small"
                      type="warning"
                      class="tag-item"
                    >
                      {{ category }}
                    </el-tag>
                  </div>
                </div>
                <div v-if="getPackageTags().length > 0" class="info-item">
                  <span class="info-label">标签</span>
                  <div class="info-value tags-wrapper">
                    <el-tag
                      v-for="tag in getPackageTags()"
                      :key="tag"
                      size="small"
                      type="info"
                      class="tag-item"
                    >
                      {{ tag }}
                    </el-tag>
                  </div>
                </div>
                <div class="info-item">
                  <span class="info-label">组织</span>
                  <el-tag type="primary">{{ pkg.versions[0]?.organization || '默认' }}</el-tag>
                </div>
                <div v-if="latestMetaData?.['cjc-version']" class="info-item">
                  <span class="info-label">SDK 版本</span>
                  <el-tag type="info">{{ latestMetaData['cjc-version'] }}</el-tag>
                </div>
                <div class="info-item">
                  <span class="info-label">类型</span>
                  <el-tag :type="pkg.versions[0]?.artifact_type === 'src' ? 'info' : 'warning'">
                    {{ pkg.versions[0]?.artifact_type === 'src' ? '源码' : '二进制' }}
                  </el-tag>
                </div>
                <div v-if="pkg.versions[0]?.executable" class="info-item">
                  <span class="info-label">可执行</span>
                  <el-tag type="danger">是</el-tag>
                </div>
                <div v-if="getPackageLicenses().length > 0" class="info-item">
                  <span class="info-label">协议</span>
                  <div class="info-value tags-wrapper">
                    <el-tag
                      v-for="license in getPackageLicenses()"
                      :key="license"
                      size="small"
                      type="success"
                      class="tag-item"
                    >
                      {{ license }}
                    </el-tag>
                  </div>
                </div>
                <div v-if="getPackageAuthors().length > 0" class="info-item">
                  <span class="info-label">作者</span>
                  <div class="info-value tags-wrapper">
                    <span
                      v-for="(author, index) in getPackageAuthors()"
                      :key="author"
                      class="author-item"
                    >
                      {{ author }}<span v-if="index < getPackageAuthors().length - 1">, </span>
                    </span>
                  </div>
                </div>
                <div v-if="pkg.repository" class="info-item">
                  <span class="info-label">仓库</span>
                  <el-link
                    :href="pkg.repository"
                    target="_blank"
                    type="primary"
                    class="info-link"
                  >
                    查看代码
                  </el-link>
                </div>
                <div v-if="pkg.homepage" class="info-item">
                  <span class="info-label">主页</span>
                  <el-link
                    :href="pkg.homepage"
                    target="_blank"
                    type="primary"
                    class="info-link"
                  >
                    访问主页
                  </el-link>
                </div>
                <div v-if="pkg.documentation" class="info-item">
                  <span class="info-label">文档</span>
                  <el-link
                    :href="pkg.documentation"
                    target="_blank"
                    type="primary"
                    class="info-link"
                  >
                    查看文档
                  </el-link>
                </div>
                <div class="info-item">
                  <span class="info-label">创建时间</span>
                  <span class="info-value">{{ formatDate(pkg.versions[0]?.created_at) }}</span>
                </div>
                <div v-if="pkg.versions[0]?.tarball_size" class="info-item">
                  <span class="info-label">包大小</span>
                  <span class="info-value">{{ formatFileSize(pkg.versions[0].tarball_size) }}</span>
                </div>
                <div class="info-item">
                  <span class="info-label">下载次数</span>
                  <span class="info-value download-count">{{ formatDownloadCount }}</span>
                </div>
              </div>

              <!-- 使用指南 -->
              <div class="usage-section">
                <h4 class="section-title">使用指南</h4>

                <!-- 安装命令（仅可执行程序） -->
                <div v-if="pkg.versions[0]?.executable" class="usage-card">
                  <div class="usage-card-header">
                    <div class="usage-card-title">
                      <el-icon><Box /></el-icon>
                      <span>安装命令</span>
                    </div>
                    <el-button
                      size="small"
                      :icon="CopyDocument"
                      @click="copyToClipboard(`cjpm install ${packageDisplayName}-${pkg.versions[0]?.version}`, '命令已复制')"
                    >
                      复制
                    </el-button>
                  </div>
                  <div class="usage-card-body">
                    <code>cjpm install {{ packageDisplayName }}-{{ pkg.versions[0]?.version }}</code>
                  </div>
                </div>

                <!-- 依赖配置 -->
                <div class="usage-card">
                  <div class="usage-card-header">
                    <div class="usage-card-title">
                      <el-icon><Document /></el-icon>
                      <span>依赖配置</span>
                    </div>
                    <el-button
                      size="small"
                      :icon="CopyDocument"
                      @click="copyToClipboard(getDependencyTOML(), '配置已复制')"
                    >
                      复制
                    </el-button>
                  </div>
                  <div class="usage-card-body">
                    <code>{{ getDependencyTOML() }}</code>
                  </div>
                  <div class="usage-card-footer">
                    <span class="usage-tip">添加到 cjpm.toml 的 dependencies 部分</span>
                  </div>
                </div>
              </div>
            </div>
          </el-col>
        </el-row>
      </div>
    </div>
  </div>
</template>

<style scoped>
.package-detail-container {
  width: 100%;
  min-height: 100vh;
  background: #f5f7fa;
}

.content-wrapper {
  max-width: 1400px;
  margin: 0 auto;
  padding: 40px 20px 60px;
}

/* Header Card */
.header-card {
  background: white;
  border-radius: 16px;
  padding: 28px;
  margin-bottom: 24px;
  box-shadow: 0 2px 12px rgba(0, 0, 0, 0.08);
}

.package-header-content {
  width: 100%;
}

.package-title-row {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-bottom: 16px;
  flex-wrap: wrap;
}

.package-name {
  font-size: 32px;
  font-weight: 700;
  color: #303133;
  margin: 0;
}

.version-badge {
  background: linear-gradient(135deg, #43e97b 0%, #38f9d7 100%);
  border: none;
  color: white;
  font-weight: 600;
  font-size: 16px;
  padding: 8px 16px;
  height: auto;
}

.package-description {
  font-size: 16px;
  color: #606266;
  line-height: 1.6;
  margin: 0 0 20px 0;
}

.package-meta {
  display: flex;
  gap: 32px;
  flex-wrap: wrap;
  align-items: center;
  padding-top: 16px;
  border-top: 1px solid #f0f0f0;
}

.meta-item {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 14px;
}

.meta-label {
  color: #909399;
  font-weight: 500;
}

.meta-value {
  color: #303133;
  font-weight: 500;
}

.tags-inline {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  align-items: center;
}

.inline-tag {
  margin: 0;
}

.more-tags {
  color: #909399;
  font-size: 12px;
  margin-left: 4px;
}

/* Tabs */
.package-tabs {
  margin-top: 0;
}

.package-tabs :deep(.el-tabs__header) {
  margin: 0 0 24px 0;
}

.package-tabs :deep(.el-tabs__nav-wrap::after) {
  display: none;
}

.package-tabs :deep(.el-tabs__item) {
  font-size: 16px;
  font-weight: 500;
  color: #606266;
  padding: 0 20px;
}

.package-tabs :deep(.el-tabs__item.is-active) {
  color: #2563eb;
  font-weight: 600;
}

.package-tabs :deep(.el-tabs__active-bar) {
  background: linear-gradient(90deg, #2563eb 0%, #3b82f6 100%);
  height: 3px;
}

.tab-count {
  margin-left: 8px;
}

/* Dependency Sub-Tabs */
.dependency-tabs :deep(.el-tabs__header) {
  margin-bottom: 20px;
}

.dependency-tabs :deep(.el-tabs__item) {
  font-size: 14px;
  font-weight: 500;
  padding: 0 16px;
}

/* Versions Card */
.versions-card {
  background: white;
  border-radius: 16px;
  padding: 28px;
  box-shadow: 0 2px 12px rgba(0, 0, 0, 0.06);
}

/* Version History */
.version-list {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.version-item {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 20px;
  background: #f5f7fa;
  border-radius: 12px;
  gap: 24px;
  transition: all 0.3s ease;
}

.version-item:hover {
  background: #e8ecf1;
  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.08);
}

.version-main {
  flex: 1;
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 24px;
}

.version-info {
  display: flex;
  align-items: center;
  gap: 12px;
}

.version-number {
  font-size: 18px;
  font-weight: 600;
  color: #303133;
}

.version-meta {
  display: flex;
  align-items: center;
  gap: 12px;
}

.version-date {
  font-size: 14px;
  color: #909399;
}

.version-actions {
  display: flex;
  gap: 8px;
}

/* Info Card */
.info-card {
  background: white;
  border-radius: 16px;
  padding: 28px;
  margin-bottom: 24px;
  box-shadow: 0 2px 12px rgba(0, 0, 0, 0.06);
}

.card-title {
  font-size: 20px;
  font-weight: 600;
  color: #303133;
  margin: 0 0 20px 0;
  display: flex;
  align-items: center;
  gap: 10px;
}

.card-title .el-icon {
  color: #2563eb;
}

/* Dependencies List */
.dependencies-list {
  display: flex;
  flex-direction: column;
  gap: 12px;
}

.dependency-item {
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 16px;
  background: #f5f7fa;
  border-radius: 12px;
  transition: all 0.3s ease;
}

.dependency-item:hover {
  background: #e8ecf1;
  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.08);
}

.dependency-main {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 16px;
}

.dependency-name {
  font-size: 16px;
  font-weight: 600;
  color: #303133;
  text-decoration: none;
  transition: color 0.3s ease;
}

.dependency-name:hover {
  color: #2563eb;
}

.dependency-meta {
  display: flex;
  gap: 12px;
  flex-wrap: wrap;
}

.meta-tag {
  font-size: 12px;
  color: #909399;
  padding: 4px 8px;
  background: white;
  border-radius: 6px;
}

/* Links Grid */
.links-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
  gap: 12px;
}

.link-item {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 16px 20px;
  background: #f5f7fa;
  border-radius: 12px;
  transition: all 0.3s ease;
  font-size: 15px;
  font-weight: 500;
}

.link-item:hover {
  background: linear-gradient(135deg, #2563eb 0%, #3b82f6 100%);
  color: white;
  transform: translateY(-2px);
}

/* Install Block */
.install-block {
  margin-bottom: 20px;
}

.install-block:last-child {
  margin-bottom: 0;
}

.install-label {
  font-size: 14px;
  font-weight: 600;
  color: #606266;
  margin-bottom: 10px;
}

.command-box {
  background: #1e1e1e;
  border-radius: 12px;
  padding: 16px 20px;
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 16px;
}

.command-box code {
  font-family: 'Fira Code', 'Consolas', monospace;
  font-size: 14px;
  color: #a9b7c6;
  flex: 1;
}

.config-box {
  background: #1e1e1e;
  border-radius: 12px;
  padding: 16px 20px;
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 16px;
}

.config-box pre {
  margin: 0;
  flex: 1;
}

.config-box code {
  font-family: 'Fira Code', 'Consolas', monospace;
  font-size: 14px;
  color: #a9b7c6;
  line-height: 1.8;
}

/* README Content */
.readme-content {
  background: #ffffff;
  border-radius: 8px;
  padding: 24px;
  overflow: hidden;
  line-height: 1.8;
}

/* Markdown 样式 */
.readme-content :deep(h1),
.readme-content :deep(h2),
.readme-content :deep(h3),
.readme-content :deep(h4),
.readme-content :deep(h5),
.readme-content :deep(h6) {
  margin-top: 24px;
  margin-bottom: 16px;
  font-weight: 600;
  line-height: 1.25;
  color: #24292e;
}

.readme-content :deep(h1) {
  font-size: 2em;
  border-bottom: 1px solid #eaecef;
  padding-bottom: 0.3em;
}

.readme-content :deep(h2) {
  font-size: 1.5em;
  border-bottom: 1px solid #eaecef;
  padding-bottom: 0.3em;
}

.readme-content :deep(h3) {
  font-size: 1.25em;
}

.readme-content :deep(p) {
  margin-top: 0;
  margin-bottom: 16px;
  color: #24292e;
}

.readme-content :deep(code) {
  padding: 0.2em 0.4em;
  margin: 0;
  font-size: 85%;
  background-color: rgba(175, 184, 193, 0.2);
  border-radius: 6px;
  font-family: 'Fira Code', 'Consolas', 'Monaco', monospace;
}

.readme-content :deep(pre) {
  padding: 16px;
  overflow: auto;
  font-size: 85%;
  line-height: 1.45;
  background-color: #f6f8fa;
  border-radius: 6px;
  margin-bottom: 16px;
}

.readme-content :deep(pre code) {
  padding: 0;
  background-color: transparent;
}

.readme-content :deep(ul),
.readme-content :deep(ol) {
  padding-left: 2em;
  margin-bottom: 16px;
}

.readme-content :deep(li) {
  margin-bottom: 4px;
}

.readme-content :deep(a) {
  color: #0969da;
  text-decoration: none;
}

.readme-content :deep(a:hover) {
  text-decoration: underline;
}

.readme-content :deep(blockquote) {
  padding: 0 1em;
  color: #57606a;
  border-left: 0.25em solid #d0d7de;
  margin-bottom: 16px;
}

.readme-content :deep(table) {
  border-collapse: collapse;
  width: 100%;
  margin-bottom: 16px;
}

.readme-content :deep(table th),
.readme-content :deep(table td) {
  padding: 6px 13px;
  border: 1px solid #d0d7de;
}

.readme-content :deep(table th) {
  background-color: #f6f8fa;
  font-weight: 600;
}

.readme-content :deep(img) {
  max-width: 100%;
  height: auto;
}

/* Sidebar Card */
.sidebar-card {
  background: white;
  border-radius: 16px;
  padding: 28px;
  box-shadow: 0 2px 12px rgba(0, 0, 0, 0.06);
  position: sticky;
  top: 20px;
}

.sidebar-title {
  font-size: 18px;
  font-weight: 600;
  color: #303133;
  margin: 0 0 20px 0;
  padding-bottom: 16px;
  border-bottom: 2px solid #f0f0f0;
}

.info-list {
  margin-bottom: 24px;
}

.info-item {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 12px 0;
  border-bottom: 1px solid #f5f7fa;
}

.info-item:last-child {
  border-bottom: none;
}

.info-label {
  font-size: 14px;
  color: #909399;
}

.info-value {
  font-size: 14px;
  color: #303133;
  font-weight: 500;
}

.tags-wrapper {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  align-items: center;
}

.tag-item {
  margin: 0;
}

.author-item {
  font-size: 14px;
  color: #303133;
}

.info-link {
  font-size: 14px;
}

.download-count {
  font-size: 16px;
  font-weight: 600;
  color: #2563eb;
}

/* 使用指南 */
.usage-section {
  margin-top: 24px;
  padding-top: 20px;
  border-top: 2px solid #f0f0f0;
}

.section-title {
  font-size: 16px;
  font-weight: 600;
  color: #303133;
  margin: 0 0 16px 0;
}

.usage-card {
  background: #f8f9fa;
  border: 1px solid #e9ecef;
  border-radius: 12px;
  margin-bottom: 12px;
  overflow: hidden;
  transition: all 0.3s ease;
}

.usage-card:hover {
  border-color: #2563eb;
  box-shadow: 0 2px 12px rgba(37, 99, 235, 0.1);
}

.usage-card-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 12px 16px;
  background: white;
  border-bottom: 1px solid #e9ecef;
}

.usage-card-title {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 14px;
  font-weight: 600;
  color: #303133;
}

.usage-card-title .el-icon {
  color: #2563eb;
  font-size: 18px;
}

.usage-card-body {
  padding: 14px 16px;
  background: #1e1e1e;
}

.usage-card-body code {
  font-family: 'Fira Code', 'Consolas', monospace;
  font-size: 13px;
  color: #a9b7c6;
  line-height: 1.6;
  word-break: break-all;
}

.usage-card-footer {
  padding: 10px 16px;
  background: white;
  border-top: 1px solid #e9ecef;
}

.usage-tip {
  font-size: 12px;
  color: #909399;
  line-height: 1.5;
}

/* Skeleton & Error */
.skeleton-wrapper {
  padding: 30px 20px;
}

.error-alert {
  margin: 30px 20px;
  border-radius: 12px;
}

/* Responsive */
@media (max-width: 992px) {
  .sidebar-card {
    position: static;
    margin-top: 24px;
  }
}

@media (max-width: 768px) {
  .package-name {
    font-size: 24px;
  }

  .package-description {
    font-size: 14px;
  }

  .package-tabs :deep(.el-tabs__item) {
    font-size: 14px;
    padding: 0 12px;
  }

  .links-grid {
    grid-template-columns: 1fr;
  }

  .version-item {
    flex-direction: column;
    align-items: stretch;
    gap: 16px;
  }

  .version-main {
    flex-direction: column;
    align-items: flex-start;
    gap: 8px;
  }

  .command-box,
  .config-box {
    flex-direction: column;
    align-items: stretch;
  }

  .command-box code,
  .config-box code {
    word-break: break-all;
  }

  .info-card,
  .versions-card,
  .sidebar-card {
    padding: 20px;
  }

  .sidebar-card {
    margin-top: 24px;
  }
}
</style>
