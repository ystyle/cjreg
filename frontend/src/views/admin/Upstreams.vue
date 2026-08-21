<script setup lang="ts">
import { ref, onMounted } from 'vue'
import {
  ElCard,
  ElTable,
  ElButton,
  ElTag,
  ElSwitch,
  ElEmpty,
  ElMessage,
  ElMessageBox,
  ElDialog,
  ElForm,
  ElFormItem,
  ElInput,
  ElInputNumber,
  ElIcon,
  ElTooltip,
  ElPopover,
  ElPagination,
} from 'element-plus'
import {
  Plus,
  Edit,
  Delete,
  Connection,
  Refresh,
  InfoFilled,
  DeleteFilled,
} from '@element-plus/icons-vue'
import {
  getUpstreams,
  createUpstream,
  updateUpstream,
  deleteUpstream,
  testUpstream,
  getUpstreamCacheStats,
  clearUpstreamCache,
  type Upstream,
  type CreateUpstreamRequest,
  type UpdateUpstreamRequest,
} from '../../api/admin'
import dayjs from 'dayjs'

const upstreams = ref<Upstream[]>([])
const loading = ref(false)
const currentPage = ref(1)
const pageSize = ref(20)
const total = ref(0)
const dialogVisible = ref(false)
const dialogMode = ref<'create' | 'edit'>('create')
const editingId = ref<number | null>(null)
const testing = ref<number | null>(null)

// 表单数据
const formData = ref<CreateUpstreamRequest & { id?: number }>({
  name: '',
  url: '',
  enabled: true,
  cache_ttl: 86400, // 默认24小时
  auth_token: '',
})

// 表单验证规则
const formRules = {
  name: [{ required: true, message: '请输入上游名称', trigger: 'blur' }],
  url: [{ required: true, message: '请输入上游地址', trigger: 'blur' }],
}

const formRef = ref()

// 加载上游列表
const loadUpstreams = async () => {
  loading.value = true
  try {
    const res = await getUpstreams({ page: currentPage.value, pageSize: pageSize.value })
    upstreams.value = res.data || []
    total.value = res.total
  } catch (error: any) {
    console.error('加载上游列表失败:', error)
    upstreams.value = []
    ElMessage.error(error.response?.data?.error || '加载上游列表失败')
  } finally {
    loading.value = false
  }
}

// 打开创建对话框
const openCreateDialog = () => {
  dialogMode.value = 'create'
  editingId.value = null
  formData.value = {
    name: '',
    url: 'https://pkg.cangjie-lang.cn/registry', // 预填充默认地址
    enabled: true,
    cache_ttl: 86400,
    auth_token: '',
  }
  dialogVisible.value = true
}

// 打开编辑对话框
const openEditDialog = (upstream: Upstream) => {
  dialogMode.value = 'edit'
  editingId.value = upstream.id
  formData.value = {
    id: upstream.id,
    name: upstream.name,
    url: upstream.url,
    enabled: upstream.enabled,
    cache_ttl: upstream.cache_ttl,
    auth_token: upstream.auth_token || '',
  }
  dialogVisible.value = true
}

// 提交表单
const submitForm = async () => {
  try {
    await formRef.value.validate()

    if (dialogMode.value === 'create') {
      await createUpstream(formData.value)
      ElMessage.success('上游创建成功')
    } else {
      await updateUpstream(editingId.value!, formData.value)
      ElMessage.success('上游更新成功')
    }

    dialogVisible.value = false
    await loadUpstreams()
  } catch (error: any) {
    if (error.errors) {
      // 表单验证错误
      return
    }
    ElMessage.error(error.response?.data?.error || '操作失败')
  }
}

// 删除上游
const handleDelete = async (upstream: Upstream) => {
  try {
    await ElMessageBox.confirm(
      `确定要删除上游 "${upstream.name}" 吗？此操作不可恢复。`,
      '删除确认',
      {
        confirmButtonText: '确定',
        cancelButtonText: '取消',
        type: 'warning',
      }
    )

    await deleteUpstream(upstream.id)
    ElMessage.success('上游删除成功')
    await loadUpstreams()
  } catch (error: any) {
    if (error !== 'cancel') {
      ElMessage.error(error.response?.data?.error || '删除失败')
    }
  }
}

// 测试上游连接
const handleTest = async (upstream: Upstream) => {
  testing.value = upstream.id
  try {
    const result = await testUpstream(upstream.id)
    if (result.success) {
      ElMessage.success(result.message || '连接测试成功')
    } else {
      ElMessage.warning(result.message || '连接测试失败')
    }
  } catch (error: any) {
    ElMessage.error(error.response?.data?.error || '连接测试失败')
  } finally {
    testing.value = null
  }
}

// 切换启用状态
const handleToggleEnabled = async (upstream: Upstream) => {
  try {
    await updateUpstream(upstream.id, { enabled: !upstream.enabled })
    ElMessage.success(upstream.enabled ? '上游已禁用' : '上游已启用')
    await loadUpstreams()
  } catch (error: any) {
    ElMessage.error(error.response?.data?.error || '操作失败')
  }
}

// 格式化缓存时间
const formatCacheTTL = (ttl: number) => {
  if (ttl === 0) return '永不过期'
  const hours = Math.floor(ttl / 3600)
  const days = Math.floor(hours / 24)
  if (days > 0) {
    return `${days}天`
  }
  return `${hours}小时`
}

// 格式化文件大小
const formatFileSize = (bytes: number): string => {
  if (bytes === 0) return '0 B'
  const k = 1024
  const sizes = ['B', 'KB', 'MB', 'GB']
  const i = Math.floor(Math.log(bytes) / Math.log(k))
  return `${(bytes / Math.pow(k, i)).toFixed(i === 0 ? 0 : 2)} ${sizes[i]}`
}

// 显示缓存统计
const showCacheStats = async (upstream: Upstream) => {
  try {
    const stats = await getUpstreamCacheStats(upstream.id)

    ElMessageBox.alert(
      `
        <div style="text-align: left;">
          <p><strong>上游名称:</strong> ${upstream.name}</p>
          <p><strong>缓存包数:</strong> ${stats.package_count}</p>
          <p><strong>占用空间:</strong> ${formatFileSize(stats.total_size)}</p>
          ${
            stats.package_count > 0
              ? `<p style="margin-top: 16px;"><strong>最近10个包:</strong></p>
                 <ul style="max-height: 200px; overflow-y: auto; padding-left: 20px;">
                   ${stats.packages.slice(0, 10).map(
                     (p: any) => `<li>${p.name}-${p.version} (${formatFileSize(p.tarball_size)})</li>`
                   ).join('')}
                 </ul>`
              : ''
          }
        </div>
      `,
      '缓存统计',
      {
        dangerouslyUseHTMLString: true,
        confirmButtonText: stats.package_count > 0 ? '清除缓存' : '关闭',
        cancelButtonText: '取消',
        showCancelButton: true,
        type: stats.package_count > 0 ? 'warning' : 'info',
      }
    ).then(() => {
      if (stats.package_count > 0) {
        handleClearCache(upstream)
      }
    }).catch(() => {
      // 用户点击取消
    })
  } catch (error: any) {
    ElMessage.error(error.response?.data?.error || '获取缓存统计失败')
  }
}

// 清除上游缓存
const handleClearCache = async (upstream: Upstream) => {
  try {
    await ElMessageBox.confirm(
      `确定要清除上游 "${upstream.name}" 的所有缓存包吗？此操作不可恢复。`,
      '清除缓存确认',
      {
        confirmButtonText: '确定清除',
        cancelButtonText: '取消',
        type: 'warning',
        dangerouslyUseHTMLString: true,
      }
    )

    const result = await clearUpstreamCache(upstream.id)
    ElMessage.success(
      `清除成功！删除了 ${result.deleted_count} 个包，释放了 ${formatFileSize(result.freed_space)} 空间`
    )
  } catch (error: any) {
    if (error !== 'cancel') {
      ElMessage.error(error.response?.data?.error || '清除缓存失败')
    }
  }
}

onMounted(() => {
  loadUpstreams()
})
</script>

<template>
  <div class="upstreams-page">
    <!-- 页面头部 -->
    <div class="page-header">
      <div class="header-left">
        <h2 class="page-title">上游管理</h2>
        <p class="page-description">
          配置上游包源，当本地没有包时会自动从上游拉取并缓存
        </p>
      </div>
      <div class="header-right">
        <el-button type="primary" :icon="Plus" @click="openCreateDialog">
          添加上游
        </el-button>
      </div>
    </div>

    <!-- 上游列表 -->
    <el-card v-loading="loading" class="upstreams-card">
      <el-table :data="upstreams" stripe>
        <el-table-column prop="name" label="名称" width="180">
          <template #default="{ row }">
            <div class="upstream-name">
              <el-icon><Connection /></el-icon>
              <span>{{ row.name }}</span>
            </div>
          </template>
        </el-table-column>

        <el-table-column prop="url" label="地址" min-width="300">
          <template #default="{ row }">
            <code class="upstream-url">{{ row.url }}</code>
          </template>
        </el-table-column>

        <el-table-column prop="cache_ttl" label="缓存时间" width="120" align="center">
          <template #default="{ row }">
            <el-tag size="small">{{ formatCacheTTL(row.cache_ttl) }}</el-tag>
          </template>
        </el-table-column>

        <el-table-column prop="enabled" label="状态" width="100" align="center">
          <template #default="{ row }">
            <el-switch
              :model-value="row.enabled"
              @change="handleToggleEnabled(row)"
              :loading="loading"
            />
          </template>
        </el-table-column>

        <el-table-column prop="last_sync_at" label="最后同步" width="180">
          <template #default="{ row }">
            <span v-if="row.last_sync_at" class="sync-time">
              {{ row.last_sync_at ? dayjs(row.last_sync_at).format('YYYY-MM-DD HH:mm:ss') : '-' }}
            </span>
            <span v-else class="sync-time empty">未同步</span>
          </template>
        </el-table-column>

        <el-table-column label="操作" width="320" align="center" fixed="right">
          <template #default="{ row }">
            <el-button
              size="small"
              :icon="Refresh"
              :loading="testing === row.id"
              @click="handleTest(row)"
            >
              测试
            </el-button>
            <el-button size="small" :icon="Edit" @click="openEditDialog(row)">
              编辑
            </el-button>
            <el-button
              size="small"
              type="warning"
              @click="showCacheStats(row)"
            >
              缓存
            </el-button>
            <el-button
              size="small"
              type="danger"
              :icon="Delete"
              @click="handleDelete(row)"
            >
              删除
            </el-button>
          </template>
        </el-table-column>
      </el-table>

      <div v-if="total > 0" class="pagination-wrapper">
        <el-pagination
          v-model:current-page="currentPage"
          v-model:page-size="pageSize"
          :total="total"
          :page-sizes="[10, 20, 50]"
          layout="total, sizes, prev, pager, next, jumper"
          background
          @current-change="loadUpstreams"
          @size-change="loadUpstreams"
        />
      </div>

      <el-empty v-if="!loading && upstreams.length === 0" description="暂无上游配置">
        <el-button type="primary" :icon="Plus" @click="openCreateDialog">
          添加第一个上游
        </el-button>
      </el-empty>
    </el-card>

    <!-- 创建/编辑对话框 -->
    <el-dialog
      v-model="dialogVisible"
      :title="dialogMode === 'create' ? '添加上游' : '编辑上游'"
      width="600px"
    >
      <el-form
        ref="formRef"
        :model="formData"
        :rules="formRules"
        label-width="100px"
      >
        <el-form-item label="上游名称" prop="name">
          <el-input
            v-model="formData.name"
            placeholder="例如: official"
            clearable
          />
        </el-form-item>

        <el-form-item label="上游地址" prop="url">
          <el-input
            v-model="formData.url"
            placeholder="https://pkg.cangjie-lang.cn/registry"
            clearable
          />
          <div class="form-tip">
            <el-icon><InfoFilled /></el-icon>
            <span>仓颉中央库地址: https://pkg.cangjie-lang.cn/registry</span>
          </div>
        </el-form-item>

        <el-form-item label="缓存时间" prop="cache_ttl">
          <el-input-number
            v-model="formData.cache_ttl"
            :min="0"
            :max="86400 * 30"
            :step="3600"
            controls-position="right"
          />
          <span class="unit-label">秒</span>
          <div class="form-tip">
            <el-icon><InfoFilled /></el-icon>
            <span>建议: 86400秒(24小时) = {{ Math.floor((formData.cache_ttl || 0) / 3600) }}小时</span>
          </div>
        </el-form-item>

        <el-form-item label="认证令牌" prop="auth_token">
          <el-input
            v-model="formData.auth_token"
            type="password"
            placeholder="可选：上游需要的认证令牌"
            show-password
            clearable
          />
        </el-form-item>

        <el-form-item label="启用状态">
          <el-switch v-model="formData.enabled" active-text="启用" />
        </el-form-item>
      </el-form>

      <template #footer>
        <el-button @click="dialogVisible = false">取消</el-button>
        <el-button type="primary" @click="submitForm">确定</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<style scoped>
.upstreams-page {
  padding: 20px;
}

.page-header {
  display: flex;
  justify-content: space-between;
  align-items: flex-start;
  margin-bottom: 20px;
}

.header-left {
  flex: 1;
}

.page-title {
  font-size: 24px;
  font-weight: 600;
  color: #303133;
  margin: 0 0 8px 0;
}

.page-description {
  font-size: 14px;
  color: #909399;
  margin: 0;
}

.upstreams-card {
  margin-bottom: 20px;
}

.upstream-name {
  display: flex;
  align-items: center;
  gap: 8px;
  font-weight: 500;
}

.upstream-url {
  font-family: 'Courier New', monospace;
  font-size: 13px;
  color: #606266;
  background: #f5f7fa;
  padding: 4px 8px;
  border-radius: 4px;
}

.sync-time {
  font-size: 13px;
  color: #606266;
}

.sync-time.empty {
  color: #c0c4cc;
}

.form-tip {
  display: flex;
  align-items: center;
  gap: 4px;
  margin-top: 4px;
  font-size: 12px;
  color: #909399;
}

.form-tip .el-icon {
  font-size: 14px;
}

.unit-label {
  margin-left: 8px;
  color: #909399;
  font-size: 14px;
}

.pagination-wrapper {
  margin-top: 20px;
  display: flex;
  justify-content: flex-end;
}

/* 响应式 */
@media (max-width: 768px) {
  .page-header {
    flex-direction: column;
    gap: 16px;
  }

  .header-right {
    width: 100%;
  }

  .header-right .el-button {
    width: 100%;
  }
}
</style>
