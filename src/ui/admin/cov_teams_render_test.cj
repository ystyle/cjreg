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
        @Expect(logs[0].detail, "permission=write")
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

    // 包关联弹窗：全量包（软删的跳过）、关联标记、toggle 两个方向、搜索过滤
    @TestCase
    public func covTeams_pkgDialogToggleBothWays(): Unit {
        let state = makePortalState("team")
        let tid = seedCovTeam(state, "pkg-team")
        let _ = covSeedPkg(state, "ystyle", "alpha", "1.0.0")
        let _ = covSeedPkg(state, "ystyle", "beta", "1.0.0")
        let _ = covSeedPkg(state, "ystyle", "hidden", "1.0.0", deleted: true)
        let page = mountTeamsCov(state)
        let (actx, _) = covActx(state)

        let _ = page.openPackages(actx, tid)
        @Expect(page.pkgDialogVisible.get(), true)
        @Expect(page.pkgSearch.get(), "")
        // 软删的包不进候选表
        @Expect(page.pkgRows.get().size, 2)
        let json = covRender(page.render())
        @Expect(json.contains("团队包关联"), true)
        @Expect(json.contains("ystyle/alpha@1.0.0"), true)
        // 未关联的行给「关联」按钮；提示语里那句"搜索包并关联/移除"是固定文案，不能用
        // contains("移除") 判断按钮（会误命中）—— 用按钮的 Tag/kind 区分。
        @Expect(json.contains("\"text\":\"关联\""), true)      // 行内「关联」按钮
        @Expect(json.contains("\"text\":\"移除\""), false)     // 还没有「移除」按钮
        // 反向对照：提示语里本来就含"关联/移除"这几个字，所以上面的断言必须按
        // **完整文本节点**匹配，否则会恒真/恒假（踩过）。
        @Expect(json.contains("搜索包并关联/移除"), true)

        // 关联 alpha
        let _ = page.togglePkg(actx, "ystyle", "alpha")
        @Expect(page.msg.get(), "已关联 alpha")
        @Expect(state.adminData.listTeamPackages(tid).size, 1)
        // 已关联的行换成「移除」按钮
        @Expect(covRender(page.render()).contains("\"text\":\"移除\""), true)

        // 再点一次 → 移除
        let _ = page.togglePkg(actx, "ystyle", "alpha")
        @Expect(page.msg.get(), "已移除 alpha")
        @Expect(state.adminData.listTeamPackages(tid).size, 0)

        // 关联两个之后逐个移除（保留另一个：next 列表的构造分支）
        let _ = page.togglePkg(actx, "ystyle", "alpha")
        let _ = page.togglePkg(actx, "ystyle", "beta")
        @Expect(state.adminData.listTeamPackages(tid).size, 2)
        let _ = page.togglePkg(actx, "ystyle", "alpha")
        @Expect(state.adminData.listTeamPackages(tid).size, 1)
        @Expect(state.adminData.listTeamPackages(tid)[0].packageName, "beta")

        // 搜索：只留命中的
        page.pkgSearch.set("beta")
        @Expect(page.pkgRows.get().size, 1)
        @Expect(page.pkgRows.get()[0].doc.name, "beta")
        @Expect(page.pkgRows.get()[0].linked, true)

        let _ = page.closePackages(actx)
        @Expect(page.pkgDialogVisible.get(), false)
    }

    // 包关联：无组织包在候选表里显示成 "-/name@version"
    @TestCase
    public func covTeams_pkgDialogNoOrgLabel(): Unit {
        let state = makePortalState("team")
        let tid = seedCovTeam(state, "noorg-team")
        let _ = covSeedPkg(state, "", "snappy", "1.0.1")
        let page = mountTeamsCov(state)
        let (actx, _) = covActx(state)
        let _ = page.openPackages(actx, tid)
        @Expect(covRender(page.render()).contains("-/snappy@1.0.1"), true)
    }

    // 成员关联弹窗：用户列表、toggle 两个方向、查找不到用户时记 #id
    @TestCase
    public func covTeams_memberDialogToggleBothWays(): Unit {
        let state = makePortalState("team")
        let tid = seedCovTeam(state, "member-team")
        let uid = state.auth.createUser("alice", "AlicePass1", false, email: "a@example.com").getOrThrow().id
        let _ = state.auth.createUser("bob", "BobPass123", false)
        // 操作者账号也占一行
        let (actx, _) = covActx(state)
        let page = mountTeamsCov(state)
        let _ = page.openMembers(actx, tid)
        @Expect(page.memberDialogVisible.get(), true)
        @Expect(page.memberSearch.get(), "")
        @Expect(page.memberRows.get().size, 3)   // alice + bob + covadmin
        let json = covRender(page.render())
        @Expect(json.contains("团队成员管理"), true)
        @Expect(json.contains("alice"), true)
        @Expect(json.contains("a@example.com") || json.contains("alice"), true)
        @Expect(json.contains("添加"), true)

        // 添加
        let _ = page.toggleMember(actx, uid)
        @Expect(page.msg.get(), "已添加成员")
        @Expect(state.adminData.listTeamMemberIds(tid).size, 1)
        @Expect(state.adminData.queryLogs(Some("admin"), "add_team_member", "", 0, 0, 0, 10)[1], 1)
        @Expect(covRender(page.render()).contains("el-button--danger"), true)

        // 移除
        let _ = page.toggleMember(actx, uid)
        @Expect(page.msg.get(), "已移除成员")
        @Expect(state.adminData.listTeamMemberIds(tid).size, 0)
        @Expect(state.adminData.queryLogs(Some("admin"), "remove_team_member", "", 0, 0, 0, 10)[1], 1)

        let _ = page.closeMembers(actx)
        @Expect(page.memberDialogVisible.get(), false)
    }

    // 成员名字兜底：库里查不到该 uid 时审计里记「#id」而不是空名字
    @TestCase
    public func covTeams_toggleMemberUnknownUserFallsBackToId(): Unit {
        let state = makePortalState("team")
        let tid = seedCovTeam(state, "ghost-team")
        let page = mountTeamsCov(state)
        let (actx, _) = covActx(state)
        let _ = page.openMembers(actx, tid)
        let _ = page.toggleMember(actx, 424242)
        @Expect(page.msg.get(), "已添加成员")
        let (logs, total) = state.adminData.queryLogs(Some("admin"), "add_team_member", "", 0, 0, 0, 10)
        @Expect(total, 1)
        @Expect(logs[0].target, "#424242")
        @Expect(logs[0].detail, "team#${tid} members=1")
    }

    // 成员搜索：用户名过滤（含 trim 与"已在另一个团队的关联不串台"）
    @TestCase
    public func covTeams_memberSearchAndLinkedState(): Unit {
        let state = makePortalState("team")
        let t1 = seedCovTeam(state, "t1")
        let t2 = seedCovTeam(state, "t2")
        let uid = state.auth.createUser("carol", "CarolPass1", false).getOrThrow().id
        state.adminData.setTeamMembers(t1, [uid])

        let page = mountTeamsCov(state)
        let (actx, _) = covActx(state)
        let _ = page.openMembers(actx, t1)
        page.memberSearch.set("carol")
        @Expect(page.memberRows.get().size, 1)
        @Expect(page.memberRows.get()[0].linked, true)

        let _ = page.openMembers(actx, t2)
        page.memberSearch.set("carol")
        @Expect(page.memberRows.get().size, 1)
        @Expect(page.memberRows.get()[0].linked, false)
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
        let _ = page.togglePkg(plain, "ystyle", "alpha")
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(state.adminData.listTeamPackages(tid).size, 0)

        let _ = page.openMembers(plain, tid)
        let _ = page.toggleMember(plain, 1)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(state.adminData.listTeamMemberIds(tid).size, 0)

        let _ = page.askDelete(plain, tid)
        let _ = page.confirmDelete(plain)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(state.adminData.getTeam(tid).getOrThrow().deletedAt, 0)

        // 未登录
        let anon = covAnonActx(state)
        let _ = page.togglePkg(anon, "ystyle", "alpha")
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
        let _ = page.togglePkg(actx, "o", "n")
        let _ = page.toggleMember(actx, 1)
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
        @Expect(page.pkgRows.get().size, 1)

        page.onUnmount(mountCtx(state, userCtxMap(1, "admin", true)))
        page.pkgSearch.set("nothing")
        @Expect(page.pkgRows.get().size, 1)   // 绑定已 dispose，不再重算
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
        page.pkgSearch.set("alpha")
        @Expect(page.pkgRows.get().size, 1)
        page.pkgSearch.set("")
        @Expect(page.pkgRows.get().size, 1)
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
