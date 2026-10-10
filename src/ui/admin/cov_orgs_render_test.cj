// 组织管理页（/admin/organizations）渲染 + 交互回归。
//
// 原先行覆盖 0.6%（只有类声明被踩到）。这一页的分支：
//   * 列表：默认/普通两个 Tag、空态提示、分页切片与越界；
//   * 新增/编辑弹窗两态（编辑时组织名输入框禁用）、必填校验（errorSignal 落到 nameError）；
//   * 删除确认（先取 org 再弹、取消、确认；不存在的 id 不弹）；
//   * 三个写动作的鉴权（库里被降级 / 未登录）；
//   * 未挂载 state 的 None 分支。
package ystyle::cjreg.ui.admin

import ystyle::cjreg.ui.*
import cjxt.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

func mountOrgs(state: CjregState): OrganizationsPage {
    let page = OrganizationsPage()
    page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
    page
}

@Test
public class CovOrgsRenderTest {
    // 空态：提示 + 表格并存；新增按钮与列表卡片标题都在
    @TestCase
    public func covOrgs_emptyState(): Unit {
        let state = makePortalState("team")
        let page = mountOrgs(state)
        @Expect(page.rows.get().size, 0)
        @Expect(page.total.get(), 0)
        let json = covRenderExpanded(page.render())
        @Expect(json.contains("暂无组织，点击「新增组织」创建"), true)
        @Expect(json.contains("el-table"), true)
        @Expect(json.contains("组织管理"), true)
        @Expect(json.contains("组织列表"), true)
        @Expect(json.contains("新增组织"), true)
        @Expect(json.contains("刷新"), false)   // 这一页没有刷新按钮
    }

    // 有数据：ID/组织名/显示名/描述/默认列都在；默认 Tag 两档都渲染
    @TestCase
    public func covOrgs_rowsAndDefaultTag(): Unit {
        let state = makePortalState("team")
        let _ = state.adminData.createOrg("ystyle", "ystyle 官方", 1, 1000,
            description: "官方组织", isDefault: true)
        let _ = state.adminData.createOrg("acme", "", 1, 1000)
        let page = mountOrgs(state)
        @Expect(page.rows.get().size, 2)
        let json = covRender(page.render())
        for (label in ["ID", "组织名", "显示名", "描述", "默认", "操作"]) {
            @Expect(json.contains(label), true)
        }
        @Expect(json.contains("ystyle"), true)
        @Expect(json.contains("官方组织"), true)
        @Expect(json.contains("el-tag--primary"), true)   // 默认
        @Expect(json.contains("el-tag--info"), true)      // 普通
        @Expect(json.contains("编辑"), true)
        @Expect(json.contains("删除"), true)
    }

    // 软删的组织不出现在列表（listOrgs 过滤 deletedAt）
    @TestCase
    public func covOrgs_softDeletedOrgHidden(): Unit {
        let state = makePortalState("team")
        let keep = state.adminData.createOrg("keep", "", 1, 1000)
        let gone = state.adminData.createOrg("gone", "", 1, 1000)
        let _ = state.adminData.deleteOrg(gone, 2000)
        let page = mountOrgs(state)
        @Expect(page.total.get(), 1)
        @Expect(page.rows.get()[0].id, keep)
        @Expect(covRender(page.render()).contains("gone"), false)
    }

    // 分页：切片 + 越界页返回空切片并触发空态提示
    @TestCase
    public func covOrgs_pagination(): Unit {
        let state = makePortalState("team")
        for (i in 0..5) {
            let _ = state.adminData.createOrg("org-${i}", "", 1, 1000)
        }
        let page = mountOrgs(state)
        let (actx, _) = covActx(state)
        @Expect(page.total.get(), 5)

        page.pageSize.set(2)
        let _ = page.onPageChange(actx)
        @Expect(page.rows.get().size, 2)
        @Expect(page.rows.get()[0].name, "org-0")

        page.currentPage.set(3)
        let _ = page.onPageChange(actx)
        @Expect(page.rows.get().size, 1)
        @Expect(page.rows.get()[0].name, "org-4")

        page.currentPage.set(50)
        let _ = page.onPageChange(actx)
        @Expect(page.rows.get().size, 0)
        @Expect(page.listHint(), "暂无组织，点击「新增组织」创建")
    }

    // 新增弹窗：openCreate 复位全部字段并打开；渲染出「新增组织」标题
    @TestCase
    public func covOrgs_openCreateResetsForm(): Unit {
        let state = makePortalState("team")
        let page = mountOrgs(state)
        page.formName.set("dirty")
        page.formDisplay.set("dirty")
        page.formDesc.set("dirty")
        page.formIsDefault.set(true)
        page.nameError.set("旧错误")

        let (actx, _) = covActx(state)
        let _ = page.openCreate(actx)
        @Expect(page.dialogVisible.get(), true)
        @Expect(page.dialogMode.get(), "create")
        @Expect(page.formName.get(), "")
        @Expect(page.formDisplay.get(), "")
        @Expect(page.formDesc.get(), "")
        @Expect(page.formIsDefault.get(), false)
        @Expect(page.nameError.get(), "")
        let json = covRender(page.render())
        @Expect(json.contains("新增组织"), true)
        @Expect(json.contains("el-dialog"), true)
    }

    // 新增成功：落库 + 提示 + 关弹窗 + 写审计（uiAuditAs 带 isDefault 详情）
    @TestCase
    public func covOrgs_submitCreateSucceeds(): Unit {
        let state = makePortalState("team")
        let page = mountOrgs(state)
        let _ = covRender(page.render())   // 建出 orgForm
        let (actx, _) = covActx(state)

        let _ = page.openCreate(actx)
        page.formName.set("newco")
        page.formDisplay.set("新公司")
        page.formDesc.set("描述")
        page.formIsDefault.set(true)
        let _ = page.submitForm(actx)

        @Expect(page.msg.get().startsWith("已创建组织 #"), true)
        @Expect(page.dialogVisible.get(), false)
        @Expect(page.rows.get().size, 1)
        let created = page.rows.get()[0]
        @Expect(created.name, "newco")
        @Expect(created.displayName, "新公司")
        @Expect(created.description, "描述")
        @Expect(created.isDefault, true)

        let (logs, total) = state.adminData.queryLogs(Some("admin"), "create_org", "", 0, 0, 0, 10)
        @Expect(total, 1)
        @Expect(logs[0].target, "newco")
        @Expect(logs[0].detail, "isDefault=true")
        @Expect(logs[0].actorName, "covadmin")
        @Expect(covRender(page.render()).contains(page.msg.get()), true)
    }

    // 必填校验：组织名为空 → nameError 写「组织名必填」，不落库
    @TestCase
    public func covOrgs_submitCreateRequiresName(): Unit {
        let state = makePortalState("team")
        let page = mountOrgs(state)
        let _ = covRender(page.render())
        let (actx, _) = covActx(state)
        let _ = page.openCreate(actx)
        page.formName.set("")
        let _ = page.submitForm(actx)
        @Expect(page.nameError.get(), "组织名必填")
        @Expect(page.rows.get().size, 0)
        @Expect(page.msg.get(), "")
        @Expect(covRender(page.render()).contains("组织名必填"), true)
    }

    // 编辑：openEdit 回填、标题变「编辑组织」、组织名输入框禁用、提交后写库并写审计
    @TestCase
    public func covOrgs_openEditAndSubmit(): Unit {
        let state = makePortalState("team")
        let id = state.adminData.createOrg("oldname", "旧显示名", 1, 1000, description: "旧描述")
        let page = mountOrgs(state)
        let (actx, _) = covActx(state)
        let _ = page.openEdit(actx, id)

        @Expect(page.dialogMode.get(), "edit")
        @Expect(page.editingId, id)
        @Expect(page.formName.get(), "oldname")
        @Expect(page.formDisplay.get(), "旧显示名")
        @Expect(page.formDesc.get(), "旧描述")
        @Expect(page.formIsDefault.get(), false)
        let json = covRender(page.render())
        @Expect(json.contains("编辑组织"), true)
        @Expect(json.contains("\"disabled\":\"disabled\""), true)

        page.formDisplay.set("新显示名")
        page.formDesc.set("新描述")
        page.formIsDefault.set(true)
        let _ = page.submitForm(actx)
        @Expect(page.msg.get(), "已更新组织 oldname")
        @Expect(page.dialogVisible.get(), false)
        let after = state.adminData.getOrg(id).getOrThrow()
        @Expect(after.displayName, "新显示名")
        @Expect(after.description, "新描述")
        @Expect(after.isDefault, true)
        @Expect(after.name, "oldname")   // 这一页不改名（updateOrg 的 newName 不传）
        let (_, total) = state.adminData.queryLogs(Some("admin"), "update_org", "", 0, 0, 0, 10)
        @Expect(total, 1)
    }

    // 编辑目标已被删掉 → updateOrg 返回 false → 「更新失败」
    @TestCase
    public func covOrgs_submitEditMissingTarget(): Unit {
        let state = makePortalState("team")
        let id = state.adminData.createOrg("x", "", 1, 1000)
        let page = mountOrgs(state)
        let _ = covRender(page.render())
        let (actx, _) = covActx(state)
        let _ = page.openEdit(actx, id)
        page.editingId = 999999
        let _ = page.submitForm(actx)
        @Expect(page.msg.get(), "更新失败")
    }

    // openEdit 遇到不存在的 id：弹窗不开、字段不动
    @TestCase
    public func covOrgs_openEditMissingIdDoesNothing(): Unit {
        let state = makePortalState("team")
        let page = mountOrgs(state)
        let (actx, _) = covActx(state)
        page.formName.set("keep")
        let _ = page.openEdit(actx, 999999)
        @Expect(page.dialogVisible.get(), false)
        @Expect(page.formName.get(), "keep")
    }

    // 关弹窗
    @TestCase
    public func covOrgs_closeDialog(): Unit {
        let state = makePortalState("team")
        let page = mountOrgs(state)
        let (actx, _) = covActx(state)
        let _ = page.openCreate(actx)
        @Expect(page.dialogVisible.get(), true)
        let _ = page.closeDialog(actx)
        @Expect(page.dialogVisible.get(), false)
        @Expect(covRender(page.render()).contains("el-dialog"), false)
    }

    // 删除确认：正文里带组织名（现读 pendingDeleteName 字段）
    @TestCase
    public func covOrgs_deleteConfirmShowsName(): Unit {
        let state = makePortalState("team")
        let id = state.adminData.createOrg("victim", "", 1, 1000)
        let page = mountOrgs(state)
        let (actx, _) = covActx(state)
        let _ = page.askDelete(actx, id)
        @Expect(page.confirmVisible.get(), true)
        @Expect(page.pendingDeleteId, id)
        @Expect(page.pendingDeleteName, "victim")
        let json = covRender(page.render())
        @Expect(json.contains("确定要删除组织「victim」吗？"), true)
        @Expect(json.contains("删除确认"), true)

        // 不存在的 id：不弹
        page.confirmVisible.set(false)
        let _ = page.askDelete(actx, 999999)
        @Expect(page.confirmVisible.get(), false)
    }

    // 取消删除：关框、数据还在
    @TestCase
    public func covOrgs_cancelDelete(): Unit {
        let state = makePortalState("team")
        let id = state.adminData.createOrg("keepme", "", 1, 1000)
        let page = mountOrgs(state)
        let (actx, _) = covActx(state)
        let _ = page.askDelete(actx, id)
        let _ = page.cancelDelete(actx)
        @Expect(page.confirmVisible.get(), false)
        @Expect(state.adminData.getOrg(id).getOrThrow().deletedAt, 0)
    }

    // 确认删除：软删 + 提示 + 审计 + 待删 id 复位
    //
    // 注意断言的口径：这一页的 confirmDelete **不重查列表**（compare plan_list.confirmDelete 里的
    // this.refresh()），所以删完之后那一行仍留在表格上，直到分页/再次 refresh 才消失。
    // 这里守住的是"库与提示已正确落定"，行消失与否由紧随其后的 refresh() 断言覆盖；
    // 「删完行还挂着」这条体验缺口记在交付说明里，不在测试里当正确行为固化。
    @TestCase
    public func covOrgs_confirmDelete(): Unit {
        let state = makePortalState("team")
        let id = state.adminData.createOrg("doomed", "", 1, 1000)
        let page = mountOrgs(state)
        let (actx, _) = covActx(state)
        @Expect(page.rows.get().size, 1)
        let _ = page.askDelete(actx, id)
        let _ = page.confirmDelete(actx)

        @Expect(page.msg.get(), "已删除组织 doomed")
        @Expect(page.confirmVisible.get(), false)
        @Expect(page.pendingDeleteId, 0)
        @Expect(state.adminData.getOrg(id).getOrThrow().deletedAt != 0, true)
        @Expect(state.adminData.listOrgs().size, 0)
        let (_, total) = state.adminData.queryLogs(Some("admin"), "delete_org", "", 0, 0, 0, 10)
        @Expect(total, 1)

        // 显式重查后行才消失（listOrgs 已过滤软删）
        page.refresh()
        @Expect(page.rows.get().size, 0)
        @Expect(page.total.get(), 0)
        @Expect(page.listHint(), "暂无组织，点击「新增组织」创建")
        @Expect(covRender(page.render()).contains("已删除组织 doomed"), true)

        // 再删一次同一 id（已被软删，但记录还在）：deleteOrg 仍返回 true → 再报一次已删除
        let _ = page.askDelete(actx, id)
        let _ = page.confirmDelete(actx)
        @Expect(page.msg.get(), "已删除组织 doomed")
    }

    // 删除失败分支：记录已被硬删（store 里没有了）→ deleteOrg 返回 false → 「删除失败」
    @TestCase
    public func covOrgs_confirmDeleteMissingRecord(): Unit {
        let state = makePortalState("team")
        let id = state.adminData.createOrg("vanished", "", 1, 1000)
        let page = mountOrgs(state)
        let (actx, _) = covActx(state)
        let _ = page.askDelete(actx, id)
        // 弹确认框之后记录被别处清掉
        state.adminData.storm.delete(state.adminData.getOrg(id).getOrThrow())
        let _ = page.confirmDelete(actx)
        @Expect(page.msg.get(), "删除失败")
        @Expect(page.confirmVisible.get(), false)
        @Expect(page.pendingDeleteId, 0)
    }

    // 权限：库里已降级 + 未登录，三个写动作都被拒且不落库/不写审计
    @TestCase
    public func covOrgs_writeActionsRequireAdmin(): Unit {
        let state = makePortalState("team")
        let id = state.adminData.createOrg("safe", "", 1, 1000)
        let page = mountOrgs(state)
        let _ = covRender(page.render())

        let (plain, _) = covActx(state, dbIsAdmin: false, ctxIsAdmin: true, username: "covplain")
        page.formName.set("nope")
        let _ = page.submitForm(plain)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(page.rows.get().size, 1)

        let _ = page.askDelete(plain, id)
        let _ = page.confirmDelete(plain)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(state.adminData.getOrg(id).getOrThrow().deletedAt, 0)

        // 未登录
        let anon = covAnonActx(state)
        let _ = page.submitForm(anon)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(state.adminData.queryLogs(Option<String>.None, "", "", 0, 0, 0, 10)[1], 0)
    }

    // 未挂载 state：render/refresh/各动作都走 None 分支
    @TestCase
    public func covOrgs_withoutState(): Unit {
        let state = makePortalState("team")
        let page = OrganizationsPage()
        @Expect(covRender(page.render()).contains("组织管理"), true)
        page.refresh()
        @Expect(page.rows.get().size, 0)

        let (actx, _) = covActx(state)
        let _ = page.onPageChange(actx)
        let _ = page.openEdit(actx, 1)
        let _ = page.submitForm(actx)
        let _ = page.askDelete(actx, 1)
        let _ = page.confirmDelete(actx)
        @Expect(page.confirmVisible.get(), false)
        @Expect(page.listHint(), "暂无组织，点击「新增组织」创建")
    }

    // 长文本：显示名/描述很长也不截断（accessor 直出）
    @TestCase
    public func covOrgs_longTextPassesThrough(): Unit {
        let state = makePortalState("team")
        let long = covLongText("d", 300)
        let _ = state.adminData.createOrg("long-org", long, 1, 1000, description: long)
        let json = covRender(mountOrgs(state).render())
        @Expect(json.contains(long), true)
    }

    // msg 为空时不渲染 Tag；非空时渲染（成功提示槽位）
    @TestCase
    public func covOrgs_msgTagRendersOnlyWhenSet(): Unit {
        let state = makePortalState("team")
        let page = mountOrgs(state)
        @Expect(covRender(page.render()).contains("已创建"), false)
        page.msg.set("已创建组织 #7")
        let json = covRender(page.render())
        @Expect(json.contains("已创建组织 #7"), true)
        @Expect(json.contains("el-tag"), true)
    }
}
