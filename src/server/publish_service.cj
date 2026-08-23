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

        // 0.5 发布权限（模式 team：团队/组织/包关联 + write；open（默认，内部先用着）仅需有效 token；
        //     后续需要转团队管理时配置 CJREG_PERMISSION_MODE=team 切换，无需改代码）
        let authorized = match (publisher) {
            case Some(u) =>
                if (this.permissionMode == "team") {
                    match (this.adminData) {
                        case Some(ad) => checkPublishPermission(ad, u, urlOrg, urlName)
                        case None => true
                    }
                } else {
                    true
                }
            case None => true
        }
        if (!authorized) {
            return PublishResult(PublishOutcome.Forbidden, 0, "no permission to publish")
        }

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

        // 5. 查同版本是否已存在（冲突/覆盖判定）
        let versions = this.store.listVersions(metaInfo.org, metaInfo.name)
        for (d in versions) {
            if (d.version == metaInfo.version && d.deletedAt == 0) {
                if (d.indexJson.contains(metaInfo.sha256sum)) {
                    // 同 sha → 幂等（视为已存在，仍可覆盖写入）
                    return PublishResult(PublishOutcome.Ok, d.id, "already exists (same sha)")
                }
                return PublishResult(PublishOutcome.Conflict, d.id,
                    "version exists with different sha, need overwrite")
            }
        }

        // 6. 制品字节存 blob（sha256 寻址，供发布计划执行推送到目标上游）
        this.blobStore.put(actualSha, pd.tarball)

        // 7. 入库（全量元数据字段，对齐官方 meta-data 规格）
        let doc = PackageDoc()
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
        doc.indexJson = String.fromUtf8(pd.metaData)
        doc.sha256 = actualSha
        doc.tarballSize = pd.tarball.size
        match (publisher) {
            case Some(u) => doc.publisherId = u.id
            case None => ()
        }
        this.store.save(doc)
        return PublishResult(PublishOutcome.Ok, doc.id, "published")
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

// 用户对 (org, name) 是否具备发布权限（write 及以上）
public func checkPublishPermission(adminData: AdminDataStore, user: User, org: String, name: String): Bool {
    // 平台管理员豁免（平台所有者）
    if (user.isAdmin) {
        return true
    }
    // 团队路径：用户是团队成员 && （团队关联该包 || 团队关联该组织）&& 团队权限 >= write
    let teams = adminData.listTeams()
    for (t in teams) {
        let memberIds = adminData.listTeamMemberIds(t.id)
        var isMember = false
        for (uid in memberIds) {
            if (uid == user.id) {
                isMember = true
                break
            }
        }
        if (!isMember) {
            continue
        }
        // 团队-包关联（organization 为空串表示无组织包）
        let pkgs = adminData.listTeamPackages(t.id)
        for (p in pkgs) {
            if (p.organization == org && p.packageName == name && permLevel(t.permission) >= 2) {
                return true
            }
        }
        // 团队-组织关联（organizationId=0 表示无组织）
        let targetOrgId: Int64 = if (org.isEmpty()) { 0 } else { orgIdByName(adminData, org) }
        let orgs = adminData.listTeamOrganizations(t.id)
        for (o in orgs) {
            if (o.organizationId == targetOrgId && permLevel(t.permission) >= 2) {
                return true
            }
        }
    }
    false
}

// 组织名 → id（不存在返回 0，与「无组织」的 0 语义一致）
func orgIdByName(adminData: AdminDataStore, org: String): Int64 {
    for (o in adminData.listOrgs()) {
        if (o.name == org) {
            return o.id
        }
    }
    0
}
