import request from './index'

// 统计信息
export interface Stats {
  packages: number
  users: number
  versions: number
  downloads: number
  siteName: string
  buildDate: string
  gitCommit: string
  gitVersion: string
}

// 依赖项
export interface Dependency {
  name: string
  require: string
  target: string | null
  type: string | null
  'output-type': string | null
}

// Meta Data Index
export interface MetaDataIndex {
  organization: string
  name: string
  version: string
  dependencies: Dependency[]
  'test-dependencies': Dependency[]
  'script-dependencies': Dependency[]
  sha256sum: string
  yanked: boolean
  'cjc-version': string
  'index-version': number
}

// Meta Data
export interface MetaData {
  organization: string
  name: string
  version: string
  description: string
  'artifact-type': string
  executable: boolean
  authors: string[]
  repository: string
  homepage: string
  documentation: string
  tag: string[]
  category: string[]
  license: string[]
  index: MetaDataIndex
  'meta-version': number
}

// 包信息
export interface Package {
  id: number
  name: string
  version: string
  description: string
  organization: string
  authors: string // JSON array string
  artifact_type: string
  executable: boolean
  repository: string
  homepage: string
  documentation: string
  tags: string // JSON array string
  categories: string // JSON array string
  licenses: string // JSON array string
  meta_version: number
  meta_data: string // JSON string of MetaData
  readme: string // README content
  tarball_path: string
  tarball_size: number
  tarball_sha256: string
  created_at: string
  updated_at: string
}

// 包详情响应（包含所有版本）
export interface PackageDetailResponse {
  name: string
  description: string
  repository: string
  homepage: string
  versions: Package[]
}

// 包列表响应
export interface PackagesResponse {
  data: Package[]
  total: number
  page: number
  pageSize: number
}

// 组织信息
export interface Organization {
  id: number
  name: string
  created_at: string
}

// 获取统计信息
export const getStats = () => {
  return request<Stats>({
    url: '/stats',
    method: 'get',
  })
}

// 获取包列表
export const getPackages = (params: {
  page?: number
  pageSize?: number
  search?: string
  categories?: string // 多个分类用逗号分隔
}) => {
  return request<PackagesResponse>({
    url: '/packages',
    method: 'get',
    params,
  })
}

// 获取包详情
export const getPackageDetail = (name: string) => {
  return request<PackageDetailResponse>({
    url: `/packages/${name}`,
    method: 'get',
  })
}

// 获取组织列表
export const getOrganizations = () => {
  return request<Organization[]>({
    url: '/organizations',
    method: 'get',
  })
}
