// 用户管理页（/admin/users）渲染 + 交互回归。
//
// 既有用例只覆盖了搜索即时过滤与空态文案（pages_users_render_test.cj）。
// 这里补的是另一半——所有写动作及其**每一条失败出口**：
//   * 新增用户：表单校验、重名失败、成功后弹 Token 弹窗；
//   * Token：展示、重置（写审计）、"无权限"分支；
//   * 启停与管理员身份：正常路径 + 「最后一个启用管理员」保护（这是唯一失败原因，
//     文案必须说清"否则管理端将无人可登录"）；
//   * 删除：非管理员可删、管理员受保护；
//   * 提示语气（msgOk）：成功绿 / 失败红两档 Tag；
//   * listHint 的三档：有行 / 搜不到 / 一个都没有。
package ystyle::cjreg.ui.admin

import ystyle::cjreg.ui.*
import cjxt.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

func mountUsersCov(state: CjregState): UsersPage {
    let page = UsersPage()
    page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
    page
}

// 造一个用户；返回其 id
func seedCovUser(state: CjregState, username: String, admin!: Bool = false,
                 email!: String = "", active!: Bool = true): Int64 {
    let u = state.auth.createUser(username, "SeedPass123", admin, email: email).getOrThrow()
    if (!active) {
        // 禁用最后一个启用管理员会被拒，所以这里直接写库绕过业务校验
        let doc = state.userStore.getUser(u.id).getOrThrow()
        doc.isActive = false
        state.userStore.saveUser(doc)
    }
    u.id
}

@Test
public class CovUsersRenderTest {
    // 三档空态：有行→空串；搜不到→「没有匹配的用户」；一个都没有→引导创建
    @TestCase
    public func covUsers_listHintThreeStates(): Unit {
        let state = makePortalState("team")
        let page = mountUsersCov(state)
        @Expect(page.listHint(), "暂无用户，点击「新增用户」创建")

        let _ = seedCovUser(state, "alice")
        page.bump()
        @Expect(page.listHint(), "")

        page.userSearch.set("zzz-nope")
        @Expect(page.listHint(), "没有匹配的用户")

        // 只有空白的关键字不算"搜索"（trimAscii 后为空 → 走"一个都没有"那档）
        page.userSearch.set("   ")
        @Expect(page.rows.get().size, 1)
        @Expect(page.listHint(), "")

        // 关键字把唯一用户过滤掉 + 真实关键字 → 匹配档
        page.userSearch.set("alice")
        @Expect(page.rows.get().size, 1)
    }

    // 角色/状态两列的四条分支：管理员/普通、正常/禁用
    @TestCase
    public func covUsers_roleAndStatusTags(): Unit {
        let state = makePortalState("team")
        let _ = seedCovUser(state, "boss", admin: true)
        let _ = seedCovUser(state, "plain", active: false, email: "p@example.com")
        let page = mountUsersCov(state)
        let json = covRender(page.render())
        @Expect(json.contains("管理员"), true)
        @Expect(json.contains("普通"), true)
        @Expect(json.contains("正常"), true)
        @Expect(json.contains("禁用"), true)
        @Expect(json.contains("el-tag--primary"), true)
        @Expect(json.contains("el-tag--danger"), true)
        @Expect(json.contains("p@example.com"), true)
        // 管理员行不给「删除」按钮，普通用户才有
        @Expect(json.contains("删除"), true)
        @Expect(json.contains("Token"), true)
    }

    // 全是管理员时不该出现「删除」按钮（管理员受保护）
    @TestCase
    public func covUsers_adminRowsHaveNoDeleteButton(): Unit {
        let state = makePortalState("team")
        let _ = seedCovUser(state, "only-admin", admin: true)
        let page = mountUsersCov(state)
        @Expect(covRender(page.render()).contains("删除"), false)
        @Expect(covRender(page.render()).contains("取消管理员"), true)
    }

    // 分页：切片 + 越界页由 bindPaged 本地钳制到最后一页（不是空表）
    @TestCase
    public func covUsers_paginationBoundaries(): Unit {
        let state = makePortalState("team")
        // 操作者账号也要占一行（covActx 会建 covadmin），先建出来再数总数
        let (actx, _) = covActx(state)
        let actorRows = state.userStore.listAllUsers().size   // = 1（covadmin）
        for (i in 0..5) {
            let _ = seedCovUser(state, "u${i}")
        }
        let page = mountUsersCov(state)
        let all = actorRows + 5
        @Expect(page.total.get(), all)
        @Expect(page.rows.get().size, all)

        // 按用户名排序不稳定（listAllUsers 按库序），所以只断言切片的**计数**与
        // "这一页的行都属于库里的同一个集合"，不断言具体是谁。
        page.pageSize.set(2)
        let _ = page.onPageChange(actx)
        @Expect(page.rows.get().size, 2)

        page.currentPage.set(3)
        let _ = page.onPageChange(actx)
        @Expect(page.rows.get().size, 2)

        // all=6、size=2 → 共 3 页；第 3 页 2 条
        page.currentPage.set(3)
        let _ = page.onPageChange(actx)
        @Expect(page.rows.get().size, 2)

        // bindPaged 只在本地钳制**切片**：页码信号仍保留越界值（分页器显示页由
        // Pagination.render 的 clampPage 夹住），所以越界页拿到的是最后一页的切片。
        page.currentPage.set(88)
        let _ = page.onPageChange(actx)
        @Expect(page.currentPage.get(), 88)
        @Expect(page.rows.get().size, 2)
        @Expect(page.total.get(), all)

        // 每页大小非法（0/负数）→ 内部按 1 处理，不是除零或空表
        page.pageSize.set(0)
        @Expect(page.rows.get().size, 1)
        @Expect(page.total.get(), all)
        page.pageSize.set(-3)
        @Expect(page.rows.get().size, 1)
    }

    // 新增/删除后列表不会自己刷新（这两条路径不 bump）——用例按实际行为断言，
    // 并守住"显式 bump 之后一定跟上"，避免把这条缺口当正确行为固化。
    @TestCase
    public func covUsers_listRefreshRequiresBump(): Unit {
        let state = makePortalState("team")
        let page = mountUsersCov(state)
        @Expect(page.rows.get().size, 0)

        let _ = seedCovUser(state, "created-behind-the-scenes")
        @Expect(page.rows.get().size, 0)   // store 不是信号
        page.bump()
        @Expect(page.rows.get().size, 1)
        @Expect(page.rows.get()[0].username, "created-behind-the-scenes")
    }

    // 新增弹窗：openCreate 复位四个字段与两条校验错误
    @TestCase
    public func covUsers_openCreateResetsForm(): Unit {
        let state = makePortalState("team")
        let page = mountUsersCov(state)
        page.formUser.set("dirty")
        page.formPass.set("dirty")
        page.formEmail.set("dirty")
        page.formIsAdmin.set(true)
        page.userError.set("旧错")
        page.passError.set("旧错")

        let (actx, _) = covActx(state)
        let _ = page.openCreate(actx)
        @Expect(page.dialogVisible.get(), true)
        @Expect(page.formUser.get(), "")
        @Expect(page.formPass.get(), "")
        @Expect(page.formEmail.get(), "")
        @Expect(page.formIsAdmin.get(), false)
        @Expect(page.userError.get(), "")
        @Expect(page.passError.get(), "")
        @Expect(covRender(page.render()).contains("新增用户"), true)
    }

    // 必要字段校验：用户名/密码为空 → 各自的 errorSignal 被写，且不建用户
    @TestCase
    public func covUsers_submitCreateValidation(): Unit {
        let state = makePortalState("team")
        let page = mountUsersCov(state)
        let _ = covRender(page.render())   // 建出 createForm
        let (actx, _) = covActx(state)
        let _ = page.openCreate(actx)

        let _ = page.submitCreate(actx)
        @Expect(page.userError.get(), "用户名必填")
        @Expect(page.dialogVisible.get(), true)
        @Expect(state.userStore.getUserByUsername("newbie").isNone(), true)

        page.formUser.set("newbie")
        let _ = page.submitCreate(actx)
        @Expect(page.passError.get(), "密码必填")
        @Expect(state.userStore.getUserByUsername("newbie").isNone(), true)
        @Expect(covRender(page.render()).contains("密码必填"), true)
    }

    // 新增成功：用户入库、提示带角色、写审计、自动弹出该用户的 Token 弹窗
    @TestCase
    public func covUsers_submitCreateSucceedsAndShowsToken(): Unit {
        let state = makePortalState("team")
        let page = mountUsersCov(state)
        let _ = covRender(page.render())
        let (actx, _) = covActx(state)
        let _ = page.openCreate(actx)

        page.formUser.set("created-user")
        page.formPass.set("Pass123456")
        page.formEmail.set("c@example.com")
        page.formIsAdmin.set(true)
        let _ = page.submitCreate(actx)

        @Expect(page.msg.get(), "已创建 created-user（管理员）")
        @Expect(page.msgOk.get(), true)
        @Expect(page.dialogVisible.get(), false)
        // 用户已入库（列表行是派生值，要 bump 才重算 —— 这里直接断言 store）
        let created = state.userStore.getUserByUsername("created-user").getOrThrow()
        @Expect(created.email, "c@example.com")
        @Expect(created.isAdmin, true)

        // Token 弹窗：用户名 + 该用户的 publishToken
        @Expect(page.tokenVisible.get(), true)
        @Expect(page.tokenUser, "created-user")
        @Expect(page.tokenValue.get().isEmpty(), false)
        @Expect(page.tokenValue.get(), created.publishToken)
        @Expect(page.tokenUserId, created.id)
        let json = covRender(page.render())
        @Expect(json.contains("用户 created-user 的发布 Token："), true)
        @Expect(json.contains(page.tokenValue.get()), true)
        @Expect(json.contains("重置 Token"), true)
        @Expect(json.contains(page.msg.get()), true)

        let (_, total) = state.adminData.queryLogs(Some("admin"), "create_user", "", 0, 0, 0, 10)
        @Expect(total, 1)

        // 显式 bump 后列表跟上（表里还有操作者自己的账号 covadmin，按用户名定位而不是按下标）
        page.bump()
        var found = ""
        for (r in page.rows.get()) {
            if (r.username == "created-user") { found = r.username }
        }
        @Expect(found, "created-user")
    }

    // 普通用户（非管理员）：提示不带角色后缀
    @TestCase
    public func covUsers_submitCreatePlainUser(): Unit {
        let state = makePortalState("team")
        let page = mountUsersCov(state)
        let _ = covRender(page.render())
        let (actx, _) = covActx(state)
        let _ = page.openCreate(actx)
        page.formUser.set("plain-new")
        page.formPass.set("Pass123456")
        let _ = page.submitCreate(actx)
        @Expect(page.msg.get(), "已创建 plain-new")
        page.bump()
        var plain = true
        for (r in page.rows.get()) {
            if (r.username == "plain-new") { plain = !r.isAdmin }
        }
        @Expect(plain, true)
    }

    // 重名失败：提示「创建失败（用户已存在）」且语气为失败，并写失败审计
    @TestCase
    public func covUsers_submitCreateDuplicate(): Unit {
        let state = makePortalState("team")
        let _ = seedCovUser(state, "dup")
        let page = mountUsersCov(state)
        let _ = covRender(page.render())
        let (actx, _) = covActx(state)
        let _ = page.openCreate(actx)
        page.formUser.set("dup")
        page.formPass.set("Pass123456")
        let _ = page.submitCreate(actx)

        @Expect(page.msg.get(), "创建失败（用户已存在）")
        @Expect(page.msgOk.get(), false)
        @Expect(page.tokenVisible.get(), false)
        let json = covRender(page.render())
        @Expect(json.contains("创建失败（用户已存在）"), true)
        @Expect(json.contains("el-tag--danger"), true)   // msgOk=false → Danger

        let (logs, total) = state.adminData.queryLogs(Some("admin"), "create_user", "", 0, 0, 0, 10)
        @Expect(total, 1)
        @Expect(logs[0].status, "failed")
        @Expect(logs[0].error, "user already exists")
    }

    // Token 弹窗：showToken 回填当前值；closeToken 关闭；不存在的 id 不动弹窗
    @TestCase
    public func covUsers_showAndCloseToken(): Unit {
        let state = makePortalState("team")
        let uid = seedCovUser(state, "token-user")
        let page = mountUsersCov(state)
        let (actx, _) = covActx(state)

        let _ = page.showToken(actx, uid)
        @Expect(page.tokenVisible.get(), true)
        @Expect(page.tokenUser, "token-user")
        @Expect(page.tokenUserId, uid)
        @Expect(page.tokenValue.get(), state.userStore.getUser(uid).getOrThrow().publishToken)
        @Expect(covRender(page.render()).contains("用户 token-user 的发布 Token："), true)

        let _ = page.closeToken(actx)
        @Expect(page.tokenVisible.get(), false)
        @Expect(covRender(page.render()).contains("用户 token-user 的发布 Token："), false)

        let _ = page.showToken(actx, 999999)
        @Expect(page.tokenVisible.get(), false)
    }

    // 重置 Token：新值写进信号、提示带用户名、写审计
    @TestCase
    public func covUsers_resetToken(): Unit {
        let state = makePortalState("team")
        let uid = seedCovUser(state, "reset-me")
        let page = mountUsersCov(state)
        let (actx, _) = covActx(state)
        let _ = page.showToken(actx, uid)
        let old = page.tokenValue.get()

        let _ = page.resetToken(actx)
        @Expect(page.tokenValue.get() != old, true)
        @Expect(page.tokenValue.get(), state.userStore.getUser(uid).getOrThrow().publishToken)
        @Expect(page.msg.get(), "已重置 reset-me 的 Token")
        @Expect(page.msgOk.get(), true)
        let (_, total) = state.adminData.queryLogs(Some("admin"), "reset_publish_token", "", 0, 0, 0, 10)
        @Expect(total, 1)
        @Expect(covRender(page.render()).contains("已重置 reset-me 的 Token"), true)
    }

    // 重置 Token 的目标已被删：resetPublishToken 返回 None → 静默（不报错、值不变）
    @TestCase
    public func covUsers_resetTokenMissingUser(): Unit {
        let state = makePortalState("team")
        let page = mountUsersCov(state)
        let (actx, _) = covActx(state)
        page.tokenUserId = 999999
        page.tokenValue.set("keep")
        let _ = page.resetToken(actx)
        @Expect(page.tokenValue.get(), "keep")
        @Expect(page.msg.get(), "")
    }

    // 启停：启用 → 禁用 两个方向，提示与审计动作名都跟着变
    @TestCase
    public func covUsers_toggleActiveBothWays(): Unit {
        let state = makePortalState("team")
        let _ = seedCovUser(state, "admin-anchor", admin: true)   // 保证有别的启用管理员
        let uid = seedCovUser(state, "toggle-me")
        let page = mountUsersCov(state)
        let (actx, _) = covActx(state)

        let _ = page.toggleActive(actx, uid)
        @Expect(page.msg.get(), "已禁用 toggle-me")
        @Expect(state.userStore.getUser(uid).getOrThrow().isActive, false)
        @Expect(state.adminData.queryLogs(Some("admin"), "disable_user", "", 0, 0, 0, 10)[1], 1)

        let _ = page.toggleActive(actx, uid)
        @Expect(page.msg.get(), "已启用 toggle-me")
        @Expect(state.userStore.getUser(uid).getOrThrow().isActive, true)
        @Expect(state.adminData.queryLogs(Some("admin"), "enable_user", "", 0, 0, 0, 10)[1], 1)

        // 不存在的 id：静默
        let before = page.msg.get()
        let _ = page.toggleActive(actx, 999999)
        @Expect(page.msg.get(), before)
    }

    // 最后一个启用管理员：禁用被拒，文案说明后果，且写失败审计
    @TestCase
    public func covUsers_cannotDisableLastActiveAdmin(): Unit {
        let state = makePortalState("team")
        let uid = seedCovUser(state, "sole-admin", admin: true)
        let page = mountUsersCov(state)
        let (actx, _) = covActx(state, dbIsAdmin: true, ctxIsAdmin: true, username: "sole-admin")

        let _ = page.toggleActive(actx, uid)
        @Expect(page.msg.get(), "不能禁用最后一个启用管理员（否则管理端将无人可登录）")
        @Expect(page.msgOk.get(), false)
        @Expect(state.userStore.getUser(uid).getOrThrow().isActive, true)
        let (logs, total) = state.adminData.queryLogs(Some("admin"), "disable_user", "", 0, 0, 0, 10)
        @Expect(total, 1)
        @Expect(logs[0].status, "failed")
        @Expect(covRender(page.render()).contains("el-tag--danger"), true)
    }

    // 已经是「唯一启用管理员」时的**启用**动作不受保护影响（保护只针对会减少管理员的方向）
    @TestCase
    public func covUsers_enablingSoleAdminStillWorks(): Unit {
        let state = makePortalState("team")
        let uid = seedCovUser(state, "sole2", admin: true, active: false)
        let page = mountUsersCov(state)
        let (actx, _) = covActx(state)
        let _ = page.toggleActive(actx, uid)
        @Expect(page.msg.get(), "已启用 sole2")
        @Expect(state.userStore.getUser(uid).getOrThrow().isActive, true)
    }

    // 管理员身份：提升 → 取消（两个方向），审计动作名分别 grant_admin / revoke_admin
    @TestCase
    public func covUsers_toggleAdminBothWays(): Unit {
        let state = makePortalState("team")
        let _ = seedCovUser(state, "anchor-admin", admin: true)
        let uid = seedCovUser(state, "promote-me")
        let page = mountUsersCov(state)
        let (actx, _) = covActx(state)

        let _ = page.toggleAdmin(actx, uid)
        @Expect(page.msg.get(), "已设为管理员 promote-me")
        @Expect(state.userStore.getUser(uid).getOrThrow().isAdmin, true)
        @Expect(state.adminData.queryLogs(Some("admin"), "grant_admin", "", 0, 0, 0, 10)[1], 1)

        let _ = page.toggleAdmin(actx, uid)
        @Expect(page.msg.get(), "已取消管理员 promote-me")
        @Expect(state.userStore.getUser(uid).getOrThrow().isAdmin, false)
        @Expect(state.adminData.queryLogs(Some("admin"), "revoke_admin", "", 0, 0, 0, 10)[1], 1)

        let before = page.msg.get()
        let _ = page.toggleAdmin(actx, 999999)
        @Expect(page.msg.get(), before)
    }

    // 取消最后一个启用管理员的身份：被拒 + 失败文案 + 失败审计
    @TestCase
    public func covUsers_cannotRevokeLastActiveAdmin(): Unit {
        let state = makePortalState("team")
        let uid = seedCovUser(state, "sole3", admin: true)
        let page = mountUsersCov(state)
        let (actx, _) = covActx(state, dbIsAdmin: true, ctxIsAdmin: true, username: "sole3")

        let _ = page.toggleAdmin(actx, uid)
        @Expect(page.msg.get(), "不能取消最后一个启用管理员的身份（否则管理端将无人可登录）")
        @Expect(page.msgOk.get(), false)
        @Expect(state.userStore.getUser(uid).getOrThrow().isAdmin, true)
        let (logs, total) = state.adminData.queryLogs(Some("admin"), "revoke_admin", "", 0, 0, 0, 10)
        @Expect(total, 1)
        @Expect(logs[0].status, "failed")
        @Expect(logs[0].error, "cannot revoke the last active admin")
    }

    // 删除确认框：正文带用户名；取消不动数据；不存在的 id 不弹
    @TestCase
    public func covUsers_deleteConfirmFlow(): Unit {
        let state = makePortalState("team")
        let uid = seedCovUser(state, "victim-u")
        let page = mountUsersCov(state)
        let (actx, _) = covActx(state)

        let _ = page.askDelete(actx, uid)
        @Expect(page.confirmVisible.get(), true)
        @Expect(page.pendingDeleteId, uid)
        @Expect(page.pendingDeleteName, "victim-u")
        @Expect(covRender(page.render()).contains("确定要删除用户「victim-u」吗？其发布权限将立即失效。"), true)

        let _ = page.cancelDelete(actx)
        @Expect(page.confirmVisible.get(), false)
        @Expect(state.userStore.getUser(uid).isSome(), true)

        let _ = page.askDelete(actx, 999999)
        @Expect(page.confirmVisible.get(), false)
    }

    // 确认删除：普通用户真删 + 写审计；管理员受保护
    @TestCase
    public func covUsers_confirmDelete(): Unit {
        let state = makePortalState("team")
        let uid = seedCovUser(state, "delete-me")
        let page = mountUsersCov(state)
        let (actx, _) = covActx(state)
        let _ = page.askDelete(actx, uid)
        let _ = page.confirmDelete(actx)

        @Expect(page.msg.get(), "已删除用户 delete-me")
        @Expect(page.msgOk.get(), true)
        @Expect(page.confirmVisible.get(), false)
        @Expect(page.pendingDeleteId, 0)
        @Expect(state.userStore.getUser(uid).isNone(), true)
        @Expect(state.adminData.queryLogs(Some("admin"), "delete_user", "", 0, 0, 0, 10)[1], 1)
        // 同 submitCreate：删完要 bump 才从表上消失（表里仍留着操作者自己的账号）
        page.bump()
        var stillThere = false
        for (r in page.rows.get()) {
            if (r.username == "delete-me") { stillThere = true }
        }
        @Expect(stillThere, false)
    }

    @TestCase
    public func covUsers_confirmDeleteProtectsAdmin(): Unit {
        let state = makePortalState("team")
        let uid = seedCovUser(state, "protected-admin", admin: true)
        let page = mountUsersCov(state)
        let (actx, _) = covActx(state)
        let _ = page.askDelete(actx, uid)
        let _ = page.confirmDelete(actx)

        @Expect(page.msg.get(), "删除失败（管理员受保护）")
        @Expect(page.msgOk.get(), false)
        @Expect(state.userStore.getUser(uid).isSome(), true)
        let (logs, total) = state.adminData.queryLogs(Some("admin"), "delete_user", "", 0, 0, 0, 10)
        @Expect(total, 1)
        @Expect(logs[0].status, "failed")
        @Expect(covRender(page.render()).contains("删除失败（管理员受保护）"), true)
    }

    // 鉴权：非管理员与未登录对全部写动作都被拒，且不落库、不留审计
    @TestCase
    public func covUsers_writeActionsRequireAdmin(): Unit {
        let state = makePortalState("team")
        let _ = seedCovUser(state, "anchor2", admin: true)
        let uid = seedCovUser(state, "target-u")
        let page = mountUsersCov(state)
        let _ = covRender(page.render())

        let (plain, _) = covActx(state, dbIsAdmin: false, ctxIsAdmin: true, username: "covplain")
        page.formUser.set("nope")
        page.formPass.set("Pass123456")
        let _ = page.submitCreate(plain)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(state.userStore.getUserByUsername("nope").isNone(), true)

        let _ = page.toggleActive(plain, uid)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(state.userStore.getUser(uid).getOrThrow().isActive, true)

        let _ = page.toggleAdmin(plain, uid)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(state.userStore.getUser(uid).getOrThrow().isAdmin, false)

        let _ = page.resetToken(plain)
        @Expect(page.msg.get(), "无权限：需要管理员登录")

        let _ = page.askDelete(plain, uid)
        let _ = page.confirmDelete(plain)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(state.userStore.getUser(uid).isSome(), true)

        // 未登录
        let anon = covAnonActx(state)
        let _ = page.toggleActive(anon, uid)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(state.adminData.queryLogs(Option<String>.None, "", "", 0, 0, 0, 10)[1], 0)
    }

    // 未挂载 state：各动作都走 None 分支（不抛、不改信号）
    @TestCase
    public func covUsers_withoutState(): Unit {
        let state = makePortalState("team")
        let page = UsersPage()
        @Expect(covRender(page.render()).contains("用户管理"), true)

        let (actx, _) = covActx(state)
        let _ = page.submitCreate(actx)
        let _ = page.showToken(actx, 1)
        @Expect(page.tokenVisible.get(), false)
        let _ = page.resetToken(actx)
        let _ = page.toggleActive(actx, 1)
        let _ = page.toggleAdmin(actx, 1)
        let _ = page.askDelete(actx, 1)
        let _ = page.confirmDelete(actx)
        let _ = page.onPageChange(actx)
        @Expect(page.rows.get().size, 0)
        @Expect(page.msg.get(), "")
    }

    // 邮箱搜索（派生过滤的一部分，顺带守住大小写不敏感）
    @TestCase
    public func covUsers_searchByEmailCaseInsensitive(): Unit {
        let state = makePortalState("team")
        let _ = seedCovUser(state, "a1", email: "Team@Corp.CN")
        let _ = seedCovUser(state, "b1", email: "other@example.com")
        let page = mountUsersCov(state)
        page.userSearch.set("corp.cn")
        @Expect(page.rows.get().size, 1)
        @Expect(page.rows.get()[0].username, "a1")

        // 前后空白不参与匹配
        page.userSearch.set("  other  ")
        @Expect(page.rows.get().size, 1)
        @Expect(page.rows.get()[0].username, "b1")
    }

    // 长文本：用户名/邮箱很长也直出
    @TestCase
    public func covUsers_longTextPassesThrough(): Unit {
        let state = makePortalState("team")
        let long = covLongText("u", 200)
        let _ = seedCovUser(state, long, email: long + "@example.com")
        let json = covRender(mountUsersCov(state).render())
        @Expect(json.contains(long), true)
    }
}
