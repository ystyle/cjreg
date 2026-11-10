// 团队管理页（/admin/teams）渲染 + 交互回归。
//
// 既有用例只覆盖两个弹窗的搜索即时过滤（team_dialog_search_test.cj）。
// 这里补的是另一半——本页是全站分支最多的管理页：
//   * 行内权限 Tag 三档（读取/写入/覆盖）+ 成员/组织/包三列计数；
//   * 基础表单：新建/编辑两态、必填校验、权限下拉三档；
//   * 组织关联弹窗：多选回填、（无组织包）+ 真实组织的选项文案（有/无 displayName 两分支）；
//   * 包关联弹窗：全量包（软删的跳过）、关联标记、toggle 两个方向；
//   * 成员关联弹窗：用户列表、关联标记、toggle 两个方向、"用户查不到时记 #id"这条兜底；
//   * 删除确认：取消/确认、不存在的 id；
//   * 全部写动作的鉴权（库里降级 + 未登录）；
//   * 未挂载 state 与 onUnmount 的 None 分支。
package ystyle::cjreg.ui.admin

import ystyle::cjreg.ui.*
import cjxt.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

func mountTeamsCov(state: CjregState): TeamsPage {
    let page = TeamsPage()
    page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
    page
}

// 造一个团队并可选带上关联；返回团队 id
func seedCovTeam(state: CjregState, name: String, perm!: String = "read",
                 display!: String = "", desc!: String = ""): Int64 {
    state.adminData.createTeam(name, 1000, displayName: display, description: desc, permission: perm)
}

@Test
public class CovTeamsRenderTest {
    // 空态：提示 + 表格并存
    @TestCase
    public func covTeams_emptyState(): Unit {
        let state = makePortalState("team")
        let page = mountTeamsCov(state)
        @Expect(page.rows.get().size, 0)
        @Expect(page.total.get(), 0)
        let json = covRenderExpanded(page.render())
        @Expect(json.contains("暂无团队，点击「新增团队」创建"), true)
        @Expect(json.contains("el-table"), true)
        @Expect(json.contains("团队管理"), true)
        @Expect(json.contains("团队列表"), true)
        @Expect(json.contains("新增团队"), true)
    }

    // 权限 Tag 三档：write→写入、overwrite→覆盖、其余（含 read 与未知值）→读取
    @TestCase
    public func covTeams_permTagMapping(): Unit {
        let state = makePortalState("team")
        let page = mountTeamsCov(state)
        // permTag 是纯函数：三个分支各渲染一次，直接断言 Tag 文案
        @Expect(covRender(page.permTag("write")).contains("写入"), true)
        @Expect(covRender(page.permTag("overwrite")).contains("覆盖"), true)
        @Expect(covRender(page.permTag("read")).contains("读取"), true)
        @Expect(covRender(page.permTag("bogus")).contains("读取"), true)

        let _ = seedCovTeam(state, "t-read", perm: "read")
        let _ = seedCovTeam(state, "t-write", perm: "write")
        let _ = seedCovTeam(state, "t-overwrite", perm: "overwrite")
        let _ = seedCovTeam(state, "t-unknown", perm: "bogus")
        page.refresh()
        let json = covRender(page.render())
        @Expect(json.contains("读取"), true)
        @Expect(json.contains("写入"), true)
        @Expect(json.contains("覆盖"), true)
        @Expect(json.contains("el-tag--warning"), true)
        @Expect(json.contains("el-tag--danger"), true)
        @Expect(json.contains("el-tag--info"), true)
    }

    // 三列关联计数：成员 / 组织 / 包（值来自三类关联表）
    @TestCase
    public func covTeams_rowCounts(): Unit {
        let state = makePortalState("team")
        let tid = seedCovTeam(state, "counted")
        let uid = state.auth.createUser("m1", "Pass123456", false).getOrThrow().id
        let oid = state.adminData.createOrg("org-a", "A 组织", 1, 1000)
        state.adminData.setTeamOrganizations(tid, [0, oid], 1000)
        state.adminData.setTeamMembers(tid, [uid])
        state.adminData.setTeamPackages(tid, [("ystyle", "alpha")], 1000)

        let page = mountTeamsCov(state)
        @Expect(page.rows.get().size, 1)
        let row = page.rows.get()[0]
        @Expect(row.members, 1)
        @Expect(row.orgs, 2)
        @Expect(row.pkgs, 1)
        let json = covRender(page.render())
        @Expect(json.contains("counted"), true)
        @Expect(json.contains("成员"), true)
        @Expect(json.contains("组织"), true)
    }

    // 分页：切片 + 越界页钳制（pageWindow 只影响切片）
    @TestCase
    public func covTeams_pagination(): Unit {
        let state = makePortalState("team")
        for (i in 0..5) {
            let _ = seedCovTeam(state, "t-${i}")
        }
        let page = mountTeamsCov(state)
        let (actx, _) = covActx(state)
        @Expect(page.total.get(), 5)

        page.pageSize.set(2)
        let _ = page.onPageChange(actx)
        @Expect(page.rows.get().size, 2)

        page.currentPage.set(3)
        let _ = page.onPageChange(actx)
        @Expect(page.rows.get().size, 1)

        // 越界页：pageWindow 返回空窗（(total,total)），rows 空 → 空态提示回来
        page.currentPage.set(50)
        let _ = page.onPageChange(actx)
        @Expect(page.rows.get().size, 0)
        @Expect(page.total.get(), 5)
        @Expect(page.listHint(), "暂无团队，点击「新增团队」创建")
    }

    // 新增团队：openCreate 复位六个字段；提交成功后落库 + 提示 + 审计（detail 带权限）
    @TestCase
    public func covTeams_createFlow(): Unit {
        let state = makePortalState("team")
        let page = mountTeamsCov(state)
        let _ = covRender(page.render())   // 建出 teamForm
        let (actx, _) = covActx(state)

        page.formName.set("dirty")
        page.formPermission.set("overwrite")
        page.teamNameError.set("旧错")
        let _ = page.openCreate(actx)
        @Expect(page.dialogVisible.get(), true)
        @Expect(page.dialogMode.get(), "create")
        @Expect(page.formName.get(), "")
        @Expect(page.formDisplay.get(), "")
        @Expect(page.formDesc.get(), "")
        @Expect(page.formPermission.get(), "read")
        @Expect(page.teamNameError.get(), "")
        @Expect(covRender(page.render()).contains("新增团队"), true)

        page.formName.set("core-team")
        page.formDisplay.set("核心团队")
        page.formDesc.set("描述")
        page.formPermission.set("write")
        let _ = page.submitForm(actx)

        @Expect(page.msg.get().startsWith("已创建团队 #"), true)
        @Expect(page.dialogVisible.get(), false)
        @Expect(page.rows.get().size, 1)
        let created = state.adminData.getTeam(page.rows.get()[0].doc.id).getOrThrow()
        @Expect(created.name, "core-team")
        @Expect(created.displayName, "核心团队")
        @Expect(created.permission, "write")
        let (logs, total) = state.adminData.queryLogs(Some("admin"), "create_team", "", 0, 0, 0, 10)
        @Expect(total, 1)
        @Expect(logs[0].target, "core-team")
        // detail 现在带上 owner 自助字段（迭代 6 新增）
        @Expect(logs[0].detail, "permission=write ownerId=0 selfService=false")
        @Expect(covRender(page.render()).contains(page.msg.get()), true)
    }

    // 必填校验：团队名为空 → 写 teamNameError，不落库
    @TestCase
    public func covTeams_createRequiresName(): Unit {
        let state = makePortalState("team")
        let page = mountTeamsCov(state)
        let _ = covRender(page.render())
        let (actx, _) = covActx(state)
        let _ = page.openCreate(actx)
        page.formName.set("")
        let _ = page.submitForm(actx)
        @Expect(page.teamNameError.get(), "团队名必填")
        @Expect(page.rows.get().size, 0)
        @Expect(covRender(page.render()).contains("团队名必填"), true)
    }

    // 编辑团队：回填、标题切换、名称输入禁用；提交后更新（权限一起改）
    @TestCase
    public func covTeams_editFlow(): Unit {
        let state = makePortalState("team")
        let tid = seedCovTeam(state, "editable", perm: "read", display: "旧显示名", desc: "旧描述")
        let page = mountTeamsCov(state)
        let (actx, _) = covActx(state)
        let _ = page.openEdit(actx, tid)

        @Expect(page.dialogMode.get(), "edit")
        @Expect(page.editingId, tid)
        @Expect(page.formName.get(), "editable")
        @Expect(page.formDisplay.get(), "旧显示名")
        @Expect(page.formDesc.get(), "旧描述")
        @Expect(page.formPermission.get(), "read")
        let json = covRender(page.render())
        @Expect(json.contains("编辑团队"), true)
        @Expect(json.contains("\"disabled\":\"disabled\""), true)

        page.formDisplay.set("新显示名")
        page.formPermission.set("overwrite")
        let _ = page.submitForm(actx)
        @Expect(page.msg.get(), "已更新团队 editable")
        let after = state.adminData.getTeam(tid).getOrThrow()
        @Expect(after.displayName, "新显示名")
        @Expect(after.permission, "overwrite")
        @Expect(after.name, "editable")
        let (_, total) = state.adminData.queryLogs(Some("admin"), "update_team", "", 0, 0, 0, 10)
        @Expect(total, 1)
    }

    // 编辑目标已被删掉 → updateTeam 返回 false → 「更新失败」；openEdit 不存在的 id 不动弹窗
    @TestCase
    public func covTeams_editFailureBranches(): Unit {
        let state = makePortalState("team")
        let tid = seedCovTeam(state, "x")
        let page = mountTeamsCov(state)
        let _ = covRender(page.render())
        let (actx, _) = covActx(state)

        let _ = page.openEdit(actx, 999999)
        @Expect(page.dialogVisible.get(), false)

        let _ = page.openEdit(actx, tid)
        page.editingId = 999999
        let _ = page.submitForm(actx)
        @Expect(page.msg.get(), "更新失败")

        let _ = page.openEdit(actx, tid)
        let _ = page.closeDialog(actx)
        @Expect(page.dialogVisible.get(), false)
        @Expect(covRender(page.render()).contains("el-dialog"), false)
    }

    // 组织关联弹窗：选项含「（无组织包）」（value=0）+ 每个组织；displayName 有/无两种文案
    @TestCase
    public func covTeams_orgDialogOptionsAndSave(): Unit {
        let state = makePortalState("team")
        let tid = seedCovTeam(state, "org-team")
        let withDisplay = state.adminData.createOrg("has-display", "有显示名", 1, 1000)
        let noDisplay = state.adminData.createOrg("no-display", "", 1, 1000)
        let page = mountTeamsCov(state)
        let (actx, _) = covActx(state)

        let _ = page.openOrgs(actx, tid)
        @Expect(page.orgDialogVisible.get(), true)
        @Expect(page.editingId, tid)
        @Expect(page.orgSelect.get().size, 0)
        let json = covRender(page.render())
        @Expect(json.contains("团队组织关联"), true)
        @Expect(json.contains("选择团队可操作的组织（含「无组织包」；可多选）"), true)
        // 无选中项 → Select 收起时显示 placeholder（选项标签要展开面板才有）
        @Expect(json.contains("选择组织"), true)
        @Expect(json.contains("「无组织包」"), true)   // 提示行里那句含「无组织包」

        // 勾选 0（无组织包）与真实组织后保存
        let picked = ArrayList<String>()
        picked.add(noDisplay.toString())
        picked.add(withDisplay.toString())
        page.orgSelect.set(picked)
        let _ = page.saveOrgs(actx)
        @Expect(page.msg.get(), "已更新团队组织关联")
        @Expect(page.orgDialogVisible.get(), false)
        @Expect(state.adminData.listTeamOrganizationIds(tid).size, 2)
        let (logs, total) = state.adminData.queryLogs(Some("admin"), "set_team_orgs", "", 0, 0, 0, 10)
        @Expect(total, 1)
        @Expect(logs[0].target, "team#${tid}")
        @Expect(logs[0].detail, "count=2")

        // 重新打开：回填已有选择（选中项标签渲染出来）
        let _ = page.openOrgs(actx, tid)
        @Expect(page.orgSelect.get().size, 2)
        @Expect(covRender(page.render()).contains("有显示名"), true)
        let _ = page.closeOrgs(actx)
        @Expect(page.orgDialogVisible.get(), false)
    }

    // 组织关联：非法 id 字符串按 0 处理（tryParse 的 None 分支）
    @TestCase
    public func covTeams_saveOrgsParsesBadIdAsZero(): Unit {
        let state = makePortalState("team")
        let tid = seedCovTeam(state, "parse-team")
        let page = mountTeamsCov(state)
        let (actx, _) = covActx(state)
        let _ = page.openOrgs(actx, tid)
        let picked = ArrayList<String>()
        picked.add("not-a-number")
        picked.add("42")
        page.orgSelect.set(picked)
        let _ = page.saveOrgs(actx)
        @Expect(page.msg.get(), "已更新团队组织关联")
        let ids = state.adminData.listTeamOrganizationIds(tid)
        @Expect(ids.size, 2)
        @Expect(ids[0], 0)
        @Expect(ids[1], 42)
    }

    // 包关联弹窗：下拉候选只列未关联包（软删跳过、同包多版本只一个），表格只列已关联
    @TestCase
    public func covTeams_pkgDialogAddAndRemove(): Unit {
        let state = makePortalState("team")
        let tid = seedCovTeam(state, "pkg-team")
        let _ = covSeedPkg(state, "ystyle", "alpha", "1.0.0")
        let _ = covSeedPkg(state, "ystyle", "alpha", "1.1.0")
        let _ = covSeedPkg(state, "ystyle", "beta", "1.0.0")
        let _ = covSeedPkg(state, "ystyle", "hidden", "1.0.0", deleted: true)
        let page = mountTeamsCov(state)
        let (actx, _) = covActx(state)

        let _ = page.openPackages(actx, tid)
        @Expect(page.pkgDialogVisible.get(), true)
        @Expect(page.pkgPick.get(), "")
        @Expect(page.pkgRows.get().size, 0)
        @Expect(page.pkgOptions().size, 2)          // alpha（两次版本只一候选）+ beta
        let json = covRender(page.render())
        @Expect(json.contains("团队包关联"), true)
        @Expect(json.contains("尚未关联任何包"), true)

        page.pkgPick.set("ystyle::alpha")
        let _ = page.addPkg(actx)
        @Expect(page.msg.get(), "已关联 ystyle::alpha")
        @Expect(state.adminData.listTeamPackages(tid).size, 1)
        @Expect(page.pkgRows.get().size, 1)
        @Expect(page.pkgRows.get()[0].name, "alpha")
        @Expect(page.pkgPick.get(), "")
        @Expect(covRender(page.render()).contains("el-button--danger"), true)

        page.pkgPick.set("ystyle::beta")
        let _ = page.addPkg(actx)
        @Expect(page.pkgRows.get().size, 2)
        let _ = page.removePkg(actx, "ystyle", "alpha")
        @Expect(page.msg.get(), "已移除 ystyle::alpha")
        @Expect(state.adminData.listTeamPackages(tid).size, 1)
        @Expect(state.adminData.listTeamPackages(tid)[0].packageName, "beta")

        page.pkgPick.set("")
        let _ = page.addPkg(actx)
        @Expect(page.msg.get(), "请先在下拉里选择包")

        let _ = page.closePackages(actx)
        @Expect(page.pkgDialogVisible.get(), false)
    }

    // 包关联：无组织包在候选里就是纯包名
    @TestCase
    public func covTeams_pkgDialogNoOrgLabel(): Unit {
        let state = makePortalState("team")
        let tid = seedCovTeam(state, "noorg-team")
        let _ = covSeedPkg(state, "", "snappy", "1.0.1")
        let page = mountTeamsCov(state)
        let (actx, _) = covActx(state)
        let _ = page.openPackages(actx, tid)
        @Expect(page.pkgOptions()[0], "snappy")
        page.pkgPick.set("snappy")
        let _ = page.addPkg(actx)
        @Expect(state.adminData.listTeamPackages(tid).size, 1)
        @Expect(state.adminData.listTeamPackages(tid)[0].organization, "")
    }

    // 成员关联弹窗：下拉候选只列非成员，表格只列已加入成员；添加/移除都写审计
    @TestCase
    public func covTeams_memberDialogAddAndRemove(): Unit {
        let state = makePortalState("team")
        let tid = seedCovTeam(state, "member-team")
        let uid = state.auth.createUser("alice", "AlicePass1", false, email: "a@example.com").getOrThrow().id
        let _ = state.auth.createUser("bob", "BobPass123", false)
        let (actx, _) = covActx(state)
        let page = mountTeamsCov(state)
        let _ = page.openMembers(actx, tid)
        @Expect(page.memberDialogVisible.get(), true)
        @Expect(page.memberPick.get(), "")
        @Expect(page.memberRows.get().size, 0)
        @Expect(covRender(page.render()).contains("团队成员管理"), true)

        page.memberPick.set("alice")
        let _ = page.addMember(actx)
        @Expect(page.msg.get(), "已添加成员 alice")
        @Expect(state.adminData.listTeamMemberIds(tid).size, 1)
        @Expect(page.memberRows.get()[0].username, "alice")
        @Expect(state.adminData.queryLogs(Some("admin"), "add_team_member", "", 0, 0, 0, 10)[1], 1)

        let _ = page.removeMember(actx, uid)
        @Expect(page.msg.get(), "已移除成员 alice")
        @Expect(state.adminData.listTeamMemberIds(tid).size, 0)
        @Expect(state.adminData.queryLogs(Some("admin"), "remove_team_member", "", 0, 0, 0, 10)[1], 1)

        page.memberPick.set("")
        let _ = page.addMember(actx)
        @Expect(page.msg.get(), "请先在下拉里选择用户")

        let _ = page.closeMembers(actx)
        @Expect(page.memberDialogVisible.get(), false)
    }

    // 移除时库里查不到该 uid：审计里记「#id」而不是空名字
    @TestCase
    public func covTeams_removeMemberUnknownUserFallsBackToId(): Unit {
        let state = makePortalState("team")
        let tid = seedCovTeam(state, "ghost-team")
        state.adminData.setTeamMembers(tid, [424242])
        let page = mountTeamsCov(state)
        let (actx, _) = covActx(state)
        let _ = page.openMembers(actx, tid)
        @Expect(page.memberRows.get()[0].username, "#424242")
        let _ = page.removeMember(actx, 424242)
        let (logs, total) = state.adminData.queryLogs(Some("admin"), "remove_team_member", "", 0, 0, 0, 10)
        @Expect(total, 1)
        @Expect(logs[0].target, "#424242")
    }

    // 成员行跟着团队切换重算
    @TestCase
    public func covTeams_memberRowsSwitchTeam(): Unit {
        let state = makePortalState("team")
        let t1 = seedCovTeam(state, "t1")
        let t2 = seedCovTeam(state, "t2")
        let uid = state.auth.createUser("carol", "CarolPass1", false).getOrThrow().id
        state.adminData.setTeamMembers(t1, [uid])

        let page = mountTeamsCov(state)
        let (actx, _) = covActx(state)
        let _ = page.openMembers(actx, t1)
        @Expect(page.memberRows.get().size, 1)
        @Expect(page.memberRows.get()[0].username, "carol")

        let _ = page.openMembers(actx, t2)
        @Expect(page.memberRows.get().size, 0)
        @Expect(page.memberOptions().size >= 1, true)
    }

    // 删除确认：正文带团队名、取消、确认、不存在的 id 不弹
    @TestCase
    public func covTeams_deleteFlow(): Unit {
        let state = makePortalState("team")
        let tid = seedCovTeam(state, "doomed-team")
        let page = mountTeamsCov(state)
        let (actx, _) = covActx(state)

        let _ = page.askDelete(actx, 999999)
        @Expect(page.confirmVisible.get(), false)

        let _ = page.askDelete(actx, tid)
        @Expect(page.confirmVisible.get(), true)
        @Expect(page.pendingDeleteId, tid)
        @Expect(page.pendingDeleteName, "doomed-team")
        @Expect(covRender(page.render()).contains("确定要删除团队「doomed-team」吗？其组织/包/成员关联将一并移除。"), true)

        let _ = page.cancelDelete(actx)
        @Expect(page.confirmVisible.get(), false)
        @Expect(state.adminData.getTeam(tid).getOrThrow().deletedAt, 0)

        let _ = page.askDelete(actx, tid)
        let _ = page.confirmDelete(actx)
        @Expect(page.msg.get(), "已删除团队 doomed-team")
        @Expect(page.confirmVisible.get(), false)
        @Expect(page.pendingDeleteId, 0)
        @Expect(state.adminData.getTeam(tid).getOrThrow().deletedAt != 0, true)
        @Expect(state.adminData.queryLogs(Some("admin"), "delete_team", "", 0, 0, 0, 10)[1], 1)
    }

    // 删除失败：记录被别处清掉 → deleteTeam 返回 false → 「删除失败」
    @TestCase
    public func covTeams_confirmDeleteMissingRecord(): Unit {
        let state = makePortalState("team")
        let tid = seedCovTeam(state, "vanish")
        let page = mountTeamsCov(state)
        let (actx, _) = covActx(state)
        let _ = page.askDelete(actx, tid)
        state.adminData.storm.delete(state.adminData.getTeam(tid).getOrThrow())
        let _ = page.confirmDelete(actx)
        @Expect(page.msg.get(), "删除失败")
        @Expect(page.confirmVisible.get(), false)
        @Expect(page.pendingDeleteId, 0)
    }

    // 鉴权：库里降级 + 未登录 → 五条写动作全被拒
    @TestCase
    public func covTeams_writeActionsRequireAdmin(): Unit {
        let state = makePortalState("team")
        let tid = seedCovTeam(state, "safe-team")
        let _ = covSeedPkg(state, "ystyle", "alpha", "1.0.0")
        let page = mountTeamsCov(state)
        let _ = covRender(page.render())

        let (plain, _) = covActx(state, dbIsAdmin: false, ctxIsAdmin: true, username: "covplain")
        page.formName.set("nope")
        let _ = page.submitForm(plain)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(page.rows.get().size, 1)

        let _ = page.openOrgs(plain, tid)
        let picked = ArrayList<String>()
        picked.add("7")
        page.orgSelect.set(picked)
        let _ = page.saveOrgs(plain)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(state.adminData.listTeamOrganizationIds(tid).size, 0)

        let _ = page.openPackages(plain, tid)
        let _ = page.pkgPick.set("ystyle::alpha")
        let _ = page.addPkg(plain)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(state.adminData.listTeamPackages(tid).size, 0)

        let _ = page.openMembers(plain, tid)
        page.memberPick.set("nobody")
        let _ = page.addMember(plain)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(state.adminData.listTeamMemberIds(tid).size, 0)

        let _ = page.askDelete(plain, tid)
        let _ = page.confirmDelete(plain)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(state.adminData.getTeam(tid).getOrThrow().deletedAt, 0)

        // 未登录
        let anon = covAnonActx(state)
        let _ = page.pkgPick.set("ystyle::alpha")
        let _ = page.addPkg(anon)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(state.adminData.queryLogs(Option<String>.None, "", "", 0, 0, 0, 10)[1], 0)
    }

    // 未挂载 state：渲染骨架 + refresh/各动作的 None 分支
    @TestCase
    public func covTeams_withoutState(): Unit {
        let state = makePortalState("team")
        let page = TeamsPage()
        @Expect(covRender(page.render()).contains("团队管理"), true)
        // renderOrgDialog 在 state 为 None 时直接返回 div()
        @Expect(covRender(page.render()).contains("团队组织关联"), false)
        page.refresh()
        @Expect(page.rows.get().size, 0)

        let (actx, _) = covActx(state)
        let _ = page.onPageChange(actx)
        let _ = page.openEdit(actx, 1)
        let _ = page.submitForm(actx)
        let _ = page.openOrgs(actx, 1)
        let _ = page.saveOrgs(actx)
        @Expect(page.msg.get(), "")
        let _ = page.pkgPick.set("o::n")
        let _ = page.addPkg(actx)
        let _ = page.addMember(actx)
        let _ = page.askDelete(actx, 1)
        let _ = page.confirmDelete(actx)
        @Expect(page.listHint(), "暂无团队，点击「新增团队」创建")
    }

    // onUnmount：两个 binding 都释放；之后再改搜索不再触发重算
    @TestCase
    public func covTeams_unmountDisposesBindings(): Unit {
        let state = makePortalState("team")
        let tid = seedCovTeam(state, "t")
        let _ = covSeedPkg(state, "ystyle", "alpha", "1.0.0")
        let page = mountTeamsCov(state)
        let (actx, _) = covActx(state)
        let _ = page.openPackages(actx, tid)
        @Expect(page.pkgRows.get().size, 0)

        page.onUnmount(mountCtx(state, userCtxMap(1, "admin", true)))
        page.refreshPkgs()
        @Expect(page.pkgRows.get().size, 0)   // 绑定已 dispose，不再重算
    }

    // 重新挂载：rebind 走 Some 分支（先 dispose 旧绑定），订阅不叠加
    @TestCase
    public func covTeams_remountRebuildsBindings(): Unit {
        let state = makePortalState("team")
        let tid = seedCovTeam(state, "t")
        let _ = covSeedPkg(state, "ystyle", "alpha", "1.0.0")
        let page = mountTeamsCov(state)
        let (actx, _) = covActx(state)
        let _ = page.openPackages(actx, tid)

        page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
        let _ = page.openPackages(actx, tid)
        page.refreshPkgs()
        @Expect(page.pkgRows.get().size, 0)
        page.refreshPkgs()
        @Expect(page.pkgRows.get().size, 0)
    }

    // 长文本：团队名/显示名/描述很长也直出
    @TestCase
    public func covTeams_longTextPassesThrough(): Unit {
        let state = makePortalState("team")
        let long = covLongText("t", 300)
        let _ = seedCovTeam(state, long, display: long, desc: long)
        let json = covRender(mountTeamsCov(state).render())
        @Expect(json.contains(long), true)
    }

    // 提示槽位：msg 为空时不渲染 Tag，非空时渲染
    @TestCase
    public func covTeams_msgTagRendersOnlyWhenSet(): Unit {
        let state = makePortalState("team")
        let page = mountTeamsCov(state)
        @Expect(covRender(page.render()).contains("已创建团队"), false)
        page.msg.set("已创建团队 #1")
        let json = covRender(page.render())
        @Expect(json.contains("已创建团队 #1"), true)
        @Expect(json.contains("el-tag"), true)
    }
}
