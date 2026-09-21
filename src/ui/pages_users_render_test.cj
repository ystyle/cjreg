// 用户管理页渲染：新增的搜索框「输入即生效」（用户名 / 邮箱）。
//
// 与包管理同一根因同一修法：行数据由 Effect 从「数据版本 + 关键字 + 分页」信号派生，
// 所以只 set 搜索信号、不触发任何动作，表格就该跟着变。
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

func mountUsers(state: CjregState): UsersPage {
    let page = UsersPage()
    page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
    page
}

func renderUsers(page: UsersPage): String {
    serializeSubtree(page.render(), HashMap<String, ActionHandler>())
}

@Test
public class UsersPageRenderTest {
    @TestCase
    public func testSearchFiltersByUsernameAndEmail(): Unit {
        let state = makePortalState("team")
        let _ = state.auth.createUser("alice", "AlicePass1", false, email: "alice@example.com").getOrThrow()
        let _ = state.auth.createUser("bob", "BobPass123", true, email: "builder@corp.cn").getOrThrow()

        let page = mountUsers(state)
        let all = renderUsers(page)
        @Expect(all.contains("alice"), true)
        @Expect(all.contains("bob"), true)

        // 按用户名搜（输入即生效）
        page.userSearch.set("ali")
        let byName = renderUsers(page)
        @Expect(byName.contains("alice"), true)
        @Expect(byName.contains("bob"), false)

        // 按邮箱搜（大小写不敏感）
        page.userSearch.set("CORP.CN")
        let byMail = renderUsers(page)
        @Expect(byMail.contains("bob"), true)
        @Expect(byMail.contains("alice"), false)

        // 无命中给明确空态
        page.userSearch.set("zzz-nothing")
        @Expect(renderUsers(page).contains("没有匹配的用户"), true)
    }

    // 没有关键字时保持原空态文案（避免"没有匹配的用户"误导）
    // 同包管理页：搜索输入框只 bind，不许再挂 input 动作（否则打字等于没反应）
    @TestCase
    public func testSearchInputCarriesNoInputAction(): Unit {
        let state = makePortalState("team")
        let _ = state.auth.createUser("alice", "AlicePass1", false, email: "alice@example.com").getOrThrow()
        let json = renderExpanded(mountUsers(state).render())
        @Expect(json.contains("\"input\":"), false)
        @Expect(json.contains("data-bind-id"), true)
    }

    @TestCase
    public func testEmptyStateTextDependsOnKeyword(): Unit {
        let state = makePortalState("team")
        let page = mountUsers(state)
        @Expect(renderUsers(page).contains("暂无用户"), true)
    }
}
