<script setup lang="ts">
import { ref } from 'vue'
import { useRouter } from 'vue-router'
import { ElCard, ElForm, ElFormItem, ElInput, ElButton, ElIcon, ElMessage } from 'element-plus'
import { Lock } from '@element-plus/icons-vue'
import { siteName } from '../../stores/site'
import { login } from '../../api/admin'
import MD5 from 'crypto-js/md5'

const router = useRouter()

const adminKey = ref('')
const loading = ref(false)

const handleLogin = async () => {
  if (!adminKey.value.trim()) {
    ElMessage.warning('请输入管理密钥')
    return
  }

  loading.value = true

  try {
    // MD5 加密管理密钥
    const keyMD5 = MD5(adminKey.value).toString()

    // 调用登录 API
    const data = await login({ adminKey: keyMD5 })

    // 保存 JWT token
    localStorage.setItem('admin_token', data.token)
    localStorage.setItem('token_expires_at', data.expiresAt.toString())

    ElMessage.success('登录成功')

    // 跳转到之前尝试访问的页面，或者默认到 dashboard
    const redirect = router.currentRoute.value.query.redirect as string || '/admin/dashboard'
    router.push(redirect)
  } catch (error: any) {
    console.error('Login error:', error)
    ElMessage.error(error.message || '登录失败')
  } finally {
    loading.value = false
  }
}

// 回车键登录
const handleKeyup = (e: KeyboardEvent) => {
  if (e.key === 'Enter') {
    handleLogin()
  }
}
</script>

<template>
  <div class="login-container">
    <div class="login-wrapper">
      <div class="login-header">
        <h1 class="login-title">管理后台</h1>
        <p class="login-subtitle">{{ siteName }}管理系统</p>
      </div>

      <el-card class="login-card">
        <el-form @submit.prevent="handleLogin">
          <el-form-item>
            <el-input
              v-model="adminKey"
              type="password"
              placeholder="请输入管理密钥"
              size="large"
              show-password
              autofocus
              @keyup="handleKeyup"
            >
              <template #prefix>
                <el-icon><Lock /></el-icon>
              </template>
            </el-input>
          </el-form-item>

          <el-button
            type="primary"
            size="large"
            :loading="loading"
            class="login-button"
            @click="handleLogin"
          >
            {{ loading ? '登录中...' : '登录' }}
          </el-button>

          <div class="login-tips">
            <p class="tip-text">请使用环境变量 CJREPO_ADMIN_KEY 设置的管理密钥登录</p>
          </div>
        </el-form>
      </el-card>

      <div class="login-footer">
        <el-button text @click="router.push('/')">
          返回首页
        </el-button>
      </div>
    </div>
  </div>
</template>

<style scoped>
.login-container {
  width: 100%;
  min-height: 100vh;
  background: linear-gradient(135deg, #2563eb 0%, #3b82f6 100%);
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 20px;
  position: relative;
  overflow: hidden;
}

.login-container::before {
  content: '';
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  background: url('data:image/svg+xml,<svg width="60" height="60" viewBox="0 0 60 60" xmlns="http://www.w3.org/2000/svg"><g fill="none" fill-rule="evenodd"><g fill="%23ffffff" fill-opacity="0.05"><path d="M36 34v-4h-2v4h-4v2h4v4h2v-4h4v-2h-4zm0-30V0h-2v4h-4v2h4v4h2V6h4V2h-4zM6 34v-4H4v4H0v2h4v4h2v-4h4v-2H6zM6 4V0H4v4H0v2h4v4h2V6h4V2H6z"/></g></g></svg>');
  opacity: 0.4;
  animation: pattern 20s linear infinite;
}

@keyframes pattern {
  0% {
    background-position: 0 0;
  }
  100% {
    background-position: 60px 60px;
  }
}

.login-wrapper {
  position: relative;
  z-index: 1;
  width: 100%;
  max-width: 420px;
}

.login-header {
  text-align: center;
  margin-bottom: 32px;
  color: white;
}

.login-title {
  font-size: 36px;
  font-weight: 700;
  margin: 0 0 12px 0;
}

.login-subtitle {
  font-size: 16px;
  color: rgba(255, 255, 255, 0.9);
  margin: 0;
}

.login-card {
  border-radius: 16px;
  box-shadow: 0 8px 32px rgba(0, 0, 0, 0.2);
  border: none;
}

.login-card :deep(.el-card__body) {
  padding: 32px;
}

.login-button {
  width: 100%;
  height: 48px;
  font-size: 16px;
  font-weight: 600;
  border-radius: 12px;
  background: linear-gradient(135deg, #2563eb 0%, #3b82f6 100%);
  border: none;
}

.login-button:hover {
  background: linear-gradient(135deg, #1d4ed8 0%, #2563eb 100%);
  transform: translateY(-2px);
  box-shadow: 0 4px 16px rgba(37, 99, 235, 0.4);
}

.login-tips {
  margin-top: 24px;
  padding-top: 24px;
  border-top: 1px solid #f0f0f0;
  text-align: center;
}

.tip-text {
  font-size: 13px;
  color: #909399;
  margin: 0;
  line-height: 1.6;
}

.login-footer {
  margin-top: 24px;
  text-align: center;
}

.login-footer .el-button {
  color: rgba(255, 255, 255, 0.9);
  font-size: 14px;
}

.login-footer .el-button:hover {
  color: white;
}
</style>
