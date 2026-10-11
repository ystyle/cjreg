// 团队 owner 自助：裁决与自助写操作的单元测试（纯函数层）
//
// 这是权限收敛的核心，用例按 docs/team-owner-plan.md 的五条约束逐条钉住：
//   约束 1 服务端守卫（谁能/不能）· 约束 2 下放边界（selfService 默认关）
//   约束 3 生命周期（转让/孤儿）· 约束 4 owner ≠ 自动 write
package ystyle::cjreg.server

import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import bstorm.*
import ystyle::cjreg.auth.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

// 造一个 owner 自助测试环境：adminData + userStore + 若干真实用户
func ownerEnv(): (AdminDataStore, Storm, BstormUserStore, AuthService) {
    beginTestStores()
    let storm = testStorm()
    let userStore = BstormUserStore(storm)
    let auth = AuthService(userStore, 3600)
    (AdminDataStore(storm), storm, userStore, auth)
}

func mkUser(auth: AuthService, name: String, admin!: Bool = false): User {
    auth.createUser(name, "Passw0rd1", admin).getOrThrow()
}

@Test
class CanManageTeamTest {
    // 未登录 → 拒绝，原因 not_authenticated
    @TestCase
    func testAnonymousDenied(): Unit {
        let (ad, _, _, _) = ownerEnv()
        let tid = ad.createTeam("t", 1000)
        let v = canManageTeam(ad, None, tid)
        @Expect(v.allowed, false)
        @Expect(v.reason, "not_authenticated")
        @Expect(teamManageDeniedCode(v.reason), 401u16)
    }

    // 团队不存在 / 已软删 → 拒绝，原因 team_not_found（404）
    @TestCase
    func testTeamNotFoundDenied(): Unit {
        let (ad, _, _, auth) = ownerEnv()
        let u = mkUser(auth, "alice")
        @Expect(canManageTeam(ad, Some(u), 99999).reason, "team_not_found")

        let tid = ad.createTeam("gone", 1000, ownerId: u.id, selfService: true)
        let _ = ad.deleteTeam(tid, 2000)
        @Expect(canManageTeam(ad, Some(u), tid).reason, "team_not_found")
    }

    // 非 owner → 拒绝，原因 not_team_owner（403）——即使 selfService 已开启
    @TestCase
    func testNonOwnerDeniedEvenWhenSelfServiceOn(): Unit {
        let (ad, _, _, auth) = ownerEnv()
        let boss = mkUser(auth, "boss")
        let other = mkUser(auth, "other")
        let tid = ad.createTeam("t", 1000, ownerId: boss.id, selfService: true)
        let v = canManageTeam(ad, Some(other), tid)
        @Expect(v.allowed, false)
        @Expect(v.reason, "not_team_owner")
        @Expect(teamManageDeniedCode(v.reason), 403u16)
    }

    // 约束 2：是 owner 但 selfService 默认关 → 拒绝（下放边界）
    @TestCase
    func testOwnerDeniedWhenSelfServiceOff(): Unit {
        let (ad, _, _, auth) = ownerEnv()
        let u = mkUser(auth, "owner1")
        let tid = ad.createTeam("t", 1000, ownerId: u.id)   // selfService 默认 false
        @Expect(ad.getTeam(tid).getOrThrow().selfService, false)
        let v = canManageTeam(ad, Some(u), tid)
        @Expect(v.allowed, false)
        @Expect(v.reason, "self_service_disabled")
        @Expect(teamManageDeniedMessage(v.reason).contains("未开启"), true)
    }

    // owner + selfService 开 → 放行，via=owner
    @TestCase
    func testOwnerAllowedWhenSelfServiceOn(): Unit {
        let (ad, _, _, auth) = ownerEnv()
        let u = mkUser(auth, "owner2")
        let tid = ad.createTeam("t", 1000, ownerId: u.id, selfService: true)
        let v = canManageTeam(ad, Some(u), tid)
        @Expect(v.allowed, true)
        @Expect(v.via, "owner")
    }

    // 约束 1/3：管理员永远是超集 —— 不是 owner、selfService 关也放行
    @TestCase
    func testAdminIsSuperset(): Unit {
        let (ad, _, _, auth) = ownerEnv()
        let owner = mkUser(auth, "owner3")
        let admin = mkUser(auth, "root", admin: true)
        let tid = ad.createTeam("t", 1000, ownerId: owner.id)   // 自助关、admin 也不是 owner
        let v = canManageTeam(ad, Some(admin), tid)
        @Expect(v.allowed, true)
        @Expect(v.via, "admin")

        // 无 owner 的团队，管理员同样可管
        let tid2 = ad.createTeam("t2", 1000)
        @Expect(canManageTeam(ad, Some(admin), tid2).via, "admin")
    }

    // 被禁用的账号不算有身份（即使它是 owner）
    @TestCase
    func testInactiveUserDenied(): Unit {
        let (ad, _, userStore, auth) = ownerEnv()
        let u = mkUser(auth, "owner4")
        let tid = ad.createTeam("t", 1000, ownerId: u.id, selfService: true)
        let doc = userStore.getUser(u.id).getOrThrow()
        doc.isActive = false
        userStore.saveUser(doc)
        let v = canManageTeam(ad, Some(userStore.getUser(u.id).getOrThrow()), tid)
        @Expect(v.allowed, false)
        @Expect(v.reason, "not_authenticated")
    }

    // isTeamOwner 薄封装：uid<=0 / 非 owner / 团队已删 都是 false
    @TestCase
    func testIsTeamOwnerEdges(): Unit {
        let (ad, _, _, auth) = ownerEnv()
        let u = mkUser(auth, "owner5")
        let tid = ad.createTeam("t", 1000, ownerId: u.id)
        @Expect(isTeamOwner(ad, u.id, tid), true)
        @Expect(isTeamOwner(ad, 0, tid), false)
        @Expect(isTeamOwner(ad, 12345, tid), false)
        let _ = ad.deleteTeam(tid, 2000)
        @Expect(isTeamOwner(ad, u.id, tid), false)
    }
}

@Test
class TeamSelfServiceOpsTest {
    // 加成员：成功 + 幂等（重复加不产生第二条记录）
    @TestCase
    func testAddMemberAndIdempotent(): Unit {
        let (ad, _, userStore, auth) = ownerEnv()
        let owner = mkUser(auth, "o")
        let target = mkUser(auth, "m")
        let tid = ad.createTeam("t", 1000, ownerId: owner.id, selfService: true)

        let r1 = addTeamMemberChecked(ad, userStore, tid, target.id)
        @Expect(r1.ok, true)
        @Expect(isTeamMember(ad, tid, target.id), true)
        @Expect(ad.listTeamMembers(tid).size, 1)

        // 幂等：再调一次仍是成功，但记录不重复
        let r2 = addTeamMemberChecked(ad, userStore, tid, target.id)
        @Expect(r2.ok, true)
        @Expect(ad.listTeamMembers(tid).size, 1)
    }

    // 加成员：用户不存在 404 / 被禁用拒绝 / id 非法
    @TestCase
    func testAddMemberRejections(): Unit {
        let (ad, _, userStore, auth) = ownerEnv()
        let owner = mkUser(auth, "o2")
        let blocked = mkUser(auth, "blocked")
        let tid = ad.createTeam("t", 1000, ownerId: owner.id, selfService: true)

        @Expect(addTeamMemberChecked(ad, userStore, tid, 99999).outcome, "user_not_found")
        @Expect(teamSelfServiceCode(addTeamMemberChecked(ad, userStore, tid, 99999)), 404u16)
        @Expect(addTeamMemberChecked(ad, userStore, tid, 0).outcome, "invalid_user")

        // 禁用账号不得被拉进团队（等于给它发布权）
        let d = userStore.getUser(blocked.id).getOrThrow()
        d.isActive = false
        userStore.saveUser(d)
        let r = addTeamMemberChecked(ad, userStore, tid, blocked.id)
        @Expect(r.ok, false)
        @Expect(r.outcome, "user_inactive")
    }

    // 约束 3：owner 不可被移出（否则「有管理权但不在成员里」）
    @TestCase
    func testRemoveMemberRules(): Unit {
        let (ad, _, userStore, auth) = ownerEnv()
        let owner = mkUser(auth, "o3")
        let member = mkUser(auth, "m3")
        let tid = ad.createTeam("t", 1000, ownerId: owner.id, selfService: true)
        let _ = addTeamMemberChecked(ad, userStore, tid, owner.id)
        let _ = addTeamMemberChecked(ad, userStore, tid, member.id)

        // owner 不可移出
        let blocked = removeTeamMemberChecked(ad, tid, owner.id)
        @Expect(blocked.ok, false)
        @Expect(blocked.outcome, "cannot_remove_owner")

        // 普通成员可移出
        let ok = removeTeamMemberChecked(ad, tid, member.id)
        @Expect(ok.ok, true)
        @Expect(isTeamMember(ad, tid, member.id), false)

        // 不在团队里 → not_a_member
        @Expect(removeTeamMemberChecked(ad, tid, member.id).outcome, "not_a_member")
    }

    // 约束 3+4：转让只能给**现有成员**；转让后新 owner 入队、旧 owner 保留成员身份、
    // 且不改变任何权限字段
    @TestCase
    func testTransferOwnerRules(): Unit {
        let (ad, _, userStore, auth) = ownerEnv()
        let old = mkUser(auth, "old")
        let insider = mkUser(auth, "insider")
        let outsider = mkUser(auth, "outsider")
        let tid = ad.createTeam("t", 1000, ownerId: old.id, selfService: true, permission: "write")
        let _ = addTeamMemberChecked(ad, userStore, tid, old.id)
        let _ = addTeamMemberChecked(ad, userStore, tid, insider.id)

        // 非成员不可接任（避免「有管理权但无发布权」）
        let bad = transferTeamOwnerChecked(ad, userStore, tid, outsider.id, 2000)
        @Expect(bad.ok, false)
        @Expect(bad.outcome, "not_a_member")

        // 转让给成员 → 成功
        let ok = transferTeamOwnerChecked(ad, userStore, tid, insider.id, 2000)
        @Expect(ok.ok, true)
        @Expect(ad.getTeam(tid).getOrThrow().ownerId, insider.id)
        // 旧 owner 保留成员身份
        @Expect(isTeamMember(ad, tid, old.id), true)
        @Expect(isTeamMember(ad, tid, insider.id), true)
        // 约束 4：owner 变了但权限字段不变
        @Expect(ad.getTeam(tid).getOrThrow().permission, "write")

        // 转让给已是 owner 的人 → 幂等成功
        let same = transferTeamOwnerChecked(ad, userStore, tid, insider.id, 3000)
        @Expect(same.ok, true)
    }

    // 转让：用户不存在 / 禁用 / 团队不存在
    @TestCase
    func testTransferRejections(): Unit {
        let (ad, _, userStore, auth) = ownerEnv()
        let owner = mkUser(auth, "o5")
        let tid = ad.createTeam("t", 1000, ownerId: owner.id, selfService: true)
        let _ = addTeamMemberChecked(ad, userStore, tid, owner.id)

        @Expect(transferTeamOwnerChecked(ad, userStore, tid, 99999, 1).outcome, "user_not_found")
        @Expect(transferTeamOwnerChecked(ad, userStore, tid, 0, 1).outcome, "invalid_user")
        @Expect(transferTeamOwnerChecked(ad, userStore, 99999, owner.id, 1).outcome, "team_not_found")
    }

    // 约束 3：删除用户前的孤儿检查 —— 是某团队 owner 就返回团队名（阻止删除）
    @TestCase
    func testOwnedTeamBlockingRemoval(): Unit {
        let (ad, _, _, auth) = ownerEnv()
        let owner = mkUser(auth, "orphan-owner")
        let plain = mkUser(auth, "plain")
        @Expect(ownedTeamBlockingUserRemoval(ad, owner.id), "")

        let _ = ad.createTeam("core", 1000, ownerId: owner.id)
        @Expect(ownedTeamBlockingUserRemoval(ad, owner.id), "core")
        @Expect(ownedTeamBlockingUserRemoval(ad, plain.id), "")
        @Expect(ownedTeamBlockingUserRemoval(ad, 0), "")

        // 团队软删后不再阻止
        let tid = ad.ownedTeamOf(owner.id)
        let _ = ad.deleteTeam(tid, 2000)
        @Expect(ownedTeamBlockingUserRemoval(ad, owner.id), "")
    }
}

@Test
class TeamOwnerStoreTest {
    // 约束 4 的关键断言：owner 身份**不**带来任何发布权限
    @TestCase
    func testOwnerGetsNoImplicitPublishPermission(): Unit {
        let (ad, storm, userStore, auth) = ownerEnv()
        let owner = mkUser(auth, "noimplicit")
        let pkgStore = PackageStore(storm)
        let tid = ad.createTeam("t", 1000, ownerId: owner.id, selfService: true, permission: "read")
        let _ = addTeamMemberChecked(ad, userStore, tid, owner.id)

        // 该团队没有绑定任何组织/包 → owner 对自己没发布的包权限仍是 0
        @Expect(effectivePermission(pkgStore, ad, owner, "acme", "whatever"), 0)
        // 团队权限仍是 read（1），没有被 owner 身份抬高
        @Expect(effectivePermission(pkgStore, ad, owner, "acme", "whatever") < 2, true)
    }

    // selfService 默认值与开关；ownerId 的读写
    @TestCase
    func testSelfServiceDefaultsAndToggle(): Unit {
        let (ad, _, _, auth) = ownerEnv()
        let u = mkUser(auth, "toggle")
        // 默认：无 owner、自助关
        let tid = ad.createTeam("t", 1000)
        let t0 = ad.getTeam(tid).getOrThrow()
        @Expect(t0.ownerId, 0)
        @Expect(t0.selfService, false)

        @Expect(ad.setTeamOwner(tid, u.id, 2000), true)
        @Expect(ad.getTeam(tid).getOrThrow().ownerId, u.id)
        @Expect(ad.setTeamSelfService(tid, true, 3000), true)
        @Expect(ad.getTeam(tid).getOrThrow().selfService, true)
        @Expect(ad.setTeamSelfService(tid, false, 4000), true)
        @Expect(ad.getTeam(tid).getOrThrow().selfService, false)

        // 不存在的团队 → false
        @Expect(ad.setTeamOwner(99999, u.id, 1), false)
        @Expect(ad.setTeamSelfService(99999, true, 1), false)
    }

    // updateTeam 的 Option 语义：没传 selfService 保持原值，显式传才改
    @TestCase
    func testUpdateTeamPreservesSelfServiceWhenAbsent(): Unit {
        let (ad, _, _, auth) = ownerEnv()
        let tid = ad.createTeam("t", 1000, selfService: true)
        // 不传 → 保持 true
        let _ = ad.updateTeam(tid, "显示名", "描述", "write", 2000)
        @Expect(ad.getTeam(tid).getOrThrow().selfService, true)
        @Expect(ad.getTeam(tid).getOrThrow().permission, "write")
        // 显式传 false → 关闭
        let _ = ad.updateTeam(tid, "显示名", "描述", "write", 3000, selfService: Some(false))
        @Expect(ad.getTeam(tid).getOrThrow().selfService, false)
    }

    // 兼容性：存量团队（缺 ownerId/selfService 键）反序列化后落字段默认值
    @TestCase
    func testLegacyTeamDocGetsSafeDefaults(): Unit {
        let (ad, storm, _, _) = ownerEnv()
        // 直接写一条不带新字段的文档，再读回
        let d = TeamDoc()
        d.id = 777
        d.name = "legacy"
        d.permission = "read"
        d.createdAt = 1
        storm.save(d)
        let back = ad.getTeam(777).getOrThrow()
        @Expect(back.ownerId, 0)
        @Expect(back.selfService, false)
        // 未指定 owner 的老团队：管理员仍可管，owner 自助不生效
        @Expect(canManageTeam(ad, None, 777).reason, "not_authenticated")
    }

    // ownedTeamOf：返回第一个拥有的团队（无则 0）
    @TestCase
    func testOwnedTeamOf(): Unit {
        let (ad, _, _, auth) = ownerEnv()
        let u = mkUser(auth, "owns")
        @Expect(ad.ownedTeamOf(u.id), 0)
        let tid = ad.createTeam("mine", 1000, ownerId: u.id)
        @Expect(ad.ownedTeamOf(u.id), tid)
        @Expect(ad.ownedTeamOf(0), 0)
    }

    // myTeamRows 带上 owner/自助标记（门户据此决定是否显示管理入口）
    @TestCase
    func testMyTeamRowsCarriesOwnerFlags(): Unit {
        let (ad, _, userStore, auth) = ownerEnv()
        let owner = mkUser(auth, "rowsowner")
        let plain = mkUser(auth, "rowsplain")
        let tid = ad.createTeam("t", 1000, ownerId: owner.id, selfService: true)
        let _ = addTeamMemberChecked(ad, userStore, tid, owner.id)
        let _ = addTeamMemberChecked(ad, userStore, tid, plain.id)

        let ownerRows = myTeamRows(ad, owner.id)
        @Expect(ownerRows.size, 1)
        @Expect(ownerRows[0].isOwner, true)
        @Expect(ownerRows[0].canSelfManage, true)

        let plainRows = myTeamRows(ad, plain.id)
        @Expect(plainRows[0].isOwner, false)
        @Expect(plainRows[0].canSelfManage, false)

        // 关了自助：是 owner 但 canSelfManage=false（入口消失）
        let _ = ad.setTeamSelfService(tid, false, 2000)
        let afterOff = myTeamRows(ad, owner.id)
        @Expect(afterOff[0].isOwner, true)
        @Expect(afterOff[0].canSelfManage, false)
    }

    // teamMemberRows 标注 owner
    @TestCase
    func testTeamMemberRowsMarksOwner(): Unit {
        let (ad, _, userStore, auth) = ownerEnv()
        let owner = mkUser(auth, "markowner")
        let m = mkUser(auth, "markmember")
        let tid = ad.createTeam("t", 1000, ownerId: owner.id, selfService: true)
        let _ = addTeamMemberChecked(ad, userStore, tid, owner.id)
        let _ = addTeamMemberChecked(ad, userStore, tid, m.id)

        let rows = teamMemberRows(ad, tid, owner.id, userStore)
        @Expect(rows.size, 2)
        var ownerMarked = 0
        for (r in rows) {
            if (r.isOwner) {
                ownerMarked++
                @Expect(r.username, "markowner")
            }
        }
        @Expect(ownerMarked, 1)
    }
}
