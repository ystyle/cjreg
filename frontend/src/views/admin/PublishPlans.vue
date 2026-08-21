<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { useRouter } from 'vue-router'
import { ElButton, ElTable, ElTableColumn, ElTag, ElCard, ElEmpty, ElMessage, ElMessageBox, ElPagination } from 'element-plus'
import { Plus, View, Delete } from '@element-plus/icons-vue'
import { getPublishPlans, deletePublishPlan, type PublishPlan } from '../../api/publish_plan'
import dayjs from 'dayjs'

const router = useRouter()

const plans = ref<PublishPlan[]>([])
const loading = ref(false)
const currentPage = ref(1)
const pageSize = ref(20)
const total = ref(0)

const fmt = (d: string) => d ? dayjs(d).format('YYYY-MM-DD HH:mm:ss') : '-'

const load = async () => {
  loading.value = true
  try {
    const res = await getPublishPlans({ page: currentPage.value, pageSize: pageSize.value })
    plans.value = res.data || []
    total.value = res.total
  } catch {
    plans.value = []
  } finally {
    loading.value = false
  }
}

const statusTag = (s: string) => {
  switch (s) {
    case 'pending': return ''
    case 'running': return 'primary'
    case 'completed': return 'success'
    case 'failed': return 'danger'
    case 'paused': return 'warning'
    default: return ''
  }
}

const statusLabel = (s: string) => {
  switch (s) {
    case 'pending': return '等待中'
    case 'running': return '运行中'
    case 'completed': return '已完成'
    case 'failed': return '失败'
    case 'paused': return '已暂停'
    default: return s
  }
}

const handleDelete = async (plan: PublishPlan) => {
  try {
    await ElMessageBox.confirm(`确定删除计划 "${plan.name}"？`, '确认删除')
    await deletePublishPlan(plan.id)
    ElMessage.success('已删除')
    await load()
  } catch (e: any) {
    if (e !== 'cancel') ElMessage.error(e.message || '删除失败')
  }
}

onMounted(load)
</script>

<template>
  <div class="page">
    <div class="page-header">
      <div class="header-left">
        <h2 class="page-title">发布计划</h2>
        <p class="page-description">批量发布包到目标上游仓库</p>
      </div>
      <div class="header-right">
        <el-button type="primary" :icon="Plus" @click="router.push('/admin/publish-plans/create')">
          新建计划
        </el-button>
      </div>
    </div>

    <el-card v-loading="loading">
      <el-table :data="plans" stripe>
        <el-table-column prop="name" label="名称" min-width="160" />
        <el-table-column prop="target_upstream" label="目标上游" width="120" />
        <el-table-column prop="total_count" label="包数量" width="80" align="center" />
        <el-table-column label="状态" width="100" align="center">
          <template #default="{ row }">
            <el-tag :type="statusTag(row.status)" size="small">{{ statusLabel(row.status) }}</el-tag>
          </template>
        </el-table-column>
        <el-table-column label="创建时间" width="180">
          <template #default="{ row }">{{ fmt(row.created_at) }}</template>
        </el-table-column>
        <el-table-column label="操作" width="240" align="center" fixed="right">
          <template #default="{ row }">
            <el-button size="small" :icon="View" @click="router.push(`/admin/publish-plans/${row.id}`)">查看</el-button>
            <el-button size="small" :icon="Delete" type="danger" @click="handleDelete(row)">删除</el-button>
          </template>
        </el-table-column>
      </el-table>
      <div v-if="total > 0" class="pagination-wrap">
        <el-pagination
          v-model:current-page="currentPage"
          v-model:page-size="pageSize"
          :total="total"
          :page-sizes="[10, 20, 50]"
          layout="total, sizes, prev, pager, next"
          @current-change="load"
          @size-change="load"
        />
      </div>
      <el-empty v-if="!loading && plans.length === 0" description="暂无发布计划">
        <el-button type="primary" :icon="Plus" @click="router.push('/admin/publish-plans/create')">创建第一个计划</el-button>
      </el-empty>
    </el-card>
  </div>
</template>

<style scoped>
.page { padding: 20px; }
.page-header { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 20px; }
.page-title { font-size: 24px; font-weight: 600; color: #303133; margin: 0 0 8px 0; }
.page-description { font-size: 14px; color: #909399; margin: 0; }
.pagination-wrap { display: flex; justify-content: center; padding: 16px 0; }
</style>
