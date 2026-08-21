import { ref } from 'vue'
import { getStats } from '../api/public'

export const siteName = ref('仓颉私有仓')

export async function initSiteConfig() {
  try {
    const stats = await getStats()
    if (stats.siteName) {
      siteName.value = stats.siteName
    }
  } catch (error) {
    console.error('Failed to load site config:', error)
  }
}
