import axios, { type AxiosInstance, type AxiosError, type AxiosResponse } from 'axios'

// 创建 axios 实例
const request: AxiosInstance = axios.create({
  baseURL: '/api',
  timeout: 10000,
  headers: {
    'Content-Type': 'application/json',
  },
})

// 请求拦截器
request.interceptors.request.use(
  (config) => {
    // 从 localStorage 获取 token
    const token = localStorage.getItem('admin_token')
    if (token) {
      config.headers.Authorization = `Bearer ${token}`
    }
    return config
  },
  (error) => {
    return Promise.reject(error)
  }
)

// 响应拦截器
request.interceptors.response.use(
  (response: AxiosResponse) => {
    return response.data
  },
  (error: AxiosError) => {
    if (error.response) {
      const { status, data } = error.response

      // 处理 401 未授权（token过期或无效）
      if (status === 401) {
        // 清除token
        localStorage.removeItem('admin_token')
        localStorage.removeItem('token_expires_at')

        // 如果不是在登录页面，跳转到登录页
        if (window.location.pathname !== '/admin/login') {
          window.location.href = '/admin/login'
        }
        return Promise.reject(new Error('未授权，请重新登录'))
      }

      // 处理其他错误
      const message = (data as any)?.error || (data as any)?.message || '请求失败'
      return Promise.reject(new Error(message))
    }

    // 网络错误
    return Promise.reject(new Error('网络错误，请检查您的网络连接'))
  }
)

export default request
