// 用户门户只读模型单元测试（我的包 / 我的团队 / Token 掩码 / 权限提示）
package ystyle::cjreg.server

import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.util.*
import bstorm.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

func makePortalFixture(): (PackageStore, AuthService, AdminDataStore) {
    PasswordHash.ITERATIONS = 1000  // 测试提速
    beginTestStores()
    let storm = testStorm()
    let pkgStore = PackageStore(storm)
    let userStore = BstormUserStore(storm)
    let authSvc = AuthService(userStore, 3600)
    let adminData = AdminDataStore(storm)
    (pkgStore, authSvc, adminData)
}

func saveVersion(store: PackageStore, org: String, name: String, version: String, publisherId: Int64, updatedAt: Int64) {
    let d = PackageDoc()
    d.organization = org
    d.name = name
    d.version = version
    d.publisherId = publisherId
    d.createdAt = updatedAt
    d.updatedAt = updatedAt
    store.save(d)
}

@Test
public class UserServiceTest {
    // 我的包：owner = 最早版本的发布者；协作者也在列表里（含参与过的包）
    @TestCase
    public func testMyPackagesOwnerVsContributor(): Unit {
        let (store, auth, adminData) = makePortalFixture()
        let alice = auth.createUser("alice", "AlicePass1", false).getOrThrow()
        let bob = auth.createUser("bob", "BobPass1", false).getOrThrow()
        let carol = auth.createUser("carol", "CarolPass1", false).getOrThrow()
        saveVersion(store, "test", "demo", "1.0.0", alice.id, 1000)
        saveVersion(store, "test", "demo", "1.1.0", bob.id, 2000)

        let aliceRows = myPackageRows(store, adminData, alice.id)
        @Expect(aliceRows.size, 1)
        @Expect(aliceRows[0].displayName(), "test::demo")
        @Expect(aliceRows[0].isOwner, true)
        @Expect(aliceRows[0].versionCount, 2)
        @Expect(aliceRows[0].latestVersion, "1.1.0")
        @Expect(aliceRows[0].updatedAt, 2000)

        let bobRows = myPackageRows(store, adminData, bob.id)
        @Expect(bobRows.size, 1)
        @Expect(bobRows[0].isOwner, false)  // 协作者：发过版本但不是 owner

        @Expect(myPackageRows(store, adminData, carol.id).size, 0)
    }

    // 无组织包与有组织包分别聚合；软删版本不计入版本数，但历史贡献保留（仍出现在列表）
    @TestCase
    public func testMyPackagesSoftDeleteKeepsHistory(): Unit {
        let (store, auth, adminData) = makePortalFixture()
        let alice = auth.createUser("alice", "AlicePass1", false).getOrThrow()
        saveVersion(store, "", "plain", "1.0.0", alice.id, 1000)
        saveVersion(store, "org", "owned", "1.0.0", alice.id, 1200)
        saveVersion(store, "org", "owned", "2.0.0", alice.id, 1500)

        let rows = myPackageRows(store, adminData, alice.id)
        @Expect(rows.size, 2)
        var plainFound = false
        var ownedFound = false
        for (r in rows) {
            if (r.name == "plain") {
                plainFound = true
                @Expect(r.displayName(), "plain")
                @Expect(r.isOwner, true)
            }
            if (r.name == "owned") {
                ownedFound = true
                @Expect(r.versionCount, 2)
                @Expect(r.latestVersion, "2.0.0")
            }
        }
        @Expect(plainFound, true)
        @Expect(ownedFound, true)

        // 软删最新版本：不计入版本数，但仍是我发过的包（历史贡献）
        for (d in store.listVersions("org", "owned")) {
            if (d.version == "2.0.0") {
                store.softDelete(d, 3000)
            }
        }
        let after = myPackageRows(store, adminData, alice.id)
        var ownedAfter = false
        for (r in after) {
            if (r.name == "owned") {
                ownedAfter = true
                @Expect(r.versionCount, 1)
                @Expect(r.latestVersion, "1.0.0")
                @Expect(r.isOwner, true)  // owner 取最早一条版本记录，不受软删影响
            }
        }
        @Expect(ownedAfter, true)
    }

    // 只列出「我所属」的团队，并带权限与关联组织/包
    @TestCase
    public func testMyTeams(): Unit {
        let (_, auth, adminData) = makePortalFixture()
        let alice = auth.createUser("alice", "AlicePass1", false).getOrThrow()
        let bob = auth.createUser("bob", "BobPass1", false).getOrThrow()
        let orgId = adminData.createOrg("test", "Test", 1, 0)
        let teamId = adminData.createTeam("writers", 0, displayName: "写手组", permission: "write")
        adminData.setTeamOrganizations(teamId, [orgId], 0)
        let pairs = ArrayList<(String, String)>()
        pairs.add(("test", "demo"))
        pairs.add(("", "plain"))
        adminData.setTeamPackages(teamId, pairs.toArray(), 0)
        adminData.setTeamMembers(teamId, [alice.id])
        // 无组织关联团队（验证「无组织包」文案与不相关团队被排除）
        let other = adminData.createTeam("no-org-team", 0, permission: "read")
        adminData.setTeamOrganizations(other, [0], 0)
        adminData.setTeamMembers(other, [bob.id])

        let rows = myTeamRows(adminData, alice.id)
        @Expect(rows.size, 1)
        @Expect(rows[0].teamId, teamId)
        @Expect(rows[0].label(), "写手组")
        @Expect(rows[0].permission, "write")
        @Expect(rows[0].orgNames.size, 1)
        @Expect(rows[0].orgNames[0], "test")
        @Expect(rows[0].packages.size, 2)
        @Expect(rows[0].packages[0], "test::demo")
        @Expect(rows[0].packages[1], "plain")

        let bobRows = myTeamRows(adminData, bob.id)
        @Expect(bobRows.size, 1)
        @Expect(bobRows[0].orgNames[0], "（无组织包）")
        @Expect(bobRows[0].packages.size, 0)
    }

    @TestCase
    public func testMaskToken(): Unit {
        @Expect(maskToken("publish-abcdefgh"), "****abcdefgh")
        @Expect(maskToken("short"), "****")
        @Expect(maskToken(""), "****")
    }

    @TestCase
    public func testPermissionHint(): Unit {
        @Expect(permissionHint("team").contains("团队模式"), true)
        @Expect(permissionHint("team").contains("overwrite"), true)
        @Expect(permissionHint("open").contains("开放模式"), true)
        @Expect(permissionHint("").contains("开放模式"), true)
    }
}
