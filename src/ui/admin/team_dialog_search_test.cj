// 团队「包关联 / 成员关联」弹窗：搜索"输入即过滤"（渲染层回归）
//
// 与前两类同一根因：过滤结果被缓存在弹窗的 rows 信号里，而输入框的 action 先于 bind 触发
// （cjxt public/js/cangjie-ui.js:333 vs :490），于是输入关键字时表格永不重算。
// 现在过滤是信号派生：只 set 关键字，不调任何 refresh，表格就必须跟着变。
//
// 顺带守住"数据变更仍能反映"：editingId / store 都不是信号，换团队、关联、移除之后
// 由 pkgVersion / memberVersion 版本号触发重算（这类改动不能因为改成派生就丢掉）。
package ystyle::cjreg.ui.admin

import ystyle::cjreg.ui.*

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

func mountTeams(state: CjregState): TeamsPage {
    let page = TeamsPage()
    page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
    page
}

// 打开弹窗那一步做的事：换 editingId + 让派生重算（openPackages 里也是这两步）
func openTeamPackages(page: TeamsPage, teamId: Int64): Unit {
    page.editingId = teamId
    page.refreshPkgs()
}

func openTeamMembers(page: TeamsPage, teamId: Int64): Unit {
    page.editingId = teamId
    page.refreshMembers()
}

@Test
public class TeamDialogSearchTest {
    // 包：表格只列已关联，候选只列未关联（同包多版本只一个候选）
    @TestCase
    public func testPkgRowsListOnlyLinked(): Unit {
        let state = makePortalState("team")
        let teamId = state.adminData.createTeam("core", 1000)
        seedPkg(state, "ystyle", "alpha", "1.0.0")
        seedPkg(state, "ystyle", "alpha", "1.1.0")
        seedPkg(state, "ystyle", "beta", "1.0.0")

        let page = mountTeams(state)
        openTeamPackages(page, teamId)
        @Expect(page.pkgRows.get().size, 0)
        @Expect(page.pkgOptions().size, 2)

        state.adminData.setTeamPackages(teamId, [("ystyle", "alpha")], 1000)
        page.refreshPkgs()
        @Expect(page.pkgRows.get().size, 1)
        @Expect(page.pkgRows.get()[0].name, "alpha")
        let opts = page.pkgOptions()
        @Expect(opts.size, 1)
        @Expect(opts[0], "ystyle::beta")
    }

    // 成员：表格只列已加入成员，候选只列非成员（下拉 + 添加语义）
    @TestCase
    public func testMemberRowsListOnlyLinked(): Unit {
        let state = makePortalState("team")
        let teamId = state.adminData.createTeam("core", 1000)
        let uid = state.auth.createUser("alice", "AlicePass1", false, email: "a@example.com").getOrThrow().id
        let _ = state.auth.createUser("bob", "BobPass1", false, email: "b@example.com")

        let page = mountTeams(state)
        openTeamMembers(page, teamId)
        @Expect(page.memberRows.get().size, 0)

        state.adminData.setTeamMembers(teamId, [uid])
        page.refreshMembers()
        @Expect(page.memberRows.get().size, 1)
        @Expect(page.memberRows.get()[0].username, "alice")
        let opts = page.memberOptions()
        @Expect(opts.size, 1)
        @Expect(opts[0], "bob")
    }
}
