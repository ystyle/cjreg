// 包管理主表的分组视图：一个 `org::name` 一行，子表才是各版本。
//
// 纯函数（不碰组件/商店），便于单测：主表要回答的是"这个包有几个版本、最新是哪个、
// 还有没有活着的版本"，而库里的行是**版本级**文档（PackageDoc），必须自己聚合。
package ystyle::cjreg.ui

import std.collection.*
import ystyle::cjreg.store.*
import ystyle::cjreg.semver_range.*

/// 主表一行 = 一个包的聚合视图。
public class PackageRow {
    public var organization: String = ""
    public var name: String = ""
    /// 完整包名 `org::name`（空组织时就是 name），用作选中键与展示。
    public var key: String = ""
    public var latestVersion: String = ""
    public var versionCount: Int64 = 0
    /// 组内最大 updatedAt（"最近更新"）
    public var updatedAt: Int64 = 0
    /// 组内全部版本都已软删（主行标「已删」，子表逐个给恢复/硬删）
    public var allDeleted: Bool = false
    /// 全部版本下载数合计
    public var downloadCount: Int64 = 0
    /// 搜索用的小写文本：组织 + 包名 + 各版本描述 + 各版本号
    public var searchText: String = ""

    public init() {}
}

/// 包展示名：组织为空时只给包名。
public func pkgKeyText(organization: String, name: String): String {
    if (organization == "") { name } else { "${organization}::${name}" }
}

/// 按 `org::name` 聚合版本级文档；组内保持首次出现顺序（库里按 id 升序）。
public func groupPackages(all: ArrayList<PackageDoc>): ArrayList<PackageRow> {
    let pos = HashMap<String, Int64>()
    let out = ArrayList<PackageRow>()
    for (d in all) {
        let key = pkgKeyText(d.organization, d.name)
        match (pos.get(key)) {
            case Some(i) =>
                let row = out[i]
                row.versionCount++
                row.downloadCount += d.downloadCount
                if (d.deletedAt == 0) { row.allDeleted = false }
                if (d.updatedAt > row.updatedAt) { row.updatedAt = d.updatedAt }
                if (compareVersions(d.version, row.latestVersion) > 0) {
                    row.latestVersion = d.version
                }
                if (!d.description.isEmpty()) {
                    row.searchText += " " + d.description.toAsciiLower()
                }
            case None =>
                let row = PackageRow()
                row.organization = d.organization
                row.name = d.name
                row.key = key
                row.latestVersion = d.version
                row.versionCount = 1
                row.updatedAt = d.updatedAt
                row.allDeleted = d.deletedAt != 0
                row.downloadCount = d.downloadCount
                row.searchText = (key + " " + d.version + " " + d.description).toAsciiLower()
                pos.add(key, out.size)
                out.add(row)
        }
    }
    out
}

/// 主表搜索：组织/包名/描述/版本号 包含关键字（q 需已 trim + 小写；空词 = 全命中）。
public func matchesPackage(row: PackageRow, q: String): Bool {
    if (q == "") { return true }
    row.searchText.contains(q)
}
