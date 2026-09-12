// 公开只读 API（C1–C5）读模型单元测试：过滤/排序/分页/可见性/JSON 形状
package ystyle::cjreg.server

import ystyle::cjreg.store.*
import ystyle::cjreg.auth.model.*
import bstorm.*
import std.unittest.testmacro.*
import std.collection.*

// 造一个包文档（按需覆盖常用展示字段）
func makePkgDoc(org: String, name: String, version: String, desc: String, publisherId: Int64,
                downloads: Int64, size: Int64, updatedAt: Int64, cats: Array<String>): PackageDoc {
    let d = PackageDoc()
    d.organization = org
    d.name = name
    d.version = version
    d.description = desc
    d.publisherId = publisherId
    d.downloadCount = downloads
    d.tarballSize = size
    d.updatedAt = updatedAt
    d.createdAt = updatedAt
    d.sha256 = "sha-" + version
    d.category = ArrayList<String>(cats)
    d.license = ArrayList<String>(["MIT"])
    d.readme = "# ${name}"
    d
}

// 用户对象直接构造（无需 AuthService/用户库）：权限裁决只读 id/isAdmin
func makePublicUser(id: Int64, name: String, isAdmin: Bool): User {
    User(id, name, "hash-${name}", isAdmin, true, "tok-${name}")
}

// 单 Storm 共享（与 main.cj 一致：PackageStore/AdminDataStore 同库）——每个 Storm 都会分配
// skiplist arena，测试里多开实例会撞 GC 堆上限（默认 256MB）导致 OutOfMemoryError
func makePublicFixture(): (PackageStore, AdminDataStore) {
    let storm = Storm.inMemory()
    let store = PackageStore(storm)
    let adminData = AdminDataStore(storm)
    // test 组织：demo 两个版本（1.0.0 旧 / 1.1.0 新）+ util 一个版本；other 组织：tool
    store.save(makePkgDoc("test", "demo", "1.0.0", "demo old", 1, 3, 100, 1000, ["cli"]))
    store.save(makePkgDoc("test", "demo", "1.1.0", "demo new", 1, 7, 200, 3000, ["cli", "web"]))
    store.save(makePkgDoc("test", "util", "0.1.0", "util pkg", 2, 1, 50, 2000, ["lib"]))
    store.save(makePkgDoc("other", "tool", "2.0.0", "tool pkg", 2, 5, 20, 4000, ["web"]))
    (store, adminData)
}

@Test
func testSplitOrgQuery() {
    let (o1, k1) = splitOrgQuery("test::demo")
    @Expect(o1, "test")
    @Expect(k1, "demo")
    let (o2, k2) = splitOrgQuery("test::")
    @Expect(o2, "test")
    @Expect(k2, "")
    let (o3, k3) = splitOrgQuery("::demo")
    @Expect(o3, "")
    @Expect(k3, "demo")
    let (o4, k4) = splitOrgQuery("  demo  ")
    @Expect(o4, "")
    @Expect(k4, "demo")
    let (o5, k5) = splitOrgQuery(" test :: demo ")
    @Expect(o5, "test")
    @Expect(k5, "demo")
}

@Test
func testSplitCommaListAndPageWindow() {
    let cats = splitCommaList("cli, web ,,lib")
    @Expect(cats.size, 3)
    @Expect(cats[0], "cli")
    @Expect(cats[2], "lib")
    @Expect(splitCommaList("").size, 0)
    // 分页窗口：page/size 归一 + 越界
    let (s1, e1) = pageWindow(10, 1, 3)
    @Expect(s1, 0)
    @Expect(e1, 3)
    let (s2, e2) = pageWindow(10, 4, 3)
    @Expect(s2, 9)
    @Expect(e2, 10)
    let (s3, e3) = pageWindow(10, 9, 3)
    @Expect(s3, 24)
    @Expect(e3, 10)   // 越界页返回空窗口
    let (s4, e4) = pageWindow(10, 0, 0)   // page<1 → 1；size<1 → 20
    @Expect(s4, 0)
    @Expect(e4, 10)
    let (s5, e5) = pageWindow(500, 1, 999)   // size 上限 100
    @Expect(s5, 0)
    @Expect(e5, 100)
}

@Test
func testCollectAndFilterPublicPackages() {
    let (store, adminData) = makePublicFixture()
    let rows = collectPublicPackages(store, adminData, None, false)
    @Expect(rows.size, 3)   // test::demo、test::util、other::tool

    // 默认排序：更新时间倒序
    let sorted = filterPublicPackages(rows, "", "", ArrayList<String>(), "updated")
    @Expect(sorted[0].fullName(), "other::tool")
    @Expect(sorted[1].fullName(), "test::demo")
    @Expect(sorted[2].fullName(), "test::util")

    // 聚合字段：demo 两个版本、下载 10、最新版本 1.1.0 及其描述/分类
    var demo: ?PublicPackageRow = None
    for (r in rows) {
        if (r.name == "demo") {
            demo = Some(r)
        }
    }
    let d = demo.getOrThrow()
    @Expect(d.versionCount, 2)
    @Expect(d.downloads, 10)
    @Expect(d.latestVersion, "1.1.0")
    @Expect(d.description, "demo new")
    @Expect(d.categories.size, 2)

    // organization 过滤
    let onlyTest = filterPublicPackages(rows, "", "test", ArrayList<String>(), "updated")
    @Expect(onlyTest.size, 2)

    // `org::name` 语法
    let orgSyntax = filterPublicPackages(rows, "test::util", "", ArrayList<String>(), "updated")
    @Expect(orgSyntax.size, 1)
    @Expect(orgSyntax[0].name, "util")
    // 语法组织与显式 organization 冲突 → 空
    @Expect(filterPublicPackages(rows, "test::util", "other", ArrayList<String>(), "updated").size, 0)

    // 关键字：命中名称 / 描述 / 组织
    @Expect(filterPublicPackages(rows, "tool", "", ArrayList<String>(), "updated").size, 1)
    @Expect(filterPublicPackages(rows, "util pkg", "", ArrayList<String>(), "updated").size, 1)

    // 分类 OR（web 命中 demo 与 tool）
    let web = splitCommaList("web")
    @Expect(filterPublicPackages(rows, "", "", web, "updated").size, 2)
    let webLib = splitCommaList("web,lib")
    @Expect(filterPublicPackages(rows, "", "", webLib, "updated").size, 3)
    @Expect(filterPublicPackages(rows, "", "", splitCommaList("nope"), "updated").size, 0)

    // 排序：下载量倒序 / 名称升序
    let byDownloads = filterPublicPackages(rows, "", "", ArrayList<String>(), "downloads")
    @Expect(byDownloads[0].name, "demo")   // 10 > 5 > 1
    let byName = filterPublicPackages(rows, "", "", ArrayList<String>(), "name")
    @Expect(byName[0].fullName(), "other::tool")
    @Expect(byName[1].fullName(), "test::demo")
}

@Test
func testSoftDeletedVersionHiddenFromPublic() {
    let (store, adminData) = makePublicFixture()
    // 软删 demo 1.1.0 → 最新版本回退到 1.0.0
    for (d in store.listVersions("test", "demo")) {
        if (d.version == "1.1.0") {
            store.softDelete(d, 5000)
        }
    }
    let rows = collectPublicPackages(store, adminData, None, false)
    for (r in rows) {
        if (r.name == "demo") {
            @Expect(r.versionCount, 1)
            @Expect(r.latestVersion, "1.0.0")
            @Expect(r.description, "demo old")
        }
    }
    // 软删后版本详情不可见
    @Expect(publicVersion(store, "test", "demo", "1.1.0", { _ => "alice" }).isNone(), true)
    // 全部版本软删 → 包从公开列表消失
    for (d in store.listVersions("other", "tool")) {
        store.softDelete(d, 5000)
    }
    let after = collectPublicPackages(store, adminData, None, false)
    for (r in after) {
        @Expect(r.name != "tool", true)
    }
}

@Test
func testPublicStatsModel() {
    let (store, adminData) = makePublicFixture()
    let _ = adminData.createOrg("test", "Test", 1, 0)
    let _ = adminData.createTeam("readers", 0, permission: "read")
    let s = publicStatsModel(store, adminData, 2, 1000, 61000)
    @Expect(s.packages, 3)
    @Expect(s.versions, 4)
    @Expect(s.downloads, 16)
    @Expect(s.storageBytes, 370)
    @Expect(s.organizations, 2)   // 已登记的 test + 有包但未登记的 other（与 /api/organizations 口径一致）
    @Expect(s.teams, 1)
    @Expect(s.users, 2)
    @Expect(s.serverVersion, CJREG_SERVER_VERSION)
    @Expect(s.uptimeSeconds, 60)
    // startedAt=0（未记录）时不上报负数
    let s2 = publicStatsModel(store, adminData, 0, 0, 61000)
    @Expect(s2.uptimeSeconds, 0)
}

@Test
func testPublicVersionsOrderAndDetail() {
    let (store, _) = makePublicFixture()
    let resolver: (Int64) -> String = { id => if (id == 1) { "alice" } else { "bob" } }
    let rows = publicVersions(store, "test", "demo", resolver)
    @Expect(rows.size, 2)
    @Expect(rows[0].version, "1.1.0")   // 版本降序
    @Expect(rows[1].version, "1.0.0")
    @Expect(rows[0].publisherName, "alice")
    @Expect(rows[0].downloads, 7)
    @Expect(rows[0].tarballSize, 200)
    // 指定版本
    match (publicVersion(store, "test", "demo", "1.0.0", resolver)) {
        case Some(v) =>
            @Expect(v.version, "1.0.0")
            @Expect(v.description, "demo old")
        case None => @Fail("1.0.0 应存在")
    }
    // version 为空 → 最新
    match (publicVersion(store, "test", "demo", "", resolver)) {
        case Some(v) => @Expect(v.version, "1.1.0")
        case None => @Fail("应取最新版本")
    }
    // 补零版本比较：1.0.0 vs 1.0.0 → 取到；0.9.0 不存在
    @Expect(publicVersion(store, "test", "demo", "0.9.0", resolver).isNone(), true)
    @Expect(publicVersion(store, "test", "nope", "", resolver).isNone(), true)
}

@Test
func testPublicOrgRowsCounts() {
    let (store, adminData) = makePublicFixture()
    let _ = adminData.createOrg("test", "测试组织", 1, 0)
    let _ = adminData.createOrg("empty", "空组织", 1, 0)
    // other 组织有包但未在组织表登记 → 合成行（id=0）；按名称升序：empty、other、test
    let rows = publicOrgRows(store, adminData, None, false)
    @Expect(rows.size, 3)
    @Expect(rows[0].name, "empty")
    @Expect(rows[0].packageCount, 0)
    @Expect(rows[0].id > 0, true)
    @Expect(rows[1].name, "other")
    @Expect(rows[1].id, 0)
    @Expect(rows[1].displayName, "")
    @Expect(rows[1].packageCount, 1)
    @Expect(rows[1].versionCount, 1)
    @Expect(rows[2].name, "test")
    @Expect(rows[2].id > 0, true)
    @Expect(rows[2].packageCount, 2)   // demo、util
    @Expect(rows[2].versionCount, 3)
    @Expect(rows[2].displayName, "测试组织")
}

@Test
func testPrivateModeVisibilityFiltering() {
    let (store, adminData) = makePublicFixture()
    let alice = makePublicUser(1, "alice", false)   // demo 的发布者（普通用户：只可见自己发布的包）
    let bob = makePublicUser(2, "bob", false)      // tool 的发布者
    // requireAuth=true：只看到自己可读的包（alice 发布过 test::demo）
    let aliceRows = collectPublicPackages(store, adminData, Some(alice), true)
    let aliceNames = ArrayList<String>()
    for (r in aliceRows) {
        aliceNames.add(r.fullName())
    }
    @Expect(aliceNames.contains("test::demo"), true)
    @Expect(aliceNames.size, 1)   // 只可见自己发布的 demo
    @Expect(aliceNames.contains("other::tool"), false)
    // 未登录 → 空
    @Expect(collectPublicPackages(store, adminData, None, true).size, 0)
    // 团队授权后 bob 可见 test 组织（read）
    let orgId = adminData.createOrg("test", "Test", 1, 0)
    let teamId = adminData.createTeam("readers", 0, permission: "read")
    adminData.setTeamOrganizations(teamId, [orgId], 0)
    adminData.setTeamMembers(teamId, [bob.id])
    let bobRows = collectPublicPackages(store, adminData, Some(bob), true)
    let bobNames = ArrayList<String>()
    for (r in bobRows) {
        bobNames.add(r.fullName())
    }
    @Expect(bobNames.contains("test::demo"), true)
    @Expect(bobNames.contains("test::util"), true)
    // 组织列表同样按可见性过滤（空组织不下发）
    let orgRows = publicOrgRows(store, adminData, Some(bob), true)
    for (r in orgRows) {
        @Expect(r.name != "empty", true)
    }
}

@Test
func testPublicJsonShapes() {
    let (store, adminData) = makePublicFixture()
    let rows = collectPublicPackages(store, adminData, None, false)
    let listJson = publicPackageListJson(rows, rows.size, 1, 20)
    @Expect(listJson.contains("\"total\":3"), true)
    @Expect(listJson.contains("\"fullName\":\"test::demo\""), true)
    @Expect(listJson.contains("\"versionCount\":2"), true)
    @Expect(listJson.contains("\"categories\":[\"cli\",\"web\"]"), true)

    // 分页：本页 1 条、total 仍为 3
    let pageJson = publicPackageListJson(rows, rows.size, 2, 1)
    @Expect(pageJson.contains("\"total\":3"), true)
    @Expect(pageJson.contains("\"page\":2"), true)

    let versions = publicVersions(store, "test", "demo", { _ => "alice" })
    let detailJson = publicPackageDetailJson("test", "demo", versions, "# demo\n含 \"引号\" 与 \\\\ 反斜杠")
    @Expect(detailJson.contains("\"versionCount\":2"), true)
    @Expect(detailJson.contains("\"latestVersion\":\"1.1.0\""), true)
    @Expect(detailJson.contains("\"downloads\":10"), true)
    @Expect(detailJson.contains("\\\"引号\\\""), true)          // README 引号被转义
    @Expect(detailJson.contains("\\\\"), true)                  // 反斜杠被转义
    @Expect(detailJson.contains("\"publisherName\":\"alice\""), true)

    let statsJson = publicStatsJson(publicStatsModel(store, adminData, 2, 0, 0))
    @Expect(statsJson.contains("\"packages\":3"), true)
    @Expect(statsJson.contains("\"serverVersion\":\"${CJREG_SERVER_VERSION}\""), true)

    let _ = adminData.createOrg("test", "测试\"组织\"", 1, 0)
    let orgJson = publicOrgListJson(publicOrgRows(store, adminData, None, false))
    // 已登记的 test + 未登记的 other（有包）→ 2 行
    @Expect(orgJson.contains("\"total\":2"), true)
    @Expect(orgJson.contains("测试\\\"组织\\\""), true)          // 组织显示名转义
    @Expect(orgJson.contains("\"packageCount\":2"), true)
    @Expect(orgJson.contains("\"name\":\"other\",\"displayName\":\"\",\"description\":\"\",\"isDefault\":false"), true)

    // 字符串数组序列化
    @Expect(jsonStringArray(ArrayList<String>()), "[]")
    @Expect(jsonStringArray(ArrayList<String>(["a", "b\"c"])), "[\"a\",\"b\\\"c\"]")
}
