// 组织 CRUD 服务层单元测试：名称校验 / 唯一性 / 改名守卫 / 删除守卫 / 默认唯一化 / JSON
package ystyle::cjreg.server

import ystyle::cjreg.store.*
import bstorm.*
import std.unittest.testmacro.*
import std.collection.*

func makeOrgFixture(): (PackageStore, AdminDataStore) {
    beginTestStores()
    let storm = testStorm()
    (PackageStore(storm), AdminDataStore(storm))
}

func makeOrgPkg(org: String, name: String, version: String): PackageDoc {
    let d = PackageDoc()
    d.organization = org
    d.name = name
    d.version = version
    d.sha256 = "sha-${org}-${name}-${version}"
    d
}

@Test
func testValidateOrgNameAndOrgJson() {
    // 名称校验（纯逻辑，不建 storm）
    @Expect(validateOrgName("test"), "")
    @Expect(validateOrgName("my-org_1"), "")
    @Expect(validateOrgName("A1"), "")
    @Expect(validateOrgName("").isEmpty(), false)                    // 空
    @Expect(validateOrgName("has space").contains("只允许"), true)     // 空格
    @Expect(validateOrgName("中文组织").contains("只允许"), true)       // 非 ASCII
    @Expect(validateOrgName("a/b").contains("只允许"), true)          // 路径字符
    let long65 = StringBuilder()
    let long64 = StringBuilder()
    for (i in 0..65) {
        long65.append("x")
        if (i < 64) {
            long64.append("x")
        }
    }
    @Expect(validateOrgName(long65.toString()).contains("过长"), true)
    @Expect(validateOrgName(long64.toString()), "")

    // JSON 形状（OrgDoc 可直接构造，不建 storm）
    let o = OrgDoc()
    o.id = 7
    o.name = "test"
    o.displayName = "测试\"组织\""
    o.description = "desc"
    o.isDefault = true
    o.ownerId = 1
    o.createdAt = 100
    o.updatedAt = 200
    let json = orgJson(o, 2, 3, 1)
    @Expect(json.contains("\"id\":7"), true)
    @Expect(json.contains("\"name\":\"test\""), true)
    @Expect(json.contains("测试\\\"组织\\\""), true)          // 引号转义
    @Expect(json.contains("\"isDefault\":true"), true)
    @Expect(json.contains("\"packageCount\":2"), true)
    @Expect(json.contains("\"versionCount\":3"), true)
    @Expect(json.contains("\"teamCount\":1"), true)
    let listJson = orgListJson(ArrayList<String>([json]), 1)
    @Expect(listJson.contains("\"total\":1"), true)
    @Expect(orgListJson(ArrayList<String>(), 0), "{\"total\":0,\"items\":[]}")
    // 结果 JSON 与状态码
    let ok = OrgResult(OrgOutcome.Ok, "已创建组织 #1", 1, 0)
    @Expect(orgResultJson(ok).contains("\"status\":\"ok\""), true)
    @Expect(orgResultCode(ok), 200u16)
    @Expect(orgResultCode(OrgResult(OrgOutcome.NotFound, "x", 0, 0)), 404u16)
    @Expect(orgResultCode(OrgResult(OrgOutcome.InvalidName, "x", 0, 0)), 400u16)
    @Expect(orgResultCode(OrgResult(OrgOutcome.DuplicateName, "x", 0, 0)), 409u16)
    @Expect(orgResultCode(OrgResult(OrgOutcome.HasPackages, "x", 0, 0)), 409u16)
    @Expect(orgResultCode(OrgResult(OrgOutcome.ReferencedByTeams, "x", 0, 0)), 409u16)
    @Expect(orgResultCode(OrgResult(OrgOutcome.RenameWithPackages, "x", 0, 0)), 409u16)
    @Expect(orgResultCode(OrgResult(OrgOutcome.Failed, "x", 0, 0)), 500u16)
    @Expect(orgResultJson(OrgResult(OrgOutcome.HasPackages, "仍有 \"2\" 个包", 5, 2))
        .contains("\"status\":\"has_packages\""), true)
    @Expect(orgResultJson(OrgResult(OrgOutcome.HasPackages, "仍有 \"2\" 个包", 5, 2))
        .contains("\\\"2\\\""), true)
}

@Test
func testCreateOrgGuardsAndDefaultUniqueness() {
    let (_, ad) = makeOrgFixture()
    // 非法名 → InvalidName
    @Expect(createOrgChecked(ad, "bad name", "", "", false, 1, 100).outcome == OrgOutcome.InvalidName, true)
    // 创建成功（字段落库）
    let ok = createOrgChecked(ad, "test", "测试组织", "描述", true, 1, 100)
    @Expect(ok.outcome == OrgOutcome.Ok, true)
    @Expect(ok.orgId > 0, true)
    @Expect(ad.listOrgs().size, 1)
    let o = ad.getOrg(ok.orgId).getOrThrow()
    @Expect(o.displayName, "测试组织")
    @Expect(o.description, "描述")
    @Expect(o.ownerId, 1)
    @Expect(o.createdAt, 100)
    @Expect(o.isDefault, true)
    // 重名 → DuplicateName
    @Expect(createOrgChecked(ad, "test", "", "", false, 1, 200).outcome == OrgOutcome.DuplicateName, true)
    @Expect(ad.listOrgs().size, 1)
    // 第二个默认 → 第一个被清掉（affected=1）
    let b = createOrgChecked(ad, "b", "", "", true, 1, 200)
    @Expect(b.outcome == OrgOutcome.Ok, true)
    @Expect(b.affected, 1)
    @Expect(ad.getOrg(ok.orgId).getOrThrow().isDefault, false)
    @Expect(ad.getOrg(b.orgId).getOrThrow().isDefault, true)
    // 非默认创建不影响默认标记
    let c = createOrgChecked(ad, "c", "", "", false, 1, 300)
    @Expect(c.outcome == OrgOutcome.Ok, true)
    @Expect(c.affected, 0)
    @Expect(ad.getOrg(b.orgId).getOrThrow().isDefault, true)
    // 已删除的组织名可复用
    @Expect(ad.deleteOrg(ok.orgId, 400), true)
    @Expect(createOrgChecked(ad, "test", "", "", false, 1, 500).outcome == OrgOutcome.Ok, true)
}

@Test
func testUpdateOrgRenameAndGuards() {
    let (pkgStore, ad) = makeOrgFixture()
    let id = createOrgChecked(ad, "test", "旧名", "旧描述", false, 1, 100).orgId
    let other = createOrgChecked(ad, "other", "", "", false, 1, 100).orgId
    let delId = createOrgChecked(ad, "gone", "", "", false, 1, 100).orgId
    @Expect(ad.deleteOrg(delId, 150), true)
    // 不存在 / 已删除 → NotFound
    @Expect(updateOrgChecked(pkgStore, ad, 999, "", "x", "", false, 200).outcome == OrgOutcome.NotFound, true)
    @Expect(updateOrgChecked(pkgStore, ad, delId, "", "x", "", false, 200).outcome == OrgOutcome.NotFound, true)
    // 无包时可改名
    let renamed = updateOrgChecked(pkgStore, ad, id, "test2", "新名", "新描述", false, 300)
    @Expect(renamed.outcome == OrgOutcome.Ok, true)
    @Expect(ad.getOrg(id).getOrThrow().name, "test2")
    @Expect(ad.getOrg(id).getOrThrow().displayName, "新名")
    @Expect(ad.getOrg(id).getOrThrow().updatedAt, 300)
    // 撞名 / 非法名
    @Expect(updateOrgChecked(pkgStore, ad, id, "other", "", "", false, 400).outcome == OrgOutcome.DuplicateName, true)
    @Expect(updateOrgChecked(pkgStore, ad, id, "bad name", "", "", false, 400).outcome == OrgOutcome.InvalidName, true)
    // 有包后禁止改名，但允许改显示名/描述
    pkgStore.save(makeOrgPkg("test2", "demo", "1.0.0"))
    let blocked = updateOrgChecked(pkgStore, ad, id, "test3", "", "", false, 500)
    @Expect(blocked.outcome == OrgOutcome.RenameWithPackages, true)
    @Expect(blocked.affected, 1)
    @Expect(ad.getOrg(id).getOrThrow().name, "test2")
    @Expect(updateOrgChecked(pkgStore, ad, id, "test2", "改显示名", "改描述", false, 600).outcome == OrgOutcome.Ok, true)
    @Expect(ad.getOrg(id).getOrThrow().displayName, "改显示名")
    // 设为默认时清除其它默认
    @Expect(ad.updateOrg(other, "", "", true, 600), true)
    let setDefault = updateOrgChecked(pkgStore, ad, id, "", "", "", true, 700)
    @Expect(setDefault.outcome == OrgOutcome.Ok, true)
    @Expect(setDefault.affected, 1)
    @Expect(ad.getOrg(other).getOrThrow().isDefault, false)
}

@Test
func testDeleteOrgGuardsAndStats() {
    let (pkgStore, ad) = makeOrgFixture()
    let id = createOrgChecked(ad, "test", "", "", false, 1, 100).orgId
    @Expect(deleteOrgChecked(pkgStore, ad, 999, 200).outcome == OrgOutcome.NotFound, true)
    // 统计：2 包 / 3 版本（软删版本不计入）
    pkgStore.save(makeOrgPkg("test", "demo", "1.0.0"))
    pkgStore.save(makeOrgPkg("test", "demo", "1.1.0"))
    let deleted = makeOrgPkg("test", "demo", "1.2.0")
    pkgStore.save(deleted)
    pkgStore.softDelete(deleted, 200)
    pkgStore.save(makeOrgPkg("test", "util", "0.1.0"))
    pkgStore.save(makeOrgPkg("other", "tool", "1.0.0"))
    let (pkgs, versions) = orgPackageStats(pkgStore, "test")
    @Expect(pkgs, 2)
    @Expect(versions, 3)
    let (emptyPkgs, emptyVersions) = orgPackageStats(pkgStore, "")
    @Expect(emptyPkgs, 0)
    @Expect(emptyVersions, 0)
    // 有包 → HasPackages（优先于团队关联检查）
    let blocked = deleteOrgChecked(pkgStore, ad, id, 300)
    @Expect(blocked.outcome == OrgOutcome.HasPackages, true)
    @Expect(blocked.affected, 2)
    @Expect(ad.listOrgs().size, 1)
    // 软删全部包后，仍被团队关联 → ReferencedByTeams
    for (d in pkgStore.listVersions("test", "demo")) {
        pkgStore.softDelete(d, 350)
    }
    for (d in pkgStore.listVersions("test", "util")) {
        pkgStore.softDelete(d, 350)
    }
    let t1 = ad.createTeam("t1", 0, permission: "read")
    let t2 = ad.createTeam("t2", 0, permission: "write")
    ad.setTeamOrganizations(t1, [id], 0)
    ad.setTeamOrganizations(t2, [id], 0)
    @Expect(orgReferencingTeams(ad, id).size, 2)
    @Expect(orgReferencingTeams(ad, 999).size, 0)
    let ref = deleteOrgChecked(pkgStore, ad, id, 400)
    @Expect(ref.outcome == OrgOutcome.ReferencedByTeams, true)
    @Expect(ref.affected, 2)
    @Expect(ref.message.contains("t1"), true)
    @Expect(ref.message.contains("2 个团队"), true)
    // 解除团队关联后可删除
    ad.setTeamOrganizations(t1, Array<Int64>(), 500)
    ad.setTeamOrganizations(t2, Array<Int64>(), 500)
    let ok = deleteOrgChecked(pkgStore, ad, id, 700)
    @Expect(ok.outcome == OrgOutcome.Ok, true)
    @Expect(ad.listOrgs().size, 0)
    @Expect(deleteOrgChecked(pkgStore, ad, id, 800).outcome == OrgOutcome.NotFound, true)
}
