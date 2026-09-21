// 主表分组与搜索：一个 org::name 一行，最新版本按 semver 取，全删要标出来。
package ystyle::cjreg.ui

import std.collection.*
import ystyle::cjreg.store.*
import std.unittest.*
import std.unittest.testmacro.*

func pkg(org: String, name: String, version: String, desc!: String = "",
         deleted!: Bool = false, updatedAt!: Int64 = 0, downloads!: Int64 = 0): PackageDoc {
    let d = PackageDoc()
    d.organization = org
    d.name = name
    d.version = version
    d.description = desc
    d.deletedAt = if (deleted) { 1 } else { 0 }
    d.updatedAt = updatedAt
    d.downloadCount = downloads
    d
}

@Test
func groupPackages_aggregatesLatestCountAndDeleted() {
    let all = ArrayList<PackageDoc>()
    all.add(pkg("ystyle", "crc", "1.0.0", downloads: 3, updatedAt: 100))
    all.add(pkg("ystyle", "crc", "1.0.10", downloads: 4, updatedAt: 300))
    all.add(pkg("ystyle", "crc", "1.0.2", deleted: true, updatedAt: 200))
    all.add(pkg("", "docker", "0.1.0", downloads: 1, updatedAt: 50))

    let rows = groupPackages(all)
    @Expect(rows.size, 2)
    @Expect(rows[0].key, "ystyle::crc")
    @Expect(rows[0].versionCount, 3)
    // semver 比较而不是字典序：1.0.10 > 1.0.2
    @Expect(rows[0].latestVersion, "1.0.10")
    @Expect(rows[0].downloadCount, 7)
    @Expect(rows[0].updatedAt, 300)
    @Expect(rows[0].allDeleted, false)        // 还有活版本
    @Expect(rows[1].key, "docker")            // 空组织只给包名
    @Expect(rows[1].versionCount, 1)
}

@Test
func groupPackages_marksFullyDeletedGroup() {
    let all = ArrayList<PackageDoc>()
    all.add(pkg("ystyle", "gone", "1.0.0", deleted: true))
    all.add(pkg("ystyle", "gone", "1.1.0", deleted: true))
    let rows = groupPackages(all)
    @Expect(rows.size, 1)
    @Expect(rows[0].allDeleted, true)
    @Expect(rows[0].versionCount, 2)
}

@Test
func matchesPackage_hitsOrgNameDescVersion() {
    let all = ArrayList<PackageDoc>()
    all.add(pkg("ystyle", "JsonRpc", "0.7.7", desc: "JSON-RPC 框架"))
    let row = groupPackages(all)[0]

    @Expect(matchesPackage(row, ""), true)
    @Expect(matchesPackage(row, "ystyle"), true)
    @Expect(matchesPackage(row, "jsonrpc"), true)    // 包名大小写不敏感
    @Expect(matchesPackage(row, "0.7.7"), true)      // 版本号可搜
    @Expect(matchesPackage(row, "框架"), true)        // 描述可搜
    @Expect(matchesPackage(row, "nope"), false)
}
