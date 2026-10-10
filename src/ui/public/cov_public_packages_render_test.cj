// 公开端包列表渲染单元测试（public_packages.cj）
//
// 这一页的三件事都容易「静默错」：① 每个 org::name 只展示最新版本（semver 比较，不是字典序）；
// ② 搜索/分类筛选是**信号派生**（render 期读信号，不靠动作回写缓存）；③ 分页切片与越界钳制。
// 所以断言直接落在 render 出来的 JSON 上：改信号 → 立刻重渲 → 内容跟着变。
package ystyle::cjreg.ui.public

import ystyle::cjreg.ui.*

import cjxt.*
import ystyle::cjreg.store.*
import std.collection.*
import std.reflect.*
import std.unittest.*
import std.unittest.testmacro.*

// ===== 夹具 =====

func mountPackagesPage(state: CjregState, loggedIn!: Bool = false): PublicPackages {
    let page = PublicPackages()
    let ctxMap = if (loggedIn) { userCtxMap(1, "admin", false) } else { HashMap<String, String>() }
    page.onMount(mountCtx(state, ctxMap))
    page
}

func renderPackagesPage(page: PublicPackages): String {
    serializeSubtree(page.render(), HashMap<String, ActionHandler>())
}

func seedListPkg(state: CjregState, org: String, name: String, version: String,
                 desc!: String = "", cat!: String = "", license!: String = "",
                 tags!: Array<String> = Array<String>(), artifact!: String = "src",
                 executable!: Bool = false, downloads!: Int64 = 0, deleted!: Bool = false): Unit {
    let d = PackageDoc()
    d.organization = org
    d.name = name
    d.version = version
    d.description = desc
    d.artifactType = artifact
    d.executable = executable
    d.downloadCount = downloads
    d.deletedAt = if (deleted) { 1 } else { 0 }
    d.createdAt = 1000
    d.updatedAt = 2000
    if (!cat.isEmpty()) { d.category = ArrayList<String>([cat]) }
    if (!license.isEmpty()) { d.license = ArrayList<String>([license]) }
    d.tag = ArrayList<String>(tags)
    state.pkgStore.save(d)
}

func packagesActionCtx(state: CjregState): (ActionContext, ArrayList<String>) {
    let nav = ArrayList<String>()
    let router = Router("sid-pkgs", { p => nav.add(p) })
    let states = HashMap<String, AppState>()
    states.add(TypeInfo.of<CjregState>().qualifiedName, state)
    (ActionContext("sid-pkgs", HashMap<String, String>(), HashMap<String, String>(), router, sessionStates: states), nav)
}

@Test
public class PublicPackagesListTest {
    // 未挂载（state=None）→ 空 div，不崩
    @TestCase
    public func testRenderWithoutMount(): Unit {
        let state = makePortalState("open")
        let page = PublicPackages()
        let json = renderPackagesPage(page)
        @Expect(json.contains("发现仓颉包"), false)
        @Expect(json.size > 0, true)
    }

    // 空库：给「暂无包数据」空态，且不渲染分页器
    @TestCase
    public func testEmptyStoreShowsEmptyState(): Unit {
        let state = makePortalState("open")
        let json = renderPackagesPage(mountPackagesPage(state))
        @Expect(json.contains("没有找到匹配的包"), true)
        @Expect(json.contains("发现仓颉包"), true)
        @Expect(json.contains("分类筛选"), true)
        @Expect(json.contains("el-pagination"), false)
    }

    // collectLatest：同一 org::name 只留最高版本（semver 比较而非字符串序）
    @TestCase
    public func testCollectLatestPicksHighestSemver(): Unit {
        let state = makePortalState("open")
        seedListPkg(state, "ystyle", "crc", "1.0.9")
        seedListPkg(state, "ystyle", "crc", "1.0.10")   // 字符串序上 "1.0.9" > "1.0.10"，semver 上相反
        seedListPkg(state, "ystyle", "crc", "1.0.2")
        let page = mountPackagesPage(state)
        let latest = page.collectLatest(state.pkgStore.storm.all<PackageDoc>())
        @Expect(latest.size, 1)
        @Expect(latest[0].version, "1.0.10")

        let json = renderPackagesPage(page)
        @Expect(json.contains("1.0.10"), true)
        @Expect(json.contains("1.0.9"), false)          // 非最新版本不出现在列表
    }

    // 软删版本不参与（若某包只剩软删版本，该包整个不出现）
    @TestCase
    public func testCollectLatestSkipsDeleted(): Unit {
        let state = makePortalState("open")
        seedListPkg(state, "ystyle", "crc", "1.0.0")
        seedListPkg(state, "ystyle", "crc", "9.9.9", deleted: true)   // 更高的版本但已软删
        seedListPkg(state, "ghost", "gone", "1.0.0", deleted: true)
        let page = mountPackagesPage(state)
        let latest = page.collectLatest(state.pkgStore.storm.all<PackageDoc>())
        @Expect(latest.size, 1)
        @Expect(latest[0].version, "1.0.0")

        let json = renderPackagesPage(page)
        @Expect(json.contains("ystyle::crc"), true)
        @Expect(json.contains("ghost::gone"), false)
        @Expect(json.contains("9.9.9"), false)
    }

    // 空组织包的卡片标题回退成裸包名（不显示 "::name"）
    @TestCase
    public func testEmptyOrgCardTitleFallsBackToName(): Unit {
        let state = makePortalState("open")
        seedListPkg(state, "", "bare", "1.0.0", desc: "无组织包")
        let json = renderPackagesPage(mountPackagesPage(state))
        @Expect(json.contains("bare"), true)
        @Expect(json.contains("::bare"), false)
    }

    // 搜索信号：名称 / 组织 / 描述 三类命中，且**不需要任何动作**即时生效
    @TestCase
    public func testSearchSignalFiltersImmediately(): Unit {
        let state = makePortalState("open")
        seedListPkg(state, "ystyle", "jsonrpc", "0.7.7", desc: "JSON-RPC 框架")
        seedListPkg(state, "acme", "demo", "1.0.0", desc: "示例包")
        let page = mountPackagesPage(state)

        // 初始：两个都在
        let all = renderPackagesPage(page)
        @Expect(all.contains("ystyle::jsonrpc"), true)
        @Expect(all.contains("acme::demo"), true)

        // 按名字
        page.search.set("jsonrpc")
        let byName = renderPackagesPage(page)
        @Expect(byName.contains("ystyle::jsonrpc"), true)
        @Expect(byName.contains("acme::demo"), false)

        // 按组织
        page.search.set("acme")
        let byOrg = renderPackagesPage(page)
        @Expect(byOrg.contains("acme::demo"), true)
        @Expect(byOrg.contains("ystyle::jsonrpc"), false)

        // 按描述
        page.search.set("JSON-RPC")
        @Expect(renderPackagesPage(page).contains("ystyle::jsonrpc"), true)

        // 无命中 → 空态而不是空表
        page.search.set("nothing-matches")
        let miss = renderPackagesPage(page)
        @Expect(miss.contains("没有找到匹配的包"), true)
        @Expect(miss.contains("ystyle::jsonrpc"), false)

        // 清空恢复全量
        page.search.set("")
        @Expect(renderPackagesPage(page).contains("acme::demo"), true)
    }

    // 分类信号：命中任一选中分类即保留；无选中则全通过
    @TestCase
    public func testCategorySignalFilters(): Unit {
        let state = makePortalState("open")
        seedListPkg(state, "ystyle", "net", "1.0.0", cat: "Network")
        seedListPkg(state, "ystyle", "tool", "1.0.0", cat: "Utility")
        seedListPkg(state, "ystyle", "nocat", "1.0.0")            // 无分类
        let page = mountPackagesPage(state)

        page.selectedCategories.set(ArrayList<String>(["Network"]))
        let onlyNet = renderPackagesPage(page)
        @Expect(onlyNet.contains("ystyle::net"), true)
        @Expect(onlyNet.contains("ystyle::tool"), false)
        @Expect(onlyNet.contains("ystyle::nocat"), false)      // 无分类的包不命中

        // 多选：并集
        page.selectedCategories.set(ArrayList<String>(["Network", "Utility"]))
        let both = renderPackagesPage(page)
        @Expect(both.contains("ystyle::net"), true)
        @Expect(both.contains("ystyle::tool"), true)
        @Expect(both.contains("ystyle::nocat"), false)

        // 清空筛选 → 全通过（含无分类）
        page.selectedCategories.set(ArrayList<String>())
        @Expect(renderPackagesPage(page).contains("ystyle::nocat"), true)
    }

    // 搜索与分类是「与」关系（同时生效）
    @TestCase
    public func testSearchAndCategoryCombine(): Unit {
        let state = makePortalState("open")
        seedListPkg(state, "ystyle", "net", "1.0.0", cat: "Network")
        seedListPkg(state, "ystyle", "tool", "1.0.0", cat: "Utility")
        let page = mountPackagesPage(state)
        page.search.set("tool")
        page.selectedCategories.set(ArrayList<String>(["Network"]))
        let json = renderPackagesPage(page)
        // 名字命中 tool 但分类不命中 Network → 被过滤掉
        @Expect(json.contains("ystyle::tool"), false)
        @Expect(json.contains("没有找到匹配的包"), true)
    }

    // matchesSearch / matchesCategory 纯函数边界
    @TestCase
    public func testMatcherEdgeCases(): Unit {
        let state = makePortalState("open")
        let page = mountPackagesPage(state)
        let d = PackageDoc()
        d.organization = "ystyle"
        d.name = "crc"
        d.description = "CRC 校验"
        @Expect(page.matchesSearch(d, ""), true)         // 空查询全通过
        @Expect(page.matchesSearch(d, "crc"), true)
        @Expect(page.matchesSearch(d, "ystyle"), true)
        @Expect(page.matchesSearch(d, "校验"), true)
        @Expect(page.matchesSearch(d, "zzz"), false)

        @Expect(page.matchesCategory(d, ArrayList<String>()), true)   // 无选中全通过
        d.category = ArrayList<String>(["Utility"])
        @Expect(page.matchesCategory(d, ArrayList<String>(["Utility"])), true)
        @Expect(page.matchesCategory(d, ArrayList<String>(["Network"])), false)
        // 无分类的包在有任何选中分类时一律不命中
        let noCat = PackageDoc()
        @Expect(page.matchesCategory(noCat, ArrayList<String>(["Utility"])), false)
    }

    // 渲染卡片：描述空 → 「暂无描述」；源码/二进制、可执行、协议、分类、标签（最多 2 个）
    @TestCase
    public func testRenderCardDetails(): Unit {
        let state = makePortalState("open")
        // 标签名刻意取成不会与内联 SVG 图标属性（path 的 d 属性）撞车的样式
        seedListPkg(state, "ystyle", "srcpkg", "1.0.0", desc: "", license: "MIT",
            cat: "Utility", tags: ["tagone", "tagtwo", "tagthree", "tagfour"])
        seedListPkg(state, "ystyle", "binpkg", "2.0.0", desc: "二进制包", artifact: "bin", executable: true)
        let json = renderPackagesPage(mountPackagesPage(state))

        @Expect(json.contains("暂无描述"), true)      // 空描述占位
        @Expect(json.contains("二进制包"), true)
        @Expect(json.contains("源码"), true)
        @Expect(json.contains("二进制"), true)
        @Expect(json.contains("可执行"), true)
        @Expect(json.contains("MIT"), true)          // license[0]
        @Expect(json.contains("工具类"), true)        // category 中文标签
        // 标签最多展示 2 个（第 3、4 个不渲染）
        @Expect(json.contains("tagone"), true)
        @Expect(json.contains("tagtwo"), true)
        @Expect(json.contains("tagthree"), false)
        @Expect(json.contains("tagfour"), false)
    }

    // 下载量文案在卡片上
    @TestCase
    public func testCardDownloadCountText(): Unit {
        let state = makePortalState("open")
        seedListPkg(state, "ystyle", "hot", "1.0.0", downloads: 12345)
        let json = renderPackagesPage(mountPackagesPage(state))
        @Expect(json.contains("1万"), true)
    }
}

@Test
public class PublicPackagesPaginationTest {
    // 默认 12 条/页：13 个包 → 第一页 12 个，第二页 1 个
    @TestCase
    public func testDefaultPageSizeSlices(): Unit {
        let state = makePortalState("open")
        for (i in 0..13) {
            seedListPkg(state, "org", "pkg${i}", "1.0.0")
        }
        let page = mountPackagesPage(state)
        @Expect(page.pageSize.get(), 12)
        @Expect(page.currentPage.get(), 1)

        let (rows, total) = page.loadPage(state.pkgStore.storm.all<PackageDoc>())
        @Expect(total, 13)
        @Expect(rows.size, 12)

        // 第二页只剩 1 条
        page.currentPage.set(2)
        let (rows2, total2) = page.loadPage(state.pkgStore.storm.all<PackageDoc>())
        @Expect(total2, 13)
        @Expect(rows2.size, 1)
    }

    // 页码越界被钳到最后一页（不返回空切片，看起来像"包丢了"）
    @TestCase
    public func testOutOfRangePageClampsToLast(): Unit {
        let state = makePortalState("open")
        for (i in 0..13) {
            seedListPkg(state, "org", "pkg${i}", "1.0.0")
        }
        let page = mountPackagesPage(state)
        page.currentPage.set(99)
        let (rows, total) = page.loadPage(state.pkgStore.storm.all<PackageDoc>())
        @Expect(total, 13)
        @Expect(rows.size, 1)

        // 页码 < 1 钳到第一页
        page.currentPage.set(0)
        let (rows0, _) = page.loadPage(state.pkgStore.storm.all<PackageDoc>())
        @Expect(rows0.size, 12)
    }

    // pageSize 变化影响切片
    @TestCase
    public func testPageSizeAffectsSlice(): Unit {
        let state = makePortalState("open")
        for (i in 0..5) {
            seedListPkg(state, "org", "pkg${i}", "1.0.0")
        }
        let page = mountPackagesPage(state)
        page.pageSize.set(2)
        let (rows, total) = page.loadPage(state.pkgStore.storm.all<PackageDoc>())
        @Expect(total, 5)
        @Expect(rows.size, 2)
    }

    // 空库：pageCount 兜底 1，切片为空但 total 为 0
    @TestCase
    public func testEmptyStorePagination(): Unit {
        let state = makePortalState("open")
        let page = mountPackagesPage(state)
        let (rows, total) = page.loadPage(state.pkgStore.storm.all<PackageDoc>())
        @Expect(total, 0)
        @Expect(rows.size, 0)
    }

    // 分页器随 total 出现，并且一旦有卡片就给分页器
    @TestCase
    public func testPagerRenderedWhenCardsExist(): Unit {
        let state = makePortalState("open")
        seedListPkg(state, "ystyle", "one", "1.0.0")
        let json = renderPackagesPage(mountPackagesPage(state))
        @Expect(json.contains("el-pagination"), true)
        @Expect(json.contains("共 1 条"), true)
    }

    // 搜索后页码复位到 1（onSearch 动作）
    @TestCase
    public func testSearchActionResetsPage(): Unit {
        let state = makePortalState("open")
        for (i in 0..13) {
            seedListPkg(state, "org", "pkg${i}", "1.0.0")
        }
        let page = mountPackagesPage(state)
        page.currentPage.set(2)
        let (actx, _) = packagesActionCtx(state)
        let _ = page.onSearch(actx)
        @Expect(page.currentPage.get(), 1)
    }

    // 详情跳转：带 org 走 "org::name"，无 org 走裸名
    @TestCase
    public func testGotoDetailRouteShapes(): Unit {
        let state = makePortalState("open")
        let page = mountPackagesPage(state)
        let (actx, nav) = packagesActionCtx(state)
        let _ = page.gotoDetail(actx, "ystyle", "crc")
        let _ = page.gotoDetail(actx, "", "bare")
        @Expect(nav.size, 2)
        @Expect(nav[0], "/packages/ystyle::crc")
        @Expect(nav[1], "/packages/bare")
    }

    // 分类侧栏列出所有官方分类的复选框
    @TestCase
    public func testCategorySidebarListsOfficialCategories(): Unit {
        let state = makePortalState("open")
        let json = renderPackagesPage(mountPackagesPage(state))
        @Expect(json.contains("网络"), true)
        @Expect(json.contains("数据库驱动"), true)
        @Expect(json.contains("工具类"), true)
        @Expect(json.contains("el-checkbox"), true)
    }

    // 列表页导航跟随登录态
    @TestCase
    public func testNavFollowsLogin(): Unit {
        let state = makePortalState("open")
        @Expect(renderPackagesPage(mountPackagesPage(state)).contains("登录"), true)
        @Expect(renderPackagesPage(mountPackagesPage(state, loggedIn: true)).contains("我的"), true)
    }
}
