<script setup lang="ts">
import { ref, onMounted } from 'vue'
import {
  ElCard,
  ElTable,
  ElTableColumn,
  ElTag,
  ElButton,
  ElMessageBox,
  ElMessage,
  ElIcon,
  ElDialog,
  ElForm,
  ElFormItem,
  ElInput,
  ElEmpty,
  ElDescriptions,
  ElDescriptionsItem,
  ElSelect,
  ElOption,
  ElRow,
  ElCol,
  ElPagination,
} from 'element-plus'
import { Delete, Refresh, Document, Download, View, Search } from '@element-plus/icons-vue'
import { getAdminPackages, deletePackage, getPackageVersions, type Package } from '../../api/admin'
import { getOrganizations, type Organization } from '../../api/public'
import dayjs from 'dayjs'

const packages = ref<Package[]>([])
const loading = ref(false)
const total = ref(0)
const currentPage = ref(1)
const pageSize = ref(20)

const searchText = ref('')
const selectedOrg = ref('')
const selectedType = ref('')
const organizations = ref<Organization[]>([])

const deleteDialog = ref(false)
const deletingPackage = ref<Package | null>(null)
const deleteConfirmText = ref('')

const versionsDialog = ref(false)
const versionsLoading = ref(false)
const versionsPackage = ref<Package | null>(null)
const versions = ref<Package[]>([])

const loadOrganizations = async () => {
  try {
    const data = await getOrganizations()
    organizations.value = data
  } catch (error: any) {
    console.error('Failed to load organizations:', error)
  }
}

const loadPackages = async () => {
  loading.value = true
  try {
    const data = await getAdminPackages({
      page: currentPage.value,
      pageSize: pageSize.value,
      search: searchText.value,
      org: selectedOrg.value,
      artifactType: selectedType.value,
    })
    packages.value = data.data
    total.value = data.total
  } catch (error: any) {
    ElMessage.error(error.message || '加载包列表失败')
  } finally {
    loading.value = false
  }
}

const handleSearch = () => {
  currentPage.value = 1
  loadPackages()
}

const handleReset = () => {
  searchText.value = ''
  selectedOrg.value = ''
  selectedType.value = ''
  currentPage.value = 1
  loadPackages()
}

const loadVersions = async (pkg: Package) => {
  versionsLoading.value = true
  versionsPackage.value = pkg
  try {
    const data = await getPackageVersions(pkg.name, pkg.organization)
    versions.value = data
    versionsDialog.value = true
  } catch (error: any) {
    ElMessage.error(error.message || '加载版本列表失败')
  } finally {
    versionsLoading.value = false
  }
}

const handleDelete = (pkg: Package) => {
  deletingPackage.value = pkg
  deleteConfirmText.value = ''
  deleteDialog.value = true
}

const confirmDelete = async () => {
  if (!deletingPackage.value) return

  if (deleteConfirmText.value !== deletingPackage.value.name) {
    ElMessage.warning('请输入正确的包名以确认删除')
    return
  }

  try {
    await deletePackage(deletingPackage.value.id)
    ElMessage.success('删除成功')
    deleteDialog.value = false
    loadPackages()
  } catch (error: any) {
    ElMessage.error(error.message || '删除失败')
  }
}

const formatSize = (bytes: number) => {
  if (bytes < 1024) return bytes + ' B'
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(2) + ' KB'
  return (bytes / (1024 * 1024)).toFixed(2) + ' MB'
}

const formatDate = (date: string) => {
  return date ? dayjs(date).format('YYYY-MM-DD HH:mm:ss') : '-'
}

onMounted(() => {
  loadOrganizations()
  loadPackages()
})
</script>

<template>
  <div class="packages-container">
    <div class="page-header">
      <h1>
        <el-icon :size="28"><Document /></el-icon>
        包管理
      </h1>
      <el-button :icon="Refresh" @click="loadPackages">刷新</el-button>
    </div>

    <el-card shadow="hover">
      <!-- 搜索栏 -->
      <el-row :gutter="16" class="search-row">
        <el-col :span="7">
          <el-input
            v-model="searchText"
            placeholder="搜索包名或描述"
            :prefix-icon="Search"
            clearable
            @keyup.enter="handleSearch"
            @clear="handleSearch"
          />
        </el-col>
        <el-col :span="5">
          <el-select
            v-model="selectedOrg"
            placeholder="筛选组织"
            clearable
            filterable
            @change="handleSearch"
          >
            <el-option
              v-for="org in organizations"
              :key="org.name"
              :label="org.name || '默认组织'"
              :value="org.name"
            />
          </el-select>
        </el-col>
        <el-col :span="5">
          <el-select
            v-model="selectedType"
            placeholder="筛选类型"
            clearable
            @change="handleSearch"
          >
            <el-option label="源码" value="src" />
            <el-option label="二进制" value="bin" />
            <el-option label="可执行" value="executable" />
          </el-select>
        </el-col>
        <el-col :span="7">
          <el-button type="primary" :icon="Search" @click="handleSearch">搜索</el-button>
          <el-button @click="handleReset">重置</el-button>
        </el-col>
      </el-row>

      <el-empty v-if="!loading && packages.length === 0" description="暂无数据" />

      <el-table v-else :data="packages" v-loading="loading" stripe>
        <el-table-column prop="id" label="ID" width="70" />
        <el-table-column prop="name" label="包名" width="280" show-overflow-tooltip />
        <el-table-column prop="version" label="最新版本" width="110">
          <template #default="{ row }">
            <el-tag type="success" size="small">{{ row.version }}</el-tag>
          </template>
        </el-table-column>
        <el-table-column prop="organization" label="组织" width="100" />
        <el-table-column label="类型" width="200" align="center">
          <template #default="{ row }">
            <el-tag size="small" :type="row.artifact_type === 'src' ? 'info' : 'warning'">
              {{ row.artifact_type === 'src' ? '源码' : '二进制' }}
            </el-tag>
            <el-tag v-if="row.executable" size="small" type="danger" style="margin-left: 4px">可执行</el-tag>
          </template>
        </el-table-column>
        <el-table-column prop="description" label="描述" min-width="200" show-overflow-tooltip />
        <el-table-column prop="tarball_size" label="大小" width="100" align="right">
          <template #default="{ row }">
            {{ formatSize(row.tarball_size) }}
          </template>
        </el-table-column>
        <el-table-column prop="created_at" label="创建时间" width="170">
          <template #default="{ row }">
            {{ formatDate(row.created_at) }}
          </template>
        </el-table-column>
        <el-table-column label="操作" width="150" fixed="right">
          <template #default="{ row }">
            <el-button
              type="primary"
              size="small"
              :icon="View"
              link
              @click="loadVersions(row)"
            >
              版本
            </el-button>
            <el-button
              type="danger"
              size="small"
              :icon="Delete"
              link
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
          @current-change="loadPackages"
          @size-change="loadPackages"
        />
      </div>
    </el-card>

    <!-- 版本列表对话框 -->
    <el-dialog
      v-model="versionsDialog"
      :title="`${versionsPackage?.name || ''} 的版本列表`"
      width="800px"
    >
      <el-table :data="versions" v-loading="versionsLoading" stripe max-height="400">
        <el-table-column prop="version" label="版本" width="120">
          <template #default="{ row }">
            <el-tag type="success" size="small">{{ row.version }}</el-tag>
          </template>
        </el-table-column>
        <el-table-column label="类型" width="120" align="center">
          <template #default="{ row }">
            <el-tag size="small" :type="row.artifact_type === 'src' ? 'info' : 'warning'">
              {{ row.artifact_type === 'src' ? '源码' : '二进制' }}
            </el-tag>
            <el-tag v-if="row.executable" size="small" type="danger" style="margin-left: 4px">可执行</el-tag>
          </template>
        </el-table-column>
        <el-table-column prop="tarball_size" label="大小" width="100" align="right">
          <template #default="{ row }">
            {{ formatSize(row.tarball_size) }}
          </template>
        </el-table-column>
        <el-table-column prop="created_at" label="发布时间" width="180">
          <template #default="{ row }">
            {{ formatDate(row.created_at) }}
          </template>
        </el-table-column>
        <el-table-column prop="deleted_at" label="状态" width="80">
          <template #default="{ row }">
            <el-tag v-if="row.deleted_at" type="danger" size="small">已删除</el-tag>
            <el-tag v-else type="success" size="small">正常</el-tag>
          </template>
        </el-table-column>
      </el-table>
      <template #footer>
        <el-button @click="versionsDialog = false">关闭</el-button>
      </template>
    </el-dialog>

    <!-- 删除确认对话框 -->
    <el-dialog
      v-model="deleteDialog"
      title="确认删除"
      width="500px"
      :close-on-click-modal="false"
    >
      <el-alert
        type="warning"
        title="警告：此操作不可恢复"
        description="删除包后将无法恢复，请谨慎操作"
        :closable="false"
        show-icon
        style="margin-bottom: 20px"
      />

      <div v-if="deletingPackage">
        <p>您即将删除以下包：</p>
        <el-descriptions :column="2" border>
          <el-descriptions-item label="包名">{{ deletingPackage.name }}</el-descriptions-item>
          <el-descriptions-item label="版本">{{ deletingPackage.version }}</el-descriptions-item>
          <el-descriptions-item label="组织">{{ deletingPackage.organization || '默认' }}</el-descriptions-item>
          <el-descriptions-item label="类型">
            {{ deletingPackage.artifact_type === 'src' ? '源码' : '二进制' }}
            <span v-if="deletingPackage.executable">（可执行）</span>
          </el-descriptions-item>
        </el-descriptions>

        <el-form style="margin-top: 20px">
          <el-form-item label="确认删除">
            <el-alert
              type="info"
              :closable="false"
              style="margin-bottom: 10px"
            >
              请输入包名 <code>{{ deletingPackage.name }}</code> 以确认删除
            </el-alert>
            <el-input
              v-model="deleteConfirmText"
              :placeholder="`请输入 ${deletingPackage.name}`"
            />
          </el-form-item>
        </el-form>
      </div>

      <template #footer>
        <el-button @click="deleteDialog = false">取消</el-button>
        <el-button
          type="danger"
          @click="confirmDelete"
          :disabled="!deletingPackage || deleteConfirmText !== deletingPackage.name"
        >
          确认删除
        </el-button>
      </template>
    </el-dialog>
  </div>
</template>

<style scoped>
.packages-container {
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

.search-row {
  margin-bottom: 20px;
}

code {
  background: #f5f7fa;
  padding: 2px 6px;
  border-radius: 3px;
  font-family: 'Courier New', monospace;
  color: #e6a23c;
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
}

.pagination-wrapper {
  margin-top: 20px;
  display: flex;
  justify-content: flex-end;
}
</style>
