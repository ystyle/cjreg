<template>
  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" class="cj-box-icon">
    <!-- 盒子后壁（深色，表示内部） -->
    <rect x="12" y="16" width="40" height="28" fill="#2B7FE0"/>

    <!-- 盒子左侧壁 -->
    <polygon points="4,24 4,52 12,44 12,16" fill="#5DADE2"/>

    <!-- 盒子右侧壁 -->
    <polygon points="60,24 60,52 52,44 52,16" fill="#5DADE2"/>

    <!-- 盒子底部 -->
    <polygon points="4,52 32,64 60,52 32,40" fill="#409EFF"/>

    <!-- 文字 cj (在盒子内部深处) -->
    <text x="32" y="36" font-family="Arial, sans-serif" font-size="14" font-weight="bold" fill="#FFFFFF" text-anchor="middle">cj</text>

    <!-- 盒子前壁（稍微透明，可以看到内部文字） -->
    <rect x="12" y="28" width="40" height="24" fill="#85C1E9" fill-opacity="0.3"/>

    <!-- 打开的盖子 - 透视效果 -->
    <polygon points="12,16 32,4 52,16 52,12 32,0 12,12" fill="#409EFF"/>
    <polygon points="12,12 32,24 52,12 52,16 32,28 12,16" fill="#5DADE2"/>

    <!-- 盖子内侧 -->
    <polygon points="12,12 32,24 52,12 32,0" fill="#85C1E9"/>

    <!-- 盒子边框线条 -->
    <line x1="12" y1="16" x2="12" y2="44" stroke="#FFFFFF" stroke-width="0.5" opacity="0.5"/>
    <line x1="52" y1="16" x2="52" y2="44" stroke="#FFFFFF" stroke-width="0.5" opacity="0.5"/>
    <line x1="4" y1="24" x2="12" y2="16" stroke="#FFFFFF" stroke-width="0.5" opacity="0.3"/>
    <line x1="60" y1="24" x2="52" y2="16" stroke="#FFFFFF" stroke-width="0.5" opacity="0.3"/>
  </svg>
</template>

<style scoped>
.cj-box-icon {
  width: 100%;
  height: 100%;
}
</style>
