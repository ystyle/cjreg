<script setup lang="ts">
import { useRouter } from 'vue-router'
import { ElCard, ElButton, ElTimeline, ElTimelineItem, ElAnchor, ElAnchorLink, ElCollapse, ElCollapseItem } from 'element-plus'
import { ArrowLeft, Document, Guide, Tools, QuestionFilled, Reading, Check } from '@element-plus/icons-vue'
import { siteName } from '../stores/site'

const router = useRouter()
</script>

<template>
  <div class="docs-container">
    <!-- Header Section -->
    <section class="header-section">
      <div class="header-content">
        <el-button @click="router.push('/')" class="back-button" text>
          <el-icon><ArrowLeft /></el-icon>
          返回首页
        </el-button>
        <h1 class="page-title">
          <el-icon class="title-icon"><Reading /></el-icon>
          帮助文档
        </h1>
        <p class="page-subtitle">快速了解如何使用{{ siteName }}和 cjpm</p>
      </div>
    </section>

    <div class="content-wrapper">
      <div class="docs-layout">
        <!-- Sidebar Navigation -->
        <aside class="docs-sidebar">
          <div class="sidebar-content">
            <h3 class="sidebar-title">目录</h3>
            <el-anchor>
              <el-anchor-link title="快速开始" href="#quickstart" />
              <el-anchor-link title="配置 cjpm" href="#config" />
              <el-anchor-link title="发布包" href="#publish" />
              <el-anchor-link title="使用包" href="#usage" />
              <el-anchor-link title="常见问题" href="#faq" />
            </el-anchor>
          </div>
        </aside>

        <!-- Main Content -->
        <main class="docs-main">
          <!-- Quick Start -->
          <section id="quickstart" class="doc-section">
            <div class="section-header">
              <el-icon class="section-icon"><Guide /></el-icon>
              <h2 class="section-title">快速开始</h2>
            </div>

            <div class="doc-card">
              <h3 class="doc-subtitle">安装 cjpm</h3>
              <p class="doc-text">首先确保您已安装仓颉工具链和 cjpm 包管理器。</p>
              <div class="code-block">
                <pre><code># 检查 cjpm 版本
cjpm --version</code></pre>
              </div>

              <h3 class="doc-subtitle">配置仓库</h3>
              <p class="doc-text">创建或编辑项目的 <code class="inline-code">cangjie-repo.toml</code>：</p>
              <div class="code-block">
                <pre><code>[repository.home]
registry = "http://localhost:8060"
token = "your-token-here"</code></pre>
              </div>
              <p class="doc-text">或配置全局设置（<code class="inline-code">$HOME/.cjpm/cangjie-repo.toml</code> 或 <code class="inline-code">$CANGJIE_HOME/tools/config/cangjie-repo.toml</code>）</p>
            </div>
          </section>

          <!-- Config -->
          <section id="config" class="doc-section">
            <div class="section-header">
              <el-icon class="section-icon"><Tools /></el-icon>
              <h2 class="section-title">配置 cjpm</h2>
            </div>

            <div class="doc-card">
              <h3 class="doc-subtitle">全局配置</h3>
              <p class="doc-text">在以下任一位置配置全局仓库设置：</p>
              <ul class="check-list">
                <li><code class="inline-code">$HOME/.cjpm/cangjie-repo.toml</code></li>
                <li><code class="inline-code">$CANGJIE_HOME/tools/config/cangjie-repo.toml</code></li>
              </ul>
              <div class="code-block">
                <pre><code>[repository.home]
registry = "http://localhost:8060"
token = "your-token-here"</code></pre>
              </div>

              <h3 class="doc-subtitle">项目配置</h3>
              <p class="doc-text">在项目根目录创建 <code class="inline-code">cangjie-repo.toml</code>：</p>
              <div class="code-block">
                <pre><code>[repository.home]
registry = "http://localhost:8060"
token = "your-token-here"</code></pre>
              </div>

              <div class="info-box">
                <el-icon><Check /></el-icon>
                <span><strong>提示：</strong>请联系管理员获取访问令牌，或使用管理后台创建用户。</span>
              </div>
            </div>
          </section>

          <!-- Publish -->
          <section id="publish" class="doc-section">
            <div class="section-header">
              <el-icon class="section-icon"><Document /></el-icon>
              <h2 class="section-title">发布包</h2>
            </div>

            <div class="doc-card">
              <h3 class="doc-subtitle">1. 准备项目</h3>
              <p class="doc-text">确保您的项目结构符合仓颉包规范：</p>
              <div class="code-block">
                <pre><code>my-package/
├── src/
│   └── main.cj
├── cjpm.toml
└── README.md</code></pre>
              </div>

              <p class="doc-text">确保 <code class="inline-code">cjpm.toml</code> 中填写了完整的包信息（名称、版本、作者等）。</p>

              <h3 class="doc-subtitle">2. 构建</h3>
              <div class="code-block">
                <pre><code>cjpm build</code></pre>
              </div>

              <h3 class="doc-subtitle">3. 发布</h3>
              <div class="code-block">
                <pre><code>cjpm publish</code></pre>
              </div>

              <h3 class="doc-subtitle">注意事项</h3>
              <ul class="check-list">
                <li>确保 <code class="inline-code">cjpm.toml</code> 中填写了完整的包信息</li>
                <li>版本号遵循语义化版本规范（SemVer）</li>
                <li>建议先在本地测试无误后再发布</li>
              </ul>
            </div>
          </section>

          <!-- Usage -->
          <section id="usage" class="doc-section">
            <div class="section-header">
              <el-icon class="section-icon"><Document /></el-icon>
              <h2 class="section-title">使用包</h2>
            </div>

            <div class="doc-card">
              <h3 class="doc-subtitle">1. 添加依赖</h3>
              <p class="doc-text">编辑项目根目录的 <code class="inline-code">cjpm.toml</code>：</p>
              <div class="code-block">
                <pre><code>[dependencies]
package-name = { version = "1.0.0" }</code></pre>
              </div>

              <h3 class="doc-subtitle">2. 下载依赖</h3>
              <div class="code-block">
                <pre><code># 检查并自动下载依赖
cjpm check</code></pre>
              </div>

              <h3 class="doc-subtitle">3. 在代码中导入</h3>
              <div class="code-block">
                <pre><code>import package_name

func main() {
    // 使用包的功能
}</code></pre>
              </div>

              <h3 class="doc-subtitle">4. 更新索引</h3>
              <div class="code-block">
                <pre><code># 更新所有依赖的索引
cjpm update

# 更新特定包的索引
cjpm update package-name</code></pre>
              </div>
            </div>
          </section>

          <!-- FAQ -->
          <section id="faq" class="doc-section">
            <div class="section-header">
              <el-icon class="section-icon"><QuestionFilled /></el-icon>
              <h2 class="section-title">常见问题</h2>
            </div>

            <div class="doc-card">
              <el-collapse>
                <el-collapse-item name="1">
                  <template #title>
                    <span class="collapse-title">如何重置用户令牌？</span>
                  </template>
                  <p class="doc-text">使用管理后台的用户管理功能，点击"重置令牌"按钮即可生成新的令牌。</p>
                </el-collapse-item>

                <el-collapse-item name="2">
                  <template #title>
                    <span class="collapse-title">发布失败怎么办？</span>
                  </template>
                  <p class="doc-text">请检查以下几点：</p>
                  <ul class="check-list">
                    <li>网络连接是否正常</li>
                    <li>仓库地址是否正确</li>
                    <li>令牌是否有效</li>
                    <li>包名是否已存在（版本号是否递增）</li>
                  </ul>
                </el-collapse-item>

                <el-collapse-item name="3">
                  <template #title>
                    <span class="collapse-title">如何删除已发布的包？</span>
                  </template>
                  <p class="doc-text">请联系管理员或在管理后台中删除。注意：删除操作不可恢复。</p>
                </el-collapse-item>

                <el-collapse-item name="4">
                  <template #title>
                    <span class="collapse-title">支持哪些许可证？</span>
                  </template>
                  <p class="doc-text">支持所有常见的开源许可证，如 MIT、Apache-2.0、GPL-3.0 等。</p>
                </el-collapse-item>

                <el-collapse-item name="5">
                  <template #title>
                    <span class="collapse-title">如何组织包？</span>
                  </template>
                  <p class="doc-text">使用组织功能可以将相关的包分组管理。发布时使用 <code class="inline-code">--org</code> 参数指定组织。</p>
                </el-collapse-item>
              </el-collapse>
            </div>
          </section>

          <!-- Help CTA -->
          <section class="doc-section">
            <div class="cta-card">
              <h3 class="cta-title">需要更多帮助？</h3>
              <p class="cta-text">如果您遇到其他问题，可以通过以下方式获取帮助</p>
              <div class="help-links">
                <div class="help-item">
                  <el-icon class="help-icon"><Document /></el-icon>
                  <span>查看仓颉官方文档</span>
                </div>
                <div class="help-item">
                  <el-icon class="help-icon"><Guide /></el-icon>
                  <span>访问仓颉社区论坛</span>
                </div>
                <div class="help-item">
                  <el-icon class="help-icon"><Tools /></el-icon>
                  <span>联系技术支持</span>
                </div>
              </div>
              <el-button type="primary" size="large" @click="router.push('/')">
                返回首页
              </el-button>
            </div>
          </section>
        </main>
      </div>
    </div>
  </div>
</template>

<style scoped>
.docs-container {
  width: 100%;
  min-height: 100vh;
  background: #f5f7fa;
}

/* Header Section */
.header-section {
  background: linear-gradient(135deg, #2563eb 0%, #3b82f6 100%);
  padding: 40px 20px;
  position: relative;
  overflow: hidden;
}

.header-section::before {
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

.header-content {
  max-width: 1400px;
  margin: 0 auto;
  position: relative;
  z-index: 1;
}

.back-button {
  color: rgba(255, 255, 255, 0.9);
  font-size: 14px;
  margin-bottom: 16px;
  padding: 8px 16px;
  border-radius: 8px;
  transition: all 0.3s ease;
}

.back-button:hover {
  background: rgba(255, 255, 255, 0.15);
  color: white;
}

.page-title {
  font-size: 42px;
  font-weight: 700;
  color: white;
  margin: 0 0 12px 0;
  display: flex;
  align-items: center;
  gap: 16px;
}

.title-icon {
  font-size: 36px;
}

.page-subtitle {
  font-size: 18px;
  color: rgba(255, 255, 255, 0.9);
  margin: 0;
}

.content-wrapper {
  max-width: 1400px;
  margin: 0 auto;
  padding: 40px 20px 60px;
}

.docs-layout {
  display: grid;
  grid-template-columns: 260px 1fr;
  gap: 30px;
  align-items: start;
}

/* Sidebar */
.docs-sidebar {
  position: sticky;
  top: 20px;
}

.sidebar-content {
  background: white;
  border-radius: 16px;
  padding: 24px;
  box-shadow: 0 2px 12px rgba(0, 0, 0, 0.06);
}

.sidebar-title {
  font-size: 16px;
  font-weight: 600;
  color: #303133;
  margin: 0 0 16px 0;
  padding-bottom: 12px;
  border-bottom: 2px solid #f0f0f0;
}

:deep(.el-anchor) {
  position: static;
}

:deep(.el-anchor__list) {
  padding: 0;
}

:deep(.el-anchor-link) {
  padding: 8px 0;
}

:deep(.el-anchor-link__title) {
  font-size: 14px;
  color: #606266;
}

:deep(.el-anchor-link.is-active .el-anchor-link__title) {
  color: #2563eb;
  font-weight: 600;
}

/* Main Content */
.docs-main {
  min-width: 0;
}

.doc-section {
  margin-bottom: 40px;
  scroll-margin-top: 20px;
}

.section-header {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-bottom: 20px;
}

.section-icon {
  width: 40px;
  height: 40px;
  background: linear-gradient(135deg, #2563eb 0%, #3b82f6 100%);
  border-radius: 10px;
  display: flex;
  align-items: center;
  justify-content: center;
  color: white;
  font-size: 20px;
}

.section-title {
  font-size: 28px;
  font-weight: 700;
  color: #303133;
  margin: 0;
}

.doc-card {
  background: white;
  border-radius: 16px;
  padding: 32px;
  box-shadow: 0 2px 12px rgba(0, 0, 0, 0.06);
}

.doc-subtitle {
  font-size: 20px;
  font-weight: 600;
  color: #303133;
  margin: 0 0 12px 0;
}

.doc-text {
  font-size: 15px;
  color: #606266;
  line-height: 1.8;
  margin: 0 0 16px 0;
}

.inline-code {
  background: #f5f7fa;
  padding: 2px 8px;
  border-radius: 4px;
  font-family: 'Fira Code', 'Consolas', monospace;
  font-size: 13px;
  color: #e96900;
}

.code-block {
  background: #1e1e1e;
  border-radius: 12px;
  padding: 20px;
  margin: 16px 0;
  overflow-x: auto;
}

.code-block pre {
  margin: 0;
}

.code-block code {
  font-family: 'Fira Code', 'Consolas', monospace;
  font-size: 14px;
  color: #a9b7c6;
  line-height: 1.8;
}

.check-list {
  list-style: none;
  padding: 0;
  margin: 16px 0;
}

.check-list li {
  padding: 10px 0 10px 28px;
  position: relative;
  color: #606266;
  font-size: 15px;
  line-height: 1.6;
}

.check-list li::before {
  content: '✓';
  position: absolute;
  left: 0;
  top: 10px;
  width: 18px;
  height: 18px;
  background: linear-gradient(135deg, #43e97b 0%, #38f9d7 100%);
  border-radius: 50%;
  color: white;
  font-size: 12px;
  display: flex;
  align-items: center;
  justify-content: center;
  font-weight: bold;
}

.info-box {
  display: flex;
  align-items: flex-start;
  gap: 12px;
  padding: 16px;
  background: linear-gradient(135deg, #e0f7fa 0%, #e1f5fe 100%);
  border-radius: 12px;
  margin-top: 20px;
}

.info-box .el-icon {
  font-size: 20px;
  color: #0288d1;
  flex-shrink: 0;
  margin-top: 2px;
}

.info-box span {
  font-size: 14px;
  color: #01579b;
  line-height: 1.6;
}

/* Collapse */
.collapse-title {
  font-weight: 600;
  color: #303133;
}

:deep(.el-collapse-item__header) {
  font-size: 16px;
  border-radius: 8px;
  padding: 0 16px;
  height: 56px;
  background: #f5f7fa;
  margin-bottom: 8px;
}

:deep(.el-collapse-item__wrap) {
  border: none;
}

:deep(.el-collapse-item__content) {
  padding: 16px;
  background: #fafafa;
  border-radius: 8px;
}

/* CTA Card */
.cta-card {
  background: linear-gradient(135deg, #2563eb 0%, #3b82f6 100%);
  border-radius: 20px;
  padding: 40px;
  text-align: center;
  color: white;
}

.cta-title {
  font-size: 28px;
  font-weight: 700;
  color: white;
  margin: 0 0 12px 0;
}

.cta-text {
  font-size: 16px;
  color: rgba(255, 255, 255, 0.9);
  margin: 0 0 24px 0;
}

.help-links {
  display: flex;
  justify-content: center;
  gap: 24px;
  margin-bottom: 32px;
  flex-wrap: wrap;
}

.help-item {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 12px 20px;
  background: rgba(255, 255, 255, 0.15);
  border-radius: 10px;
  font-size: 15px;
}

.help-icon {
  font-size: 20px;
}

.cta-card .el-button {
  background: white;
  color: #2563eb;
  border: none;
  font-weight: 600;
}

.cta-card .el-button:hover {
  background: rgba(255, 255, 255, 0.9);
}

/* Responsive */
@media (max-width: 1024px) {
  .docs-layout {
    grid-template-columns: 1fr;
  }

  .docs-sidebar {
    position: static;
  }
}

@media (max-width: 768px) {
  .page-title {
    font-size: 28px;
  }

  .title-icon {
    font-size: 28px;
  }

  .page-subtitle {
    font-size: 16px;
  }

  .section-title {
    font-size: 22px;
  }

  .section-icon {
    width: 32px;
    height: 32px;
    font-size: 16px;
  }

  .doc-card {
    padding: 20px;
  }

  .help-links {
    flex-direction: column;
    gap: 12px;
  }

  .cta-card {
    padding: 24px;
  }

  .cta-title {
    font-size: 22px;
  }
}
</style>
