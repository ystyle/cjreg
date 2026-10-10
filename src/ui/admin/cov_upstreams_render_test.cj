// 上游管理页（/admin/upstreams）渲染 + 交互回归。
//
// 这一页原先几乎没有测试（行覆盖 0.4%），但它的分支不少：
//   * 行内三类标签：官方/镜像、启用/禁用、两个正交开关（回源=读路径、可推送=写路径）；
//   * 表单 Dialog 的新建/编辑两态（编辑时名称与 URL 都禁用）；
//   * 删除确认正文走 SignalView（静态子节点是首次渲染快照，直写会显示空名字）；
//   * 「官方仓受保护」这条业务规则只在渲染/动作的返回文案里体现。
package ystyle::cjreg.ui.admin

import ystyle::cjreg.ui.*
import cjxt.*
import ystyle::cjreg.store.*
import ystyle::cjreg.config.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

func mountUpstreams(state: CjregState): UpstreamsPage {
    let page = UpstreamsPage()
    page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
    page
}

@Test
public class CovUpstreamsRenderTest {
    // 空态：没有上游时给出明确提示，且表格槽位仍在（listBody 的两个槽位永远都在）
    @TestCase
    public func covUpstreams_emptyStateAndTable(): Unit {
        let state = makePortalState("team")
        let page = mountUpstreams(state)
        @Expect(page.rows.get().size, 0)
        @Expect(page.total.get(), 0)
        let json = covRenderExpanded(page.render())
        @Expect(json.contains("暂无上游，点击「新增上游」添加"), true)
        @Expect(json.contains("el-table"), true)
        @Expect(json.contains("上游管理"), true)
        @Expect(json.contains("多仓上游配置"), true)
    }

    // 行内标签：类型（官方/镜像）、状态（启用/禁用）、能力（回源/不回源 · 可推送/禁推送）
    @TestCase
    public func covUpstreams_rowTagsCoverAllBranches(): Unit {
        let state = makePortalState("team")
        let _ = covSeedUpstream(state, "official", url: "https://pkg.cangjie-lang.cn/registry",
            isOfficial: true, proxyEnabled: true, asTarget: false, priority: 0, lastSyncAt: 1700000000000)
        let _ = covSeedUpstream(state, "mirror", url: "https://mirror.test/registry",
            isOfficial: false, enabled: false, proxyEnabled: false, asTarget: true,
            priority: 5, cacheTtl: 600, lastSyncAt: 0)

        let page = mountUpstreams(state)
        @Expect(page.rows.get().size, 2)
        let json = covRender(page.render())
        @Expect(json.contains("官方"), true)
        @Expect(json.contains("镜像"), true)
        @Expect(json.contains("启用"), true)
        @Expect(json.contains("禁用"), true)
        @Expect(json.contains("回源"), true)
        @Expect(json.contains("不回源"), true)
        @Expect(json.contains("可推送"), true)
        @Expect(json.contains("禁推送"), true)
        // 缓存与优先级原样展示；没有同步记录的上游「最后同步」显示 —
        @Expect(json.contains("600s"), true)
        @Expect(json.contains("1700000000000"), true)
        @Expect(json.contains("-"), true)
        // 官方仓不给「删除」按钮（受保护），非官方仓才有
        @Expect(json.contains("删除"), true)
    }

    // 官方仓行上没有删除入口：只有一行官方仓时，整页不该出现「删除」按钮文案
    @TestCase
    public func covUpstreams_officialRowHasNoDeleteButton(): Unit {
        let state = makePortalState("team")
        let _ = covSeedUpstream(state, "official", isOfficial: true)
        let page = mountUpstreams(state)
        @Expect(covRender(page.render()).contains("删除"), false)
    }

    // 翻页：pageWindow 切片 + onPageChange 重查
    @TestCase
    public func covUpstreams_paginationSlicesRows(): Unit {
        let state = makePortalState("team")
        for (i in 0..5) {
            let _ = covSeedUpstream(state, "up-${i}", priority: i)
        }
        let page = mountUpstreams(state)
        @Expect(page.total.get(), 5)
        @Expect(page.rows.get().size, 5)

        page.pageSize.set(2)
        let (actx, _) = covActx(state)
        let _ = page.onPageChange(actx)
        @Expect(page.rows.get().size, 2)
        @Expect(page.total.get(), 5)

        page.currentPage.set(3)
        let _ = page.onPageChange(actx)
        @Expect(page.rows.get().size, 1)
        @Expect(page.rows.get()[0].name, "up-4")

        // 页码越界：pageWindow 只影响切片，越界页返回空切片而不是抛异常
        page.currentPage.set(99)
        let _ = page.onPageChange(actx)
        @Expect(page.rows.get().size, 0)
        @Expect(covRender(page.render()).contains("暂无上游，点击「新增上游」添加"), true)
    }

    // 新建表单：openCreate 复位全部字段（含两个开关的出厂默认：回源开、可推送关）
    @TestCase
    public func covUpstreams_openCreateResetsForm(): Unit {
        let state = makePortalState("team")
        let page = mountUpstreams(state)
        page.formName.set("dirty")
        page.formUrl.set("https://dirty/registry")
        page.formPriority.set(9)
        page.formCacheTtl.set(1)
        page.formToken.set("secret")
        page.formProxyEnabled.set(false)
        page.formAsTarget.set(true)
        page.nameError.set("旧错误")
        page.urlError.set("旧错误")

        let (actx, _) = covActx(state)
        let _ = page.openCreate(actx)
        @Expect(page.dialogVisible.get(), true)
        @Expect(page.dialogMode.get(), "create")
        @Expect(page.formName.get(), "")
        @Expect(page.formUrl.get(), "")
        @Expect(page.formPriority.get(), 0)
        @Expect(page.formCacheTtl.get(), 86400)
        @Expect(page.formToken.get(), "")
        @Expect(page.formProxyEnabled.get(), true)
        @Expect(page.formAsTarget.get(), false)
        @Expect(page.nameError.get(), "")
        @Expect(page.urlError.get(), "")
        @Expect(covRender(page.render()).contains("新增上游"), true)
    }

    // 新建成功：入 store、写审计、给出提示、关弹窗、列表跟着刷新
    @TestCase
    public func covUpstreams_submitCreateAddsUpstream(): Unit {
        let state = makePortalState("team")
        let page = mountUpstreams(state)
        let _ = covRender(page.render())          // 走一次渲染，把 upForm 建出来
        let (actx, _) = covActx(state)

        let _ = page.openCreate(actx)
        page.formName.set("mirror-a")
        page.formUrl.set("https://mirror.a/registry")
        page.formPriority.set(3)
        page.formCacheTtl.set(120)
        page.formToken.set("tok")
        page.formAsTarget.set(true)
        let _ = page.submitForm(actx)

        @Expect(page.msg.get(), "已添加 mirror-a")
        @Expect(page.dialogVisible.get(), false)
        @Expect(page.rows.get().size, 1)
        let added = state.upStore.getByName("mirror-a").getOrThrow()
        @Expect(added.priority, 3)
        @Expect(added.cacheTtl, 120)
        @Expect(added.authToken, "tok")
        @Expect(added.asTarget, true)
        @Expect(added.proxyEnabled, true)
        // 审计：动作名与操作者
        let (logs, total) = state.adminData.queryLogs(Some("admin"), "add upstream", "", 0, 0, 0, 10)
        @Expect(total, 1)
        @Expect(logs[0].actorName, "covadmin")
        @Expect(covRender(page.render()).contains("已添加 mirror-a"), true)
    }

    // 新建失败：重名 → 明确提示（不是静默什么都不发生）
    @TestCase
    public func covUpstreams_submitCreateDuplicateFails(): Unit {
        let state = makePortalState("team")
        let _ = covSeedUpstream(state, "dup")
        let page = mountUpstreams(state)
        let _ = covRender(page.render())
        let (actx, _) = covActx(state)

        let _ = page.openCreate(actx)
        page.formName.set("dup")
        page.formUrl.set("https://dup/registry")
        let _ = page.submitForm(actx)
        @Expect(page.msg.get(), "添加失败（名称已存在？）")
        @Expect(state.upStore.listAll().size, 1)
    }

    // 表单校验失败：名称/URL 必填错误写进 errorSignal，且不落库
    @TestCase
    public func covUpstreams_submitCreateValidationFails(): Unit {
        let state = makePortalState("team")
        let page = mountUpstreams(state)
        let _ = covRender(page.render())
        let (actx, _) = covActx(state)
        let _ = page.openCreate(actx)

        page.formName.set("")
        page.formUrl.set("https://x/registry")
        let _ = page.submitForm(actx)
        @Expect(page.nameError.get(), "名称必填")
        @Expect(page.msg.get(), "")
        @Expect(state.upStore.listAll().size, 0)
        @Expect(covRender(page.render()).contains("名称必填"), true)

        // URL 空 → 第二条规则报错（名称先填好，否则第一条就短路了）
        page.formName.set("ok-name")
        page.formUrl.set("")
        let _ = page.submitForm(actx)
        @Expect(page.urlError.get(), "URL 必填")
        @Expect(state.upStore.listAll().size, 0)
    }

    // 编辑：openEdit 回填全部字段（含两个开关）；编辑态的名称/URL 输入框禁用
    @TestCase
    public func covUpstreams_openEditPrefillsAndDisables(): Unit {
        let state = makePortalState("team")
        let id = covSeedUpstream(state, "mirror-b", url: "https://b/registry", priority: 7,
            cacheTtl: 300, authToken: "t-b", proxyEnabled: false, asTarget: true)
        let page = mountUpstreams(state)
        let (actx, _) = covActx(state)
        let _ = page.openEdit(actx, id)

        @Expect(page.dialogMode.get(), "edit")
        @Expect(page.editingId, id)
        @Expect(page.formName.get(), "mirror-b")
        @Expect(page.formUrl.get(), "https://b/registry")
        @Expect(page.formPriority.get(), 7)
        @Expect(page.formCacheTtl.get(), 300)
        @Expect(page.formToken.get(), "t-b")
        @Expect(page.formProxyEnabled.get(), false)
        @Expect(page.formAsTarget.get(), true)
        @Expect(page.dialogVisible.get(), true)

        let json = covRender(page.render())
        @Expect(json.contains("编辑上游"), true)
        // 编辑态两个输入框都带 disabled
        @Expect(json.contains("\"disabled\":\"disabled\""), true)

        // 不存在的 id：什么都不改（不动弹窗、不清字段）
        page.dialogVisible.set(false)
        let _ = page.openEdit(actx, 999999)
        @Expect(page.dialogVisible.get(), false)
        @Expect(page.formName.get(), "mirror-b")
    }

    // 编辑成功：开关与数值都写回；写审计
    @TestCase
    public func covUpstreams_submitEditUpdates(): Unit {
        let state = makePortalState("team")
        let id = covSeedUpstream(state, "mirror-c", url: "https://c/registry", proxyEnabled: true, asTarget: false)
        let page = mountUpstreams(state)
        let _ = covRender(page.render())
        let (actx, _) = covActx(state)
        let _ = page.openEdit(actx, id)

        page.formPriority.set(11)
        page.formCacheTtl.set(60)
        page.formToken.set("new-token")
        page.formProxyEnabled.set(false)
        page.formAsTarget.set(true)
        let _ = page.submitForm(actx)

        @Expect(page.msg.get(), "已更新上游 mirror-c")
        let up = state.upStore.getById(id).getOrThrow()
        @Expect(up.priority, 11)
        @Expect(up.cacheTtl, 60)
        @Expect(up.authToken, "new-token")
        @Expect(up.proxyEnabled, false)
        @Expect(up.asTarget, true)
        @Expect(up.url, "https://c/registry")   // URL 不可改
        let (_, total) = state.adminData.queryLogs(Some("admin"), "update upstream", "", 0, 0, 0, 10)
        @Expect(total, 1)
    }

    // 编辑目标已被删掉：update 返回 false → 「更新失败」
    @TestCase
    public func covUpstreams_submitEditMissingTarget(): Unit {
        let state = makePortalState("team")
        let id = covSeedUpstream(state, "mirror-d")
        let page = mountUpstreams(state)
        let _ = covRender(page.render())
        let (actx, _) = covActx(state)
        let _ = page.openEdit(actx, id)
        page.editingId = 999999
        let _ = page.submitForm(actx)
        @Expect(page.msg.get(), "更新失败")
    }

    // 关弹窗
    @TestCase
    public func covUpstreams_closeDialogHidesDialog(): Unit {
        let state = makePortalState("team")
        let page = mountUpstreams(state)
        let (actx, _) = covActx(state)
        let _ = page.openCreate(actx)
        @Expect(page.dialogVisible.get(), true)
        let _ = page.closeDialog(actx)
        @Expect(page.dialogVisible.get(), false)
        @Expect(covRender(page.render()).contains("el-dialog"), false)
    }

    // 启停开关：两个方向都要覆盖（文案与库内状态一致）
    @TestCase
    public func covUpstreams_toggleEnabledBothWays(): Unit {
        let state = makePortalState("team")
        let id = covSeedUpstream(state, "mirror-e", enabled: true)
        let page = mountUpstreams(state)
        let (actx, _) = covActx(state)

        let _ = page.toggleEnabled(actx, id)
        @Expect(page.msg.get(), "已禁用 mirror-e")
        @Expect(state.upStore.getById(id).getOrThrow().enabled, false)

        let _ = page.toggleEnabled(actx, id)
        @Expect(page.msg.get(), "已启用 mirror-e")
        @Expect(state.upStore.getById(id).getOrThrow().enabled, true)

        // 不存在的 id：静默（不写提示、不抛）
        let before = page.msg.get()
        let _ = page.toggleEnabled(actx, 999999)
        @Expect(page.msg.get(), before)
    }

    // 删除确认：正文走 SignalView，换对象后内容跟着变（不是首次渲染的快照）
    @TestCase
    public func covUpstreams_deleteConfirmBodyFollowsSignal(): Unit {
        let state = makePortalState("team")
        let a = covSeedUpstream(state, "mirror-f")
        let b = covSeedUpstream(state, "mirror-g")
        let page = mountUpstreams(state)
        let (actx, _) = covActx(state)

        let _ = page.askDelete(actx, a)
        @Expect(page.confirmVisible.get(), true)
        @Expect(page.pendingDeleteName.get(), "mirror-f")
        @Expect(covRender(page.render()).contains("确定要删除上游「mirror-f」吗？此操作不可恢复。"), true)

        let _ = page.askDelete(actx, b)
        @Expect(page.pendingDeleteName.get(), "mirror-g")
        @Expect(covRender(page.render()).contains("确定要删除上游「mirror-g」吗？此操作不可恢复。"), true)

        // 不存在的 id：不弹确认框
        page.confirmVisible.set(false)
        let _ = page.askDelete(actx, 999999)
        @Expect(page.confirmVisible.get(), false)
    }

    // 取消删除：关掉确认框且不动数据
    @TestCase
    public func covUpstreams_cancelDeleteKeepsUpstream(): Unit {
        let state = makePortalState("team")
        let id = covSeedUpstream(state, "mirror-h")
        let page = mountUpstreams(state)
        let (actx, _) = covActx(state)
        let _ = page.askDelete(actx, id)
        let _ = page.cancelDelete(actx)
        @Expect(page.confirmVisible.get(), false)
        @Expect(state.upStore.getById(id).isSome(), true)
    }

    // 确认删除：非官方仓真删（写审计）；官方仓受保护，返回失败文案
    @TestCase
    public func covUpstreams_confirmDeleteRemovesNonOfficial(): Unit {
        let state = makePortalState("team")
        let id = covSeedUpstream(state, "mirror-i")
        let page = mountUpstreams(state)
        let (actx, _) = covActx(state)
        let _ = page.askDelete(actx, id)
        let _ = page.confirmDelete(actx)

        @Expect(page.msg.get(), "已删除 mirror-i")
        @Expect(page.confirmVisible.get(), false)
        @Expect(page.pendingDeleteId, 0)
        @Expect(state.upStore.getById(id).isNone(), true)
        let (_, total) = state.adminData.queryLogs(Some("admin"), "delete upstream", "", 0, 0, 0, 10)
        @Expect(total, 1)
    }

    @TestCase
    public func covUpstreams_confirmDeleteProtectsOfficial(): Unit {
        let state = makePortalState("team")
        let id = covSeedUpstream(state, "official", url: "https://pkg.cangjie-lang.cn/registry", isOfficial: true)
        let page = mountUpstreams(state)
        let (actx, _) = covActx(state)
        let _ = page.askDelete(actx, id)
        let _ = page.confirmDelete(actx)

        @Expect(page.msg.get(), "删除失败（官方仓受保护）")
        @Expect(state.upStore.getById(id).isSome(), true)
        @Expect(covRender(page.render()).contains("删除失败（官方仓受保护）"), true)
    }

    // 权限：会话上下文说自己是管理员但库里已被降级 → 所有写动作都被拒
    @TestCase
    public func covUpstreams_writeActionsRequireDbAdmin(): Unit {
        let state = makePortalState("team")
        let id = covSeedUpstream(state, "mirror-j")
        let page = mountUpstreams(state)
        let _ = covRender(page.render())
        // 库里那条记录不是管理员
        let (actx, _) = covActx(state, dbIsAdmin: false, ctxIsAdmin: true, username: "covplain")

        let _ = page.openCreate(actx)
        page.formName.set("nope")
        page.formUrl.set("https://nope/registry")
        let _ = page.submitForm(actx)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(state.upStore.getByName("nope").isNone(), true)

        let _ = page.toggleEnabled(actx, id)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(state.upStore.getById(id).getOrThrow().enabled, true)

        let _ = page.askDelete(actx, id)
        let _ = page.confirmDelete(actx)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(state.upStore.getById(id).isSome(), true)
    }

    // 未登录（上下文里连 uid 都没有）：同样被拒
    @TestCase
    public func covUpstreams_anonymousActionsRejected(): Unit {
        let state = makePortalState("team")
        let page = mountUpstreams(state)
        let _ = covRender(page.render())
        let actx = covAnonActx(state)

        page.formName.set("anon")
        page.formUrl.set("https://anon/registry")
        let _ = page.submitForm(actx)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(state.upStore.getByName("anon").isNone(), true)
    }

    // state 未挂载（页面被直接 new 出来）：所有动作与渲染都走 Option.None 分支
    @TestCase
    public func covUpstreams_withoutMountedState(): Unit {
        let state = makePortalState("team")
        let page = UpstreamsPage()
        @Expect(covRender(page.render()).contains("上游管理"), true)
        page.refresh()   // None 分支：什么都不做
        @Expect(page.rows.get().size, 0)

        let (actx, _) = covActx(state)
        let _ = page.openEdit(actx, 1)
        let _ = page.submitForm(actx)
        let _ = page.toggleEnabled(actx, 1)
        let _ = page.askDelete(actx, 1)
        let _ = page.confirmDelete(actx)
        let _ = page.onPageChange(actx)
        @Expect(page.rows.get().size, 0)
    }

    // 成功提示 Tag 随 msg 出现/消失
    @TestCase
    public func covUpstreams_msgTagRendersOnlyWhenSet(): Unit {
        let state = makePortalState("team")
        let page = mountUpstreams(state)
        @Expect(covRender(page.render()).contains("已添加"), false)
        page.msg.set("已添加 x")
        let json = covRender(page.render())
        @Expect(json.contains("已添加 x"), true)
        @Expect(json.contains("el-tag"), true)
    }
}
