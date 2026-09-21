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

    // 主子表：未选中给提示；选中后右栏出现该包的版本与操作按钮
    @TestCase
    public func testMasterDetailShowsVersionsOfSelectedPackage(): Unit {
        let state = makePortalState("team")
        seedPkg(state, "ystyle", "crc", "1.0.0")
        seedPkg(state, "ystyle", "crc", "1.0.1")
        seedPkg(state, "acme", "demo", "9.9.9")

        let page = mountPackages(state)
        @Expect(renderPackages(page).contains("左侧选一个包"), true)

        page.select("ystyle", "crc")
        let json = renderPackages(page)
        @Expect(json.contains("ystyle::crc 的版本（2）"), true)
        @Expect(json.contains("1.0.1"), true)
        @Expect(json.contains("软删除"), true)      // 子表操作列在位
        // 子表数据只含选中包的版本（直接断信号：主表那行 acme::demo 仍会显示它的最新版本）
        @Expect(page.verRows.get().size, 2)
        @Expect(page.verRows.get()[0].organization, "ystyle")
        @Expect(page.verRows.get()[0].name, "crc")
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
