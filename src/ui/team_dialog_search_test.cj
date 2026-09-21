// 团队「包关联 / 成员关联」弹窗：搜索"输入即过滤"（渲染层回归）
//
// 与前两类同一根因：过滤结果被缓存在弹窗的 rows 信号里，而输入框的 action 先于 bind 触发
// （cjxt public/js/cangjie-ui.js:333 vs :490），于是输入关键字时表格永不重算。
// 现在过滤是信号派生：只 set 关键字，不调任何 refresh，表格就必须跟着变。
//
// 顺带守住"数据变更仍能反映"：editingId / store 都不是信号，换团队、关联、移除之后
// 由 pkgVersion / memberVersion 版本号触发重算（这类改动不能因为改成派生就丢掉）。
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
    // 包搜索：只 set 关键字，关联表立刻只剩命中的包
    @TestCase
    public func testPkgSearchFiltersImmediately(): Unit {
        let state = makePortalState("team")
        let teamId = state.adminData.createTeam("core", 1000)
        seedPkg(state, "ystyle", "alpha", "1.0.0")
        seedPkg(state, "ystyle", "beta", "1.0.0")

        let page = mountTeams(state)
        openTeamPackages(page, teamId)
        @Expect(page.pkgRows.get().size, 2)

        page.pkgSearch.set("alpha")
        @Expect(page.pkgRows.get().size, 1)
        @Expect(page.pkgRows.get()[0].doc.name, "alpha")

        page.pkgSearch.set("")
        @Expect(page.pkgRows.get().size, 2)
    }

    // 关联/移除后标记要跟着变（这不是"输入即过滤"，但同样走派生，别改丢了）
    @TestCase
    public func testPkgLinkStateRefreshesOnToggle(): Unit {
        let state = makePortalState("team")
        let teamId = state.adminData.createTeam("core", 1000)
        seedPkg(state, "ystyle", "alpha", "1.0.0")
        let page = mountTeams(state)
        openTeamPackages(page, teamId)
        @Expect(page.pkgRows.get()[0].linked, false)

        state.adminData.setTeamPackages(teamId, [("ystyle", "alpha")], 1000)
        page.refreshPkgs()
        @Expect(page.pkgRows.get()[0].linked, true)
    }

    // 换团队：editingId 变了，派生必须按新团队的关联状态重算
    @TestCase
    public func testSwitchingTeamRefreshesLinkState(): Unit {
        let state = makePortalState("team")
        let t1 = state.adminData.createTeam("t1", 1000)
        let t2 = state.adminData.createTeam("t2", 1000)
        seedPkg(state, "ystyle", "alpha", "1.0.0")
        state.adminData.setTeamPackages(t1, [("ystyle", "alpha")], 1000)

        let page = mountTeams(state)
        openTeamPackages(page, t1)
        @Expect(page.pkgRows.get()[0].linked, true)
        openTeamPackages(page, t2)
        @Expect(page.pkgRows.get()[0].linked, false)
    }

    // 成员搜索：用户名过滤同样即时生效
    @TestCase
    public func testMemberSearchFiltersImmediately(): Unit {
        let state = makePortalState("team")
        let teamId = state.adminData.createTeam("core", 1000)
        let _ = state.auth.createUser("alice", "AlicePass1", false, email: "a@example.com")
        let _ = state.auth.createUser("bob", "BobPass1", false, email: "b@example.com")

        let page = mountTeams(state)
        openTeamMembers(page, teamId)
        @Expect(page.memberRows.get().size, 2)

        page.memberSearch.set("bob")
        @Expect(page.memberRows.get().size, 1)
        @Expect(page.memberRows.get()[0].user.username, "bob")

        // 首尾空白不参与匹配（trimAscii）
        page.memberSearch.set("  alice ")
        @Expect(page.memberRows.get().size, 1)
        @Expect(page.memberRows.get()[0].user.username, "alice")
    }

    // 成员关联状态变更后同样要刷新
    @TestCase
    public func testMemberLinkStateRefreshesOnToggle(): Unit {
        let state = makePortalState("team")
        let teamId = state.adminData.createTeam("core", 1000)
        let uid = state.auth.createUser("alice", "AlicePass1", false, email: "a@example.com").getOrThrow().id
        let page = mountTeams(state)
        openTeamMembers(page, teamId)
        @Expect(page.memberRows.get()[0].linked, false)

        state.adminData.setTeamMembers(teamId, [uid])
        page.refreshMembers()
        @Expect(page.memberRows.get()[0].linked, true)
    }
}
