// 包管理页渲染：搜索"输入即生效" + 左主（包）右子（版本）主子表。
//
// 这条正是本次修的缺陷：旧实现把过滤结果缓存进 rows、render 又不读过滤信号，
// 于是输入关键字后表格永不重算（只有再点「刷新」才生效）。
// 这里只 set 搜索信号，不触发任何动作，断言表格已经跟着变。
package ystyle::cjreg.ui

import cjxt.*
import cjxt.components.Input
import bstorm.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.util.*
import ystyle::cjreg.auth.model.*
import ystyle::cjreg.config.*
import std.collection.*
import std.reflect.*
import std.unittest.*
import std.unittest.testmacro.*

func seedPkg(state: CjregState, org: String, name: String, version: String,
             desc!: String = "", deleted!: Bool = false): Unit {
    let d = PackageDoc()
    d.organization = org
    d.name = name
    d.version = version
    d.description = desc
    d.deletedAt = if (deleted) { 1 } else { 0 }
    d.createdAt = 1000
    d.updatedAt = 2000
    state.pkgStore.save(d)
}

func mountPackages(state: CjregState): PackagesPage {
    let page = PackagesPage()
    page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
    page
}

func renderPackages(page: PackagesPage): String {
    serializeSubtree(page.render(), HashMap<String, ActionHandler>())
}

// 组件级事件（Component.on）由渲染遍历挂到 VNode 上（cjxt renderctx 的 attachComponentEvents），
// 直接 render() 看不到它们 —— 断言"这个输入框有没有挂 input 动作"必须走 expandTree。
func renderExpanded(c: IComponent): String {
    serializeSubtree(RenderContext.expandTree(c, ""), HashMap<String, ActionHandler>())
}

@Test
public class PackagesPageRenderTest {
    // 主表：一个 org::name 一行；搜索信号一变，行立刻跟着变（不需要任何动作）
    @TestCase
    public func testSearchFiltersMasterRowsOnSignalChange(): Unit {
        let state = makePortalState("team")
        seedPkg(state, "ystyle", "jsonrpc", "0.7.6")
        seedPkg(state, "ystyle", "jsonrpc", "0.7.7")
        seedPkg(state, "acme", "demo", "1.0.0", desc: "示例包")

        let page = mountPackages(state)
        let all = renderPackages(page)
        @Expect(all.contains("ystyle::jsonrpc"), true)
        @Expect(all.contains("acme::demo"), true)
        // 主表是聚合行：版本数 2、最新版本 0.7.7
        @Expect(all.contains("0.7.7"), true)

        page.search.set("demo")
        let hit = renderPackages(page)
        @Expect(hit.contains("acme::demo"), true)
        @Expect(hit.contains("ystyle::jsonrpc"), false)

        // 描述也参与匹配（大小写不敏感走 ASCII 小写）
        page.search.set("示例")
        @Expect(renderPackages(page).contains("acme::demo"), true)

        // 无命中：给明确空态，而不是空表
        page.search.set("nothing-matches")
        @Expect(renderPackages(page).contains("没有匹配的包"), true)
    }

    // 「点了没反应」的结构性回归：动作只写信号，**页面上必须有人读它**，否则没有组件变脏、
    // 服务端根本不下发补丁（浏览器里的表现就是点一下什么都不发生）。
    // 选中态曾经是普通字段（渲染时读不到、写它也不脏），于是单元测试直接 select()+render()
    // 是好的、真浏览器里右栏一直停在空态 —— 这条守住"渲染遍历里确实订阅了选中信号"。
    @TestCase
    public func testSelectingPackageMarksPageDirty(): Unit {
        let state = makePortalState("team")
        seedPkg(state, "ystyle", "crc", "1.0.0")
        let page = mountPackages(state)
        let _ = RenderContext.expandTree(page, "")     // 走一次渲染遍历：注册订阅
        RenderContext.clearDirty()
        @Expect(RenderContext.collectDirty().size, 0)

        page.select("ystyle", "crc")
        @Expect(RenderContext.collectDirty().size > 0, true)
        RenderContext.clearDirty()
    }

    // 空态提示与表格**并存**（提示槽位固定），不是"没行就把表格换掉"。
    // 为什么：同一批补丁里页面（父）与表格（子）都会变脏，子补丁后应用；若两者换过节点类型，
    // 子补丁会把父补丁里的中文提示顶成空表格的 "No Data"（实测：搜索无命中、计划项全隐藏）。
    @TestCase
    public func testEmptyHintCoexistsWithTable(): Unit {
        let state = makePortalState("team")
        seedPkg(state, "ystyle", "crc", "1.0.0")
        let page = mountPackages(state)
        page.search.set("nothing-matches")
        let json = renderExpanded(page.render())
        @Expect(json.contains("没有匹配的包"), true)   // 提示还在
        @Expect(json.contains("el-table"), true)       // 表格也还在（槽位没换）
    }

    // 版本列表是 Drawer（抽屉）：没点「查看版本」时抽屉不渲染；点了就有标题与版本行。
    // 抽屉里必须走 SignalView（children 是页面渲染时的快照，Drawer 自己变脏时子补丁会后应用）。
    @TestCase
    public func testVersionDrawerOpensOnSelect(): Unit {
        let state = makePortalState("team")
        seedPkg(state, "ystyle", "crc", "1.0.0")
        seedPkg(state, "ystyle", "crc", "1.0.1")
        seedPkg(state, "acme", "demo", "9.9.9")

        let page = mountPackages(state)
        let closed = renderPackages(page)
        @Expect(page.verDrawerVisible.get(), false)
        @Expect(closed.contains("el-drawer"), false)      // 关着就不该有抽屉节点

        page.select("ystyle", "crc")
        @Expect(page.verDrawerVisible.get(), true)
        let json = renderPackages(page)
        @Expect(json.contains("el-drawer"), true)
        @Expect(json.contains("ystyle::crc 的版本（2）"), true)
        @Expect(json.contains("1.0.1"), true)
        // 版本表操作列是一个「操作」下拉菜单
        @Expect(json.contains("操作"), true)
        @Expect(json.contains("详情"), true)
        // 抽屉数据只含选中包的版本（主表那行 acme::demo 仍会显示它的最新版本）
        @Expect(page.verRows.get().size, 2)
        @Expect(page.verRows.get()[0].organization, "ystyle")
        @Expect(page.verRows.get()[0].name, "crc")
    }

    // 版本表：倒序（新版本在前）+ 无 ID 列 + 分页（10 条/页）+ 操作收进下拉菜单
    @TestCase
    public func testVersionTableIsDescendingPaginatedWithoutId(): Unit {
        let state = makePortalState("team")
        for (i in 0..12) {
            seedPkg(state, "ystyle", "many", "1.0.${i}")
        }
        let page = mountPackages(state)
        page.select("ystyle", "many")

        // 倒序：全量第一个是最新版本
        @Expect(page.verAll.get().size, 12)
        @Expect(page.verAll.get()[0].version, "1.0.11")
        @Expect(page.verAll.get()[11].version, "1.0.0")
        // 分页：第一页 10 条，总数 12
        @Expect(page.verRows.get().size, 10)
        @Expect(page.verRows.get()[0].version, "1.0.11")
        @Expect(page.verTotal.get(), 12)

        let json = renderPackages(page)
        @Expect(json.contains("共 12 条"), true)          // 抽屉里的分页器
        @Expect(json.contains("1.0.11"), true)
        @Expect(json.contains("1.0.0"), false)            // 第二页的版本不在第一页里
        @Expect(json.contains("\"ID\""), false)          // ID 列已去掉
        // 操作列是个「操作」下拉（菜单项挂在 DOM 上、面板默认收起）
        @Expect(json.contains("操作"), true)
        @Expect(json.contains("el-dropdown"), true)
    }

    // 版本行「操作」是下拉菜单（cjxt Dropdown）：菜单项随版本状态变化，面板默认收起
    @TestCase
    public func testVersionActionsUseDropdownMenu(): Unit {
        let state = makePortalState("team")
        seedPkg(state, "ystyle", "crc", "1.0.0")
        let page = mountPackages(state)
        page.select("ystyle", "crc")
        let json = renderPackages(page)
        @Expect(json.contains("el-dropdown"), true)
        @Expect(json.contains("详情"), true)
        @Expect(json.contains("软删除"), true)          // 未删除的版本：详情 / 软删除
        @Expect(json.contains("重拉"), false)            // 本地发布的不给「重拉」
        @Expect(json.contains("恢复"), false)

        // 软删过的版本：给恢复 / 硬删除，且菜单收起时也挂在 DOM 上（Dropdown 面板靠 display 切换）
        for (d in state.pkgStore.listVersions("ystyle", "crc")) {
            d.deletedAt = 1
            state.pkgStore.save(d)
        }
        page.select("ystyle", "crc")
        let json2 = renderPackages(page)
        @Expect(json2.contains("恢复"), true)
        @Expect(json2.contains("硬删除"), true)
        @Expect(json2.contains("软删除"), false)
    }

    // 回源镜像版本才出现「重拉」
    @TestCase
    public func testMirroredVersionOffersRefetch(): Unit {
        let state = makePortalState("team")
        seedPkg(state, "ystyle", "crc", "1.0.0")
        for (d in state.pkgStore.listVersions("ystyle", "crc")) {
            d.upstreamId = 7
            state.pkgStore.save(d)
        }
        let page = mountPackages(state)
        page.select("ystyle", "crc")
        @Expect(renderPackages(page).contains("重拉"), true)
    }

    // 翻到第二页：只剩最后两条（新→旧序的尾部）
    @TestCase
    public func testVersionPagerShowsSecondPage(): Unit {
        let state = makePortalState("team")
        for (i in 0..12) {
            seedPkg(state, "ystyle", "many", "1.0.${i}")
        }
        let page = mountPackages(state)
        page.select("ystyle", "many")
        page.verPage.set(2)
        @Expect(page.verRows.get().size, 2)
        @Expect(page.verRows.get()[0].version, "1.0.1")
        @Expect(page.verRows.get()[1].version, "1.0.0")
    }

    // 换包时页码必须回到第一页（否则会停在上一包的第 N 页，看起来像"版本丢了"）
    @TestCase
    public func testSwitchingPackageResetsVersionPage(): Unit {
        let state = makePortalState("team")
        for (i in 0..12) {
            seedPkg(state, "ystyle", "many", "1.0.${i}")
        }
        seedPkg(state, "acme", "few", "2.0.0")
        let page = mountPackages(state)
        page.select("ystyle", "many")
        page.verPage.set(2)
        @Expect(page.verRows.get().size, 2)

        page.select("acme", "few")
        @Expect(page.verPage.get(), 1)
        @Expect(page.verRows.get().size, 1)
        @Expect(page.verRows.get()[0].version, "2.0.0")
    }

    // 主表「包」列收窄 + 新增「描述」列：包名不该把整行留白吃掉
    @TestCase
    public func testMasterColumnsAreCompact(): Unit {
        let state = makePortalState("team")
        seedPkg(state, "ystyle", "crc", "1.0.0", desc: "CRC 校验库")
        let json = renderPackages(mountPackages(state))
        @Expect(json.contains("描述"), true)
        @Expect(json.contains("CRC 校验库"), true)
    }

    // 绑定输入框不得再挂 input 动作：动作会在输入那一刻换来一次补丁，补丁应用完会清掉
    // 客户端的 bindDirty 守卫并把输入框退回旧值，300ms 后的 bind 就把空串写回信号
    // ——"打字完全没反应"就是这么来的（见 list_binding.cj 头部说明）。
    // 这条守住结构：整页不应存在 input 事件的动作绑定。
    @TestCase
    public func testSearchInputCarriesNoInputAction(): Unit {
        let state = makePortalState("team")
        seedPkg(state, "ystyle", "crc", "1.0.0")
        let json = renderExpanded(mountPackages(state).render())
        @Expect(json.contains("\"input\":"), false)
        @Expect(json.contains("data-bind-id"), true)
    }

    // 正向对照：真挂了 input 动作时序列化里就会出现 "input": —— 上面那条断言因此有牙
    @TestCase
    public func testInputActionWouldShowUpInJson(): Unit {
        let handler: ActionHandler = { _ => PatchResult.ReRender }
        let node = Input().bind(Signal<String>("")).on("input", handler)
        let json = renderExpanded(node)
        @Expect(json.contains("\"input\":"), true)
    }

    // 组织下拉过滤同样即时生效（Select 只 bind + 复位页码）
    @TestCase
    public func testOrgFilterAppliesImmediately(): Unit {
        let state = makePortalState("team")
        seedPkg(state, "ystyle", "crc", "1.0.0")
        seedPkg(state, "acme", "demo", "1.0.0")

        let page = mountPackages(state)
        page.orgFilter.set("acme")
        let json = renderPackages(page)
        @Expect(json.contains("acme::demo"), true)
        @Expect(json.contains("ystyle::crc"), false)
    }
}
