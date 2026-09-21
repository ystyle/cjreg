// 包管理页渲染：搜索"输入即生效" + 左主（包）右子（版本）主子表。
//
// 这条正是本次修的缺陷：旧实现把过滤结果缓存进 rows、render 又不读过滤信号，
// 于是输入关键字后表格永不重算（只有再点「刷新」才生效）。
// 这里只 set 搜索信号，不触发任何动作，断言表格已经跟着变。
package ystyle::cjreg.ui

import cjxt.*
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
