// 管理面（/api/admin/*）响应 DTO：认证 / 用户 / 审计日志 / 包 / 上游 / resolve / 发布计划 / SSE 进度帧
//
// 响应体一律交给 JsonWriter 序列化：字段名与转义由序列化器负责，不再手工拼 JSON 字符串。
// 字段名、字段顺序即客户端契约（前端与测试按 JSON 文本断言）：新增字段只能追加在末尾。
package ystyle::cjreg.server

import std.collection.*
import stdx.encoding.json.stream.*

// ===== 认证与用户 =====

// {"id":N,"username":"..","isAdmin":bool,"token":"..","expiresAt":N}
public class LoginResp <: JsonSerializable {
    public let id: Int64
    public let username: String
    public let isAdmin: Bool
    public let token: String
    public let expiresAt: Int64

    public init(id: Int64, username: String, isAdmin: Bool, token: String, expiresAt: Int64) {
        this.id = id
        this.username = username
        this.isAdmin = isAdmin
        this.token = token
        this.expiresAt = expiresAt
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(id)
        w.writeName("username").writeValue(username)
        w.writeName("isAdmin").writeValue(isAdmin)
        w.writeName("token").writeValue(token)
        w.writeName("expiresAt").writeValue(expiresAt)
        w.endObject()
    }
}

// 管理端「我是谁」：{"id":N,"username":"..","isAdmin":bool,"isActive":bool,"publishToken":".."}
public class AdminMeResp <: JsonSerializable {
    public let id: Int64
    public let username: String
    public let isAdmin: Bool
    public let isActive: Bool
    public let publishToken: String

    public init(id: Int64, username: String, isAdmin: Bool, isActive: Bool, publishToken: String) {
        this.id = id
        this.username = username
        this.isAdmin = isAdmin
        this.isActive = isActive
        this.publishToken = publishToken
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(id)
        w.writeName("username").writeValue(username)
        w.writeName("isAdmin").writeValue(isAdmin)
        w.writeName("isActive").writeValue(isActive)
        w.writeName("publishToken").writeValue(publishToken)
        w.endObject()
    }
}

// 用户列表行：{"id":N,"username":"..","isAdmin":bool,"isActive":bool}
public class UserRowResp <: JsonSerializable {
    public let id: Int64
    public let username: String
    public let isAdmin: Bool
    public let isActive: Bool

    public init(id: Int64, username: String, isAdmin: Bool, isActive: Bool) {
        this.id = id
        this.username = username
        this.isAdmin = isAdmin
        this.isActive = isActive
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(id)
        w.writeName("username").writeValue(username)
        w.writeName("isAdmin").writeValue(isAdmin)
        w.writeName("isActive").writeValue(isActive)
        w.endObject()
    }
}

// 建用户 / 改角色后的用户摘要：{"id":N,"username":"..","isAdmin":bool}
public class UserAdminResp <: JsonSerializable {
    public let id: Int64
    public let username: String
    public let isAdmin: Bool

    public init(id: Int64, username: String, isAdmin: Bool) {
        this.id = id
        this.username = username
        this.isAdmin = isAdmin
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(id)
        w.writeName("username").writeValue(username)
        w.writeName("isAdmin").writeValue(isAdmin)
        w.endObject()
    }
}

// 审计日志清理结果：{"deleted":N}
public class DeletedResp <: JsonSerializable {
    public let deleted: Int64

    public init(deleted: Int64) {
        this.deleted = deleted
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("deleted").writeValue(deleted)
        w.endObject()
    }
}

// 手动跳过计划项：{"status":"ok","itemId":N}
// （字段名是 itemId 而非 id：与 OkIdResp 的形态刻意区分，客户端按 itemId 读取）
public class SkipItemResp <: JsonSerializable {
    public let itemId: Int64

    public init(itemId: Int64) {
        this.itemId = itemId
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("status").writeValue("ok")
        w.writeName("itemId").writeValue(itemId)
        w.endObject()
    }
}

// ===== 审计日志 =====

// {"id":N,"kind":"..","actorId":N,"actorName":"..","action":"..","status":"..","target":"..",
//  "detail":"..","error":"..","ipAddr":"..","userAgent":"..","createdAt":N}
public class LogRowDto <: JsonSerializable {
    public let id: Int64
    public let kind: String
    public let actorId: Int64
    public let actorName: String
    public let action: String
    public let status: String
    public let target: String
    public let detail: String
    public let error: String
    public let ipAddr: String
    public let userAgent: String
    public let createdAt: Int64

    public init(id: Int64, kind: String, actorId: Int64, actorName: String, action: String, status: String,
                target: String, detail: String, error: String, ipAddr: String, userAgent: String,
                createdAt: Int64) {
        this.id = id
        this.kind = kind
        this.actorId = actorId
        this.actorName = actorName
        this.action = action
        this.status = status
        this.target = target
        this.detail = detail
        this.error = error
        this.ipAddr = ipAddr
        this.userAgent = userAgent
        this.createdAt = createdAt
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(id)
        w.writeName("kind").writeValue(kind)
        w.writeName("actorId").writeValue(actorId)
        w.writeName("actorName").writeValue(actorName)
        w.writeName("action").writeValue(action)
        w.writeName("status").writeValue(status)
        w.writeName("target").writeValue(target)
        w.writeName("detail").writeValue(detail)
        w.writeName("error").writeValue(error)
        w.writeName("ipAddr").writeValue(ipAddr)
        w.writeName("userAgent").writeValue(userAgent)
        w.writeName("createdAt").writeValue(createdAt)
        w.endObject()
    }
}

// 日志查询：{"total":N,"offset":N,"limit":N,"items":[<LogRowDto>..]}
public class LogQueryResp <: JsonSerializable {
    public let total: Int64
    public let offset: Int64
    public let limit: Int64
    public let items: ArrayList<LogRowDto>

    public init(total: Int64, offset: Int64, limit: Int64, items: ArrayList<LogRowDto>) {
        this.total = total
        this.offset = offset
        this.limit = limit
        this.items = items
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("total").writeValue(total)
        w.writeName("offset").writeValue(offset)
        w.writeName("limit").writeValue(limit)
        w.writeName("items").writeValue(items)
        w.endObject()
    }
}

// ===== 包（列表与单版本详情）=====

// {"id":N,"organization":"..","name":"..","version":"..","deletedAt":N,"sha256":"..",
//  "tarballSize":N,"downloads":N,"publisherId":N,"upstreamId":N,"createdAt":N,"updatedAt":N}
public class AdminPackageDto <: JsonSerializable {
    public let id: Int64
    public let organization: String
    public let name: String
    public let version: String
    public let deletedAt: Int64
    public let sha256: String
    public let tarballSize: Int64
    public let downloads: Int64
    public let publisherId: Int64
    public let upstreamId: Int64
    public let createdAt: Int64
    public let updatedAt: Int64

    public init(id: Int64, organization: String, name: String, version: String, deletedAt: Int64, sha256: String,
                tarballSize: Int64, downloads: Int64, publisherId: Int64, upstreamId: Int64,
                createdAt: Int64, updatedAt: Int64) {
        this.id = id
        this.organization = organization
        this.name = name
        this.version = version
        this.deletedAt = deletedAt
        this.sha256 = sha256
        this.tarballSize = tarballSize
        this.downloads = downloads
        this.publisherId = publisherId
        this.upstreamId = upstreamId
        this.createdAt = createdAt
        this.updatedAt = updatedAt
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(id)
        w.writeName("organization").writeValue(organization)
        w.writeName("name").writeValue(name)
        w.writeName("version").writeValue(version)
        w.writeName("deletedAt").writeValue(deletedAt)
        w.writeName("sha256").writeValue(sha256)
        w.writeName("tarballSize").writeValue(tarballSize)
        w.writeName("downloads").writeValue(downloads)
        w.writeName("publisherId").writeValue(publisherId)
        w.writeName("upstreamId").writeValue(upstreamId)
        w.writeName("createdAt").writeValue(createdAt)
        w.writeName("updatedAt").writeValue(updatedAt)
        w.endObject()
    }
}

// 管理端包列表：{"total":N,"items":[<AdminPackageDto>..]}
public class AdminPackageListResp <: JsonSerializable {
    public let total: Int64
    public let items: ArrayList<AdminPackageDto>

    public init(total: Int64, items: ArrayList<AdminPackageDto>) {
        this.total = total
        this.items = items
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("total").writeValue(total)
        w.writeName("items").writeValue(items)
        w.endObject()
    }
}

// 单版本详情（管理端口径，含 README 全文）：
// {"id":N,"organization":"..","name":"..","version":"..","cjcVersion":"..","description":"..",
//  "artifactType":"..","executable":bool,"authors":[..],"repository":"..","homepage":"..",
//  "documentation":"..","tag":[..],"category":[..],"license":[..],"sha256":"..","tarballSize":N,
//  "downloads":N,"publisherId":N,"publisher":"..","upstreamId":N,"upstreamName":"..","deletedAt":N,
//  "createdAt":N,"updatedAt":N,"readme":"..","readmeLength":N,"artifactPresent":bool}
public class PackageVersionDetailDto <: JsonSerializable {
    public let id: Int64
    public let organization: String
    public let name: String
    public let version: String
    public let cjcVersion: String
    public let description: String
    public let artifactType: String
    public let executable: Bool
    public let authors: ArrayList<String>
    public let repository: String
    public let homepage: String
    public let documentation: String
    public let tag: ArrayList<String>
    public let category: ArrayList<String>
    public let license: ArrayList<String>
    public let sha256: String
    public let tarballSize: Int64
    public let downloads: Int64
    public let publisherId: Int64
    public let publisher: String
    public let upstreamId: Int64
    public let upstreamName: String
    public let deletedAt: Int64
    public let createdAt: Int64
    public let updatedAt: Int64
    public let readme: String
    public let readmeLength: Int64
    public let artifactPresent: Bool

    public init(id: Int64, organization: String, name: String, version: String, cjcVersion: String,
                description: String, artifactType: String, executable: Bool, authors: ArrayList<String>,
                repository: String, homepage: String, documentation: String, tag: ArrayList<String>,
                category: ArrayList<String>, license: ArrayList<String>, sha256: String, tarballSize: Int64,
                downloads: Int64, publisherId: Int64, publisher: String, upstreamId: Int64, upstreamName: String,
                deletedAt: Int64, createdAt: Int64, updatedAt: Int64, readme: String, readmeLength: Int64,
                artifactPresent: Bool) {
        this.id = id
        this.organization = organization
        this.name = name
        this.version = version
        this.cjcVersion = cjcVersion
        this.description = description
        this.artifactType = artifactType
        this.executable = executable
        this.authors = authors
        this.repository = repository
        this.homepage = homepage
        this.documentation = documentation
        this.tag = tag
        this.category = category
        this.license = license
        this.sha256 = sha256
        this.tarballSize = tarballSize
        this.downloads = downloads
        this.publisherId = publisherId
        this.publisher = publisher
        this.upstreamId = upstreamId
        this.upstreamName = upstreamName
        this.deletedAt = deletedAt
        this.createdAt = createdAt
        this.updatedAt = updatedAt
        this.readme = readme
        this.readmeLength = readmeLength
        this.artifactPresent = artifactPresent
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(id)
        w.writeName("organization").writeValue(organization)
        w.writeName("name").writeValue(name)
        w.writeName("version").writeValue(version)
        w.writeName("cjcVersion").writeValue(cjcVersion)
        w.writeName("description").writeValue(description)
        w.writeName("artifactType").writeValue(artifactType)
        w.writeName("executable").writeValue(executable)
        w.writeName("authors").writeValue(authors)
        w.writeName("repository").writeValue(repository)
        w.writeName("homepage").writeValue(homepage)
        w.writeName("documentation").writeValue(documentation)
        w.writeName("tag").writeValue(tag)
        w.writeName("category").writeValue(category)
        w.writeName("license").writeValue(license)
        w.writeName("sha256").writeValue(sha256)
        w.writeName("tarballSize").writeValue(tarballSize)
        w.writeName("downloads").writeValue(downloads)
        w.writeName("publisherId").writeValue(publisherId)
        w.writeName("publisher").writeValue(publisher)
        w.writeName("upstreamId").writeValue(upstreamId)
        w.writeName("upstreamName").writeValue(upstreamName)
        w.writeName("deletedAt").writeValue(deletedAt)
        w.writeName("createdAt").writeValue(createdAt)
        w.writeName("updatedAt").writeValue(updatedAt)
        w.writeName("readme").writeValue(readme)
        w.writeName("readmeLength").writeValue(readmeLength)
        w.writeName("artifactPresent").writeValue(artifactPresent)
        w.endObject()
    }
}

// ===== 上游 =====

// {"id":N,"name":"..","url":"..","enabled":bool,"isOfficial":bool,"priority":N,"cacheTtl":N,
//  "proxyEnabled":bool,"asTarget":bool}
public class UpstreamDto <: JsonSerializable {
    public let id: Int64
    public let name: String
    public let url: String
    public let enabled: Bool
    public let isOfficial: Bool
    public let priority: Int64
    public let cacheTtl: Int64
    public let proxyEnabled: Bool
    public let asTarget: Bool

    public init(id: Int64, name: String, url: String, enabled: Bool, isOfficial: Bool, priority: Int64,
                cacheTtl: Int64, proxyEnabled: Bool, asTarget: Bool) {
        this.id = id
        this.name = name
        this.url = url
        this.enabled = enabled
        this.isOfficial = isOfficial
        this.priority = priority
        this.cacheTtl = cacheTtl
        this.proxyEnabled = proxyEnabled
        this.asTarget = asTarget
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(id)
        w.writeName("name").writeValue(name)
        w.writeName("url").writeValue(url)
        w.writeName("enabled").writeValue(enabled)
        w.writeName("isOfficial").writeValue(isOfficial)
        w.writeName("priority").writeValue(priority)
        w.writeName("cacheTtl").writeValue(cacheTtl)
        w.writeName("proxyEnabled").writeValue(proxyEnabled)
        w.writeName("asTarget").writeValue(asTarget)
        w.endObject()
    }
}

// 新增上游回执：{"id":N,"name":"..","isOfficial":bool,"proxyEnabled":bool,"asTarget":bool}
public class UpstreamAddedResp <: JsonSerializable {
    public let id: Int64
    public let name: String
    public let isOfficial: Bool
    public let proxyEnabled: Bool
    public let asTarget: Bool

    public init(id: Int64, name: String, isOfficial: Bool, proxyEnabled: Bool, asTarget: Bool) {
        this.id = id
        this.name = name
        this.isOfficial = isOfficial
        this.proxyEnabled = proxyEnabled
        this.asTarget = asTarget
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(id)
        w.writeName("name").writeValue(name)
        w.writeName("isOfficial").writeValue(isOfficial)
        w.writeName("proxyEnabled").writeValue(proxyEnabled)
        w.writeName("asTarget").writeValue(asTarget)
        w.endObject()
    }
}

// 上游连通性探测结果（upstreamProbeJson 的形态）：
// {"upstreamId":N,"upstreamName":"..","baseUrl":"..","testedUrl":"..","enabled":bool,"reachable":bool,
//  "healthy":bool,"status":N,"latencyMs":N,"bodyBytes":N,"authUsed":bool,"packages":[..],"error":"..",
//  "summary":".."}
public class UpstreamProbeResp <: JsonSerializable {
    public let upstreamId: Int64
    public let upstreamName: String
    public let baseUrl: String
    public let testedUrl: String
    public let enabled: Bool
    public let reachable: Bool
    public let healthy: Bool
    public let status: Int64
    public let latencyMs: Int64
    public let bodyBytes: Int64
    public let authUsed: Bool
    public let packages: ArrayList<String>
    public let error: String
    public let summary: String

    public init(upstreamId: Int64, upstreamName: String, baseUrl: String, testedUrl: String, enabled: Bool,
                reachable: Bool, healthy: Bool, status: Int64, latencyMs: Int64, bodyBytes: Int64,
                authUsed: Bool, packages: ArrayList<String>, error: String, summary: String) {
        this.upstreamId = upstreamId
        this.upstreamName = upstreamName
        this.baseUrl = baseUrl
        this.testedUrl = testedUrl
        this.enabled = enabled
        this.reachable = reachable
        this.healthy = healthy
        this.status = status
        this.latencyMs = latencyMs
        this.bodyBytes = bodyBytes
        this.authUsed = authUsed
        this.packages = packages
        this.error = error
        this.summary = summary
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("upstreamId").writeValue(upstreamId)
        w.writeName("upstreamName").writeValue(upstreamName)
        w.writeName("baseUrl").writeValue(baseUrl)
        w.writeName("testedUrl").writeValue(testedUrl)
        w.writeName("enabled").writeValue(enabled)
        w.writeName("reachable").writeValue(reachable)
        w.writeName("healthy").writeValue(healthy)
        w.writeName("status").writeValue(status)
        w.writeName("latencyMs").writeValue(latencyMs)
        w.writeName("bodyBytes").writeValue(bodyBytes)
        w.writeName("authUsed").writeValue(authUsed)
        w.writeName("packages").writeValue(packages)
        w.writeName("error").writeValue(error)
        w.writeName("summary").writeValue(summary)
        w.endObject()
    }
}

// ===== resolve 诊断 =====

// {"repo":"..","version":"..","sha256sum":"..","conflict":bool}
public class ResolveCandidateDto <: JsonSerializable {
    public let repo: String
    public let version: String
    public let sha256sum: String
    public let conflict: Bool

    public init(repo: String, version: String, sha256sum: String, conflict: Bool) {
        this.repo = repo
        this.version = version
        this.sha256sum = sha256sum
        this.conflict = conflict
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("repo").writeValue(repo)
        w.writeName("version").writeValue(version)
        w.writeName("sha256sum").writeValue(sha256sum)
        w.writeName("conflict").writeValue(conflict)
        w.endObject()
    }
}

// {"name":"..","org":"..","require":"..","found":bool,"replaced":bool,"replacedBy":"..",
//  "selected":<ResolveCandidateDto>|null,"candidates":[<ResolveCandidateDto>..],"trace":[".."..]}
// selected 未命中时输出 null（不是省略字段）：消费方靠它区分「没有候选」与「字段缺失」
public class ResolveResp <: JsonSerializable {
    public let name: String
    public let org: String
    public let require: String
    public let found: Bool
    public let replaced: Bool
    public let replacedBy: String
    public let selected: ?ResolveCandidateDto
    public let candidates: ArrayList<ResolveCandidateDto>
    public let trace: ArrayList<String>

    public init(name: String, org: String, require: String, found: Bool, replaced: Bool, replacedBy: String,
                selected: ?ResolveCandidateDto, candidates: ArrayList<ResolveCandidateDto>,
                trace: ArrayList<String>) {
        this.name = name
        this.org = org
        this.require = require
        this.found = found
        this.replaced = replaced
        this.replacedBy = replacedBy
        this.selected = selected
        this.candidates = candidates
        this.trace = trace
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("name").writeValue(name)
        w.writeName("org").writeValue(org)
        w.writeName("require").writeValue(require)
        w.writeName("found").writeValue(found)
        w.writeName("replaced").writeValue(replaced)
        w.writeName("replacedBy").writeValue(replacedBy)
        w.writeName("selected").writeValue(selected)
        w.writeName("candidates").writeValue(candidates)
        w.writeName("trace").writeValue(trace)
        w.endObject()
    }
}

// ===== 发布计划 analyze =====

// {"name":"..","org":"..","version":"..","order":N,"category":"..","selected":bool,
//  "local_sha256":"..","remote_sha256":"..","requirement":"..","target_version":"..",
//  "target_compared":bool}
public class PlanItemAnalysisDto <: JsonSerializable {
    public let name: String
    public let org: String
    public let version: String
    public let order: Int64
    public let category: String
    public let selected: Bool
    public let localSha256: String
    public let remoteSha256: String
    public let requirement: String
    public let targetVersion: String
    public let targetCompared: Bool

    public init(name: String, org: String, version: String, order: Int64, category: String, selected: Bool,
                localSha256: String, remoteSha256: String, requirement: String, targetVersion: String,
                targetCompared: Bool) {
        this.name = name
        this.org = org
        this.version = version
        this.order = order
        this.category = category
        this.selected = selected
        this.localSha256 = localSha256
        this.remoteSha256 = remoteSha256
        this.requirement = requirement
        this.targetVersion = targetVersion
        this.targetCompared = targetCompared
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("name").writeValue(name)
        w.writeName("org").writeValue(org)
        w.writeName("version").writeValue(version)
        w.writeName("order").writeValue(order)
        w.writeName("category").writeValue(category)
        w.writeName("selected").writeValue(selected)
        w.writeName("local_sha256").writeValue(localSha256)
        w.writeName("remote_sha256").writeValue(remoteSha256)
        w.writeName("requirement").writeValue(requirement)
        w.writeName("target_version").writeValue(targetVersion)
        w.writeName("target_compared").writeValue(targetCompared)
        w.endObject()
    }
}

// {"target_checked":bool,"target_error":"..","publish_order":[<PlanItemAnalysisDto>..],"hasCycle":bool}
// target_checked=false 表示这次没做成目标仓对照（消费方必须连 target_error 一起看）
public class PlanAnalyzeResp <: JsonSerializable {
    public let targetChecked: Bool
    public let targetError: String
    public let publishOrder: ArrayList<PlanItemAnalysisDto>
    public let hasCycle: Bool

    public init(targetChecked: Bool, targetError: String, publishOrder: ArrayList<PlanItemAnalysisDto>,
                hasCycle: Bool) {
        this.targetChecked = targetChecked
        this.targetError = targetError
        this.publishOrder = publishOrder
        this.hasCycle = hasCycle
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("target_checked").writeValue(targetChecked)
        w.writeName("target_error").writeValue(targetError)
        w.writeName("publish_order").writeValue(publishOrder)
        w.writeName("hasCycle").writeValue(hasCycle)
        w.endObject()
    }
}

// 计划执行回执：{"success":N,"skipped":N,"failed":N,"total":N,"aborted":bool,
//               "abort_reason":"..","errors":[".."..]}
public class PlanExecuteResp <: JsonSerializable {
    public let success: Int64
    public let skipped: Int64
    public let failed: Int64
    public let total: Int64
    public let aborted: Bool
    public let abortReason: String
    public let errors: ArrayList<String>

    public init(success: Int64, skipped: Int64, failed: Int64, total: Int64, aborted: Bool, abortReason: String,
                errors: ArrayList<String>) {
        this.success = success
        this.skipped = skipped
        this.failed = failed
        this.total = total
        this.aborted = aborted
        this.abortReason = abortReason
        this.errors = errors
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("success").writeValue(success)
        w.writeName("skipped").writeValue(skipped)
        w.writeName("failed").writeValue(failed)
        w.writeName("total").writeValue(total)
        w.writeName("aborted").writeValue(aborted)
        w.writeName("abort_reason").writeValue(abortReason)
        w.writeName("errors").writeValue(errors)
        w.endObject()
    }
}

// ===== 发布计划进度帧（SSE：data 部分，帧结构与连接语义见 buildPlanEventsPayload）=====

// {"id":N,"org":"..","name":"..","version":"..","status":"..","error":".."}
public class PlanProgressItemDto <: JsonSerializable {
    public let id: Int64
    public let org: String
    public let name: String
    public let version: String
    public let status: String
    public let error: String

    public init(id: Int64, org: String, name: String, version: String, status: String, error: String) {
        this.id = id
        this.org = org
        this.name = name
        this.version = version
        this.status = status
        this.error = error
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(id)
        w.writeName("org").writeValue(org)
        w.writeName("name").writeValue(name)
        w.writeName("version").writeValue(version)
        w.writeName("status").writeValue(status)
        w.writeName("error").writeValue(error)
        w.endObject()
    }
}

// {"planId":N,"status":"..","completed":N,"total":N,"lastError":"..","items":[<PlanProgressItemDto>..]}
public class PlanProgressDto <: JsonSerializable {
    public let planId: Int64
    public let status: String
    public let completed: Int64
    public let total: Int64
    public let lastError: String
    public let items: ArrayList<PlanProgressItemDto>

    public init(planId: Int64, status: String, completed: Int64, total: Int64, lastError: String,
                items: ArrayList<PlanProgressItemDto>) {
        this.planId = planId
        this.status = status
        this.completed = completed
        this.total = total
        this.lastError = lastError
        this.items = items
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("planId").writeValue(planId)
        w.writeName("status").writeValue(status)
        w.writeName("completed").writeValue(completed)
        w.writeName("total").writeValue(total)
        w.writeName("lastError").writeValue(lastError)
        w.writeName("items").writeValue(items)
        w.endObject()
    }
}

// 终态补发的 done 帧：{"planId":N,"status":".."}
public class PlanDoneDto <: JsonSerializable {
    public let planId: Int64
    public let status: String

    public init(planId: Int64, status: String) {
        this.planId = planId
        this.status = status
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("planId").writeValue(planId)
        w.writeName("status").writeValue(status)
        w.endObject()
    }
}

// ===== 服务层结果 DTO（由管理端点直接写出）=====

// 三级删除 / 恢复结果：{"status":"..","message":"..","skippedPlanItems":N,"blobRemoved":bool,
//                        "artifactPresent":bool}
public class LifecycleResp <: JsonSerializable {
    public let status: String
    public let message: String
    public let skippedPlanItems: Int64
    public let blobRemoved: Bool
    public let artifactPresent: Bool

    public init(status: String, message: String, skippedPlanItems: Int64, blobRemoved: Bool,
                artifactPresent: Bool) {
        this.status = status
        this.message = message
        this.skippedPlanItems = skippedPlanItems
        this.blobRemoved = blobRemoved
        this.artifactPresent = artifactPresent
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("status").writeValue(status)
        w.writeName("message").writeValue(message)
        w.writeName("skippedPlanItems").writeValue(skippedPlanItems)
        w.writeName("blobRemoved").writeValue(blobRemoved)
        w.writeName("artifactPresent").writeValue(artifactPresent)
        w.endObject()
    }
}

// 上游重拉结果：{"status":"..","message":"..","oldSha":"..","newSha":"..","changed":bool,
//                "size":N,"readmeLength":N,"upstream":".."}
public class RefetchResp <: JsonSerializable {
    public let status: String
    public let message: String
    public let oldSha: String
    public let newSha: String
    public let changed: Bool
    public let size: Int64
    public let readmeLength: Int64
    public let upstream: String

    public init(status: String, message: String, oldSha: String, newSha: String, changed: Bool, size: Int64,
                readmeLength: Int64, upstream: String) {
        this.status = status
        this.message = message
        this.oldSha = oldSha
        this.newSha = newSha
        this.changed = changed
        this.size = size
        this.readmeLength = readmeLength
        this.upstream = upstream
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("status").writeValue(status)
        w.writeName("message").writeValue(message)
        w.writeName("oldSha").writeValue(oldSha)
        w.writeName("newSha").writeValue(newSha)
        w.writeName("changed").writeValue(changed)
        w.writeName("size").writeValue(size)
        w.writeName("readmeLength").writeValue(readmeLength)
        w.writeName("upstream").writeValue(upstream)
        w.endObject()
    }
}

// ===== 在线备份（admin/backups）=====

// 一个归档文件：{"file":"..","size":N,"mtime":ms,"timeText":"10-22 15:30"}
public class BackupArchiveResp <: JsonSerializable {
    public let file: String
    public let size: Int64
    public let mtime: Int64
    public let timeText: String

    public init(file: String, size: Int64, mtime: Int64, timeText: String) {
        this.file = file
        this.size = size
        this.mtime = mtime
        this.timeText = timeText
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("file").writeValue(file)
        w.writeName("size").writeValue(size)
        w.writeName("mtime").writeValue(mtime)
        w.writeName("timeText").writeValue(timeText)
        w.endObject()
    }
}

// 一次备份任务：{"id","fileName","status","message","createdAt","timeText","totalRows","blobFiles","sizeBytes","includeBlobs"}
public class BackupJobResp <: JsonSerializable {
    public let id: String
    public let fileName: String
    public let status: String
    public let message: String
    public let createdAt: Int64
    public let timeText: String
    public let totalRows: Int64
    public let blobFiles: Int64
    public let sizeBytes: Int64
    public let includeBlobs: Bool

    public init(id: String, fileName: String, status: String, message: String, createdAt: Int64,
                timeText: String, totalRows: Int64, blobFiles: Int64, sizeBytes: Int64, includeBlobs: Bool) {
        this.id = id
        this.fileName = fileName
        this.status = status
        this.message = message
        this.createdAt = createdAt
        this.timeText = timeText
        this.totalRows = totalRows
        this.blobFiles = blobFiles
        this.sizeBytes = sizeBytes
        this.includeBlobs = includeBlobs
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(id)
        w.writeName("fileName").writeValue(fileName)
        w.writeName("status").writeValue(status)
        w.writeName("message").writeValue(message)
        w.writeName("createdAt").writeValue(createdAt)
        w.writeName("timeText").writeValue(timeText)
        w.writeName("totalRows").writeValue(totalRows)
        w.writeName("blobFiles").writeValue(blobFiles)
        w.writeName("sizeBytes").writeValue(sizeBytes)
        w.writeName("includeBlobs").writeValue(includeBlobs)
        w.endObject()
    }
}

// 备份页总览：{"busy":bool,"archives":[..],"jobs":[..],"pendingRestore":"..","pendingAt":ms}
public class BackupListResp <: JsonSerializable {
    public let busy: Bool
    public let archives: ArrayList<BackupArchiveResp>
    public let jobs: ArrayList<BackupJobResp>
    public let pendingRestore: String
    public let pendingAt: Int64

    public init(busy: Bool, archives: ArrayList<BackupArchiveResp>, jobs: ArrayList<BackupJobResp>,
                pendingRestore: String, pendingAt: Int64) {
        this.busy = busy
        this.archives = archives
        this.jobs = jobs
        this.pendingRestore = pendingRestore
        this.pendingAt = pendingAt
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("busy").writeValue(busy)
        w.writeName("archives").startArray()
        for (a in archives) {
            a.toJson(w)
        }
        w.endArray()
        w.writeName("jobs").startArray()
        for (j in jobs) {
            j.toJson(w)
        }
        w.endArray()
        w.writeName("pendingRestore").writeValue(pendingRestore)
        w.writeName("pendingAt").writeValue(pendingAt)
        w.endObject()
    }
}

// 触发备份请求：{"includeBlobs": bool}（缺省 true）
public class CreateBackupRequest <: JsonDeserializable<CreateBackupRequest> {
    public var includeBlobs: ?Bool = None

    public init() {}

    public static func fromJson(r: JsonReader): CreateBackupRequest {
        let req = CreateBackupRequest()
        r.startObject()
        while (r.peek() != EndObject) {
            let n = r.readName()
            match (n) {
                case "includeBlobs" => req.includeBlobs = Some(r.readValue<Bool>())
                case _ => r.skip()
            }
        }
        r.endObject()
        req
    }
}

// 校验结果：{"file":"..","totalRows":N,"blobFiles":N,"ok":true}
public class RestoreCheckResp <: JsonSerializable {
    public let file: String
    public let totalRows: Int64
    public let blobFiles: Int64
    public let ok: Bool

    public init(file: String, totalRows: Int64, blobFiles: Int64, ok: Bool) {
        this.file = file
        this.totalRows = totalRows
        this.blobFiles = blobFiles
        this.ok = ok
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("file").writeValue(file)
        w.writeName("totalRows").writeValue(totalRows)
        w.writeName("blobFiles").writeValue(blobFiles)
        w.writeName("ok").writeValue(ok)
        w.endObject()
    }
}


// 一次性下载票据：{"ticket":"..","file":"..","url":"/api/admin/backups/<file>/download?ticket=.."}
public class DownloadTicketResp <: JsonSerializable {
    public let ticket: String
    public let file: String

    public init(ticket: String, file: String) {
        this.ticket = ticket
        this.file = file
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("ticket").writeValue(ticket)
        w.writeName("file").writeValue(file)
        w.endObject()
    }
}
