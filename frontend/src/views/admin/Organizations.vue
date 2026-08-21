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
  ElIcon,
  ElPagination,
} from 'element-plus'
import {
  Plus,
  Edit,
  Delete,
  Setting,
  InfoFilled,
} from '@element-plus/icons-vue'
import {
  getOrganizations,
  createOrganization,
  updateOrganization,
  deleteOrganization,
  type Organization,
  type CreateOrganizationRequest,
  type UpdateOrganizationRequest,
} from '../../api/admin'

const organizations = ref<Organization[]>([])
const loading = ref(false)
const currentPage = ref(1)
const pageSize = ref(20)
const total = ref(0)
const dialogVisible = ref(false)
const dialogMode = ref<'create' | 'edit'>('create')
const editingId = ref<number | null>(null)

const formData = ref<CreateOrganizationRequest & { id?: number }>({
  name: '',
  display_name: '',
  description: '',
})

const formRules = {
  name: [{ required: true, message: '请输入组织标识', trigger: 'blur' }],
  display_name: [{ required: true, message: '请输入组织名称', trigger: 'blur' }],
}

const formRef = ref()


const loadOrganizations = async () => {
  loading.value = true
  try {
    const res = await getOrganizations({ page: currentPage.value, pageSize: pageSize.value })
    organizations.value = res.data || []
    total.value = res.total
  } catch (error: any) {
    console.error('加载组织列表失败:', error)
    organizations.value = []
    ElMessage.error(error.response?.data?.error || '加载组织列表失败')
  } finally {
    loading.value = false
  }
}

const openCreateDialog = () => {
  dialogMode.value = 'create'
  editingId.value = null
  formData.value = {
    name: '',
    display_name: '',
    description: '',
  }
  dialogVisible.value = true
}

const openEditDialog = (org: Organization) => {
  dialogMode.value = 'edit'
  editingId.value = org.id
  formData.value = {
    id: org.id,
    name: org.name,
    display_name: org.display_name,
    description: org.description,
  }
  dialogVisible.value = true
}

const submitForm = async () => {
  try {
    await formRef.value.validate()

    if (dialogMode.value === 'create') {
      await createOrganization(formData.value)
      ElMessage.success('组织创建成功')
    } else {
      await updateOrganization(editingId.value!, formData.value)
      ElMessage.success('组织更新成功')
    }

    dialogVisible.value = false
    await loadOrganizations()
  } catch (error: any) {
    if (error.errors) {
      return
    }
    ElMessage.error(error.response?.data?.error || '操作失败')
  }
}

const handleDelete = async (org: Organization) => {
  try {
    await ElMessageBox.confirm(
      `确定要删除组织 "${org.display_name}" 吗？此操作不可恢复。`,
      '删除确认',
      {
        confirmButtonText: '确定',
        cancelButtonText: '取消',
        type: 'warning',
      }
    )

    await deleteOrganization(org.id)
    ElMessage.success('组织删除成功')
    await loadOrganizations()
  } catch (error: any) {
    if (error !== 'cancel') {
      ElMessage.error(error.response?.data?.error || '删除失败')
    }
  }
}

const handleToggleDefault = async (org: Organization) => {
  if (org.is_default) return

  try {
    await updateOrganization(org.id, { is_default: true })
    ElMessage.success('已设置为默认组织')
    await loadOrganizations()
  } catch (error: any) {
    ElMessage.error(error.response?.data?.error || '操作失败')
  }
}

onMounted(() => {
  loadOrganizations()
})
</script>

<template>
  <div class="organizations-page">
    <div class="page-header">
      <div class="header-left">
        <h2 class="page-title">组织管理</h2>
        <p class="page-description">
          管理组织信息。用户权限请通过"团队管理"配置。
        </p>
      </div>
      <div class="header-right">
        <el-button type="primary" :icon="Plus" @click="openCreateDialog">
          添加组织
        </el-button>
      </div>
    </div>

    <el-card v-loading="loading" class="organizations-card">
      <el-table :data="organizations" stripe>
        <el-table-column prop="name" label="标识" width="150">
          <template #default="{ row }">
            <div class="org-name">
              <el-icon><Setting /></el-icon>
              <span>{{ row.name }}</span>
            </div>
          </template>
        </el-table-column>

        <el-table-column prop="display_name" label="组织名称" width="180">
          <template #default="{ row }">
            <span class="org-display-name">{{ row.display_name }}</span>
          </template>
        </el-table-column>

        <el-table-column prop="description" label="描述" min-width="200">
          <template #default="{ row }">
            <span class="org-description">{{ row.description || '-' }}</span>
          </template>
        </el-table-column>

        <el-table-column prop="member_count" label="成员数" width="100" align="center">
          <template #default="{ row }">
            <el-tag size="small">{{ row.member_count }}</el-tag>
          </template>
        </el-table-column>

        <el-table-column prop="package_count" label="包数" width="100" align="center">
          <template #default="{ row }">
            <el-tag size="small" type="success">{{ row.package_count }}</el-tag>
          </template>
        </el-table-column>

        <el-table-column prop="is_default" label="默认" width="80" align="center">
          <template #default="{ row }">
            <el-switch
              :model-value="row.is_default"
              @change="handleToggleDefault(row)"
              :disabled="row.is_default"
            />
          </template>
        </el-table-column>

        <el-table-column label="操作" width="250" align="center" fixed="right">
          <template #default="{ row }">
            <el-button size="small" :icon="Edit" @click="openEditDialog(row)">
              编辑
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
          :page-sizes="[10, 20, 50, 100]"
          layout="total, sizes, prev, pager, next, jumper"
          background
          @current-change="loadOrganizations"
          @size-change="loadOrganizations"
        />
      </div>

      <el-empty v-if="!loading && organizations.length === 0" description="暂无组织">
        <el-button type="primary" :icon="Plus" @click="openCreateDialog">
          创建第一个组织
        </el-button>
      </el-empty>
    </el-card>

    <el-dialog
      v-model="dialogVisible"
      :title="dialogMode === 'create' ? '添加组织' : '编辑组织'"
      width="600px"
    >
      <el-form
        ref="formRef"
        :model="formData"
        :rules="formRules"
        label-width="100px"
      >
        <el-form-item label="组织标识" prop="name">
          <el-input
            v-model="formData.name"
            placeholder="例如: company"
            :disabled="dialogMode === 'edit'"
            clearable
          />
          <div class="form-tip">
            <el-icon><InfoFilled /></el-icon>
            <span>唯一标识，创建后不可修改</span>
          </div>
        </el-form-item>

        <el-form-item label="组织名称" prop="display_name">
          <el-input
            v-model="formData.display_name"
            placeholder="例如: XX公司"
            clearable
          />
        </el-form-item>

        <el-form-item label="描述">
          <el-input
            v-model="formData.description"
            type="textarea"
            :rows="3"
            placeholder="组织描述"
            clearable
          />
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
.organizations-page {
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

.organizations-card {
  margin-bottom: 20px;
}

.org-name {
  display: flex;
  align-items: center;
  gap: 8px;
  font-weight: 500;
  font-family: 'Courier New', monospace;
}

.org-display-name {
  font-weight: 500;
  color: #303133;
}

.org-description {
  color: #606266;
  font-size: 13px;
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

.pagination-wrapper {
  margin-top: 20px;
  display: flex;
  justify-content: flex-end;
}
</style>
