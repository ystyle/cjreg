// 公开端首页渲染单元测试（public_home.cj）
//
// 首页的价值全在「平台统计」四个数字上：包总数（去重后的 org::name）/ 版本数（全部版本）/
// 用户数 / 下载量（累计）。这些数字算错不会抛异常，只会让首页说谎，所以逐个口径断言，
// 而不是只断言"页面能渲染出字符串"。
package ystyle::cjreg.ui.public

import ystyle::cjreg.ui.*

import cjxt.*
import ystyle::cjreg.store.*
import std.collection.*
import std.reflect.*
import std.unittest.*
import std.unittest.testmacro.*

// ===== 夹具 =====

func mountHome(state: CjregState, loggedIn!: Bool = false, isAdmin!: Bool = false): PublicHome {
    let page = PublicHome()
    let ctxMap = if (loggedIn) { userCtxMap(1, "admin", isAdmin) } else { HashMap<String, String>() }
    page.onMount(mountCtx(state, ctxMap))
    page
}

func renderHome(page: PublicHome): String {
    serializeSubtree(page.render(), HashMap<String, ActionHandler>())
}

func seedHomePkg(state: CjregState, org: String, name: String, version: String,
                 downloads!: Int64 = 0, deleted!: Bool = false): Unit {
    let d = PackageDoc()
    d.organization = org
    d.name = name
    d.version = version
    d.downloadCount = downloads
    d.deletedAt = if (deleted) { 1 } else { 0 }
    d.createdAt = 1000
    d.updatedAt = 2000
    state.pkgStore.save(d)
}

// 首页动作只需一个把 push 记下来的 ActionContext
func homeActionCtx(state: CjregState): (ActionContext, ArrayList<String>) {
    let nav = ArrayList<String>()
    let router = Router("sid-home", { p => nav.add(p) })
    let states = HashMap<String, AppState>()
    states.add(TypeInfo.of<CjregState>().qualifiedName, state)
    (ActionContext("sid-home", HashMap<String, String>(), HashMap<String, String>(), router, sessionStates: states), nav)
}

@Test
public class PublicHomeRenderTest {
    // 未 onMount（state=None）时给「加载中...」，而不是崩溃或空 div
    @TestCase
    public func testRenderWithoutMountShowsLoading(): Unit {
        let state = makePortalState("open")
        let page = PublicHome()          // 刻意不 onMount
        let json = renderHome(page)
        @Expect(json.contains("加载中..."), true)
        @Expect(json.contains("平台统计"), false)
    }

    // 空站：四个统计都是 0，且四个卡片标签齐全（不是空区块）
    @TestCase
    public func testRenderEmptyStore(): Unit {
        let state = makePortalState("open")
        let page = mountHome(state)
        let (pkgTotal, versions, downloads, keys) = page.collectStats(state)
        @Expect(pkgTotal, 0)
        @Expect(versions, 0)
        @Expect(downloads, 0)
        @Expect(keys, 0)

        let json = renderHome(page)
        @Expect(json.contains("平台统计"), true)
        @Expect(json.contains("包总数"), true)
        @Expect(json.contains("版本数"), true)
        @Expect(json.contains("用户数"), true)
        @Expect(json.contains("下载量"), true)
        // Hero 与核心功能区也在
        @Expect(json.contains("发现和使用仓颉语言包"), true)
        @Expect(json.contains("核心功能"), true)
        @Expect(json.contains("准备好开始了吗?"), true)
    }

    // 去重口径：同一 org::name 的多版本算 1 个包，但每个版本都计入版本数；下载量按版本累加
    @TestCase
    public func testStatsDeduplicatePackagesAndSumDownloads(): Unit {
        let state = makePortalState("open")
        seedHomePkg(state, "ystyle", "crc", "1.0.0", downloads: 10)
        seedHomePkg(state, "ystyle", "crc", "1.0.1", downloads: 20)
        seedHomePkg(state, "acme", "demo", "2.0.0", downloads: 5)

        let page = mountHome(state)
        let (pkgTotal, versions, downloads, keys) = page.collectStats(state)
        @Expect(pkgTotal, 2)        // ystyle::crc + acme::demo
        @Expect(versions, 3)        // 三个版本文档
        @Expect(downloads, 35)
        @Expect(keys, 2)
    }

    // 软删的版本完全不计入（版本数/下载量/包数都不算）
    @TestCase
    public func testStatsSkipSoftDeletedVersions(): Unit {
        let state = makePortalState("open")
        seedHomePkg(state, "ystyle", "crc", "1.0.0", downloads: 10)
        seedHomePkg(state, "ystyle", "crc", "1.0.1", downloads: 99, deleted: true)
        seedHomePkg(state, "ghost", "gone", "9.9.9", downloads: 50, deleted: true)

        let page = mountHome(state)
        let (pkgTotal, versions, downloads, keys) = page.collectStats(state)
        @Expect(pkgTotal, 1)
        @Expect(versions, 1)
        @Expect(downloads, 10)       // 软删版本的 99 与 50 都不进累计
        @Expect(keys, 1)
    }

    // 组织为空与有组织是两条不同的 key（不会被错误合并成同一个包）
    @TestCase
    public func testStatsTreatEmptyOrgAsDistinctKey(): Unit {
        let state = makePortalState("open")
        seedHomePkg(state, "", "same", "1.0.0")
        seedHomePkg(state, "org", "same", "1.0.0")
        let page = mountHome(state)
        let (pkgTotal, versions, _, keys) = page.collectStats(state)
        @Expect(pkgTotal, 2)
        @Expect(keys, 2)
        @Expect(versions, 2)
    }

    // 用户数来自用户表
    @TestCase
    public func testUserCountReflectsUserStore(): Unit {
        let state = makePortalState("open")
        let _ = state.auth.createUser("alice", "AlicePass1", false)
        let _ = state.auth.createUser("bob", "BobPass1", false)
        let page = mountHome(state)
        let json = renderHome(page)
        // 2 个用户 → 统计卡片里有「2」与「用户数」
        @Expect(json.contains("用户数"), true)
        @Expect(state.userStore.listAllUsers().size, 2)
    }

    // 大下载量走「万」档（口径与列表卡片一致）
    @TestCase
    public func testDownloadStatUsesWanFormat(): Unit {
        let state = makePortalState("open")
        seedHomePkg(state, "ystyle", "hot", "1.0.0", downloads: 34000)
        let page = mountHome(state)
        let json = renderHome(page)
        @Expect(json.contains("3万"), true)
    }

    // 导航跟随登录态：未登录给「登录」，管理员给「管理后台」
    @TestCase
    public func testNavFollowsLoginState(): Unit {
        let state = makePortalState("team")
        let anon = renderHome(mountHome(state))
        @Expect(anon.contains("登录"), true)
        @Expect(anon.contains("管理后台"), false)

        let admin = renderHome(mountHome(state, loggedIn: true, isAdmin: true))
        @Expect(admin.contains("管理后台"), true)
        @Expect(admin.contains("我的"), true)
    }

    // 动作：浏览包 / 快速开始 分别推 /packages 与 /docs
    @TestCase
    public func testNavigationActionsPushExpectedRoutes(): Unit {
        let state = makePortalState("open")
        let page = mountHome(state)
        let (actx, nav) = homeActionCtx(state)
        let _ = page.gotoPackages(actx)
        let _ = page.gotoDocs(actx)
        @Expect(nav.size, 2)
        @Expect(nav[0], "/packages")
        @Expect(nav[1], "/docs")
    }

    // 组件级事件（Button.onClick）在 expandTree 后才挂到 VNode 上：断言入口确实可点
    @TestCase
    public func testHeroButtonsAreClickable(): Unit {
        let state = makePortalState("open")
        let page = mountHome(state)
        let json = serializeSubtree(RenderContext.expandTree(page.render(), ""), HashMap<String, ActionHandler>())
        @Expect(json.contains("浏览包"), true)
        @Expect(json.contains("快速开始"), true)
        @Expect(json.contains("探索包"), true)
        @Expect(json.contains("查看文档"), true)
    }
}
