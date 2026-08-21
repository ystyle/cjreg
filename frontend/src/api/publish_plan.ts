import request from './index'

export interface PublishPlan {
  id: number
  name: string
  target_upstream: number
  status: string
  total_count: number
  completed_count: number
  created_at: string
}

export interface PublishPlanItem {
  id: number
  plan_id: number
  package_id: number
  package_name: string
  package_organization: string
  package_version: string
  order: number
  category: string
  status: string
  selected: boolean
  error: string
  started_at: string
  completed_at: string
}

export interface PublishPlanDetail {
  plan: PublishPlan
  items: PublishPlanItem[]
}

export interface PublishPlansResponse {
  data: PublishPlan[]
  total: number
  page: number
  pageSize: number
}

export const getPublishPlans = (params?: { page?: number; pageSize?: number }) => {
  return request<PublishPlansResponse>({
    url: '/admin/publish-plans',
    method: 'get',
    params,
  })
}

export const getPublishPlan = (id: number) => {
  return request<PublishPlanDetail>({
    url: `/admin/publish-plans/${id}`,
    method: 'get',
  })
}

export const createPublishPlan = (data: {
  name: string
  target_upstream: number
  package_ids: number[]
  poll_interval?: number
  poll_timeout?: number
}) => {
  return request<PublishPlan>({
    url: '/admin/publish-plans',
    method: 'post',
    data,
  })
}

export const deletePublishPlan = (id: number) => {
  return request({
    url: `/admin/publish-plans/${id}`,
    method: 'delete',
  })
}

export const startPublishPlan = (id: number) => {
  return request({
    url: `/admin/publish-plans/${id}/start`,
    method: 'post',
  })
}

export const pausePublishPlan = (id: number) => {
  return request({
    url: `/admin/publish-plans/${id}/pause`,
    method: 'post',
  })
}

export const resumePublishPlan = (id: number) => {
  return request({
    url: `/admin/publish-plans/${id}/resume`,
    method: 'post',
  })
}

export const analyzePackages = (data: { package_ids: number[]; target_upstream: number }) => {
  return request<{
    packages: Array<{
      package_id: number
      organization: string
      name: string
      version: string
      sha256: string
      category: string
      selected: boolean
    }>
    publish_order: number[]
    total: number
  }>({
    url: '/admin/publish-plans/analyze',
    method: 'post',
    data,
  })
}
