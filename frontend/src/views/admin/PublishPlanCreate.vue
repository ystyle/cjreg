<script setup lang="ts">
import { ref, computed } from 'vue'
import { useRouter } from 'vue-router'
import {
  ElButton, ElCard, ElInput, ElInputNumber, ElSelect, ElOption, ElTag, ElTable, ElTableColumn,
  ElMessage, ElSteps, ElStep, ElCheckbox, ElEmpty, ElProgress, ElRow, ElCol,
} from 'element-plus'
import { ArrowLeft, ArrowRight, Plus } from '@element-plus/icons-vue'
import { createPublishPlan, analyzePackages } from '../../api/publish_plan'
import { getAdminPackages, getUpstreams } from '../../api/admin'

const router = useRouter()
const step = ref(0)

// Step 1: 选择包
const targetUpstream = ref<number | null>(null)
const upstreams = ref<Array<{ id: number; name: string }>>([])
const pkgInput = ref('')
const pkgResults = ref<Array<{ package_id: number; label: string; organization: string; name: string; version: string }>>([])
const selectedPkgs = ref<{ package_id: number; label: string }[]>([])
let searchTimer: ReturnType<typeof setTimeout>

const removePkg = (i: number) => selectedPkgs.value.splice(i, 1)

const onSearchInput = () => {
  clearTimeout(searchTimer)
  searchTimer = setTimeout(async () => {
    const kw = pkgInput.value.trim()
    if (!kw) { pkgResults.value = []; return }
    try {
      const res = await getAdminPackages({ search: kw, pageSize: 10 })
      const seen = new Set<number>()
      pkgResults.value = (res?.data || []).filter((p: any) => {
        if (seen.has(p.id)) return false
        seen.add(p.id)
        return true
      }).map((p: any) => ({
        package_id: p.id,
        organization: p.organization,
        name: p.name,
        version: p.version,
        label: `${p.organization ? p.organization + '::' : ''}${p.name}@${p.version}`,
      }))
    } catch { pkgResults.value = [] }
  }, 300)
}

const addPkg = (pkg: { package_id: number; label: string }) => {
  if (selectedPkgs.value.some(p => p.package_id === pkg.package_id)) return
  selectedPkgs.value.push({ package_id: pkg.package_id, label: pkg.label })
  pkgInput.value = ''
  pkgResults.value = []
}

// Step 2: 分析结果
const analyzing = ref(false)
const analyzeProgress = ref(0)
const analyzeResult = ref<Array<{
  package_id: number; organization: string; name: string; version: string;
  category: string; selected: boolean; sha256: string;
}>>([])

const runAnalyze = async () => {
  if (!targetUpstream.value || selectedPkgs.value.length === 0) return
  analyzing.value = true
  analyzeProgress.value = 0
  const interval = setInterval(() => {
    analyzeProgress.value = Math.min(analyzeProgress.value + 10, 90)
  }, 500)

  try {
    const res = await analyzePackages({
      package_ids: selectedPkgs.value.map(p => p.package_id),
      target_upstream: targetUpstream.value,
    })
    analyzeProgress.value = 100
    analyzeResult.value = res.packages || []
    publishOrder.value = res.publish_order || []
    const count = res.packages?.length || 0
    const est = count * pollInterval.value * 5 * 2
    pollTimeout.value = Math.max(est, 60)
    step.value = 1
  } catch {
    ElMessage.error('分析失败')
  } finally {
    clearInterval(interval)
    analyzing.value = false
  }
}

const categoryLabel = (c: string) => {
  switch (c) {
    case 'conflict': return '🔴 冲突'
    case 'need_publish': return '🔴 需要发布'
    case 'version_optional': return '🟡 可选版本'
    case 'already_exists': return '⚪ 已存在'
    default: return c
  }
}

const toggleSelect = (pkg: any) => {
  if (pkg.category !== 'already_exists') pkg.selected = !pkg.selected
}

const publishOrder = ref<number[]>([])

const sortedPkgs = computed(() => {
  const selected = analyzeResult.value.filter(p => p.selected)
  const rank = new Map(publishOrder.value.map((id, i) => [id, i]))
  return [...selected].sort((a, b) => (rank.get(a.package_id) ?? 999) - (rank.get(b.package_id) ?? 999))
})

const suggestedTimeout = computed(() => {
  const count = analyzeResult.value.filter(p => p.selected).length
  const est = count * pollInterval.value * 5 * 2
  return Math.max(est, 60)
})

// Step 3: 确认并创建
const planName = ref('')
const pollInterval = ref(60)
const pollTimeout = ref(600)
const creating = ref(false)

const submit = async () => {
  if (!planName.value.trim()) { ElMessage.warning('请输入计划名称'); return }
  if (!targetUpstream.value) { ElMessage.warning('请选择目标上游'); return }
  let ids = analyzeResult.value.filter(p => p.selected).map(p => p.package_id)
  if (ids.length === 0) { ElMessage.warning('请选择要发布的包'); return }
  // 按 publish_order 排序（被依赖的在前）
  if (publishOrder.value.length > 0) {
    const rank = new Map(publishOrder.value.map((id, i) => [id, i]))
    ids.sort((a, b) => (rank.get(a) ?? 999) - (rank.get(b) ?? 999))
  }

  creating.value = true
  try {
    const plan = await createPublishPlan({
      name: planName.value,
      target_upstream: targetUpstream.value,
      package_ids: ids,
      poll_interval: pollInterval.value,
      poll_timeout: pollTimeout.value,
    })
    ElMessage.success('计划创建成功')
    router.push(`/admin/publish-plans/${plan.id}`)
  } catch (e: any) {
    ElMessage.error(e.message || '创建失败')
  } finally {
    creating.value = false
  }
}

import { onMounted } from 'vue'

onMounted(async () => {
  try {
    const res = await getUpstreams()
    upstreams.value = res?.data || []
  } catch {
    upstreams.value = []
  }
})

const canNext = computed(() => {
  if (step.value === 0) return targetUpstream.value !== null && selectedPkgs.value.length > 0
  return true
})
</script>

<template>
  <div class="page">
    <div class="page-header">
      <div class="header-left">
        <el-button text :icon="ArrowLeft" @click="step > 0 ? step-- : router.push('/admin/publish-plans')">返回</el-button>
        <h2 class="page-title">新建发布计划</h2>
      </div>
    </div>

    <el-steps :active="step" finish-status="success" class="steps">
      <el-step title="选择包" />
      <el-step title="分析结果" />
      <el-step title="确认创建" />
    </el-steps>

    <!-- Step 1: 选择包 -->
    <el-card v-show="step === 0" class="step-card">
      <template #header><span>选择起始包</span></template>

      <div class="form-item">
        <label>目标上游</label>
        <el-select v-model="targetUpstream" placeholder="选择发布目标" style="width: 300px">
          <el-option v-for="u in upstreams" :key="u.id" :value="u.id" :label="u.name" />
        </el-select>
      </div>

      <div class="form-item">
        <label>添加包</label>
        <div class="search-row">
          <el-input
            v-model="pkgInput"
            placeholder="输入包名搜索，支持 org::keyword 格式"
            clearable
            @input="onSearchInput"
            @clear="pkgResults = []"
          />
          <div v-if="pkgResults.length > 0" class="search-results">
            <div
              v-for="pkg in pkgResults"
              :key="pkg.package_id"
              class="search-result-item"
              @click="addPkg(pkg)"
            >
              <span v-if="pkg.organization" class="pkg-org">{{ pkg.organization }}::</span>
              <span class="pkg-name">{{ pkg.name }}</span>
              <el-tag size="small">{{ pkg.version }}</el-tag>
              <el-button size="small" type="primary" link>添加</el-button>
            </div>
          </div>
        </div>
      </div>

      <div class="tag-list" v-if="selectedPkgs.length > 0">
        <el-tag v-for="(pkg, i) in selectedPkgs" :key="pkg.package_id" closable @close="removePkg(i)" style="margin: 4px">
          {{ pkg.label }}
        </el-tag>
      </div>
      <el-empty v-else description="请添加起始包" :image-size="80" />

      <div class="step-actions">
        <el-button type="primary" :disabled="!canNext || analyzing" :loading="analyzing" @click="runAnalyze">
          分析依赖
        </el-button>
      </div>

      <div v-if="analyzing" class="analyzing-box">
        <el-progress :percentage="analyzeProgress" />
        <p class="analyze-text">正在分析依赖树，获取远程版本对比...</p>
      </div>
    </el-card>

    <!-- Step 2: 分析结果 -->
    <el-card v-show="step === 1" class="step-card">
      <template #header><span>分析结果（{{ analyzeResult.length }} 个包）</span></template>

      <div v-for="cat in ['conflict', 'need_publish', 'version_optional', 'already_exists']" :key="cat">
        <div v-if="analyzeResult.filter(p => p.category === cat).length > 0" class="category-group">
          <h4>{{ categoryLabel(cat) }} ({{ analyzeResult.filter(p => p.category === cat).length }})</h4>
          <div v-for="pkg in analyzeResult.filter(p => p.category === cat)" :key="pkg.package_id"
            class="pkg-item" :class="{ selected: pkg.selected }" @click="toggleSelect(pkg)">
            <el-checkbox :model-value="pkg.selected" :disabled="pkg.category === 'already_exists'" />
            <span class="pkg-name">{{ pkg.organization ? pkg.organization + '::' : '' }}{{ pkg.name }}</span>
            <el-tag size="small">{{ pkg.version }}</el-tag>
          </div>
        </div>
      </div>

      <div class="step-actions">
        <el-button @click="step = 0">上一步</el-button>
        <el-button type="primary" :disabled="analyzeResult.filter(p => p.selected).length === 0" @click="step = 2">下一步</el-button>
      </div>
    </el-card>

    <!-- Step 3: 确认创建 -->
    <el-card v-show="step === 2" class="step-card">
      <template #header><span>确认创建</span></template>

      <div class="form-item">
        <label>计划名称</label>
        <el-input v-model="planName" placeholder="例如: v1.1 发布" style="max-width: 400px" />
      </div>

      <div class="form-item">
        <label>目标上游</label>
        <span>{{ upstreams.find(u => u.id === targetUpstream)?.name || targetUpstream }}</span>
      </div>

      <el-row :gutter="16">
        <el-col :span="12">
          <div class="form-item">
            <label>轮询间隔（秒）</label>
            <el-input-number v-model="pollInterval" :min="5" :max="600" />
            <div class="form-tip">每次检查上游索引的间隔，最低 5 秒，默认 60 秒</div>
          </div>
        </el-col>
        <el-col :span="12">
          <div class="form-item">
            <label>总超时（秒）</label>
            <el-input-number v-model="pollTimeout" :min="60" :max="86400" />
            <div class="form-tip">建议 {{ suggestedTimeout }} 秒（{{ Math.round(suggestedTimeout / 60) }} 分钟）</div>
          </div>
        </el-col>
      </el-row>

      <div class="form-item">
        <label>发布包 ({{ analyzeResult.filter(p => p.selected).length }} 个)</label>
        <el-table :data="sortedPkgs" stripe max-height="300">
          <el-table-column label="#" width="50">
            <template #default="{ $index }">{{ $index + 1 }}</template>
          </el-table-column>
          <el-table-column label="包">
            <template #default="{ row }">{{ row.organization ? row.organization + '::' : '' }}{{ row.name }}</template>
          </el-table-column>
          <el-table-column prop="version" label="版本" width="120" />
        </el-table>
      </div>

      <div class="step-actions">
        <el-button @click="step = 1">上一步</el-button>
        <el-button type="primary" :loading="creating" @click="submit">创建计划</el-button>
      </div>
    </el-card>
  </div>
</template>

<style scoped>
.page { padding: 20px; max-width: 900px; }
.page-header { margin-bottom: 24px; }
.header-left { display: flex; align-items: center; gap: 12px; }
.page-title { font-size: 22px; font-weight: 600; margin: 0; color: #303133; }
.steps { margin-bottom: 24px; }
.step-card { margin-bottom: 20px; }
.form-item { margin-bottom: 16px; }
.form-item label { display: block; font-size: 14px; color: #606266; margin-bottom: 6px; font-weight: 500; }
.search-row { position: relative; }
.search-results {
  position: absolute; top: 100%; left: 0; right: 0; z-index: 100;
  background: #fff; border: 1px solid #e4e7ed; border-radius: 4px;
  box-shadow: 0 2px 12px rgba(0,0,0,0.1); max-height: 240px; overflow-y: auto;
}
.search-result-item {
  display: flex; align-items: center; gap: 8px; padding: 8px 12px;
  cursor: pointer; transition: background 0.2s;
}
.search-result-item:hover { background: #f5f7fa; }
.pkg-org { font-weight: 600; color: #409eff; font-family: 'Courier New', monospace; }
.pkg-name { font-weight: 500; font-family: 'Courier New', monospace; }
.form-tip { margin-top: 4px; font-size: 12px; color: #909399; }
.tag-list { margin: 8px 0; }
.step-actions { display: flex; gap: 8px; justify-content: flex-end; margin-top: 20px; padding-top: 16px; border-top: 1px solid #eee; }
.analyzing-box { margin-top: 16px; padding: 20px; background: #f5f7fa; border-radius: 8px; }
.analyze-text { font-size: 14px; color: #909399; margin-top: 8px; }
.category-group { margin-bottom: 20px; }
.category-group h4 { font-size: 14px; color: #303133; margin: 0 0 8px 0; }
.pkg-item { display: flex; align-items: center; gap: 8px; padding: 8px 12px; cursor: pointer; border-radius: 4px; transition: background 0.2s; }
.pkg-item:hover { background: #f5f7fa; }
.pkg-item .pkg-name { flex: 1; font-size: 14px; }
</style>
