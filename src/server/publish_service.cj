// 发布核心业务：解析官方二进制 → 校验 meta 与 URL 一致 → sha256 校验制品 → 入库
// 纯逻辑（不依赖 HTTP），可单测；tang handler 为薄壳
package ystyle::cjreg.server

import ystyle::cjreg.protocol.*
import ystyle::cjreg.index.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*
import stdx.crypto.digest.SHA256
import stdx.encoding.hex.toHexString
import stdx.encoding.json.stream.*
import std.io.*
import std.collection.*
import std.convert.*
import std.time.*

// 发布结果
public enum PublishOutcome {
    | Ok             // 入库成功（新包/新版本/覆盖成功）
    | InvalidFormat  // 二进制格式非法
    | MetaMismatch   // meta 与 URL 的 name/org/version 不一致
    | ShaMismatch    // 制品 sha256 与 meta 不一致
    | Conflict       // 同版本已存在且 sha 不同（需 overwrite）
    | BadRequest     // 参数错误
    | Unauthorized   // 发布 token 缺失/无效（规格 401）
    | Forbidden      // 对组织/包无发布权限（规格 403）

    public operator func ==(other: PublishOutcome): Bool {
        match (this) {
            case PublishOutcome.Ok => match (other) {
                case PublishOutcome.Ok => true
                case _ => false
            }
            case PublishOutcome.InvalidFormat => match (other) {
                case PublishOutcome.InvalidFormat => true
                case _ => false
            }
            case PublishOutcome.MetaMismatch => match (other) {
                case PublishOutcome.MetaMismatch => true
                case _ => false
            }
            case PublishOutcome.ShaMismatch => match (other) {
                case PublishOutcome.ShaMismatch => true
                case _ => false
            }
            case PublishOutcome.Conflict => match (other) {
                case PublishOutcome.Conflict => true
                case _ => false
            }
            case PublishOutcome.BadRequest => match (other) {
                case PublishOutcome.BadRequest => true
                case _ => false
            }
            case PublishOutcome.Unauthorized => match (other) {
                case PublishOutcome.Unauthorized => true
                case _ => false
            }
            case PublishOutcome.Forbidden => match (other) {
                case PublishOutcome.Forbidden => true
                case _ => false
            }
        }
    }
}

public class PublishResult {
    public var outcome: PublishOutcome
    public var pkgId: Int64
    public var message: String

    public init(outcome: PublishOutcome, pkgId: Int64, message: String) {
        this.outcome = outcome
        this.pkgId = pkgId
        this.message = message
    }
}

// 制品 SHA-256（hex）
public func sha256Hex(data: Array<Byte>): String {
    let sha = SHA256()
    sha.write(data)
    toHexString(sha.finish())
}

// 发布服务（校验 + 入库 + 制品字节存 blob 供发布计划执行）
public class PublishService {
    public var store: PackageStore
    public var blobStore: BlobStore
    // 发布认证（规格：Authorization header 携带用户 publish token；None = 离线模式不校验）
    public var auth: ?AuthService
    // 发布权限数据（团队/组织/包关联；None = 无权限模型，跳过 403 检查）
    public var adminData: ?AdminDataStore
    // 权限模式：open（默认，内部先用着：有效 token 即可发布）/ team（严格：团队/组织/包关联 + write）
    public var permissionMode: String

    public init(store: PackageStore, blobStore: BlobStore, auth!: ?AuthService = None, adminData!: ?AdminDataStore = None, permissionMode!: String = "open") {
        this.store = store
        this.blobStore = blobStore
        this.auth = auth
        this.adminData = adminData
        this.permissionMode = permissionMode
    }

    // 发布；urlOrg 为 URL 里的 organization 参数（可空）
    // 无认证重载（离线模式/测试兼容）
    public func publish(urlOrg: String, urlName: String, body: Array<Byte>): PublishResult {
        this.publish(urlOrg, urlName, body, "")
    }

    public func publish(urlOrg: String, urlName: String, body: Array<Byte>, token: String): PublishResult {
        if (urlName.isEmpty()) {
            return PublishResult(PublishOutcome.BadRequest, 0, "package name required")
        }
        // 0. 发布认证（规格：Authorization: ${publishToken}；缺失/无效 → 401）
        var publisher: ?User = None
        match (this.auth) {
            case Some(authSvc) =>
                if (token.isEmpty()) {
                    return PublishResult(PublishOutcome.Unauthorized, 0, "missing publish token")
                }
                match (authSvc.validatePublishToken(token)) {
                    case Some(u) => publisher = Some(u)
                    case None => return PublishResult(PublishOutcome.Unauthorized, 0, "invalid publish token")
                }
            case None => ()
        }

        // 0.5 发布权限裁决已移至 meta 解析之后（覆盖判定需要 version 信息，见步骤 5）

        // 1. 解析官方二进制
        let data = parsePublishData(body)
        if (data.isNone()) {
            return PublishResult(PublishOutcome.InvalidFormat, 0, "invalid publish data format")
        }
        let pd = data.getOrThrow()

        // 2. 解析 meta-data.json（取 name/org/version）
        let meta = parseMetaJson(pd.metaData)
        if (meta.isNone()) {
            return PublishResult(PublishOutcome.InvalidFormat, 0, "invalid meta-data.json")
        }
        let metaInfo = meta.getOrThrow()

        // 3. 校验 meta 与 URL 一致
        if (metaInfo.name != urlName || metaInfo.org != urlOrg) {
            return PublishResult(PublishOutcome.MetaMismatch, 0,
                "metadata mismatch: url(${urlOrg}::${urlName}) vs meta(${metaInfo.org}::${metaInfo.name})")
        }

        // 4. sha256 校验制品与 meta.index.sha256sum 一致
        let actualSha = sha256Hex(pd.tarball)
        if (!metaInfo.sha256sum.isEmpty() && actualSha != metaInfo.sha256sum) {
            return PublishResult(PublishOutcome.ShaMismatch, 0,
                "sha256 mismatch: meta=${metaInfo.sha256sum} actual=${actualSha}")
        }

        // 5. 同版本已存在判定 + 权限裁决（必须在 meta 解析之后：覆盖判定需要 version）
        //    open 模式：有效 token 即发布（现状保留；同版本不同 sha 仍返回 409，不静默覆盖）
        //    team 模式：双路径裁决（对齐 design.md §5.3.6 / §5.4.3）——
        //      新包且命名空间未被团队纳管 → 任意有效 token 可认领（首次发布者成为 publisher）
        //      已被纳管 或 已有版本 → 需 write；覆盖同版本（sha 不同）→ 需 overwrite
        let versions = this.store.listVersions(metaInfo.org, metaInfo.name)
        var existing: ?PackageDoc = None
        for (d in versions) {
            if (d.version == metaInfo.version && d.deletedAt == 0) {
                existing = Some(d)
                break
            }
        }
        let sameSha = match (existing) {
            case Some(d) => d.sha256 == actualSha  // 精确比 sha256 字段（避免 meta 缺 sha 时误判幂等）
            case None => false
        }
        // 覆盖 = 同版本已存在且 sha 不同（同 sha 走幂等，不消耗 overwrite）
        let needOverwrite = existing.isSome() && !sameSha
        var overwriteAllowed = false
        if (this.permissionMode == "team") {
            match (this.adminData) {
                case Some(ad) =>
                    let needCheck = versions.size > 0 || isNamespaceGoverned(ad, metaInfo.org, metaInfo.name)
                    match (publisher) {
                        case Some(u) =>
                            if (needCheck && !checkPublishPermission(this.store, ad, u, metaInfo.org, metaInfo.name, needOverwrite)) {
                                return PublishResult(PublishOutcome.Forbidden, 0, "no permission to publish")
                            }
                            overwriteAllowed = needOverwrite
                        case None => overwriteAllowed = needOverwrite  // 无认证（离线模式）：不裁决
                    }
                case None => overwriteAllowed = needOverwrite
            }
        }

        // 6. 幂等 / 覆盖 / 冲突
        match (existing) {
            case Some(d) =>
                if (sameSha) {
                    // 同 sha → 幂等（视为已存在，不入库）
                    return PublishResult(PublishOutcome.Ok, d.id, "already exists (same sha)")
                }
                if (!overwriteAllowed) {
                    return PublishResult(PublishOutcome.Conflict, d.id,
                        "version exists with different sha, need overwrite")
                }
                return this.overwriteVersion(d, metaInfo, pd, actualSha, publisher)
            case None => ()
        }

        // 7. 新版本入库（blob 内容寻址，供发布计划执行推送到目标上游）
        this.blobStore.put(actualSha, pd.tarball)
        let doc = PackageDoc()
        let now = nowMsUtc()
        fillPackageDoc(doc, metaInfo, String.fromUtf8(pd.metaData), actualSha, pd.tarball.size,
            publisherIdOf(publisher), now, now)
        this.store.save(doc)
        return PublishResult(PublishOutcome.Ok, doc.id, "published")
    }

    // 覆盖已存在版本（调用方已完成 overwrite 裁决）：更新原文档而非新建，保持 id/createdAt 稳定
    // 注意：包名所有权（publisherId）不因覆盖转移——首次发布者始终是 publisher；覆盖者由管理日志追责
    func overwriteVersion(doc: PackageDoc, metaInfo: MetaInfo, pd: PublishData, sha: String, publisher: ?User): PublishResult {
        this.blobStore.put(sha, pd.tarball)
        let now = nowMsUtc()
        let created = if (doc.createdAt > 0) { doc.createdAt } else { now }
        let owner = if (doc.publisherId != 0) { doc.publisherId } else { publisherIdOf(publisher) }
        fillPackageDoc(doc, metaInfo, String.fromUtf8(pd.metaData), sha, pd.tarball.size, owner, now, created)
        this.store.save(doc)
        return PublishResult(PublishOutcome.Ok, doc.id, "overwritten")
    }
}

// meta-data.json 关键字段（发布校验用）
public class MetaInfo {
    public var org: String
    public var name: String
    public var version: String
    public var sha256sum: String
    // meta-data.json 展示字段（官方规格）
    public var cjcVersion: String = ""
    public var description: String = ""
    public var artifactType: String = "src"
    public var executable: Bool = false
    public var authors: ArrayList<String> = ArrayList<String>()
    public var repository: String = ""
    public var homepage: String = ""
    public var documentation: String = ""
    public var tag: ArrayList<String> = ArrayList<String>()
    public var category: ArrayList<String> = ArrayList<String>()
    public var license: ArrayList<String> = ArrayList<String>()
    public var metaVersion: Int64 = 1

    public init(org: String, name: String, version: String, sha256sum: String) {
        this.org = org
        this.name = name
        this.version = version
        this.sha256sum = sha256sum
    }
}

// 字符串数组读取（meta 的 authors/tag/category/license）
func readStringArray(r: JsonReader, out: ArrayList<String>): Unit {
    let token = r.peek()
    match (token) {
        case Some(JsonToken.BeginArray) =>
            r.startArray()
            while (r.peek() != EndArray) {
                out.add(r.readValue<String>())
            }
            r.endArray()
        case _ => r.skip()
    }
}

// 从 meta-data.json 解析全部元数据字段（官方规格对齐）
// meta 顶层含 organization/name/version/cjc-version/description/...；sha256sum 在嵌套 index 对象内
public func parseMetaJson(metaBytes: Array<Byte>): ?MetaInfo {
    let body = String.fromUtf8(metaBytes)
    let bb = ByteBuffer()
    bb.write(body.toArray())
    let r = JsonReader(bb)
    var org = ""
    var name = ""
    var version = ""
    var sha = ""
    var cjcVersion = ""
    var description = ""
    var artifactType = "src"
    var executable = false
    let authors = ArrayList<String>()
    var repository = ""
    var homepage = ""
    var documentation = ""
    let tag = ArrayList<String>()
    let category = ArrayList<String>()
    let license = ArrayList<String>()
    var metaVersion: Int64 = 1
    try {
        while (let Some(v) <- r.peek()) {
            match (v) {
                case BeginObject =>
                    r.startObject()
                    while (r.peek() != EndObject) {
                        let n = r.readName()
                        match (n) {
                            case "organization" => org = r.readValue<String>()
                            case "name" => name = r.readValue<String>()
                            case "version" => version = r.readValue<String>()
                            case "cjc-version" => cjcVersion = r.readValue<String>()
                            case "description" => description = r.readValue<String>()
                            case "artifact-type" => artifactType = r.readValue<String>()
                            case "executable" => executable = r.readValue<Bool>()
                            case "authors" => readStringArray(r, authors)
                            case "repository" => repository = r.readValue<String>()
                            case "homepage" => homepage = r.readValue<String>()
                            case "documentation" => documentation = r.readValue<String>()
                            case "tag" => readStringArray(r, tag)
                            case "category" => readStringArray(r, category)
                            case "license" => readStringArray(r, license)
                            case "meta-version" =>
                                let mv = r.peek()
                                match (mv) {
                                    case Some(JsonToken.JsonString) => metaVersion = Int64.parse(r.readValue<String>())
                                    case Some(JsonToken.JsonNumber) => metaVersion = r.readValue<Int64>()
                                    case _ => r.skip()
                                }
                            case "index" =>
                                // 进入嵌套 index 对象取 sha256sum
                                r.startObject()
                                while (r.peek() != EndObject) {
                                    let innerName = r.readName()
                                    if (innerName == "sha256sum") {
                                        sha = r.readValue<String>()
                                    } else {
                                        r.skip()
                                    }
                                }
                                r.endObject()
                            case _ => r.skip()
                        }
                    }
                    r.endObject()
                    let info = MetaInfo(org, name, version, sha)
                    info.cjcVersion = cjcVersion
                    info.description = description
                    info.artifactType = artifactType
                    info.executable = executable
                    info.authors = authors
                    info.repository = repository
                    info.homepage = homepage
                    info.documentation = documentation
                    info.tag = tag
                    info.category = category
                    info.license = license
                    info.metaVersion = metaVersion
                    return Some(info)
                case _ => r.skip()
            }
        }
        return None
    } catch (e: Exception) {
        return None
    }
}

// ===== 发布权限检查（对齐 cjrepo：团队路径；平台管理员豁免） =====

// 权限级别：read=1 / write=2 / overwrite=3
func permLevel(p: String): Int64 {
    match (p) {
        case "write" => 2
        case "overwrite" => 3
        case _ => 1
    }
}

// 当前时刻（UTC 毫秒）
func nowMsUtc(): Int64 {
    DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
}

// 发布者用户 ID（未认证 → 0）
func publisherIdOf(publisher: ?User): Int64 {
    match (publisher) {
        case Some(u) => u.id
        case None => 0
    }
}

// 组织名 → 团队关联用的组织 ID：空串 = 无组织（0）；非空但未登记 = -1（不匹配任何组织关联）
// 0 专表「无组织包」：未知组织名不得落到 0，否则会被「关联无组织」的团队越权覆盖
func orgIdByName(adminData: AdminDataStore, org: String): Int64 {
    if (org.isEmpty()) {
        return 0
    }
    for (o in adminData.listOrgs()) {
        if (o.name == org) {
            return o.id
        }
    }
    return -1
}

// 团队成员判定
public func isTeamMember(adminData: AdminDataStore, teamId: Int64, userId: Int64): Bool {
    for (uid in adminData.listTeamMemberIds(teamId)) {
        if (uid == userId) {
            return true
        }
    }
    return false
}

// 该用户是否为 (org, name) 的发布者（任一版本 publisherId 命中，含软删版本）
public func isPackagePublisher(store: PackageStore, org: String, name: String, userId: Int64): Bool {
    for (d in store.listVersions(org, name)) {
        if (d.publisherId == userId) {
            return true
        }
    }
    return false
}

// 命名空间是否已被团队纳管：存在 TeamOrganization 关联该组织，或 TeamPackage 关联该包名
// 纳管后不再开放「无主认领」——新包也需 write 权限（自由命名空间仍可由首个发布者认领）
public func isNamespaceGoverned(adminData: AdminDataStore, org: String, name: String): Bool {
    let targetOrgId = orgIdByName(adminData, org)
    for (t in adminData.listTeams()) {
        for (p in adminData.listTeamPackages(t.id)) {
            if (p.organization == org && p.packageName == name) {
                return true
            }
        }
        if (targetOrgId >= 0) {
            for (o in adminData.listTeamOrganizations(t.id)) {
                if (o.organizationId == targetOrgId) {
                    return true
                }
            }
        }
    }
    return false
}

// 用户对 (org, name) 的有效权限级别 = max(个人发布路径, 团队路径)（对齐 design.md §5.4.3）
//   平台管理员 → overwrite（直通）
//   个人发布路径：该用户是该包任一版本的发布者 → write（覆盖仍属团队 overwrite 权限）
//   团队路径：团队成员 && （TeamPackage 包级 || TeamOrganization 组织级）→ 团队 permission（取最高）
public func effectivePermission(store: PackageStore, adminData: AdminDataStore, user: User, org: String, name: String): Int64 {
    if (user.isAdmin) {
        return 3
    }
    var level: Int64 = 0
    if (isPackagePublisher(store, org, name, user.id)) {
        level = 2
    }
    let targetOrgId = orgIdByName(adminData, org)
    for (t in adminData.listTeams()) {
        let teamLevel = permLevel(t.permission)
        if (teamLevel <= level) {
            continue  // 团队权限不高于现有水平，命中也不影响结果
        }
        if (!isTeamMember(adminData, t.id, user.id)) {
            continue
        }
        var hit = false
        for (p in adminData.listTeamPackages(t.id)) {
            if (p.organization == org && p.packageName == name) {
                hit = true
                break
            }
        }
        if (!hit && targetOrgId >= 0) {
            for (o in adminData.listTeamOrganizations(t.id)) {
                if (o.organizationId == targetOrgId) {
                    hit = true
                    break
                }
            }
        }
        if (hit) {
            level = teamLevel
        }
    }
    return level
}

// 发布裁决：新包/新版本需 write 及以上；覆盖已存在版本需 overwrite
public func checkPublishPermission(store: PackageStore, adminData: AdminDataStore, user: User,
                                   org: String, name: String, overwrite: Bool): Bool {
    let need: Int64 = if (overwrite) { 3 } else { 2 }
    effectivePermission(store, adminData, user, org, name) >= need
}

// 读裁决（requireAuth=true 时的下载/索引）：read 及以上
public func checkReadPermission(store: PackageStore, adminData: AdminDataStore, user: User,
                                org: String, name: String): Bool {
    effectivePermission(store, adminData, user, org, name) >= 1
}

// 用 meta 填充包文档（新发布/覆盖共用）：deletedAt 归零、记录 created/updated 时间、清掉回源痕迹
func fillPackageDoc(doc: PackageDoc, metaInfo: MetaInfo, indexJson: String, sha: String, tarballSize: Int64,
                    publisherId: Int64, now: Int64, createdAt: Int64): Unit {
    doc.organization = metaInfo.org
    doc.name = metaInfo.name
    doc.version = metaInfo.version
    doc.cjcVersion = metaInfo.cjcVersion
    doc.description = metaInfo.description
    doc.artifactType = metaInfo.artifactType
    doc.executable = metaInfo.executable
    doc.authors = metaInfo.authors
    doc.repository = metaInfo.repository
    doc.homepage = metaInfo.homepage
    doc.documentation = metaInfo.documentation
    doc.tag = metaInfo.tag
    doc.category = metaInfo.category
    doc.license = metaInfo.license
    doc.metaVersion = metaInfo.metaVersion
    doc.indexJson = indexJson
    doc.sha256 = sha
    doc.tarballSize = tarballSize
    doc.publisherId = publisherId
    doc.upstreamId = 0
    doc.upstreamName = ""
    doc.readme = ""
    doc.deletedAt = 0
    doc.createdAt = createdAt
    doc.updatedAt = now
}
