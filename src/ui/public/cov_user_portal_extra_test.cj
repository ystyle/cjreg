// 用户门户 /me 补充单测（user_portal.cj）
//
// 换人重渲、Token 展示与重置、搜索与分页、登出、动作级会话校验。
// 与既有 user_portal_test.cj 的关注点错开：那边守「三区块渲染 + 登录收尾」的基线，
// 这边守**交互与状态变化**——每个动作改了什么、哪些信号被置脏、越权/失效会话怎么处理。
package ystyle::cjreg.ui.public

import ystyle::cjreg.ui.*

import cjxt.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.util.*
import ystyle::cjreg.auth.model.*
import ystyle::cjreg.config.*
import std.collection.*
import std.reflect.*
import std.unittest.*
import std.unittest.testmacro.*

// ===== 夹具 =====

func mountPortal(state: CjregState, ctxMap: HashMap<String, String>): UserPortalPage {
    let page = UserPortalPage()
    page.onMount(mountCtx(state, ctxMap))
    page
}

func renderPortal(page: UserPortalPage): String {
    serializeSubtree(page.render(), HashMap<String, ActionHandler>())
}

// 会话上下文与 ctxMap 共享同一份 map（动作里 setContext 的结果可事后断言）
func portalActionCtx(state: CjregState, ctxMap: HashMap<String, String>)
    : (ActionContext, ArrayList<String>) {
    let nav = ArrayList<String>()
    let router = Router("sid-portal", { p => nav.add(p) })
    let states = HashMap<String, AppState>()
    states.add(TypeInfo.of<CjregState>().qualifiedName, state)
    (ActionContext("sid-portal", ctxMap, HashMap<String, String>(), router, sessionStates: states), nav)
}

func seedPortalPkg(state: CjregState, org: String, name: String, version: String,
                   publisherId!: Int64 = 0, downloads!: Int64 = 0,
                   updatedAt!: Int64 = 2000): PackageDoc {
    let d = PackageDoc()
    d.organization = org
    d.name = name
    d.version = version
    d.publisherId = publisherId
    d.downloadCount = downloads
    d.createdAt = 1000
    d.updatedAt = updatedAt
    state.pkgStore.save(d)
    d
}

@Test
public class UserPortalTokenTest {
    // Token 区块：展示完整 Token + 可直接复制的 cangjie-repo.toml 示例（地址取自配置）
    @TestCase
    public func testTokenSectionShowsFullTokenAndExample(): Unit {
        let state = makePortalState("team", publicUrl: "https://reg.example.com")
        let alice = state.auth.createUser("alice", "AlicePass1", false).getOrThrow()
        let page = mountPortal(state, userCtxMap(alice.id, "alice", false))
        let json = renderPortal(page)
        @Expect(json.contains("我的发布 Token"), true)
        @Expect(json.contains(alice.publishToken), true)
        @Expect(json.contains("[repository.home]"), true)
        @Expect(json.contains("https://reg.example.com"), true)
        @Expect(json.contains("重置 Token"), true)
        @Expect(json.contains("请勿泄漏"), true)
    }

    // 配置的 public_url 为空 → 示例回退占位符（不显示空 registry）
    @TestCase
    public func testTokenExampleFallsBackWhenUrlEmpty(): Unit {
        let state = makePortalState("team")
        state.config.publicUrl = ""
        let alice = state.auth.createUser("alice", "AlicePass1", false).getOrThrow()
        let page = mountPortal(state, userCtxMap(alice.id, "alice", false))
        @Expect(renderPortal(page).contains("http://<cjreg 地址>"), true)
    }

    // 重置对话框：askResetToken 打开、cancelResetToken 关闭
    @TestCase
    public func testResetDialogOpenAndCancel(): Unit {
        let state = makePortalState("team")
        let alice = state.auth.createUser("alice", "AlicePass1", false).getOrThrow()
        let page = mountPortal(state, userCtxMap(alice.id, "alice", false))
        let (actx, _) = portalActionCtx(state, userCtxMap(alice.id, "alice", false))

        @Expect(page.resetVisible.get(), false)
        let _ = page.askResetToken(actx)
        @Expect(page.resetVisible.get(), true)
        @Expect(renderPortal(page).contains("重置后旧 Token 立即失效"), true)

        let _ = page.cancelResetToken(actx)
        @Expect(page.resetVisible.get(), false)
    }

    // 确认重置：Token 换新、对话框关闭、成功提示，并且**只能重置自己的**（id 取自会话）
    @TestCase
    public func testConfirmResetTokenRotatesOwnToken(): Unit {
        let state = makePortalState("team")
        let alice = state.auth.createUser("alice", "AlicePass1", false).getOrThrow()
        let bob = state.auth.createUser("bob", "BobPass1", false).getOrThrow()
        let bobTokenBefore = bob.publishToken
        let aliceTokenBefore = alice.publishToken

        let ctxMap = userCtxMap(alice.id, "alice", false)
        let page = mountPortal(state, ctxMap)
        let (actx, _) = portalActionCtx(state, ctxMap)
        let _ = page.askResetToken(actx)
        let _ = page.confirmResetToken(actx)

        @Expect(page.resetVisible.get(), false)
        @Expect(page.tokenValue.get().isEmpty(), false)
        @Expect(page.tokenValue.get() == aliceTokenBefore, false)   // 确实换了
        @Expect(page.msg.get(), "已重置发布 Token（旧 Token 已失效）")
        @Expect(page.msgOk.get(), true)
        // 别人的 Token 不受影响
        @Expect(state.userStore.getUser(bob.id).getOrThrow().publishToken, bobTokenBefore)
        // 换后的值就是库里的值
        @Expect(state.userStore.getUser(alice.id).getOrThrow().publishToken, page.tokenValue.get())
    }

    // 会话失效（uid 指向已删除用户）→ 拒绝重置并提示重新登录
    @TestCase
    public func testConfirmResetTokenRejectsStaleSession(): Unit {
        let state = makePortalState("team")
        let alice = state.auth.createUser("alice", "AlicePass1", false).getOrThrow()
        let ctxMap = userCtxMap(alice.id, "alice", false)
        let page = mountPortal(state, ctxMap)
        // 会话换成一个不存在的 uid（用户被删/库被换）
        ctxMap["uid"] = "99999"
        let (actx, _) = portalActionCtx(state, ctxMap)
        let _ = page.confirmResetToken(actx)
        @Expect(page.msg.get(), "会话已失效，请重新登录")
        @Expect(page.msgOk.get(), false)
    }

    // 会话里没有 uid → 同样拒绝（不是"重置了 0 号用户"）
    @TestCase
    public func testConfirmResetTokenWithoutUidIsRejected(): Unit {
        let state = makePortalState("team")
        let _ = state.auth.createUser("alice", "AlicePass1", false)
        let ctxMap = HashMap<String, String>()
        let page = mountPortal(state, ctxMap)
        let (actx, _) = portalActionCtx(state, ctxMap)
        let _ = page.confirmResetToken(actx)
        @Expect(page.msg.get(), "会话已失效，请重新登录")
        @Expect(page.msgOk.get(), false)
    }

    // uid 不是数字 → 当未登录处理，不抛异常
    @TestCase
    public func testNonNumericUidTreatedAsAnonymous(): Unit {
        let state = makePortalState("team")
        let ctxMap = HashMap<String, String>()
        ctxMap["uid"] = "not-a-number"
        let page = mountPortal(state, ctxMap)
        @Expect(page.currentUid(), 0)
        @Expect(page.tokenValue.get(), "")
    }

    // 未挂载（state=None）时 confirmResetToken 安全返回
    @TestCase
    public func testConfirmResetTokenWithoutStateIsSafe(): Unit {
        let state = makePortalState("team")
        let ctxMap = userCtxMap(1, "alice", false)
        let page = UserPortalPage()
        let (actx, _) = portalActionCtx(state, ctxMap)
        let _ = page.confirmResetToken(actx)
        @Expect(page.msg.get(), "")
    }
}

@Test
public class UserPortalPackagesTest {
    // 我的包：搜索命中包名/组织；无命中 → 「还没有发布过包」空态
    @TestCase
    public func testPackageSearchFiltersRows(): Unit {
        let state = makePortalState("team")
        let alice = state.auth.createUser("alice", "AlicePass1", false).getOrThrow()
        seedPortalPkg(state, "ystyle", "jsonrpc", "0.7.7", publisherId: alice.id)
        seedPortalPkg(state, "acme", "demo", "1.0.0", publisherId: alice.id)

        let page = mountPortal(state, userCtxMap(alice.id, "alice", false))
        @Expect(page.pkgTotal.get(), 2)

        page.pkgSearch.set("jsonrpc")
        let (actx, _) = portalActionCtx(state, userCtxMap(alice.id, "alice", false))
        let _ = page.onSearch(actx)
        @Expect(page.pkgTotal.get(), 1)
        @Expect(page.pkgRows.get()[0].name, "jsonrpc")
        @Expect(page.pkgPage.get(), 1)              // 搜索复位页码

        // 按组织搜
        page.pkgSearch.set("acme")
        let _ = page.onSearch(actx)
        @Expect(page.pkgTotal.get(), 1)
        @Expect(page.pkgRows.get()[0].org, "acme")

        // 无命中 → 空态文案
        page.pkgSearch.set("nothing-here")
        let _ = page.onSearch(actx)
        @Expect(page.pkgTotal.get(), 0)
        @Expect(renderPortal(page).contains("还没有发布过包"), true)
    }

    // 分页：11 个包、10 条/页 → 第二页 1 条；onPageChange 重算切片
    @TestCase
    public func testPackagePagination(): Unit {
        let state = makePortalState("team")
        let alice = state.auth.createUser("alice", "AlicePass1", false).getOrThrow()
        for (i in 0..11) {
            seedPortalPkg(state, "org", "pkg${i}", "1.0.0", publisherId: alice.id)
        }
        let page = mountPortal(state, userCtxMap(alice.id, "alice", false))
        @Expect(page.pkgTotal.get(), 11)
        @Expect(page.pkgRows.get().size, 10)        // 第一页
        @Expect(page.pkgPageSize.get(), 10)

        let (actx, _) = portalActionCtx(state, userCtxMap(alice.id, "alice", false))
        page.pkgPage.set(2)
        let _ = page.onPageChange(actx)
        @Expect(page.pkgRows.get().size, 1)         // 第二页剩 1 条
        @Expect(renderPortal(page).contains("共 11 条"), true)
    }

    // 不是我的包 → 列表为空（只列我发过版本的）
    @TestCase
    public func testOnlyMyPackagesListed(): Unit {
        let state = makePortalState("team")
        let alice = state.auth.createUser("alice", "AlicePass1", false).getOrThrow()
        let bob = state.auth.createUser("bob", "BobPass1", false).getOrThrow()
        seedPortalPkg(state, "ystyle", "mine", "1.0.0", publisherId: alice.id)
        seedPortalPkg(state, "ystyle", "bobs", "1.0.0", publisherId: bob.id)

        let page = mountPortal(state, userCtxMap(alice.id, "alice", false))
        @Expect(page.pkgTotal.get(), 1)
        @Expect(page.pkgRows.get()[0].name, "mine")
        let json = renderPortal(page)
        @Expect(json.contains("ystyle::mine"), true)
        @Expect(json.contains("ystyle::bobs"), false)
    }

    // 历史贡献：软删版本也算「我发过」（包仍在我的列表里，版本数按未删的算）
    @TestCase
    public func testSoftDeletedVersionStillCountsAsMine(): Unit {
        let state = makePortalState("team")
        let alice = state.auth.createUser("alice", "AlicePass1", false).getOrThrow()
        seedPortalPkg(state, "ystyle", "gone", "1.0.0", publisherId: alice.id)
        let d = seedPortalPkg(state, "ystyle", "gone", "2.0.0", publisherId: alice.id)
        d.deletedAt = 1
        state.pkgStore.save(d)

        let page = mountPortal(state, userCtxMap(alice.id, "alice", false))
        @Expect(page.pkgTotal.get(), 1)
        @Expect(page.pkgRows.get()[0].name, "gone")
        @Expect(page.pkgRows.get()[0].versionCount, 1)   // 软删版本不计版本数
    }

    // owner 标记：最早一条版本记录的发布者才是「所有者」，协作者显示「协作者」
    @TestCase
    public func testOwnerFlagFromEarliestVersion(): Unit {
        let state = makePortalState("team")
        let alice = state.auth.createUser("alice", "AlicePass1", false).getOrThrow()
        let bob = state.auth.createUser("bob", "BobPass1", false).getOrThrow()
        // alice 先发（成为 owner），bob 后来协作了同一包
        seedPortalPkg(state, "ystyle", "shared", "1.0.0", publisherId: alice.id)
        seedPortalPkg(state, "ystyle", "shared", "1.1.0", publisherId: bob.id)

        // alice 视角：所有者
        let alicePage = mountPortal(state, userCtxMap(alice.id, "alice", false))
        @Expect(alicePage.pkgRows.get()[0].isOwner, true)
        @Expect(renderPortal(alicePage).contains("所有者"), true)

        // bob 视角：协作者
        let bobPage = mountPortal(state, userCtxMap(bob.id, "bob", false))
        @Expect(bobPage.pkgRows.get()[0].isOwner, false)
        @Expect(renderPortal(bobPage).contains("协作者"), true)
    }

    // 换人后 render 就地重渲能纠正列表（onMount 不再跑）：loadedUid 变了就重新加载
    @TestCase
    public func testRenderReloadsAfterUserSwitches(): Unit {
        let state = makePortalState("team")
        let alice = state.auth.createUser("alice", "AlicePass1", false).getOrThrow()
        let bob = state.auth.createUser("bob", "BobPass1", false).getOrThrow()
        seedPortalPkg(state, "ystyle", "alicepkg", "1.0.0", publisherId: alice.id)

        let ctxMap = userCtxMap(alice.id, "alice", false)
        let page = mountPortal(state, ctxMap)
        @Expect(renderPortal(page).contains("ystyle::alicepkg"), true)

        // 换成 bob（bob 没发过包）：只 render，不重跑 onMount
        ctxMap["uid"] = bob.id.toString()
        ctxMap["username"] = "bob"
        let json = renderPortal(page)
        @Expect(json.contains("ystyle::alicepkg"), false)
        @Expect(json.contains("还没有发布过包"), true)
        @Expect(json.contains("当前登录：bob"), true)
        @Expect(page.tokenValue.get(), bob.publishToken)     // Token 也跟着换
    }

    // 未登录（uid=0）时 refresh 直接返回，不查库、不抛异常
    @TestCase
    public func testAnonymousPortalDoesNotLoad(): Unit {
        let state = makePortalState("team")
        let ctxMap = HashMap<String, String>()
        let page = mountPortal(state, ctxMap)
        @Expect(page.currentUid(), 0)
        @Expect(page.currentUsername(), "")
        @Expect(page.tokenValue.get(), "")
        @Expect(page.pkgTotal.get(), 0)
        @Expect(page.teamRows.get().size, 0)
        // 未登录也能渲染（导航给「登录」）
        @Expect(renderPortal(page).contains("登录"), true)
    }

    // 未挂载时 currentUid/currentUsername 走 None 分支
    @TestCase
    public func testUnmountedPortalAccessors(): Unit {
        let page = UserPortalPage()
        @Expect(page.currentUid(), 0)
        @Expect(page.currentUsername(), "")
    }
}

@Test
public class UserPortalTeamsAndActionsTest {
    // 团队区块：关联组织/包的展示 + 权限 Tag 颜色分支（overwrite/write/read）
    @TestCase
    public func testTeamSectionShowsPermissionsAndAssociations(): Unit {
        let state = makePortalState("team")
        let alice = state.auth.createUser("alice", "AlicePass1", false).getOrThrow()
        let orgId = state.adminData.createOrg("myorg", "我的组织", 1, 0)
        let t1 = state.adminData.createTeam("writers", 0, displayName: "写手组", permission: "write")
        state.adminData.setTeamOrganizations(t1, [orgId], 0)
        let pairs = ArrayList<(String, String)>()
        pairs.add(("myorg", "demo"))
        state.adminData.setTeamPackages(t1, pairs.toArray(), 0)
        state.adminData.setTeamMembers(t1, [alice.id])
        let t2 = state.adminData.createTeam("owners", 0, displayName: "覆盖组", permission: "overwrite")
        state.adminData.setTeamMembers(t2, [alice.id])

        let page = mountPortal(state, userCtxMap(alice.id, "alice", false))
        @Expect(page.teamRows.get().size, 2)
        let json = renderPortal(page)
        @Expect(json.contains("写手组"), true)
        @Expect(json.contains("覆盖组"), true)
        @Expect(json.contains("write"), true)
        @Expect(json.contains("overwrite"), true)
        @Expect(json.contains("myorg::demo"), true)     // 关联包
        @Expect(json.contains("myorg"), true)           // 关联组织名（orgLabel 取 name）
        @Expect(json.contains("团队模式"), true)         // 权限模式提示
    }

    // read 权限团队的 Tag 走 Info 分支；无关联组织/包显示 "-"
    @TestCase
    public func testReadTeamShowsPlaceholders(): Unit {
        let state = makePortalState("team")
        let alice = state.auth.createUser("alice", "AlicePass1", false).getOrThrow()
        let t = state.adminData.createTeam("readers", 0, displayName: "只读组", permission: "read")
        state.adminData.setTeamMembers(t, [alice.id])
        let json = renderPortal(mountPortal(state, userCtxMap(alice.id, "alice", false)))
        @Expect(json.contains("只读组"), true)
        @Expect(json.contains("read"), true)
        @Expect(json.contains("-"), true)               // 关联组织/包占位
    }

    // open 模式下权限提示文案不同
    @TestCase
    public func testOpenModeHint(): Unit {
        let state = makePortalState("open")
        let alice = state.auth.createUser("alice", "AlicePass1", false).getOrThrow()
        let json = renderPortal(mountPortal(state, userCtxMap(alice.id, "alice", false)))
        @Expect(json.contains("开放模式"), true)
        @Expect(json.contains("团队模式"), false)
    }

    // 登出：清会话上下文四项 + currentUser 置空 + 跳登录页
    @TestCase
    public func testLogoutClearsContextAndRedirects(): Unit {
        let state = makePortalState("team")
        let alice = state.auth.createUser("alice", "AlicePass1", false).getOrThrow()
        state.currentUser.set(Some(alice))
        state.sessionToken.set("sess-abc")
        let ctxMap = userCtxMap(alice.id, "alice", false)
        let page = mountPortal(state, ctxMap)
        let (actx, nav) = portalActionCtx(state, ctxMap)
        let _ = page.doLogout(actx)

        @Expect(ctxMap.get("uid").getOrThrow(), "")
        @Expect(ctxMap.get("username").getOrThrow(), "")
        @Expect(ctxMap.get("isAdmin").getOrThrow(), "")
        @Expect(ctxMap.get("token").getOrThrow(), "")
        @Expect(state.currentUser.get().isNone(), true)
        @Expect(nav.size, 1)
        @Expect(nav[0], "/user/login")
    }

    // 登出后重渲：导航回到「登录」入口
    @TestCase
    public func testNavReturnsToLoginAfterLogout(): Unit {
        let state = makePortalState("team")
        let alice = state.auth.createUser("alice", "AlicePass1", false).getOrThrow()
        state.currentUser.set(Some(alice))
        let ctxMap = userCtxMap(alice.id, "alice", false)
        let page = mountPortal(state, ctxMap)
        @Expect(renderPortal(page).contains("我的"), true)

        let (actx, _) = portalActionCtx(state, ctxMap)
        let _ = page.doLogout(actx)
        let json = renderPortal(page)
        @Expect(json.contains("登录"), true)
        @Expect(json.contains("管理后台"), false)
    }

    // 提示 Tag：ok/fail 决定颜色（msgOk=false → Danger）
    @TestCase
    public func testNotifySetsMessageKind(): Unit {
        let state = makePortalState("team")
        let alice = state.auth.createUser("alice", "AlicePass1", false).getOrThrow()
        let page = mountPortal(state, userCtxMap(alice.id, "alice", false))
        // 无消息时不渲染提示行（emptyState 也用 empty-line，故按内容断言而不是类名）
        @Expect(renderPortal(page).contains("出问题了"), false)

        page.notify("出问题了", false)
        @Expect(page.msg.get(), "出问题了")
        @Expect(page.msgOk.get(), false)
        let json = renderPortal(page)
        @Expect(json.contains("出问题了"), true)
        @Expect(json.contains("empty-line"), true)

        page.notify("成功了", true)
        @Expect(page.msgOk.get(), true)
        @Expect(renderPortal(page).contains("成功了"), true)
    }

    // 搜索框回车：Enter 触发搜索（Enter 与非 Enter 两条分支）
    @TestCase
    public func testEnterKeyTriggersSearch(): Unit {
        let state = makePortalState("team")
        let alice = state.auth.createUser("alice", "AlicePass1", false).getOrThrow()
        seedPortalPkg(state, "ystyle", "jsonrpc", "1.0.0", publisherId: alice.id)
        seedPortalPkg(state, "acme", "demo", "1.0.0", publisherId: alice.id)
        let ctxMap = userCtxMap(alice.id, "alice", false)
        let page = mountPortal(state, ctxMap)
        page.pkgSearch.set("jsonrpc")
        page.pkgPage.set(1)

        // 非 Enter：不触发搜索
        let states = HashMap<String, AppState>()
        states.add(TypeInfo.of<CjregState>().qualifiedName, state)
        let nonEnter = ActionContext("sid-portal", ctxMap, HashMap<String, String>(),
            Router("sid-portal", { _ => () }),
            sessionStates: states,
            keyEvent: Some(KeyEvent("a", "", 65, false, false, false, false)))
        let _ = page.onEnterSearch(nonEnter)
        @Expect(page.pkgTotal.get(), 2)      // 没搜

        // Enter：触发搜索并复位页码
        let enter = ActionContext("sid-portal", ctxMap, HashMap<String, String>(),
            Router("sid-portal", { _ => () }),
            sessionStates: states,
            keyEvent: Some(KeyEvent("Enter", "Enter", 13, false, false, false, false)))
        page.pkgPage.set(2)
        let _ = page.onEnterSearch(enter)
        @Expect(page.pkgTotal.get(), 1)
        @Expect(page.pkgPage.get(), 1)

        // 没有 keyEvent：不触发
        let noKey = ActionContext("sid-portal", ctxMap, HashMap<String, String>(),
            Router("sid-portal", { _ => () }), sessionStates: states)
        page.pkgSearch.set("acme")
        let _ = page.onEnterSearch(noKey)
        @Expect(page.pkgTotal.get(), 1)      // 仍是上一次的结果，说明没重算
    }

    // 门户导航跟随登录态（管理员额外有后台入口）
    @TestCase
    public func testPortalNavFollowsLoginState(): Unit {
        let state = makePortalState("team")
        let admin = state.auth.createUser("adminz", "AdminPass1", true).getOrThrow()
        let adminJson = renderPortal(mountPortal(state, userCtxMap(admin.id, "adminz", true)))
        @Expect(adminJson.contains("管理后台"), true)
        @Expect(adminJson.contains("我的"), true)

        let alice = state.auth.createUser("alice", "AlicePass1", false).getOrThrow()
        let userJson = renderPortal(mountPortal(state, userCtxMap(alice.id, "alice", false)))
        @Expect(userJson.contains("管理后台"), false)
        @Expect(userJson.contains("我的"), true)
    }

    // 退出登录按钮与重置对话框都在渲染树里
    @TestCase
    public func testToolbarAndDialogRendered(): Unit {
        let state = makePortalState("team")
        let alice = state.auth.createUser("alice", "AlicePass1", false).getOrThrow()
        let page = mountPortal(state, userCtxMap(alice.id, "alice", false))
        @Expect(renderPortal(page).contains("退出登录"), true)

        // MessageBox 关闭时返回 EmptyVNode（整块不在 DOM）：打开后才断言标题与文案
        @Expect(renderPortal(page).contains("重置发布 Token"), false)
        let (actx, _) = portalActionCtx(state, userCtxMap(alice.id, "alice", false))
        let _ = page.askResetToken(actx)
        let json = renderPortal(page)
        @Expect(json.contains("重置发布 Token"), true)
        @Expect(json.contains("确定继续？"), true)
        @Expect(json.contains("取消"), true)
    }

    // 「我的包」表格「详情」按钮：点了跳 /packages/org::name（含无组织包的裸名形态）
    @TestCase
    public func testDetailButtonNavigatesToPackage(): Unit {
        let state = makePortalState("team")
        let alice = state.auth.createUser("alice", "AlicePass1", false).getOrThrow()
        seedPortalPkg(state, "ystyle", "crc", "1.0.0", publisherId: alice.id)
        seedPortalPkg(state, "", "bare", "1.0.0", publisherId: alice.id)

        let ctxMap = userCtxMap(alice.id, "alice", false)
        let page = mountPortal(state, ctxMap)
        @Expect(page.pkgTotal.get(), 2)

        // 展开渲染树，把表格单元格里的「详情」动作全部取出来执行
        let handlers = HashMap<String, ActionHandler>()
        let _ = serializeSubtree(RenderContext.expandTree(page.render(), ""), handlers)
        @Expect(handlers.size > 0, true)

        let (actx, nav) = portalActionCtx(state, ctxMap)
        for ((_, h) in handlers) {
            try {
                h(actx)
            } catch (_: Exception) {
                ()   // 其它控件的动作（分页/消息框）不在本用例关注范围
            }
        }
        // 至少有一个详情跳转，且有组织时用 org::name 形态
        @Expect(nav.size > 0, true)
        var foundScoped = false
        var foundBare = false
        for (p in nav) {
            if (p.contains("/packages/ystyle::crc")) { foundScoped = true }
            if (p.contains("/packages/bare")) { foundBare = true }
        }
        @Expect(foundScoped, true)
        @Expect(foundBare, true)
    }

    // 未挂载（state=None）时三个区块渲染分支各自回退，不抛异常
    @TestCase
    public func testSectionsWithoutStateFallBack(): Unit {
        let page = UserPortalPage()          // 不 onMount：state=None、sctx=None
        // renderTokenSection / renderTeamsSection / render 都走 None 分支
        let json = renderPortal(page)
        @Expect(json.contains("http://<cjreg 地址>"), true)   // publicUrl 回退占位符
        @Expect(json.contains("开放模式"), true)                // permissionMode 回退 open
        @Expect(json.contains("当前登录："), true)              // username 回退空串
        @Expect(json.contains("我的发布 Token"), true)
    }

    // refresh 在 state=None 时直接返回（uid>0 但没挂 state 的边界）
    @TestCase
    public func testRefreshWithoutStateIsSafe(): Unit {
        let page = UserPortalPage()
        page.loadedUid = 999
        page.refresh()                        // 内部 currentUid()=0 → 直接 return
        @Expect(page.pkgTotal.get(), 0)
        @Expect(page.teamRows.get().size, 0)
        @Expect(page.tokenValue.get(), "")
    }

    // 重置失败分支：会话校验通过、但用户已被删（resetPublishToken 返回 None）
    @TestCase
    public func testConfirmResetTokenWhenUserVanished(): Unit {
        let state = makePortalState("team")
        let alice = state.auth.createUser("alice", "AlicePass1", false).getOrThrow()
        let ctxMap = userCtxMap(alice.id, "alice", false)
        let page = mountPortal(state, ctxMap)
        // 让会话里的 uid 指向一个"存在但 getUser 返回 None"后仍能通过 userSession 的场景：
        // 直接把用户从库里删掉 → userSession 也会返回 None（走"会话已失效"分支）。
        let _ = state.userStore.removeUser(alice.id)
        let (actx, _) = portalActionCtx(state, ctxMap)
        let _ = page.confirmResetToken(actx)
        // 用户没了 → 要么提示会话失效，要么提示重置失败，但绝不能报"已重置"
        @Expect(page.msgOk.get(), false)
        @Expect(page.msg.get() == "已重置发布 Token（旧 Token 已失效）", false)
    }
}
