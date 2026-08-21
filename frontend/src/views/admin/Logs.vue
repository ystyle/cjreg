<script setup lang="ts">
import { ref, onMounted } from 'vue'
import {
  ElCard,
  ElTable,
  ElTableColumn,
  ElTag,
  ElButton,
  ElIcon,
  ElInput,
  ElSelect,
  ElRow,
  ElCol,
  ElTabs,
  ElTabPane,
  ElDialog,
  ElForm,
  ElFormItem,
  ElMessage,
  ElPopconfirm,
  ElPagination,
} from 'element-plus'
import { Refresh, Document, Delete, Brush } from '@element-plus/icons-vue'
import {
  getPublishLogs,
  getAdminLogs,
  cleanLogs,
  type PublishLog,
  type AdminLog,
} from '../../api/admin'
import dayjs from 'dayjs'

const activeTab = ref('publish')

// 发布日志
const publishLogs = ref<PublishLog[]>([])
const publishLoading = ref(false)
const publishTotal = ref(0)
const publishPage = ref(1)
const publishPageSize = ref(20)

// 管理员操作日志
const adminLogs = ref<AdminLog[]>([])
const adminLoading = ref(false)
const adminTotal = ref(0)
const adminPage = ref(1)
const adminPageSize = ref(20)

// 搜索筛选
const selectedStatus = ref('')
const selectedAction = ref('')

// 清理日志
const cleanDialog = ref(false)
const cleanLoading = ref(false)
const cleanForm = ref({
  logType: 'publish' as 'publish' | 'admin',
  days: 90,
})

const openCleanDialog = () => {
  cleanForm.value.logType = activeTab.value as 'publish' | 'admin'
  cleanDialog.value = true
}

const handleClean = async () => {
  cleanLoading.value = true
  try {
    const data = await cleanLogs(cleanForm.value)
    ElMessage.success(data.message || '清理成功')
    cleanDialog.value = false

    // 刷新日志列表
    if (activeTab.value === 'publish') {
      loadPublishLogs()
    } else {
      loadAdminLogs()
    }
  } catch (error: any) {
    ElMessage.error(error.message || '清理失败')
  } finally {
    cleanLoading.value = false
  }
}

const loadPublishLogs = async () => {
  publishLoading.value = true
  try {
    const data = await getPublishLogs({
      page: publishPage.value,
      pageSize: publishPageSize.value,
      status: selectedStatus.value,
    })
    publishLogs.value = data.data || []
    publishTotal.value = data.total
  } catch (error: any) {
    ElMessage.error(error.message || '加载发布日志失败')
  } finally {
    publishLoading.value = false
  }
}

const loadAdminLogs = async () => {
  adminLoading.value = true
  try {
    const data = await getAdminLogs({
      page: adminPage.value,
      pageSize: adminPageSize.value,
      action: selectedAction.value,
    })
    adminLogs.value = data.data || []
    adminTotal.value = data.total
  } catch (error: any) {
    ElMessage.error(error.message || '加载操作日志失败')
  } finally {
    adminLoading.value = false
  }
}

const handleTabChange = () => {
  if (activeTab.value === 'publish') {
    loadPublishLogs()
  } else {
    loadAdminLogs()
  }
}

const handleSearch = () => {
  if (activeTab.value === 'publish') {
    publishPage.value = 1
    loadPublishLogs()
  } else {
    adminPage.value = 1
    loadAdminLogs()
  }
}

const handleRefresh = () => {
  if (activeTab.value === 'publish') {
    loadPublishLogs()
  } else {
    loadAdminLogs()
  }
}

const formatDate = (date: string) => {
  return date ? dayjs(date).format('YYYY-MM-DD HH:mm:ss') : '-'
}

const getStatusType = (status: string) => {
  const map: Record<string, string> = {
    success: 'success',
    failed: 'danger',
    pending: 'warning',
  }
  return map[status] || 'info'
}

const getActionType = (action: string) => {
  const map: Record<string, string> = {
    delete_package: 'danger',
    create_user: 'success',
    reset_token: 'warning',
    restore_package: 'info',
    admin_login: 'primary',
  }
  return map[action] || ''
}

const formatAction = (action: string) => {
  const map: Record<string, string> = {
    delete_package: '删除包',
    create_user: '创建用户',
    reset_token: '重置Token',
    restore_package: '恢复包',
    hard_delete_package: '永久删除',
    toggle_user: '切换用户状态',
    admin_login: '管理员登录',
  }
  return map[action] || action
}

onMounted(() => {
  loadPublishLogs()
})
</script>

<template>
  <div class="logs-container">
    <div class="page-header">
      <h1>
        <el-icon :size="28"><Document /></el-icon>
        操作日志
      </h1>
      <div class="header-actions">
        <el-button type="danger" :icon="Brush" @click="openCleanDialog">
          清理日志
        </el-button>
        <el-button :icon="Refresh" @click="handleRefresh">刷新</el-button>
      </div>
    </div>

    <!-- 日志表格 -->
    <el-card shadow="hover">
      <el-tabs v-model="activeTab" @tab-change="handleTabChange">
        <!-- 发布日志 -->
        <el-tab-pane label="发布日志" name="publish">
          <el-row :gutter="20" style="margin-bottom: 16px">
            <el-col :xs="24" :sm="12">
              <el-select
                v-model="selectedStatus"
                placeholder="筛选发布状态"
                clearable
                style="width: 100%"
                @change="handleSearch"
              >
                <el-option label="成功" value="success" />
                <el-option label="失败" value="failed" />
              </el-select>
            </el-col>
          </el-row>
          <div v-if="publishTotal > 0" class="pagination-wrapper">
            <el-pagination
              v-model:current-page="publishPage"
              v-model:page-size="publishPageSize"
              :total="publishTotal"
              :page-sizes="[10, 20, 50, 100]"
              layout="total, sizes, prev, pager, next, jumper"
              background
              @current-change="loadPublishLogs"
              @size-change="loadPublishLogs"
            />
          </div>
            <el-table
              :data="publishLogs"
              v-loading="publishLoading"
              stripe
              style="width: 100%"
            >
              <el-table-column prop="id" label="ID" width="80" />
              <el-table-column prop="package_name" label="包名" min-width="150" />
              <el-table-column prop="version" label="版本" width="100" />
              <el-table-column prop="organization" label="组织" width="120" />
              <el-table-column prop="status" label="状态" width="100">
                <template #default="{ row }">
                  <el-tag :type="getStatusType(row.status)" size="small">
                    {{ row.status }}
                  </el-tag>
                </template>
              </el-table-column>
              <el-table-column prop="error" label="错误信息" min-width="200" show-overflow-tooltip>
                <template #default="{ row }">
                  <span v-if="row.error" style="color: #f56c6c">{{ row.error }}</span>
                  <span v-else style="color: #909399">-</span>
                </template>
              </el-table-column>
              <el-table-column prop="created_at" label="时间" width="180">
                <template #default="{ row }">
                  {{ formatDate(row.created_at) }}
                </template>
              </el-table-column>
            </el-table>
          </el-tab-pane>

          <!-- 管理员操作日志 -->
          <el-tab-pane label="管理员操作日志" name="admin">
            <el-row :gutter="20" style="margin-bottom: 16px">
              <el-col :xs="24" :sm="12">
                <el-select
                  v-model="selectedAction"
                  placeholder="筛选操作类型"
                  clearable
                  style="width: 100%"
                  @change="handleSearch"
                >
                  <el-option label="删除包" value="delete_package" />
                  <el-option label="创建用户" value="create_user" />
                  <el-option label="重置Token" value="reset_token" />
                  <el-option label="恢复包" value="restore_package" />
                  <el-option label="管理员登录" value="admin_login" />
                </el-select>
              </el-col>
            </el-row>
            <div v-if="adminTotal > 0" class="pagination-wrapper">
              <el-pagination
                v-model:current-page="adminPage"
                v-model:page-size="adminPageSize"
                :total="adminTotal"
                :page-sizes="[10, 20, 50, 100]"
                layout="total, sizes, prev, pager, next, jumper"
                background
                @current-change="loadAdminLogs"
                @size-change="loadAdminLogs"
              />
            </div>
            <el-table
              :data="adminLogs"
              v-loading="adminLoading"
              stripe
              style="width: 100%"
            >
              <el-table-column prop="id" label="ID" width="80" />
              <el-table-column prop="action" label="操作" width="150">
                <template #default="{ row }">
                  <el-tag v-if="getActionType(row.action)" :type="getActionType(row.action)" size="small">
                    {{ formatAction(row.action) }}
                  </el-tag>
                  <span v-else>{{ row.action }}</span>
                </template>
              </el-table-column>
              <el-table-column prop="target" label="目标对象" min-width="150" show-overflow-tooltip />
              <el-table-column prop="created_at" label="时间" width="180">
                <template #default="{ row }">
                  {{ formatDate(row.created_at) }}
                </template>
              </el-table-column>
            </el-table>
          </el-tab-pane>
        </el-tabs>
    </el-card>

    <!-- 清理日志对话框 -->
    <el-dialog
      v-model="cleanDialog"
      title="清理日志"
      width="500px"
      :close-on-click-modal="false"
    >
      <el-alert
        type="warning"
        :closable="false"
        show-icon
        style="margin-bottom: 20px"
      >
        此操作将物理删除日志记录，删除后无法恢复，请谨慎操作！
      </el-alert>

      <el-form :model="cleanForm" label-width="100px">
        <el-form-item label="日志类型">
          <el-select v-model="cleanForm.logType" style="width: 100%">
            <el-option label="发布日志" value="publish" />
            <el-option label="管理员操作日志" value="admin" />
          </el-select>
        </el-form-item>
        <el-form-item label="时间范围">
          <el-select v-model="cleanForm.days" style="width: 100%">
            <el-option label="超过3个月" :value="90" />
            <el-option label="超过半年" :value="180" />
            <el-option label="超过1年" :value="365" />
          </el-select>
        </el-form-item>
      </el-form>

      <el-alert type="info" :closable="false" style="margin-top: 15px">
        将删除{{ cleanForm.days === 90 ? '3个月' : cleanForm.days === 180 ? '半年' : '1年' }}前的{{
          cleanForm.logType === 'publish' ? '发布日志' : '管理员操作日志'
        }}
      </el-alert>

      <template #footer>
        <el-button @click="cleanDialog = false">取消</el-button>
        <el-popconfirm
          title="确定要清理日志吗？此操作不可恢复！"
          confirm-button-text="确定"
          cancel-button-text="取消"
          @confirm="handleClean"
        >
          <template #reference>
            <el-button type="danger" :loading="cleanLoading">确定清理</el-button>
          </template>
        </el-popconfirm>
      </template>
    </el-dialog>
  </div>
</template>

<style scoped>
.logs-container {
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

.header-actions {
  display: flex;
  gap: 10px;
}

.pagination-wrapper {
  margin-top: 20px;
  display: flex;
  justify-content: flex-end;
}
</style>
