<script setup lang="ts">
import { ref, onMounted, onUnmounted } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { ElButton, ElCard, ElTag, ElTable, ElTableColumn, ElMessage, ElMessageBox, ElProgress } from 'element-plus'
import { ArrowLeft, VideoPause, VideoPlay, Delete } from '@element-plus/icons-vue'
import { getPublishPlan, startPublishPlan, pausePublishPlan, resumePublishPlan, deletePublishPlan, type PublishPlan, type PublishPlanItem } from '../../api/publish_plan'
import dayjs from 'dayjs'
import { fetchEventSource } from '@microsoft/fetch-event-source'

const route = useRoute()
const router = useRouter()
const planId = Number(route.params.id)

const plan = ref<PublishPlan | null>(null)
const items = ref<PublishPlanItem[]>([])
const logs = ref<string[]>([])
const loading = ref(true)

const statusTag = (s: string) => {
  switch (s) {
    case 'pending': return ''; case 'publishing': return 'primary'
    case 'waiting_index': return 'warning'; case 'completed': return 'success'
    case 'failed': return 'danger'; default: return ''
  }
}
const statusLabel = (s: string) => {
  switch (s) {
    case 'pending': return '等待'; case 'publishing': return '发布中'
    case 'waiting_index': return '等待索引'; case 'completed': return '✅ 完成'
    case 'failed': return '❌ 失败'; default: return s
  }
}

let sseCtrl: AbortController | null = null
let pollTimer: ReturnType<typeof setInterval>

const connectSSE = () => {
  if (sseCtrl) sseCtrl.abort()
  const token = localStorage.getItem('admin_token')
  if (!token) return

  // 兜底轮询：每 5 秒刷新一次
  if (!pollTimer) {
    pollTimer = setInterval(async () => {
      if (plan.value?.status === 'running' || plan.value?.status === 'paused') {
        try { const res = await getPublishPlan(planId); plan.value = res.plan; items.value = res.items || [] } catch {}
      }
    }, 5000)
  }

  sseCtrl = new AbortController()
  fetchEventSource(`/api/admin/publish-plans/${planId}/events`, {
    method: 'GET',
    headers: { 'Authorization': `Bearer ${token}` },
    signal: sseCtrl.signal,
    onopen: async () => {},
    onmessage: (evt) => {
      try {
        const data = JSON.parse(evt.data)
        if (data.type === 'status') {
          if (plan.value) {
            plan.value.status = data.payload
            if (data.payload === 'completed' || data.payload === 'failed') {
              clearInterval(pollTimer)
              pollTimer = null
              sseCtrl?.abort()
              load()
            }
          }
        }
      } catch {}
    },
    onerror: () => {
      if (plan.value && (plan.value.status === 'running' || plan.value.status === 'paused')) {
        return 3000
      }
      clearInterval(pollTimer)
      pollTimer = null
      sseCtrl?.abort()
    },
  })
}

const load = async () => {
  loading.value = true
  try {
    const res = await getPublishPlan(planId)
    plan.value = res.plan
    items.value = res.items || []
  } catch {
    ElMessage.error('加载失败')
  } finally {
    loading.value = false
  }
}

const handleStart = async () => {
  try {
    await startPublishPlan(planId)
    ElMessage.success('已开始')
    connectSSE()
    await load()
  } catch (e: any) { ElMessage.error(e.message) }
}

const handlePause = async () => {
  try {
    await pausePublishPlan(planId)
    ElMessage.success('已暂停')
    if (plan.value) plan.value.status = 'paused'
  } catch (e: any) { ElMessage.error(e.message) }
}

const handleResume = async () => {
  try {
    await resumePublishPlan(planId)
    ElMessage.success('已恢复')
    connectSSE()
    await load()
  } catch (e: any) { ElMessage.error(e.message) }
}

const handleDelete = async () => {
  try {
    await ElMessageBox.confirm('确定删除此计划？', '确认删除')
    await deletePublishPlan(planId)
    ElMessage.success('已删除')
    router.push('/admin/publish-plans')
  } catch (e: any) {
    if (e !== 'cancel') ElMessage.error(e.message)
  }
}

const isRunning = () => plan.value?.status === 'running'

onMounted(() => {
  load().then(() => {
    if (isRunning()) connectSSE()
  })
})

onUnmounted(() => {
  if (sseCtrl) sseCtrl.abort()
  if (pollTimer) clearInterval(pollTimer)
})
</script>

<template>
  <div class="page">
    <div class="page-header">
      <div class="header-left">
        <el-button text :icon="ArrowLeft" @click="router.push('/admin/publish-plans')">返回列表</el-button>
        <h2 class="page-title">{{ plan?.name || '加载中...' }}</h2>
      </div>
      <div class="header-right">
        <el-button v-if="plan && (plan.status === 'pending' || plan.status === 'paused' || plan.status === 'failed')" type="primary" :icon="VideoPlay" @click="handleStart">开始</el-button>
        <el-button v-if="plan?.status === 'running'" :icon="VideoPause" @click="handlePause">暂停</el-button>
        <el-button v-if="plan?.status === 'paused'" :icon="VideoPlay" @click="handleResume">恢复</el-button>
        <el-button :icon="Delete" type="danger" @click="handleDelete">删除</el-button>
      </div>
    </div>

    <el-row :gutter="16">
      <el-col :span="6">
        <el-card>
          <div class="stat-label">状态</div>
          <el-tag v-if="plan" :type="statusTag(plan.status)" size="large">{{ statusLabel(plan.status) }}</el-tag>
        </el-card>
      </el-col>
      <el-col :span="6">
        <el-card>
          <div class="stat-label">目标上游</div>
          <div class="stat-value">{{ plan?.target_upstream }}</div>
        </el-card>
      </el-col>
      <el-col :span="6">
        <el-card>
          <div class="stat-label">创建时间</div>
          <div class="stat-value">{{ plan?.created_at ? dayjs(plan.created_at).format('YYYY-MM-DD HH:mm:ss') : '-' }}</div>
        </el-card>
      </el-col>
      <el-col :span="6">
        <el-card>
          <div class="stat-label">完成时间</div>
          <div class="stat-value">{{ plan?.updated_at ? dayjs(plan.updated_at).format('YYYY-MM-DD HH:mm:ss') : '-' }}</div>
        </el-card>
      </el-col>
    </el-row>

    <el-card class="progress-card" v-if="plan">
      <div class="progress-header">
        <span>进度: {{ plan.completed_count }}/{{ plan.total_count }}</span>
      </div>
      <el-progress
        :percentage="plan.total_count > 0 ? Math.round(plan.completed_count / plan.total_count * 100) : 0"
        :status="plan.status === 'completed' ? 'success' : undefined"
      />
    </el-card>

    <el-card v-loading="loading">
      <template #header><span>发布项</span></template>
      <el-table :data="items" stripe max-height="400">
        <el-table-column label="#" width="50">
          <template #default="{ $index }">{{ $index + 1 }}</template>
        </el-table-column>
        <el-table-column label="包名" min-width="180">
          <template #default="{ row }">
            <span>{{ row.package_organization ? row.package_organization + '::' : '' }}{{ row.package_name }}@{{ row.package_version }}</span>
          </template>
        </el-table-column>
        <el-table-column label="状态" width="110" align="center">
          <template #default="{ row }">
            <el-tag v-if="row.status !== 'pending'" :type="statusTag(row.status)" size="small">{{ statusLabel(row.status) }}</el-tag>
            <span v-else>-</span>
          </template>
        </el-table-column>
        <el-table-column prop="error" label="错误信息" min-width="200" />
      </el-table>
    </el-card>

    <el-card class="log-card" v-if="logs.length > 0">
      <template #header><span>执行日志</span></template>
      <div class="log-list">
        <div v-for="(line, i) in logs" :key="i" class="log-line">{{ line }}</div>
      </div>
    </el-card>
  </div>
</template>

<style scoped>
.page { padding: 20px; }
.page-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; }
.header-left { display: flex; align-items: center; gap: 12px; }
.page-title { font-size: 22px; font-weight: 600; margin: 0; color: #303133; }
.header-right { display: flex; gap: 8px; }
.stat-label { font-size: 13px; color: #909399; margin-bottom: 4px; }
.stat-value { font-size: 16px; font-weight: 500; color: #303133; }
.progress-card { margin: 16px 0; }
.progress-header { margin-bottom: 8px; font-size: 14px; color: #606266; }
.log-card { margin-top: 16px; }
.log-list { max-height: 300px; overflow-y: auto; font-family: monospace; font-size: 13px; }
.log-line { padding: 4px 0; border-bottom: 1px solid #f0f0f0; color: #606266; }
</style>
