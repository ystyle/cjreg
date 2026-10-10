// 第二轮补齐：把第一轮按"页面主流程"写的用例里漏掉的**短分支**扫一遍。
//
// 这些分支单独看都很小，但都是真实存在的状态机出口：
//   * 「state 未挂载」在每一个动作里的早退（页面被 new 出来但没 onMount）；
//   * onUnmount 的 Some 分支（释放已有绑定）；
//   * tryParse 失败 → 0（下拉框给了非数字值）；
//   * 目标仓不能覆盖时的两个 None 出口（计划已被删 / state 未挂载）；
//   * 依赖成环时创建与预览的拒绝路径；
//   * 登录页有推送通道时的异步分支（runLoginAsync 返回 true → doLogin 提前 return）；
//   * 预览正文的非 force 文案（第一轮只走了 force 覆盖路径）。
package ystyle::cjreg.ui.admin

import ystyle::cjreg.ui.*
import cjxt.*
import ystyle::cjreg.store.*
import ystyle::cjreg.config.*
import ystyle::cjreg.index.*
import ystyle::cjreg.server.{IndexProbe, PlanCategory, PlanItem, PublishPlanService,
    ProxyService, MemoryBlobStore}
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*
import std.collection.*
import std.reflect.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class CovSecondWaveAdminTest {
    // ===== 未挂载 state 的动作早退（每个页面各来一遍）=====

    @TestCase
    public func covWave2_usersUnmountedActions(): Unit {
        let state = makePortalState("team")
        let page = UsersPage()
        let (actx, _) = covActx(state)
        // closeDialog 不需要 state：任何页面状态下都能关
        page.dialogVisible.set(true)
        let _ = page.closeDialog(actx)
        @Expect(page.dialogVisible.get(), false)
        // 其余动作在 state 为 None 时早退（不改信号、不抛）
        page.tokenUser = "keep"
        let _ = page.resetToken(actx)
        @Expect(page.tokenUser, "keep")
        // filteredUsers 的 None 分支
        @Expect(page.rows.get().size, 0)
    }

    @TestCase
    public func covWave2_usersUnmountDisposesBinding(): Unit {
        let state = makePortalState("team")
        let uid = state.auth.createUser("u1", "Pass123456", false).getOrThrow().id
        let page = UsersPage()
        page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
        @Expect(page.rows.get().size, 1)
        // 已挂载后卸载：走 Some 分支释放绑定
        page.onUnmount(mountCtx(state, userCtxMap(1, "admin", true)))
        let _ = state.auth.setUserActive(uid, false)
        page.bump()
        @Expect(page.rows.get().size, 1)   // 绑定已释放，不再重算
    }

    @TestCase
    public func covWave2_packagesUnmountedActions(): Unit {
        let state = makePortalState("team")
        let page = PackagesPage()
        let (actx, _) = covActx(state)
        // 各动作的 None 早退
        let _ = page.doRestore(actx, 1, "a", "1.0.0")
        let _ = page.confirmDelete(actx)
        let _ = page.showDetail(actx, 1)
        let _ = page.doRefetch(actx)
        let _ = page.onPageChange(actx)
        let _ = page.doRefresh(actx)
        let _ = page.closeVersionDrawer(actx)
        let _ = page.selectPackage(actx, "o", "n")
        @Expect(page.msg.get(), "")
        // filteredRows 的 None 分支（未挂载时主表派生为空）
        @Expect(page.rows.get().size, 0)
    }

    @TestCase
    public func covWave2_packagesUnmountDisposesBothBindings(): Unit {
        let state = makePortalState("team")
        let _ = covSeedPkg(state, "ystyle", "alpha", "1.0.0")
        let page = PackagesPage()
        page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
        page.select("ystyle", "alpha")
        @Expect(page.verRows.get().size, 1)
        // 两个绑定都存在时卸载：走两条 Some 分支
        page.onUnmount(mountCtx(state, userCtxMap(1, "admin", true)))
        page.search.set("nope")
        @Expect(page.rows.get().size, 1)      // 主表绑定已释放
        page.verPage.set(5)
        @Expect(page.verRows.get().size, 1)   // 版本表绑定已释放
    }

    @TestCase
    public func covWave2_teamsUnmountedDialogFilters(): Unit {
        let state = makePortalState("team")
        let page = TeamsPage()
        // 未挂载时两个弹窗的派生函数走 None 分支（返回空列表，不抛）
        @Expect(page.pkgRows.get().size, 0)
        @Expect(page.memberRows.get().size, 0)
        // 直接调一次：验证真的走了 None 且不抛
        let (actx, _) = covActx(state)
        let _ = page.openPackages(actx, 1)
        @Expect(page.pkgRows.get().size, 0)
        let _ = page.openMembers(actx, 1)
        @Expect(page.memberRows.get().size, 0)
    }

    @TestCase
    public func covWave2_teamsUnmountDisposesBothBindings(): Unit {
        let state = makePortalState("team")
        let tid = state.adminData.createTeam("t", 1000)
        let _ = covSeedPkg(state, "ystyle", "alpha", "1.0.0")
        let _ = state.auth.createUser("m1", "Pass123456", false).getOrThrow()
        let page = TeamsPage()
        page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
        let (actx, _) = covActx(state)   // 操作者账号也会进成员候选表
        let _ = page.openPackages(actx, tid)
        let _ = page.openMembers(actx, tid)
        @Expect(page.pkgRows.get().size, 1)
        @Expect(page.memberRows.get().size, 2)   // m1 + covadmin
        // 两个绑定都存在时卸载：走两条 Some 分支
        page.onUnmount(mountCtx(state, userCtxMap(1, "admin", true)))
        page.pkgSearch.set("nothing")
        @Expect(page.pkgRows.get().size, 1)
        page.memberSearch.set("nothing")
        @Expect(page.memberRows.get().size, 2)
    }

    @TestCase
    public func covWave2_planDetailUnmountedActions(): Unit {
        let state = makePortalState("team")
        let page = PublishPlanDetailPage()
        let (actx, _) = covActx(state)
        // 六个动作在 state 为 None 时的早退（第一条 match 的 None 分支）
        let _ = page.doStart(actx)
        let _ = page.checkIndex(actx)
        let _ = page.stopExecution(actx)
        let _ = page.toggleItem(actx, 1, true)
        let _ = page.reanalyze(actx)
        @Expect(page.analyzing.get(), false)
        @Expect(page.msg.get(), "")
        // targetOverwriteAllowed 的两个 None 出口：state 未挂载 → false
        @Expect(page.targetOverwriteAllowed(), false)
    }

    @TestCase
    public func covWave2_planDetailTargetGoneMeansNoOverwrite(): Unit {
        let state = makePortalState("team")
        let upId = covSeedUpstream(state, "up-x")
        let pid = covSeedPlan(state, "gone-plan", targetUpstream: upId)
        let page = mountPlanDetailCov(state, pid)
        @Expect(page.targetOverwriteAllowed(), true)
        // 计划被别处删掉 → 内层 match 的 None 分支 → false（保守：不给覆盖入口）
        state.adminData.deletePlan(pid)
        @Expect(page.targetOverwriteAllowed(), false)
    }

    @TestCase
    public func covWave2_planListUnmountedActions(): Unit {
        let state = makePortalState("team")
        let page = PublishPlansPage()
        let (actx, _) = covActx(state)
        let _ = page.askDelete(actx, 1)
        let _ = page.confirmDelete(actx)
        let _ = page.cancelDelete(actx)
        let _ = page.gotoCreate(actx)
        let _ = page.gotoDetail(actx, 1)
        @Expect(page.confirmVisible.get(), false)
        @Expect(page.msg.get(), "")
    }

    @TestCase
    public func covWave2_orgsUnmountedActions(): Unit {
        let state = makePortalState("team")
        let page = OrganizationsPage()
        let (actx, _) = covActx(state)
        let _ = page.openEdit(actx, 1)
        let _ = page.submitForm(actx)
        let _ = page.askDelete(actx, 1)
        let _ = page.confirmDelete(actx)
        let _ = page.cancelDelete(actx)
        let _ = page.closeDialog(actx)
        @Expect(page.dialogVisible.get(), false)
        @Expect(page.msg.get(), "")
    }

    @TestCase
    public func covWave2_upstreamsUnmountedActions(): Unit {
        let state = makePortalState("team")
        let page = UpstreamsPage()
        let (actx, _) = covActx(state)
        let _ = page.openCreate(actx)
        let _ = page.openEdit(actx, 1)
        let _ = page.submitForm(actx)
        let _ = page.toggleEnabled(actx, 1)
        let _ = page.askDelete(actx, 1)
        let _ = page.confirmDelete(actx)
        let _ = page.cancelDelete(actx)
        let _ = page.closeDialog(actx)
        @Expect(page.dialogVisible.get(), false)
        @Expect(page.msg.get(), "")
    }

    @TestCase
    public func covWave2_logsUnmountedActions(): Unit {
        let state = makePortalState("team")
        let page = LogsPage()
        let (actx, _) = covActx(state)
        let _ = page.confirmClear(actx)
        let _ = page.askClear(actx)
        let _ = page.cancelClear(actx)
        @Expect(page.confirmVisible.get(), false)
        @Expect(page.msg.get(), "")
    }

    @TestCase
    public func covWave2_planCreateUnmountedActions(): Unit {
        let state = makePortalState("team")
        let page = PublishPlanCreatePage()
        let (actx, _) = covActx(state)
        let _ = page.submitCreate(actx)
        let _ = page.backToList(actx)
        let _ = page.onTargetChanged(actx)
        page.refreshPreview(actx)
        @Expect(page.msg.get(), "")
        @Expect(page.previewRows.get().size, 0)
    }

    // ===== 目标上游下拉给了非数字值 → tryParse 的 None 分支按 0 处理 =====

    @TestCase
    public func covWave2_planCreateNonNumericTarget(): Unit {
        let state = makePortalState("team")
        let doc = covSeedPublishable(state, "ystyle", "alpha", "1.0.0")
        let upId = covSeedUpstream(state, "up-y")
        let page = PublishPlanCreatePage()
        page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
        let _ = covRender(page.render())   // 建出 planForm
        let (actx, _) = covActx(state)

        // 非数字的目标上游：按 0（= 不选上游）处理 → 依赖链照展开、不做对照
        page.planName.set("bad-target")
        page.targetUpstream.set("not-a-number")
        let picked = ArrayList<Int64>()
        picked.add(doc.id)
        page.selectedPkgs.set(picked)
        let _ = page.submitCreate(actx)
        let plan = state.adminData.listPlans()[0]
        @Expect(plan.targetUpstream, 0)
        @Expect(plan.name, "bad-target")
        // 目标上游为 0 → 没有对照 → targetError 留空（"未选择上游"只在预览里提示）
        @Expect(plan.lastError, "")
        @Expect(upId > 0, true)
    }

    // 预览：非数字目标上游同样按 0 → 「未选择目标上游」那条提示
    @TestCase
    public func covWave2_planCreatePreviewNonNumericTarget(): Unit {
        let state = makePortalState("team")
        let _ = covSeedPublishable(state, "ystyle", "alpha", "1.0.0")
        let page = PublishPlanCreatePage()
        page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
        page.targetUpstream.set("still-not-a-number")
        let roots = ArrayList<(String, String, String)>()
        roots.add(("ystyle", "alpha", "1.0.0"))
        let (items, note) = page.computePreview(state, roots, 0)
        @Expect(items.size, 1)
        @Expect(note, "未选择目标上游：只展开了依赖链，选好上游后才能对照目标仓版本")
    }

    // 消息槽位：提交被拒时的提示渲染成 Tag；空串时不渲染
    @TestCase
    public func covWave2_planCreateMsgTag(): Unit {
        let state = makePortalState("team")
        let page = PublishPlanCreatePage()
        page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
        let _ = covRender(page.render())
        @Expect(covRender(page.render()).contains("请至少选择一个包"), false)
        page.msg.set("请至少选择一个包")
        @Expect(covRender(page.render()).contains("请至少选择一个包"), true)
    }

    // ===== 依赖成环：预览与创建两条拒绝路径 =====

    // 造一个双包互依赖的仓（A 依赖 B，B 依赖 A）
    func cyclicFixture(): (CjregState, Int64) {
        let state = makePortalState("team")
        let a = covSeedPublishable(state, "ystyle", "alpha", "1.0.0")
        let b = covSeedPublishable(state, "ystyle", "beta", "1.0.0")
        // 改写成互依赖的 indexJson
        let ea = PackageIndex()
        ea.organization = "ystyle"
        ea.name = "alpha"
        ea.version = "1.0.0"
        ea.sha256sum = a.sha256
        ea.dependencies.add(DependencyEntry("beta", "1.0.0", "", "", ""))
        a.indexJson = generateNDJSON(ArrayList<PackageIndex>([ea]))
        state.pkgStore.save(a)
        let eb = PackageIndex()
        eb.organization = "ystyle"
        eb.name = "beta"
        eb.version = "1.0.0"
        eb.sha256sum = b.sha256
        eb.dependencies.add(DependencyEntry("alpha", "1.0.0", "", "", ""))
        b.indexJson = generateNDJSON(ArrayList<PackageIndex>([eb]))
        state.pkgStore.save(b)
        (state, a.id)
    }

    @TestCase
    public func covWave2_planCreatePreviewRejectsCycle(): Unit {
        let (state, _) = cyclicFixture()
        let page = PublishPlanCreatePage()
        page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
        // 先确认 analyze 自己认出了环
        let svc = PublishPlanService(state.pkgStore)
        let roots = ArrayList<(String, String, String)>()
        roots.add(("ystyle", "alpha", "1.0.0"))
        @Expect(svc.analyze(roots).hasCycle, true)

        let (_, note) = page.computePreview(state, roots, 0)
        @Expect(note, "依赖存在环：创建会被拒绝，请先解开依赖环")
    }

    @TestCase
    public func covWave2_planCreateSubmitRejectsCycle(): Unit {
        let (state, pkgId) = cyclicFixture()
        let page = PublishPlanCreatePage()
        page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
        let _ = covRender(page.render())
        let (actx, nav) = covActx(state)
        page.planName.set("cyclic-plan")
        page.targetUpstream.set("0")
        let picked = ArrayList<Int64>()
        picked.add(pkgId)
        page.selectedPkgs.set(picked)
        let _ = page.submitCreate(actx)

        @Expect(page.msg.get(), "依赖存在环")
        @Expect(state.adminData.listPlans().size, 0)
        @Expect(nav.size, 0)
        @Expect(covRender(page.render()).contains("依赖存在环"), true)
    }

    // 预览摘要里 need 分支（既不是 already_exists 也不是 conflict）
    @TestCase
    public func covWave2_planCreatePreviewNeedCount(): Unit {
        let state = makePortalState("team")
        let _ = covSeedPublishable(state, "ystyle", "alpha", "1.0.0")
        let _ = covSeedPublishable(state, "ystyle", "beta", "1.0.0")
        let upId = covSeedUpstream(state, "up-need")
        // 目标仓索引空 → 两条都 need_publish
        let proxy = ProxyService(state.pkgStore, MemoryBlobStore(), UpstreamService(state.upStore))
        proxy.httpFetch = { u, t =>
            if (u.contains("/index/")) { Some("".toArray()) } else { None }
        }
        state.proxySvc = Some(proxy)
        let page = PublishPlanCreatePage()
        page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
        let roots = ArrayList<(String, String, String)>()
        roots.add(("ystyle", "alpha", "1.0.0"))
        roots.add(("ystyle", "beta", "1.0.0"))
        let (items, note) = page.computePreview(state, roots, upId)
        @Expect(items.size, 2)
        @Expect(note, "共 2 项 · 需发布 2")
        @Expect(upId > 0, true)
    }

    // ===== 重拉确认框：非 force 那套正文（第一轮只覆盖了 force 路径）=====

    @TestCase
    public func covWave2_pkgRefetchDialogNonForceBody(): Unit {
        let state = makePortalState("team")
        let blob = MemoryBlobStore()
        state.blobStore = Some(blob)
        let doc = covSeedPkg(state, "ystyle", "alpha", "1.0.0", upstreamId: 1, upstreamName: "up")
        let page = PackagesPage()
        page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
        let (actx, _) = covActx(state)
        page.select("ystyle", "alpha")
        let _ = page.askRefetch(actx, doc.id, "alpha", "1.0.0", false, "")
        @Expect(page.refetchVisible.get(), true)
        @Expect(page.refetchForce.get(), false)
        let json = covRender(page.render())
        @Expect(json.contains("将按上游内容重新拉取该版本，并覆盖本地缓存的制品与元数据。"), true)
        @Expect(json.contains("本地该版本的下载计数、发布者、创建时间保持不变；上游不可达时不会改动本地。"), true)
        @Expect(json.contains("⚠ 上游同版本的内容已经变了。"), false)
    }

    // ===== 团队：toggleMember 在已有成员时保留其它成员（next 列表构造）=====

    @TestCase
    public func covWave2_teamsToggleMemberKeepsOthers(): Unit {
        let state = makePortalState("team")
        let tid = state.adminData.createTeam("t", 1000)
        let u1 = state.auth.createUser("m1", "Pass123456", false).getOrThrow().id
        let u2 = state.auth.createUser("m2", "Pass123456", false).getOrThrow().id
        state.adminData.setTeamMembers(tid, [u1, u2])
        let page = TeamsPage()
        page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
        let (actx, _) = covActx(state)
        let _ = page.openMembers(actx, tid)

        // 移除 u1：u2 必须留下（走 else 分支的 next.add(uid)）
        let _ = page.toggleMember(actx, u1)
        @Expect(page.msg.get(), "已移除成员")
        let left = state.adminData.listTeamMemberIds(tid)
        @Expect(left.size, 1)
        @Expect(left[0], u2)

        // 再添加第三个成员
        let u3 = state.auth.createUser("m3", "Pass123456", false).getOrThrow().id
        let _ = page.toggleMember(actx, u3)
        @Expect(page.msg.get(), "已添加成员")
        @Expect(state.adminData.listTeamMemberIds(tid).size, 2)
    }
}

// ===== 登录页：有推送通道时的异步分支（runLoginAsync 返回 true → doLogin 提前 return）=====
//
// 放在 ui 包（登录页所在包）。这里只为覆盖「先回 loading 补丁、后台线程校验、
// 结果经 pushUpdate 回到串行上下文收尾」这条异步接线：注入一个真实 App（无对应 WS
// 会话 → pushUpdate 返回 false 但不抛），断言 doLogin 已把 busy 置真并**没有**同步收尾。
@Test
public class CovSecondWaveLoginTest {
    @TestCase
    public func covWave2_loginAsyncPathWithApp(): Unit {
        let state = makePortalState("open")
        let _ = state.auth.createUser("root-async", "RootPass123", true).getOrThrow()
        state.app = Some(App())
        let page = LoginPage()
        page.onMount(mountCtx(state, HashMap<String, String>()))
        let _ = covSecondWaveRender(page.render())   // 建出 loginForm

        let sessionCtx = HashMap<String, String>()
        let nav = ArrayList<String>()
        let router = Router("sid-test", { p => nav.add(p) })
        let states = HashMap<String, AppState>()
        states.add(TypeInfo.of<CjregState>().qualifiedName, state)
        let actx = ActionContext("sid-test", sessionCtx, HashMap<String, String>(), router,
            sessionStates: states)

        page.username.set("root-async")
        page.password.set("RootPass123")
        let _ = page.doLogin(actx)

        // 有推送通道 → 动作只置 busy 就返回（收尾交给后台线程）
        @Expect(page.busy.get(), true)
        @Expect(sessionCtx.contains("uid"), false)   // 还没写会话上下文
        @Expect(nav.size, 0)
        @Expect(page.errorMsg.get(), "")
        // 后台线程里的 pushUpdate 找不到会话 → 回调不执行 → busy 保持
        sleep(80 * Duration.millisecond)
        @Expect(page.busy.get(), true)
    }
}

func covSecondWaveRender(c: IComponent): String {
    serializeSubtree(c, HashMap<String, ActionHandler>())
}
