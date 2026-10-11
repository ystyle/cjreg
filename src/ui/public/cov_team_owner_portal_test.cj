// 门户 owner 自助面板的渲染与动作单测（user_portal.cj 的团队区块）
//
// 守三件事：
//   ① 入口可见性三态（owner+自助开 / owner+自助关 / 非 owner）—— 体验层；
//   ② 面板打开后成员列表、加人、移出、转让各自改了什么信号；
//   ③ **服务端守卫在 UI 侧同样生效**：绕过按钮直接调 action 也必须被拒（UI 隐藏不算安全）。
package ystyle::cjreg.ui.public

import ystyle::cjreg.ui.*

import cjxt.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.util.*
import ystyle::cjreg.auth.model.*
import ystyle::cjreg.config.*
import ystyle::cjreg.server.{canManageTeam, addTeamMemberChecked, isTeamMember}
import std.collection.*
import std.reflect.*
import std.unittest.*
import std.unittest.testmacro.*

// 造一个带团队的 state，并返回 (state, owner用户, 成员用户, teamId)
func ownerPanelState(selfService!: Bool = true, permission!: String = "write")
    : (CjregState, User, User, Int64) {
    let state = makePortalState("team")
    let owner = state.auth.createUser("panelowner", "OwnerPass1", false).getOrThrow()
    let member = state.auth.createUser("panelmember", "MemberPass1", false).getOrThrow()
    let tid = state.adminData.createTeam("panelteam", 1000, displayName: "面板团队",
        permission: permission, ownerId: owner.id, selfService: selfService)
    state.adminData.addTeamMember(tid, owner.id)
    (state, owner, member, tid)
}

// 以指定用户身份挂载门户页
func mountAs(state: CjregState, u: User): UserPortalPage {
    mountPortal(state, userCtxMap(u.id, u.username, u.isAdmin))
}

@Test
public class PortalOwnerPanelRenderTest {
    // 入口可见性①：owner + 自助开 → 有「管理成员」按钮
    @TestCase
    public func testOwnerWithSelfServiceSeesManageButton(): Unit {
        let (state, owner, _, tid) = ownerPanelState(selfService: true)
        let page = mountAs(state, owner)
        let json = renderPortal(page)
        @Expect(json.contains("管理成员"), true)
        // 团队列显示 label()（有显示名就用显示名）
        @Expect(json.contains("面板团队"), true)
        // 未打开面板时不应出现面板标题
        @Expect(json.contains("管理团队成员"), false)
    }

    // 入口可见性②：owner 但自助关 → 显示状态标签、无按钮（体验层；真正的门在服务端）
    @TestCase
    public func testOwnerWithoutSelfServiceSeesHint(): Unit {
        let (state, owner, _, _) = ownerPanelState(selfService: false)
        let page = mountAs(state, owner)
        let json = renderPortal(page)
        @Expect(json.contains("管理成员"), false)
        @Expect(json.contains("owner·自助未开"), true)
    }

    // 入口可见性③：非 owner（普通成员）→ 既无按钮也无 owner 提示
    @TestCase
    public func testPlainMemberSeesNoEntry(): Unit {
        let (state, owner, member, tid) = ownerPanelState(selfService: true)
        state.adminData.addTeamMember(tid, member.id)
        let page = mountAs(state, member)
        let json = renderPortal(page)
        @Expect(json.contains("管理成员"), false)
        @Expect(json.contains("owner·自助未开"), false)
        @Expect(json.contains("面板团队"), true)   // 仍能看到自己在团队里
    }

    // 打开面板：成员列表载入（含 owner 标注），标题出现
    @TestCase
    public func testOpenPanelLoadsMembers(): Unit {
        let (state, owner, member, tid) = ownerPanelState(selfService: true)
        state.adminData.addTeamMember(tid, member.id)
        let page = mountAs(state, owner)
        let (actx, _) = portalActionCtx(state, userCtxMap(owner.id, owner.username, false))

        let _ = page.openManageMembers(actx, tid, "面板团队")
        @Expect(page.manageTeamId.get(), tid)
        @Expect(page.manageTeamName.get(), "面板团队")
        // 走对话框（与管理端同一套交互）：显隐由独立信号控制，且渲染出 el-dialog
        @Expect(page.manageVisible.get(), true)
        @Expect(renderPortal(page).contains("el-dialog"), true)
        let rows = page.memberRows.get()
        @Expect(rows.size, 2)
        var ownerMarked = false
        for (r in rows) {
            if (r.isOwner) {
                ownerMarked = true
                @Expect(r.username, "panelowner")
            }
        }
        @Expect(ownerMarked, true)

        let json = renderPortal(page)
        @Expect(json.contains("管理团队成员"), true)
        @Expect(json.contains("panelmember"), true)
        // 对话框形态：标题走 SignalView（Dialog 的静态 title 是首帧快照），正文含表格与关联区块
        @Expect(json.contains("关联范围"), true)
        @Expect(json.contains("el-dialog"), true)
    }

    // 收起面板：清空状态
    @TestCase
    public func testClosePanel(): Unit {
        let (state, owner, _, tid) = ownerPanelState(selfService: true)
        let page = mountAs(state, owner)
        let (actx, _) = portalActionCtx(state, userCtxMap(owner.id, owner.username, false))
        let _ = page.openManageMembers(actx, tid, "面板团队")
        @Expect(page.memberRows.get().size, 1)

        let _ = page.closeManageMembers(actx)
        @Expect(page.manageVisible.get(), false)
        @Expect(page.manageTeamId.get(), 0)
        @Expect(page.memberRows.get().size, 0)
        // 关闭时关联状态一并清掉，下次打开不会带上次的残留
        @Expect(page.linkOrgs.get().size, 0)
        @Expect(page.linkPkgs.get().size, 0)
        @Expect(renderPortal(page).contains("管理团队成员"), false)
    }

    // 加人：按用户名 → 落库 + 列表刷新 + 输入框清空
    @TestCase
    public func testAddMemberByName(): Unit {
        let (state, owner, member, tid) = ownerPanelState(selfService: true)
        let page = mountAs(state, owner)
        let (actx, _) = portalActionCtx(state, userCtxMap(owner.id, owner.username, false))
        let _ = page.openManageMembers(actx, tid, "面板团队")
        @Expect(page.memberRows.get().size, 1)

        page.addMemberName.set(member.username)
        let _ = page.addMember(actx)
        @Expect(isTeamMember(state.adminData, tid, member.id), true)
        @Expect(page.memberRows.get().size, 2)
        @Expect(page.addMemberName.get(), "")
        @Expect(page.msg.get().contains(member.username), true)
    }

    // 加人：用户名不存在 → 明确提示且不落库
    @TestCase
    public func testAddMemberUnknownName(): Unit {
        let (state, owner, _, tid) = ownerPanelState(selfService: true)
        let page = mountAs(state, owner)
        let (actx, _) = portalActionCtx(state, userCtxMap(owner.id, owner.username, false))
        let _ = page.openManageMembers(actx, tid, "面板团队")

        page.addMemberName.set("no-such-person")
        let _ = page.addMember(actx)
        @Expect(page.msgOk.get(), false)
        @Expect(page.msg.get().contains("用户不存在"), true)
        @Expect(page.memberRows.get().size, 1)
    }

    // 加人：空输入 → 提示，不落库
    @TestCase
    public func testAddMemberEmptyName(): Unit {
        let (state, owner, _, tid) = ownerPanelState(selfService: true)
        let page = mountAs(state, owner)
        let (actx, _) = portalActionCtx(state, userCtxMap(owner.id, owner.username, false))
        let _ = page.openManageMembers(actx, tid, "面板团队")
        page.addMemberName.set("   ")
        let _ = page.addMember(actx)
        @Expect(page.msgOk.get(), false)
        @Expect(page.msg.get().contains("请输入"), true)
    }

    // 移出：确认流程（ask → confirm），member 被移除、owner 保留
    @TestCase
    public func testRemoveMemberFlow(): Unit {
        let (state, owner, member, tid) = ownerPanelState(selfService: true)
        state.adminData.addTeamMember(tid, member.id)
        let page = mountAs(state, owner)
        let (actx, _) = portalActionCtx(state, userCtxMap(owner.id, owner.username, false))
        let _ = page.openManageMembers(actx, tid, "面板团队")

        let _ = page.askRemoveMember(actx, member.id, member.username)
        @Expect(page.removeVisible.get(), true)
        @Expect(page.pendingRemoveId.get(), member.id)

        let _ = page.confirmRemoveMember(actx)
        @Expect(page.removeVisible.get(), false)
        @Expect(isTeamMember(state.adminData, tid, member.id), false)
        @Expect(page.memberRows.get().size, 1)

        // 取消分支：不删
        let _ = page.askRemoveMember(actx, owner.id, owner.username)
        let _ = page.cancelRemoveMember(actx)
        @Expect(page.removeVisible.get(), false)
        @Expect(page.pendingRemoveId.get(), 0)
        @Expect(isTeamMember(state.adminData, tid, owner.id), true)
    }

    // 移出 owner → 被拒（服务端规则在 UI 动作里同样生效）
    @TestCase
    public func testRemoveOwnerRejected(): Unit {
        let (state, owner, _, tid) = ownerPanelState(selfService: true)
        let page = mountAs(state, owner)
        let (actx, _) = portalActionCtx(state, userCtxMap(owner.id, owner.username, false))
        let _ = page.openManageMembers(actx, tid, "面板团队")

        let _ = page.askRemoveMember(actx, owner.id, owner.username)
        let _ = page.confirmRemoveMember(actx)
        @Expect(page.msgOk.get(), false)
        @Expect(page.msg.get().contains("转让"), true)
        @Expect(isTeamMember(state.adminData, tid, owner.id), true)
    }

    // 转让：ask → confirm；转让后 ownerId 变化、旧 owner 仍是成员、列表标注跟着换
    @TestCase
    public func testTransferOwnerFlow(): Unit {
        let (state, owner, member, tid) = ownerPanelState(selfService: true)
        state.adminData.addTeamMember(tid, member.id)
        let page = mountAs(state, owner)
        let (actx, _) = portalActionCtx(state, userCtxMap(owner.id, owner.username, false))
        let _ = page.openManageMembers(actx, tid, "面板团队")

        let _ = page.askTransferOwner(actx, member.id)
        @Expect(page.transferVisible.get(), true)
        let _ = page.confirmTransferOwner(actx)
        @Expect(page.transferVisible.get(), false)
        @Expect(state.adminData.getTeam(tid).getOrThrow().ownerId, member.id)
        // 旧 owner 仍是成员（转让 ≠ 移出）
        @Expect(isTeamMember(state.adminData, tid, owner.id), true)

        // 取消分支
        let _ = page.askTransferOwner(actx, owner.id)
        let _ = page.cancelTransferOwner(actx)
        @Expect(page.transferVisible.get(), false)
        @Expect(page.transferTargetId.get(), 0)
        @Expect(state.adminData.getTeam(tid).getOrThrow().ownerId, member.id)
    }

    // ★ 绕过按钮直接调 action（非 owner）→ 服务端守卫拒绝，数据不变
    @TestCase
    public func testNonOwnerCannotManageEvenIfActionInvoked(): Unit {
        let (state, owner, member, tid) = ownerPanelState(selfService: true)
        state.adminData.addTeamMember(tid, member.id)
        let page = mountAs(state, member)   // 普通成员
        let (actx, _) = portalActionCtx(state, userCtxMap(member.id, member.username, false))

        // 直接打开面板 + 加人（模拟"手搓请求"）
        let _ = page.openManageMembers(actx, tid, "面板团队")
        page.addMemberName.set("panelowner")
        let _ = page.addMember(actx)
        @Expect(page.msgOk.get(), false)
        @Expect(page.msg.get().contains("所有者"), true)

        // 直接调移除与转让，同样被拒
        let _ = page.askRemoveMember(actx, owner.id, owner.username)
        let _ = page.confirmRemoveMember(actx)
        @Expect(page.msgOk.get(), false)
        let _ = page.askTransferOwner(actx, member.id)
        let _ = page.confirmTransferOwner(actx)
        @Expect(page.msgOk.get(), false)

        // 数据完全没动
        @Expect(state.adminData.getTeam(tid).getOrThrow().ownerId, owner.id)
        @Expect(isTeamMember(state.adminData, tid, owner.id), true)
    }

    // ★ owner 但自助关：直接调 action 也被拒（下放边界在 UI 侧同样生效）
    @TestCase
    public func testOwnerBlockedWhenSelfServiceOffInAction(): Unit {
        let (state, owner, member, tid) = ownerPanelState(selfService: false)
        let page = mountAs(state, owner)
        let (actx, _) = portalActionCtx(state, userCtxMap(owner.id, owner.username, false))

        let _ = page.openManageMembers(actx, tid, "面板团队")
        page.addMemberName.set(member.username)
        let _ = page.addMember(actx)
        @Expect(page.msgOk.get(), false)
        @Expect(page.msg.get().contains("未开启"), true)
        @Expect(isTeamMember(state.adminData, tid, member.id), false)
    }

    // 会话失效（uid 0）→ 拒绝并提示重新登录
    @TestCase
    public func testExpiredSessionRejected(): Unit {
        let (state, owner, member, tid) = ownerPanelState(selfService: true)
        let page = mountAs(state, owner)
        // uid = 0 的会话（未登录/已失效）
        let emptyMap = userCtxMap(0, "", false)
        let (actx, _) = portalActionCtx(state, emptyMap)

        let _ = page.openManageMembers(actx, tid, "面板团队")
        page.addMemberName.set(member.username)
        let _ = page.addMember(actx)
        @Expect(page.msgOk.get(), false)
        @Expect(page.msg.get().contains("登录"), true)
    }

    // 转让/移除的确认框渲染出来（受各自信号控制）
    @TestCase
    public func testConfirmDialogsRender(): Unit {
        let (state, owner, member, tid) = ownerPanelState(selfService: true)
        state.adminData.addTeamMember(tid, member.id)
        let page = mountAs(state, owner)
        let (actx, _) = portalActionCtx(state, userCtxMap(owner.id, owner.username, false))

        // 默认都不可见
        @Expect(renderPortal(page).contains("移出团队成员"), false)
        @Expect(renderPortal(page).contains("转让团队所有权"), false)

        let _ = page.askRemoveMember(actx, member.id, member.username)
        @Expect(renderPortal(page).contains("移出团队成员"), true)
        @Expect(renderPortal(page).contains(member.username), true)
        let _ = page.cancelRemoveMember(actx)

        let _ = page.askTransferOwner(actx, member.id)
        @Expect(renderPortal(page).contains("转让团队所有权"), true)
    }

    // 审计：owner 自助动作写日志（actor = 操作者）
    @TestCase
    public func testSelfServiceWritesAuditFromUi(): Unit {
        let (state, owner, member, tid) = ownerPanelState(selfService: true)
        let page = mountAs(state, owner)
        let (actx, _) = portalActionCtx(state, userCtxMap(owner.id, owner.username, false))
        let _ = page.openManageMembers(actx, tid, "面板团队")
        page.addMemberName.set(member.username)
        let _ = page.addMember(actx)

        let (logs, total) = state.adminData.queryLogs(Some("admin"), "add_team_member", "", 0, 0, 0, 10)
        @Expect(total, 1)
        @Expect(logs[0].actorId, owner.id)
        @Expect(logs[0].actorName, "panelowner")
        @Expect(logs[0].detail.contains("teamId=${tid}"), true)
    }
}

@Test
public class PortalLinkPanelTest {
    // owner 改组织关联：toggle 一次关联、再 toggle 取消
    @TestCase
    public func testToggleTeamOrg(): Unit {
        let (state, owner, _, tid) = ownerPanelState(selfService: true)
        let oid = state.adminData.createOrg("acme", "", owner.id, 1000)
        let page = mountAs(state, owner)
        let (actx, _) = portalActionCtx(state, userCtxMap(owner.id, owner.username, false))
        let _ = page.openManageMembers(actx, tid, "面板团队")
        @Expect(page.linkOrgs.get().size, 0)

        // 关联
        let _ = page.toggleTeamOrg(actx, oid)
        @Expect(page.linkOrgs.get().size, 1)
        @Expect(page.linkOrgs.get()[0], oid.toString())
        @Expect(state.adminData.listTeamOrganizationIds(tid).size, 1)

        // 再 toggle → 取消
        let _ = page.toggleTeamOrg(actx, oid)
        @Expect(page.linkOrgs.get().size, 0)
        @Expect(state.adminData.listTeamOrganizationIds(tid).size, 0)
    }

    // owner 包关联：加（org::name 与裸名两种写法）+ 移除
    @TestCase
    public func testAddAndRemoveTeamPkg(): Unit {
        let (state, owner, _, tid) = ownerPanelState(selfService: true)
        // 造两个真实包：带组织 / 无组织
        let a = PackageDoc()
        a.organization = "acme"
        a.name = "demo"
        a.version = "1.0.0"
        state.pkgStore.save(a)
        let b = PackageDoc()
        b.organization = ""
        b.name = "plain"
        b.version = "1.0.0"
        state.pkgStore.save(b)

        let page = mountAs(state, owner)
        let (actx, _) = portalActionCtx(state, userCtxMap(owner.id, owner.username, false))
        let _ = page.openManageMembers(actx, tid, "面板团队")

        // org::name 写法
        page.linkPkgInput.set("acme::demo")
        let _ = page.addTeamPkg(actx)
        @Expect(page.msgOk.get(), true)
        @Expect(state.adminData.listTeamPackages(tid).size, 1)
        @Expect(page.linkPkgInput.get(), "")

        // 裸包名写法
        page.linkPkgInput.set("plain")
        let _ = page.addTeamPkg(actx)
        @Expect(state.adminData.listTeamPackages(tid).size, 2)

        // 移除第一个
        let _ = page.removeTeamPkg(actx, "acme", "demo")
        @Expect(state.adminData.listTeamPackages(tid).size, 1)

        // 空输入 / 包不存在
        page.linkPkgInput.set("  ")
        let _ = page.addTeamPkg(actx)
        @Expect(page.msgOk.get(), false)
        page.linkPkgInput.set("acme::ghost")
        let _ = page.addTeamPkg(actx)
        @Expect(page.msgOk.get(), false)
        @Expect(page.msg.get().contains("不存在"), true)
    }

    // 非 owner 直接调关联 action → 被服务端守卫拒绝，数据不变
    @TestCase
    public func testNonOwnerCannotChangeLinks(): Unit {
        let (state, owner, member, tid) = ownerPanelState(selfService: true)
        state.adminData.addTeamMember(tid, member.id)
        let oid = state.adminData.createOrg("acme", "", owner.id, 1000)
        let page = mountAs(state, member)
        let (actx, _) = portalActionCtx(state, userCtxMap(member.id, member.username, false))
        let _ = page.openManageMembers(actx, tid, "面板团队")

        let _ = page.toggleTeamOrg(actx, oid)
        @Expect(page.msgOk.get(), false)
        @Expect(state.adminData.listTeamOrganizationIds(tid).size, 0)

        page.linkPkgInput.set("acme::demo")
        let _ = page.addTeamPkg(actx)
        @Expect(page.msgOk.get(), false)
        @Expect(state.adminData.listTeamPackages(tid).size, 0)
    }

    // 关联区块在面板里渲染出来（组织按钮 + 包输入框）
    @TestCase
    public func testLinkPanelRenders(): Unit {
        let (state, owner, _, tid) = ownerPanelState(selfService: true)
        let _ = state.adminData.createOrg("acme", "示例组织", owner.id, 1000)
        let page = mountAs(state, owner)
        let (actx, _) = portalActionCtx(state, userCtxMap(owner.id, owner.username, false))
        let _ = page.openManageMembers(actx, tid, "面板团队")
        let json = renderPortal(page)
        @Expect(json.contains("关联范围"), true)
        @Expect(json.contains("关联该包"), true)
        @Expect(json.contains("acme"), true)
    }
}
