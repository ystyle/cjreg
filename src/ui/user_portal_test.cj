// 用户门户页面渲染单元测试（/me 三区块 + 登录页）
//
// 用 cjxt serializeSubtree 直接渲染组件树并断言 JSON 内容——不起 HTTP 服务、不依赖浏览器。
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

func makePortalState(mode: String, publicUrl!: String = "http://localhost:8060", port!: UInt16 = 8060): CjregState {
    let cfg = CjregConfig()
    cfg.publicUrl = publicUrl
    cfg.port = port
    cfg.permissionMode = mode
    PasswordHash.ITERATIONS = 1000  // 测试提速
    let storm = Storm.inMemory()
    let pkgStore = PackageStore(storm)
    let userStore = BstormUserStore(storm)
    let upStore = BstormUpstreamStore(storm)
    let authSvc = AuthService(userStore, 3600)
    let adminData = AdminDataStore(storm)
    CjregState(pkgStore, userStore, upStore, adminData, authSvc, config: cfg)
}

// 组装页面挂载所需的 LifecycleContext（states + 会话上下文）
func mountCtx(state: CjregState, ctxMap: HashMap<String, String>): LifecycleContext {
    let states = HashMap<String, AppState>()
    states.add(TypeInfo.of<CjregState>().qualifiedName, state)
    let sctx: SessionContext = SessionContextState(ctxMap)
    LifecycleContext("sid-test", HashMap<String, String>(), None, None, states: states, sessionContext: Some(sctx))
}

func userCtxMap(uid: Int64, username: String, isAdmin: Bool): HashMap<String, String> {
    let m = HashMap<String, String>()
    m["uid"] = uid.toString()
    m["username"] = username
    m["isAdmin"] = if (isAdmin) { "1" } else { "0" }
    m["token"] = "sess-test"
    m
}

@Test
public class UserPortalRenderTest {
    // /me 三个区块齐全，且数据来自读模型（我的包 / 团队 / 完整 Token）
    @TestCase
    public func testPortalRendersThreeSections(): Unit {
        let state = makePortalState("team")
        let alice = state.auth.createUser("alice", "AlicePass1", false).getOrThrow()
        // 我拥有的包
        let d = PackageDoc()
        d.organization = "test"
        d.name = "demo"
        d.version = "1.0.0"
        d.publisherId = alice.id
        d.createdAt = 1000
        d.updatedAt = 2000
        state.pkgStore.save(d)
        // 我所属团队（write + 组织/包关联）
        let orgId = state.adminData.createOrg("test", "Test", 1, 0)
        let teamId = state.adminData.createTeam("writers", 0, displayName: "写手组", permission: "write")
        state.adminData.setTeamOrganizations(teamId, [orgId], 0)
        let pairs = ArrayList<(String, String)>()
        pairs.add(("test", "demo"))
        state.adminData.setTeamPackages(teamId, pairs.toArray(), 0)
        state.adminData.setTeamMembers(teamId, [alice.id])

        let page = UserPortalPage()
        page.onMount(mountCtx(state, userCtxMap(alice.id, "alice", false)))
        let json = serializeSubtree(page.render(), HashMap<String, ActionHandler>())

        @Expect(json.contains("我的发布 Token"), true)
        @Expect(json.contains("我的包"), true)
        @Expect(json.contains("我的团队与权限"), true)
        @Expect(json.contains("test::demo"), true)
        @Expect(json.contains("所有者"), true)
        @Expect(json.contains("写手组"), true)
        @Expect(json.contains("团队模式"), true)
        // 门户展示完整 Token（否则用户无法配置 cjpm）
        @Expect(json.contains(alice.publishToken), true)
        @Expect(json.contains("当前登录：alice"), true)
        // registry 示例用配置的对外地址（cjreg.toml server.public_url）
        @Expect(json.contains("http://localhost:8060"), true)
        @Expect(json.contains("http://<cjreg 地址>"), false)
    }

    // 配置了域名时，门户示例显示域名（而不是 localhost 兜底）
    @TestCase
    public func testPortalExampleUsesConfiguredPublicUrl(): Unit {
        let state = makePortalState("team", publicUrl: "https://pkg.example.com", port: 8064)
        let alice = state.auth.createUser("alice", "AlicePass1", false).getOrThrow()
        let page = UserPortalPage()
        page.onMount(mountCtx(state, userCtxMap(alice.id, "alice", false)))
        let json = serializeSubtree(page.render(), HashMap<String, ActionHandler>())
        @Expect(json.contains("https://pkg.example.com"), true)
        @Expect(json.contains("http://localhost:8060"), false)
    }

    // 没有包/团队时给空态引导，而不是空白区块
    @TestCase
    public func testPortalEmptyStates(): Unit {
        let state = makePortalState("open")
        let bob = state.auth.createUser("bob", "BobPass1", false).getOrThrow()
        let page = UserPortalPage()
        page.onMount(mountCtx(state, userCtxMap(bob.id, "bob", false)))
        let json = serializeSubtree(page.render(), HashMap<String, ActionHandler>())
        @Expect(json.contains("还没有发布过包"), true)
        @Expect(json.contains("暂未加入任何团队"), true)
        @Expect(json.contains("开放模式"), true)
    }

    // 会话换人后就地重渲（不重跑 onMount）也能纠正列表数据
    @TestCase
    public func testPortalReloadsWhenSessionUserChanges(): Unit {
        let state = makePortalState("team")
        let alice = state.auth.createUser("alice", "AlicePass1", false).getOrThrow()
        let bob = state.auth.createUser("bob", "BobPass1", false).getOrThrow()
        let d = PackageDoc()
        d.organization = "test"
        d.name = "demo"
        d.version = "1.0.0"
        d.publisherId = alice.id
        state.pkgStore.save(d)

        let ctxMap = userCtxMap(alice.id, "alice", false)
        let page = UserPortalPage()
        page.onMount(mountCtx(state, ctxMap))
        @Expect(serializeSubtree(page.render(), HashMap<String, ActionHandler>()).contains("test::demo"), true)
        // 同一会话换成 bob（上下文变化 → 就地重渲）：bob 没发过包
        ctxMap["uid"] = bob.id.toString()
        ctxMap["username"] = "bob"
        let json = serializeSubtree(page.render(), HashMap<String, ActionHandler>())
        @Expect(json.contains("test::demo"), false)
        @Expect(json.contains("还没有发布过包"), true)
        @Expect(json.contains("当前登录：bob"), true)
    }

    // 登录页：用户门户入口（提示普通用户与管理员均可登录）
    @TestCase
    public func testUserLoginPageRenders(): Unit {
        let state = makePortalState("open")
        let page = UserLoginPage()
        page.onMount(mountCtx(state, HashMap<String, String>()))
        let json = serializeSubtree(page.render(), HashMap<String, ActionHandler>())
        @Expect(json.contains("cjreg 用户门户"), true)
        @Expect(json.contains("用户名"), true)
        @Expect(json.contains("密码"), true)
        @Expect(json.contains("管理员登录入口"), true)
    }
}
