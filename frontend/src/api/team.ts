import request from './index'

export interface Team {
  id: number
  name: string
  display_name: string
  description: string
  permission: string
  member_count: number
  org_count: number
  package_count: number
  created_at: string
}

export interface TeamOrganization {
  id: number
  organization_id: number | null
  organization_name: string
  is_null_org: boolean
}

export interface TeamPackage {
  id: number
  team_id: number
  organization: string
  package_name: string
}

export interface TeamMember {
  id: number
  user_id: number
  username: string
  email: string
  is_active: boolean
}

// 团队列表分页响应
export interface TeamsResponse {
  data: Team[]
  total: number
  page: number
  pageSize: number
}

export const getTeams = (params?: { page?: number; pageSize?: number }) => {
  return request<TeamsResponse>({
    url: '/admin/teams',
    method: 'get',
    params,
  })
}

export const createTeam = (data: {
  name: string
  display_name?: string
  description?: string
  permission: string
}) => {
  return request<Team>({
    url: '/admin/teams',
    method: 'post',
    data,
  })
}

export const updateTeam = (id: number, data: {
  name?: string
  display_name?: string
  description?: string
  permission?: string
}) => {
  return request<Team>({
    url: `/admin/teams/${id}`,
    method: 'put',
    data,
  })
}

export const deleteTeam = (id: number) => {
  return request({
    url: `/admin/teams/${id}`,
    method: 'delete',
  })
}

export const getTeamOrganizations = (id: number) => {
  return request<TeamOrganization[]>({
    url: `/admin/teams/${id}/organizations`,
    method: 'get',
  })
}

export const updateTeamOrganizations = (id: number, organization_ids: (number | null)[]) => {
  return request<TeamOrganization[]>({
    url: `/admin/teams/${id}/organizations`,
    method: 'put',
    data: { organization_ids },
  })
}

export const getTeamPackages = (id: number) => {
  return request<TeamPackage[]>({
    url: `/admin/teams/${id}/packages`,
    method: 'get',
  })
}

export const updateTeamPackages = (id: number, packages: {
  organization: string
  package_name: string
}[]) => {
  return request<TeamPackage[]>({
    url: `/admin/teams/${id}/packages`,
    method: 'put',
    data: { packages },
  })
}

export const getTeamMembers = (id: number) => {
  return request<TeamMember[]>({
    url: `/admin/teams/${id}/members`,
    method: 'get',
  })
}

export const updateTeamMembers = (id: number, user_ids: number[]) => {
  return request<TeamMember[]>({
    url: `/admin/teams/${id}/members`,
    method: 'put',
    data: { user_ids },
  })
}
