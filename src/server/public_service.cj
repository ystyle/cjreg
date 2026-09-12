// 公开只读 API 的读模型与 JSON 序列化（C1–C5，纯逻辑不依赖 HTTP → 可直接单测）
//
// 端点与语义（对齐 cjrepo public.go，字段按 cjreg 的实际存储裁剪）：
//   GET /api/stats                      C1 统计（包/版本/下载/组织/团队/用户/存储/构建信息）
//   GET /api/packages                   C2 包列表（分页 + 搜索 + `org::name` 语法 + 分类 OR + 排序）
//   GET /api/packages/:name             C3 包详情（全部版本 + README，`?organization=`）
//   GET /api/packages/:name/:version    C4 版本详情
//   GET /api/organizations              C5 组织列表
//
// 可见性：`require_auth=false`（默认）时全部公开；`require_auth=true`（私有仓）时先要求有效 Token，
// 再按 read 权限过滤（复用 checkReadPermission，与下载/索引同一裁决），管理员可见全部。
// 软删版本（deletedAt != 0）对所有公开端点不可见。
package ystyle::cjreg.server

import ystyle::cjreg.store.*
import ystyle::cjreg.auth.model.*
import ystyle::cjreg.semver_range.*
import std.collection.*
import std.sort.*

// 服务端版本（公开统计的「构建信息」；与 CHANGELOG 的版本号保持一致）
public let CJREG_SERVER_VERSION = "0.1.0"

// ===== C1 统计 =====

public struct PublicStats {
    public let packages: Int64          // 未软删版本所属的 org::name 去重数
    public let versions: Int64          // 未软删版本数
    public let downloads: Int64         // 下载计数之和
    public let organizations: Int64
    public let teams: Int64
    public let users: Int64
    public let storageBytes: Int64      // 已知制品字节之和（回源缓存版本 tarballSize 为 0）
    public let serverVersion: String
    public let startedAt: Int64
    public let uptimeSeconds: Int64

    public init(packages: Int64, versions: Int64, downloads: Int64, organizations: Int64, teams: Int64,
                users: Int64, storageBytes: Int64, serverVersion: String, startedAt: Int64, uptimeSeconds: Int64) {
        this.packages = packages
        this.versions = versions
        this.downloads = downloads
        this.organizations = organizations
        this.teams = teams
        this.users = users
        this.storageBytes = storageBytes
        this.serverVersion = serverVersion
        this.startedAt = startedAt
        this.uptimeSeconds = uptimeSeconds
    }
}

/// 统计模型：只统计未软删版本；组织/团队取管理库计数，用户数由调用方传入（用户库不在本层）
public func publicStatsModel(pkgStore: PackageStore, adminData: AdminDataStore, userCount: Int64,
                             startedAt: Int64, now: Int64): PublicStats {
    var versions: Int64 = 0
    var downloads: Int64 = 0
    var storage: Int64 = 0
    let keys = HashMap<String, Bool>()
    for (d in pkgStore.storm.all<PackageDoc>()) {
        if (d.deletedAt != 0) {
            continue
        }
        versions++
        downloads += d.downloadCount
        if (d.tarballSize > 0) {
            storage += d.tarballSize
        }
        keys[d.organization + "::" + d.name] = true
    }
    let uptime = if (now > startedAt && startedAt > 0) { (now - startedAt) / 1000 } else { 0 }
    PublicStats(keys.size, versions, downloads, adminData.listOrgs().size, adminData.listTeams().size,
        userCount, storage, CJREG_SERVER_VERSION, startedAt, uptime)
}

public func publicStatsJson(s: PublicStats): String {
    let sb = StringBuilder()
    sb.append("{\"packages\":${s.packages},\"versions\":${s.versions},\"downloads\":${s.downloads},")
    sb.append("\"organizations\":${s.organizations},\"teams\":${s.teams},\"users\":${s.users},")
    sb.append("\"storageBytes\":${s.storageBytes},\"serverVersion\":\"${escapeJsonStr(s.serverVersion)}\",")
    sb.append("\"startedAt\":${s.startedAt},\"uptimeSeconds\":${s.uptimeSeconds}}")
    sb.toString()
}

// ===== C2 包列表 =====

/// 公开包摘要（一行 = 一个 org::name，取未软删版本聚合）
public struct PublicPackageRow {
    public let org: String
    public let name: String
    public let versionCount: Int64
    public let latestVersion: String
    public let description: String          // 最新版本描述
    public let downloads: Int64
    public let updatedAt: Int64
    public let categories: ArrayList<String>
    public let license: ArrayList<String>

    public init(org: String, name: String, versionCount: Int64, latestVersion: String, description: String,
                downloads: Int64, updatedAt: Int64, categories: ArrayList<String>, license: ArrayList<String>) {
        this.org = org
        this.name = name
        this.versionCount = versionCount
        this.latestVersion = latestVersion
        this.description = description
        this.downloads = downloads
        this.updatedAt = updatedAt
        this.categories = categories
        this.license = license
    }

    /// 全名：有组织时 `org::name`
    public func fullName(): String {
        if (this.org.isEmpty()) { this.name } else { "${this.org}::${this.name}" }
    }
}

/// 收集公开可见包：未软删版本聚合；requireAuth=true 时按 read 权限过滤（user 为空则仅管理员可见）
public func collectPublicPackages(pkgStore: PackageStore, adminData: AdminDataStore,
                                  user: ?User, requireAuth: Bool): ArrayList<PublicPackageRow> {
    let keys = ArrayList<String>()
    let orgs = ArrayList<String>()
    let names = ArrayList<String>()
    let counts = ArrayList<Int64>()
    let latest = ArrayList<String>()
    let descs = ArrayList<String>()
    let downloads = ArrayList<Int64>()
    let updated = ArrayList<Int64>()
    let cats = ArrayList<ArrayList<String>>()
    let lics = ArrayList<ArrayList<String>>()
    for (d in pkgStore.storm.all<PackageDoc>()) {
        if (d.deletedAt != 0) {
            continue
        }
        let key = d.organization + "::" + d.name
        var idx = -1
        for (i in 0..keys.size) {
            if (keys[i] == key) {
                idx = i
                break
            }
        }
        if (idx < 0) {
            keys.add(key)
            orgs.add(d.organization)
            names.add(d.name)
            counts.add(0)
            latest.add("")
            descs.add("")
            downloads.add(0)
            updated.add(0)
            cats.add(ArrayList<String>())
            lics.add(ArrayList<String>())
            idx = keys.size - 1
        }
        counts[idx] = counts[idx] + 1
        downloads[idx] = downloads[idx] + d.downloadCount
        if (latest[idx].isEmpty() || compareVersions(d.version, latest[idx]) > 0) {
            latest[idx] = d.version
            descs[idx] = d.description
            cats[idx] = d.category
            lics[idx] = d.license
        }
        if (d.updatedAt > updated[idx]) {
            updated[idx] = d.updatedAt
        }
    }
    let rows = ArrayList<PublicPackageRow>()
    for (i in 0..keys.size) {
        if (requireAuth && !canReadPackage(pkgStore, adminData, user, orgs[i], names[i])) {
            continue
        }
        rows.add(PublicPackageRow(orgs[i], names[i], counts[i], latest[i], descs[i], downloads[i], updated[i],
            cats[i], lics[i]))
    }
    rows
}

/// 私有仓读权限：管理员恒可见；未登录不可见；其余按 read 权限裁决
func canReadPackage(pkgStore: PackageStore, adminData: AdminDataStore, user: ?User, org: String, name: String): Bool {
    match (user) {
        case Some(u) => checkReadPermission(pkgStore, adminData, u, org, name)
        case None => false
    }
}

/// `q` 支持 `org::name` 语法：返回 (org 过滤, 剩余关键字)
/// - `test::demo` → ("test", "demo")；`test::` → ("test", "")；`::demo` → ("", "demo")
/// - 无 `::` 时 org 过滤为空，整个 q 作为关键字
public func splitOrgQuery(q: String): (String, String) {
    let idx = q.indexOf("::")
    match (idx) {
        case Some(i) => (q[0..i].trimAscii(), q[(i + 2)..q.size].trimAscii())
        case None => ("", q.trimAscii())
    }
}

/// 过滤 + 排序（纯函数，便于单测）
/// - q：关键字（名称/描述/组织子串，大小写敏感与官方一致）
/// - org：组织过滤（与 q 的 `org::` 前缀取交集，两者都非空时必须一致）
/// - categories：多分类 OR（空 = 不过滤）
/// - sort：updated（默认，最近更新在前）| downloads | name
public func filterPublicPackages(rows: ArrayList<PublicPackageRow>, q: String, org: String,
                                 categories: ArrayList<String>, sortKey: String): ArrayList<PublicPackageRow> {
    let (qOrg, kw) = splitOrgQuery(q)
    let hits = ArrayList<PublicPackageRow>()
    for (r in rows) {
        if (!org.isEmpty() && r.org != org) {
            continue
        }
        if (!qOrg.isEmpty() && r.org != qOrg) {
            continue
        }
        if (!kw.isEmpty() && !r.name.contains(kw) && !r.description.contains(kw) && !r.org.contains(kw)) {
            continue
        }
        if (categories.size > 0) {
            var hit = false
            for (c in categories) {
                for (rc in r.categories) {
                    if (rc == c) {
                        hit = true
                        break
                    }
                }
                if (hit) {
                    break
                }
            }
            if (!hit) {
                continue
            }
        }
        hits.add(r)
    }
    match (sortKey) {
        case "downloads" => sort(hits, by: pkgByDownloadsAsc, descending: true)
        case "name" => sort(hits, by: pkgByNameAsc)
        case _ => sort(hits, by: pkgByUpdatedAsc, descending: true)
    }
    hits
}

func pkgByUpdatedAsc(a: PublicPackageRow, b: PublicPackageRow): Ordering {
    if (a.updatedAt != b.updatedAt) {
        return if (a.updatedAt < b.updatedAt) { Ordering.LT } else { Ordering.GT }
    }
    return pkgByNameAsc(a, b)
}

func pkgByDownloadsAsc(a: PublicPackageRow, b: PublicPackageRow): Ordering {
    if (a.downloads != b.downloads) {
        return if (a.downloads < b.downloads) { Ordering.LT } else { Ordering.GT }
    }
    return pkgByNameAsc(a, b)
}

func pkgByNameAsc(a: PublicPackageRow, b: PublicPackageRow): Ordering {
    let ka = a.fullName()
    let kb = b.fullName()
    if (ka == kb) {
        return Ordering.EQ
    }
    if (ka < kb) {
        return Ordering.LT
    }
    return Ordering.GT
}

/// 分页窗口（page 从 1 起，size 上限 100）
public func pageWindow(total: Int64, page: Int64, size: Int64): (Int64, Int64) {
    let safePage = if (page < 1) { 1 } else { page }
    let safeSize = if (size < 1) { 20 } else { if (size > 100) { 100 } else { size } }
    let start = (safePage - 1) * safeSize
    let end = if (start + safeSize > total) { total } else { start + safeSize }
    (start, end)
}

public func publicPackageListJson(rows: ArrayList<PublicPackageRow>, total: Int64, page: Int64, size: Int64): String {
    let (start, end) = pageWindow(rows.size, page, size)
    let sb = StringBuilder()
    sb.append("{\"total\":${total},\"page\":${page},\"size\":${size},\"items\":[")
    var i = start
    while (i < end) {
        if (i > start) {
            sb.append(",")
        }
        sb.append(publicPackageJsonInner(rows[i]))
        i++
    }
    sb.append("]}")
    sb.toString()
}

func publicPackageJsonInner(r: PublicPackageRow): String {
    let sb = StringBuilder()
    sb.append("{\"organization\":\"${escapeJsonStr(r.org)}\",\"name\":\"${escapeJsonStr(r.name)}\",")
    sb.append("\"fullName\":\"${escapeJsonStr(r.fullName())}\",\"versionCount\":${r.versionCount},")
    sb.append("\"latestVersion\":\"${escapeJsonStr(r.latestVersion)}\",")
    sb.append("\"description\":\"${escapeJsonStr(r.description)}\",\"downloads\":${r.downloads},")
    sb.append("\"updatedAt\":${r.updatedAt},")
    sb.append("\"categories\":${jsonStringArray(r.categories)},\"license\":${jsonStringArray(r.license)}}")
    sb.toString()
}

// ===== C3/C4 版本 =====

/// 公开版本行（C4 单版本；C3 的 versions 数组元素）
public struct PublicVersionRow {
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
    public let publisherName: String
    public let createdAt: Int64
    public let updatedAt: Int64

    public init(version: String, cjcVersion: String, description: String, artifactType: String, executable: Bool,
                authors: ArrayList<String>, repository: String, homepage: String, documentation: String,
                tag: ArrayList<String>, category: ArrayList<String>, license: ArrayList<String>, sha256: String,
                tarballSize: Int64, downloads: Int64, publisherName: String, createdAt: Int64, updatedAt: Int64) {
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
        this.publisherName = publisherName
        this.createdAt = createdAt
        this.updatedAt = updatedAt
    }
}

/// 包文档 → 公开版本行（publisherName 由调用方解析后传入，保持本层不依赖用户库）
public func publicVersionRow(d: PackageDoc, publisherName: String): PublicVersionRow {
    PublicVersionRow(d.version, d.cjcVersion, d.description, d.artifactType, d.executable, d.authors,
        d.repository, d.homepage, d.documentation, d.tag, d.category, d.license, d.sha256, d.tarballSize,
        d.downloadCount, publisherName, d.createdAt, d.updatedAt)
}

/// 未软删版本（version 降序：最新在前）
public func publicVersions(pkgStore: PackageStore, org: String, name: String,
                           nameOf: (Int64) -> String): ArrayList<PublicVersionRow> {
    let rows = ArrayList<PublicVersionRow>()
    for (d in pkgStore.listVersions(org, name)) {
        if (d.deletedAt != 0) {
            continue
        }
        rows.add(publicVersionRow(d, nameOf(d.publisherId)))
    }
    sort(rows, by: versionRowByVersionAsc, descending: true)
    rows
}

func versionRowByVersionAsc(a: PublicVersionRow, b: PublicVersionRow): Ordering {
    let c = compareVersions(a.version, b.version)
    if (c == 0) {
        return Ordering.EQ
    }
    return if (c < 0) { Ordering.LT } else { Ordering.GT }
}

/// 指定版本（未软删）；version 为空时取最新版本
public func publicVersion(pkgStore: PackageStore, org: String, name: String, version: String,
                          nameOf: (Int64) -> String): ?PublicVersionRow {
    var best: ?PackageDoc = None
    for (d in pkgStore.listVersions(org, name)) {
        if (d.deletedAt != 0) {
            continue
        }
        if (!version.isEmpty()) {
            if (d.version == version) {
                return Some(publicVersionRow(d, nameOf(d.publisherId)))
            }
            continue
        }
        match (best) {
            case Some(b) => if (compareVersions(d.version, b.version) > 0) { best = Some(d) }
            case None => best = Some(d)
        }
    }
    match (best) {
        case Some(b) => Some(publicVersionRow(b, nameOf(b.publisherId)))
        case None => None
    }
}

public func publicVersionJsonRow(v: PublicVersionRow): String {
    let sb = StringBuilder()
    sb.append("{\"version\":\"${escapeJsonStr(v.version)}\",\"cjcVersion\":\"${escapeJsonStr(v.cjcVersion)}\",")
    sb.append("\"description\":\"${escapeJsonStr(v.description)}\",")
    sb.append("\"artifactType\":\"${escapeJsonStr(v.artifactType)}\",\"executable\":${v.executable},")
    sb.append("\"authors\":${jsonStringArray(v.authors)},\"repository\":\"${escapeJsonStr(v.repository)}\",")
    sb.append("\"homepage\":\"${escapeJsonStr(v.homepage)}\",\"documentation\":\"${escapeJsonStr(v.documentation)}\",")
    sb.append("\"tag\":${jsonStringArray(v.tag)},\"category\":${jsonStringArray(v.category)},")
    sb.append("\"license\":${jsonStringArray(v.license)},\"sha256\":\"${escapeJsonStr(v.sha256)}\",")
    sb.append("\"tarballSize\":${v.tarballSize},\"downloads\":${v.downloads},")
    sb.append("\"publisherName\":\"${escapeJsonStr(v.publisherName)}\",")
    sb.append("\"createdAt\":${v.createdAt},\"updatedAt\":${v.updatedAt}}")
    sb.toString()
}

/// C3 包详情：包级聚合 + 全部版本 + 最新版本 README
public func publicPackageDetailJson(org: String, name: String, rows: ArrayList<PublicVersionRow>, readme: String): String {
    var downloads: Int64 = 0
    for (r in rows) {
        downloads += r.downloads
    }
    let latest = if (rows.size > 0) { rows[0].version } else { "" }
    let sb = StringBuilder()
    sb.append("{\"organization\":\"${escapeJsonStr(org)}\",\"name\":\"${escapeJsonStr(name)}\",")
    sb.append("\"fullName\":\"${escapeJsonStr(if (org.isEmpty()) { name } else { "${org}::${name}" })}\",")
    sb.append("\"versionCount\":${rows.size},\"latestVersion\":\"${escapeJsonStr(latest)}\",")
    sb.append("\"downloads\":${downloads},\"readme\":\"${escapeJsonStr(readme)}\",\"versions\":[")
    for (i in 0..rows.size) {
        if (i > 0) {
            sb.append(",")
        }
        sb.append(publicVersionJsonRow(rows[i]))
    }
    sb.append("]}")
    sb.toString()
}

// ===== C5 组织 =====

public struct PublicOrgRow {
    public let id: Int64
    public let name: String
    public let displayName: String
    public let description: String
    public let isDefault: Bool
    public let packageCount: Int64      // 该组织下未软删的 org::name 去重数
    public let versionCount: Int64      // 该组织下未软删版本数

    public init(id: Int64, name: String, displayName: String, description: String, isDefault: Bool,
                packageCount: Int64, versionCount: Int64) {
        this.id = id
        this.name = name
        this.displayName = displayName
        this.description = description
        this.isDefault = isDefault
        this.packageCount = packageCount
        this.versionCount = versionCount
    }
}

public func publicOrgRows(pkgStore: PackageStore, adminData: AdminDataStore,
                          user: ?User, requireAuth: Bool): ArrayList<PublicOrgRow> {
    // 各组织的包/版本统计（仅未软删）
    let counts = HashMap<String, Int64>()
    let versionCounts = HashMap<String, Int64>()
    for (d in pkgStore.storm.all<PackageDoc>()) {
        if (d.deletedAt != 0) {
            continue
        }
        versionCounts[d.organization] = (versionCounts.get(d.organization) ?? 0) + 1
    }
    let seen = HashMap<String, Bool>()
    for (d in pkgStore.storm.all<PackageDoc>()) {
        if (d.deletedAt != 0) {
            continue
        }
        let key = d.organization + "::" + d.name
        if (seen.get(key) ?? false) {
            continue
        }
        seen[key] = true
        counts[d.organization] = (counts.get(d.organization) ?? 0) + 1
    }
    let rows = ArrayList<PublicOrgRow>()
    let emitted = HashMap<String, Bool>()
    for (o in adminData.listOrgs()) {
        if (!orgVisible(pkgStore, adminData, user, requireAuth, o.name)) {
            continue
        }
        emitted[o.name] = true
        rows.add(PublicOrgRow(o.id, o.name, o.displayName, o.description, o.isDefault,
            counts.get(o.name) ?? 0, versionCounts.get(o.name) ?? 0))
    }
    // 未在组织表中登记、但已有可见包的组织也下发（发布不要求先建组织；id=0 表示未登记实体）
    for (orgName in orgNamesWithPackages(pkgStore)) {
        if (emitted.get(orgName) ?? false) {
            continue
        }
        if (!orgVisible(pkgStore, adminData, user, requireAuth, orgName)) {
            continue
        }
        rows.add(PublicOrgRow(0, orgName, "", "", false, counts.get(orgName) ?? 0,
            versionCounts.get(orgName) ?? 0))
    }
    sort(rows, by: orgRowByNameAsc)
    rows
}

// 包所在的组织名（去重，按名称升序）
func orgNamesWithPackages(pkgStore: PackageStore): ArrayList<String> {
    let names = ArrayList<String>()
    for (d in pkgStore.storm.all<PackageDoc>()) {
        if (d.deletedAt != 0) {
            continue
        }
        var found = false
        for (n in names) {
            if (n == d.organization) {
                found = true
                break
            }
        }
        if (!found) {
            names.add(d.organization)
        }
    }
    sort(names)
    names
}

func orgRowByNameAsc(a: PublicOrgRow, b: PublicOrgRow): Ordering {
    if (a.name == b.name) {
        return Ordering.EQ
    }
    return if (a.name < b.name) { Ordering.LT } else { Ordering.GT }
}

// 组织是否下发：开放模式恒 true；私有仓要求该组织至少有一个可读包（避免泄露组织名）
func orgVisible(pkgStore: PackageStore, adminData: AdminDataStore, user: ?User,
                requireAuth: Bool, orgName: String): Bool {
    if (!requireAuth) {
        return true
    }
    for (d in pkgStore.storm.all<PackageDoc>()) {
        if (d.deletedAt != 0 || d.organization != orgName) {
            continue
        }
        if (canReadPackage(pkgStore, adminData, user, d.organization, d.name)) {
            return true
        }
    }
    return false
}

public func publicOrgListJson(rows: ArrayList<PublicOrgRow>): String {
    let sb = StringBuilder()
    sb.append("{\"total\":${rows.size},\"items\":[")
    for (i in 0..rows.size) {
        if (i > 0) {
            sb.append(",")
        }
        let r = rows[i]
        sb.append("{\"id\":${r.id},\"name\":\"${escapeJsonStr(r.name)}\",")
        sb.append("\"displayName\":\"${escapeJsonStr(r.displayName)}\",")
        sb.append("\"description\":\"${escapeJsonStr(r.description)}\",\"isDefault\":${r.isDefault},")
        sb.append("\"packageCount\":${r.packageCount},\"versionCount\":${r.versionCount}}")
    }
    sb.append("]}")
    sb.toString()
}

// ===== 公共辅助 =====

/// 字符串数组 → JSON 数组
public func jsonStringArray(items: ArrayList<String>): String {
    let sb = StringBuilder()
    sb.append("[")
    for (i in 0..items.size) {
        if (i > 0) {
            sb.append(",")
        }
        sb.append("\"${escapeJsonStr(items[i])}\"")
    }
    sb.append("]")
    sb.toString()
}

/// 逗号分隔参数 → 去空项数组（`category=a,b` → [a, b]）
public func splitCommaList(raw: String): ArrayList<String> {
    let out = ArrayList<String>()
    for (part in raw.split(",")) {
        let v = part.trimAscii()
        if (!v.isEmpty()) {
            out.add(v)
        }
    }
    out
}
