// 公开只读 API（C1–C5）的响应 DTO
//
// 响应体一律交给 JsonWriter 序列化：字段名与转义由序列化器负责，不再手工拼 JSON 字符串。
// 字段名、字段顺序即客户端契约（前端与测试按 JSON 文本断言）：新增字段只能追加在末尾。
package ystyle::cjreg.server

import std.collection.*
import stdx.encoding.json.stream.*

// ===== C1 统计 =====

// {"packages":N,"versions":N,"downloads":N,"organizations":N,"teams":N,"users":N,
//  "storageBytes":N,"serverVersion":"..","startedAt":N,"uptimeSeconds":N}
public class PublicStatsDto <: JsonSerializable {
    public let packages: Int64
    public let versions: Int64
    public let downloads: Int64
    public let organizations: Int64
    public let teams: Int64
    public let users: Int64
    public let storageBytes: Int64
    public let serverVersion: String
    public let startedAt: Int64
    public let uptimeSeconds: Int64

    public init(packages: Int64, versions: Int64, downloads: Int64, organizations: Int64, teams: Int64,
                users: Int64, storageBytes: Int64, serverVersion: String, startedAt: Int64,
                uptimeSeconds: Int64) {
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

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("packages").writeValue(packages)
        w.writeName("versions").writeValue(versions)
        w.writeName("downloads").writeValue(downloads)
        w.writeName("organizations").writeValue(organizations)
        w.writeName("teams").writeValue(teams)
        w.writeName("users").writeValue(users)
        w.writeName("storageBytes").writeValue(storageBytes)
        w.writeName("serverVersion").writeValue(serverVersion)
        w.writeName("startedAt").writeValue(startedAt)
        w.writeName("uptimeSeconds").writeValue(uptimeSeconds)
        w.endObject()
    }
}

// ===== C2 包列表 =====

// {"organization":"..","name":"..","fullName":"..","versionCount":N,"latestVersion":"..",
//  "description":"..","downloads":N,"updatedAt":N,"categories":[..],"license":[..]}
public class PublicPackageDto <: JsonSerializable {
    public let organization: String
    public let name: String
    public let fullName: String
    public let versionCount: Int64
    public let latestVersion: String
    public let description: String
    public let downloads: Int64
    public let updatedAt: Int64
    public let categories: ArrayList<String>
    public let license: ArrayList<String>

    public init(organization: String, name: String, fullName: String, versionCount: Int64,
                latestVersion: String, description: String, downloads: Int64, updatedAt: Int64,
                categories: ArrayList<String>, license: ArrayList<String>) {
        this.organization = organization
        this.name = name
        this.fullName = fullName
        this.versionCount = versionCount
        this.latestVersion = latestVersion
        this.description = description
        this.downloads = downloads
        this.updatedAt = updatedAt
        this.categories = categories
        this.license = license
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("organization").writeValue(organization)
        w.writeName("name").writeValue(name)
        w.writeName("fullName").writeValue(fullName)
        w.writeName("versionCount").writeValue(versionCount)
        w.writeName("latestVersion").writeValue(latestVersion)
        w.writeName("description").writeValue(description)
        w.writeName("downloads").writeValue(downloads)
        w.writeName("updatedAt").writeValue(updatedAt)
        w.writeName("categories").writeValue(categories)
        w.writeName("license").writeValue(license)
        w.endObject()
    }
}

// {"total":N,"page":N,"size":N,"items":[<PublicPackageDto>..]}
public class PublicPackageListDto <: JsonSerializable {
    public let total: Int64
    public let page: Int64
    public let size: Int64
    public let items: ArrayList<PublicPackageDto>

    public init(total: Int64, page: Int64, size: Int64, items: ArrayList<PublicPackageDto>) {
        this.total = total
        this.page = page
        this.size = size
        this.items = items
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("total").writeValue(total)
        w.writeName("page").writeValue(page)
        w.writeName("size").writeValue(size)
        w.writeName("items").startArray()
        for (it in items) {
            w.writeValue(it)
        }
        w.endArray()
        w.endObject()
    }
}

// ===== C3/C4 版本 =====

// {"version":"..","cjcVersion":"..","description":"..","artifactType":"..","executable":bool,
//  "authors":[..],"repository":"..","homepage":"..","documentation":"..","tag":[..],"category":[..],
//  "license":[..],"sha256":"..","tarballSize":N,"downloads":N,"publisherName":"..",
//  "createdAt":N,"updatedAt":N}
public class PublicVersionDto <: JsonSerializable {
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

    public init(version: String, cjcVersion: String, description: String, artifactType: String,
                executable: Bool, authors: ArrayList<String>, repository: String, homepage: String,
                documentation: String, tag: ArrayList<String>, category: ArrayList<String>,
                license: ArrayList<String>, sha256: String, tarballSize: Int64, downloads: Int64,
                publisherName: String, createdAt: Int64, updatedAt: Int64) {
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

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
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
        w.writeName("publisherName").writeValue(publisherName)
        w.writeName("createdAt").writeValue(createdAt)
        w.writeName("updatedAt").writeValue(updatedAt)
        w.endObject()
    }
}

// C3 包详情：{"organization":"..","name":"..","fullName":"..","versionCount":N,"latestVersion":"..",
//            "downloads":N,"readme":"..","versions":[<PublicVersionDto>..]}
public class PublicPackageDetailDto <: JsonSerializable {
    public let organization: String
    public let name: String
    public let fullName: String
    public let versionCount: Int64
    public let latestVersion: String
    public let downloads: Int64
    public let readme: String
    public let versions: ArrayList<PublicVersionDto>

    public init(organization: String, name: String, fullName: String, versionCount: Int64,
                latestVersion: String, downloads: Int64, readme: String,
                versions: ArrayList<PublicVersionDto>) {
        this.organization = organization
        this.name = name
        this.fullName = fullName
        this.versionCount = versionCount
        this.latestVersion = latestVersion
        this.downloads = downloads
        this.readme = readme
        this.versions = versions
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("organization").writeValue(organization)
        w.writeName("name").writeValue(name)
        w.writeName("fullName").writeValue(fullName)
        w.writeName("versionCount").writeValue(versionCount)
        w.writeName("latestVersion").writeValue(latestVersion)
        w.writeName("downloads").writeValue(downloads)
        w.writeName("readme").writeValue(readme)
        w.writeName("versions").startArray()
        for (it in versions) {
            w.writeValue(it)
        }
        w.endArray()
        w.endObject()
    }
}

// ===== C5 组织 =====

// {"id":N,"name":"..","displayName":"..","description":"..","isDefault":bool,
//  "packageCount":N,"versionCount":N}
public class PublicOrgDto <: JsonSerializable {
    public let id: Int64
    public let name: String
    public let displayName: String
    public let description: String
    public let isDefault: Bool
    public let packageCount: Int64
    public let versionCount: Int64

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

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(id)
        w.writeName("name").writeValue(name)
        w.writeName("displayName").writeValue(displayName)
        w.writeName("description").writeValue(description)
        w.writeName("isDefault").writeValue(isDefault)
        w.writeName("packageCount").writeValue(packageCount)
        w.writeName("versionCount").writeValue(versionCount)
        w.endObject()
    }
}

// {"total":N,"items":[<PublicOrgDto>..]}
public class PublicOrgListDto <: JsonSerializable {
    public let total: Int64
    public let items: ArrayList<PublicOrgDto>

    public init(total: Int64, items: ArrayList<PublicOrgDto>) {
        this.total = total
        this.items = items
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("total").writeValue(total)
        w.writeName("items").startArray()
        for (it in items) {
            w.writeValue(it)
        }
        w.endArray()
        w.endObject()
    }
}
