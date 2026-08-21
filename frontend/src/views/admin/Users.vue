<script setup lang="ts">
import { ref, onMounted } from 'vue'
import {
  ElCard,
  ElTable,
  ElTableColumn,
  ElButton,
  ElDialog,
  ElForm,
  ElFormItem,
  ElInput,
  ElMessage,
  ElIcon,
  ElTag,
  ElSwitch,
  ElEmpty,
  ElPopconfirm,
  ElPagination,
} from 'element-plus'
import { User, Refresh, Plus, Key, CopyDocument, Delete } from '@element-plus/icons-vue'
import {
  getUsers,
  createUser,
  resetUserToken,
  toggleUser,
  deleteUser,
  getOrganizations,
  type User as UserType,
  type Organization,
} from '../../api/admin'
import dayjs from 'dayjs'

const users = ref<UserType[]>([])
const loading = ref(false)
const currentPage = ref(1)
const pageSize = ref(20)
const total = ref(0)

const organizations = ref<Organization[]>([])
const organizationsLoading = ref(false)

const createDialog = ref(false)
const createForm = ref({
  username: '',
  email: '',
  organization_id: undefined as number | undefined,
})

const tokenDialog = ref(false)
const tokenUser = ref<UserType | null>(null)
const newToken = ref('')

const loadUsers = async () => {
  loading.value = true
  try {
    const res = await getUsers({ page: currentPage.value, pageSize: pageSize.value })
    users.value = res.data
    total.value = res.total
  } catch (error: any) {
    ElMessage.error(error.message || '加载用户列表失败')
  } finally {
    loading.value = false
  }
}

const openCreateDialog = async () => {
  organizationsLoading.value = true
  try {
    const res = await getOrganizations()
    organizations.value = res.data || []
  } catch (error: any) {
    console.error('加载组织列表失败:', error)
  } finally {
    organizationsLoading.value = false
  }
  createDialog.value = true
}

const handleCreate = async () => {
  if (!createForm.value.username || !createForm.value.email) {
    ElMessage.warning('请填写完整信息')
    return
  }

  try {
    const data = await createUser(createForm.value)
    ElMessage.success('用户创建成功')
    createDialog.value = false

    // 显示 token
    newToken.value = data.token
    tokenUser.value = data
    tokenDialog.value = true

    createForm.value = { username: '', email: '', organization_id: undefined }
    loadUsers()
  } catch (error: any) {
    ElMessage.error(error.message || '创建用户失败')
  }
}

const handleResetToken = async (user: UserType) => {
  try {
    const data = await resetUserToken(user.id)
    ElMessage.success('Token 重置成功')

    tokenUser.value = user
    newToken.value = data.token
    tokenDialog.value = true

    loadUsers()
  } catch (error: any) {
    ElMessage.error(error.message || '重置 Token 失败')
  }
}

const handleToggle = async (user: UserType) => {
  try {
    await toggleUser(user.id)
    ElMessage.success('用户状态更新成功')
    loadUsers()
  } catch (error: any) {
    ElMessage.error(error.message || '更新用户状态失败')
  }
}

const handleDelete = async (user: UserType) => {
  try {
    await deleteUser(user.id)
    ElMessage.success('用户删除成功')
    loadUsers()
  } catch (error: any) {
    ElMessage.error(error.message || '删除用户失败')
  }
}

const copyToken = async () => {
  try {
    await navigator.clipboard.writeText(newToken.value)
    ElMessage.success('Token 已复制到剪贴板')
  } catch {
    ElMessage.error('复制失败')
  }
}

const copyRowToken = async (user: UserType) => {
  if (!user.token || user.token === '') {
    ElMessage.warning('该用户 Token 为空，请先重置 Token')
    return
  }
  try {
    await navigator.clipboard.writeText(user.token)
    ElMessage.success('Token 已复制到剪贴板')
  } catch {
    ElMessage.error('复制失败')
  }
}

const formatDate = (date: string) => {
  return date ? dayjs(date).format('YYYY-MM-DD HH:mm:ss') : '-'
}

const maskToken = (token: string) => {
  return token
}

onMounted(() => {
  loadUsers()
})
</script>

<template>
  <div class="users-container">
    <div class="page-header">
      <h1>
        <el-icon :size="28"><User /></el-icon>
        用户管理
      </h1>
      <div class="header-actions">
        <el-button type="primary" :icon="Plus" @click="openCreateDialog">
          创建用户
        </el-button>
        <el-button :icon="Refresh" @click="loadUsers">刷新</el-button>
      </div>
    </div>

    <el-card shadow="hover">
      <el-empty v-if="!loading && users.length === 0" description="暂无数据" />

      <el-table v-else :data="users" v-loading="loading" stripe>
        <el-table-column prop="id" label="ID" width="70" />
        <el-table-column prop="username" label="用户名" width="150" />
        <el-table-column prop="email" label="邮箱" show-overflow-tooltip />
        <el-table-column label="Token" width="100" align="center">
          <template #default="{ row }">
            <el-button
              type="primary"
              size="small"
              :icon="CopyDocument"
              link
              @click="copyRowToken(row)"
            >
              复制
            </el-button>
          </template>
        </el-table-column>
        <el-table-column prop="is_active" label="状态" align="center">
          <template #default="{ row }">
            <el-switch
              :model-value="row.is_active"
              @change="handleToggle(row)"
            />
          </template>
        </el-table-column>
        <el-table-column prop="created_at" label="创建时间" width="170">
          <template #default="{ row }">
            {{ formatDate(row.created_at) }}
          </template>
        </el-table-column>
        <el-table-column label="操作" width="220" fixed="right">
          <template #default="{ row }">
            <el-button
              type="warning"
              size="small"
              :icon="Key"
              @click="handleResetToken(row)"
            >
              重置 Token
            </el-button>
            <el-popconfirm
              title="确定要删除此用户吗？"
              confirm-button-text="确定"
              cancel-button-text="取消"
              @confirm="handleDelete(row)"
            >
              <template #reference>
                <el-button
                  type="danger"
                  size="small"
                  :icon="Delete"
                >
                  删除
                </el-button>
              </template>
            </el-popconfirm>
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
          @current-change="loadUsers"
          @size-change="loadUsers"
        />
      </div>
    </el-card>

    <!-- 创建用户对话框 -->
    <el-dialog
      v-model="createDialog"
      title="创建用户"
      width="500px"
      :close-on-click-modal="false"
    >
      <el-form :model="createForm" label-width="100px">
        <el-form-item label="用户名" required>
          <el-input
            v-model="createForm.username"
            placeholder="请输入用户名"
          />
        </el-form-item>
        <el-form-item label="邮箱" required>
          <el-input
            v-model="createForm.email"
            type="email"
            placeholder="请输入邮箱"
          />
        </el-form-item>
        <el-form-item label="所属组织">
          <el-select
            v-model="createForm.organization_id"
            placeholder="请选择组织（可选）"
            clearable
            style="width: 100%"
            :loading="organizationsLoading"
          >
            <el-option
              v-for="org in organizations"
              :key="org.id"
              :label="org.display_name || org.name"
              :value="org.id"
            >
              <span>{{ org.display_name || org.name }}</span>
              <span v-if="org.is_default" style="color: #8492a6; font-size: 12px; margin-left: 8px">
                (默认)
              </span>
            </el-option>
          </el-select>
        </el-form-item>
      </el-form>

      <template #footer>
        <el-button @click="createDialog = false">取消</el-button>
        <el-button type="primary" @click="handleCreate">创建</el-button>
      </template>
    </el-dialog>

    <!-- Token 显示对话框 -->
    <el-dialog
      v-model="tokenDialog"
      title="用户 Token"
      width="600px"
      :close-on-click-modal="false"
    >
      <el-alert
        type="success"
        :closable="false"
        show-icon
        style="margin-bottom: 20px"
      >
        <template #title>
          {{ tokenUser ? `用户 ${tokenUser.username} 的 Token` : '新用户 Token' }}
        </template>
      </el-alert>

      <el-form label-width="80px">
        <el-form-item label="Token">
          <el-input
            v-model="newToken"
            readonly
            type="textarea"
            :rows="3"
          />
        </el-form-item>
      </el-form>

      <el-alert
        type="warning"
        :closable="false"
        style="margin-top: 20px"
      >
        请妥善保管此 Token，它将用于用户访问仓库。关闭此对话框后，您将无法再次查看完整的 Token。
      </el-alert>

      <template #footer>
        <el-button type="primary" :icon="CopyDocument" @click="copyToken">
          复制 Token
        </el-button>
        <el-button @click="tokenDialog = false">关闭</el-button>
      </template>
    </el-dialog>
  </div>
</template>

<style scoped>
.users-container {
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

@media (max-width: 768px) {
  .page-header {
    flex-direction: column;
    gap: 15px;
    align-items: flex-start;
  }

  .page-header h1 {
    font-size: 22px;
  }

  .header-actions {
    width: 100%;
  }

  .header-actions button {
    flex: 1;
  }
}

.pagination-wrapper {
  margin-top: 20px;
  display: flex;
  justify-content: flex-end;
}
</style>
