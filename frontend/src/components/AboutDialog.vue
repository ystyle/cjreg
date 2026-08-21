<script setup lang="ts">
import { ref } from 'vue'
import { ElDialog } from 'element-plus'
import { getStats } from '../api/public'
import type { Stats } from '../api/public'

const visible = ref(false)
const stats = ref<Stats | null>(null)

const open = () => {
  visible.value = true
  if (!stats.value) {
    loadStats()
  }
}

const loadStats = async () => {
  try {
    stats.value = await getStats()
  } catch (error) {
    console.error('Failed to load stats:', error)
  }
}

defineExpose({ open })
</script>

<template>
  <ElDialog
    v-model="visible"
    title="关于 cjrepo"
    width="400px"
    :close-on-click-modal="true"
  >
    <div class="about-content">
      <h2 class="site-name">{{ stats?.siteName || '仓颉私有仓' }}</h2>
      
      <div class="version-info">
        <span class="version">{{ stats?.gitVersion || 'dev' }}</span>
        <span class="commit">({{ stats?.gitCommit || 'unknown' }})</span>
      </div>
      
      <div class="build-date">
        构建时间：{{ stats?.buildDate || 'unknown' }}
      </div>
      
      <hr class="divider" />
      
      <div class="links">
        <h4>联系方式</h4>
        <div class="link-item">
          <a href="mailto:lxy5266@live.com">lxy5266@live.com</a>
        </div>
      </div>

      <hr class="divider" />

      <div class="links">
        <h4>项目链接</h4>
        <div class="link-item">
          <a href="https://github.com/anomalyco/cjrepo" target="_blank">
            GitHub 仓库
          </a>
        </div>
        <div class="link-item">
          <a href="https://cangjie-lang.cn" target="_blank">
            仓颉语言官网
          </a>
        </div>
        <div class="link-item">
          <a href="https://cangjie-lang.cn/docs" target="_blank">
            仓颉语言文档
          </a>
        </div>
      </div>
    </div>
  </ElDialog>
</template>

<style scoped>
.about-content {
  text-align: center;
}

.site-name {
  margin: 0 0 10px 0;
  font-size: 20px;
  color: #303133;
}

.version-info {
  margin-bottom: 8px;
  font-size: 14px;
}

.version {
  font-weight: bold;
  color: #409eff;
}

.commit {
  color: #909399;
  font-size: 12px;
}

.build-date {
  font-size: 13px;
  color: #606266;
  margin-bottom: 16px;
}

.divider {
  border: none;
  border-top: 1px solid #ebeef5;
  margin: 16px 0;
}

.links h4 {
  margin: 0 0 12px 0;
  font-size: 14px;
  color: #606266;
}

.link-item {
  margin: 8px 0;
}

.link-item a {
  color: #409eff;
  text-decoration: none;
}

.link-item a:hover {
  text-decoration: underline;
}
</style>