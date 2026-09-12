// 公开导航登录态单元测试（cjreg Q2「登录后才显示管理入口」）
//
// 入口由会话上下文（cjxt SessionContext 接口）在渲染期决定：
// 未登录 → 「登录」（/user/login）；已登录 → 「我的」（/me）；管理员额外 → 「管理后台」（/admin）。
package ystyle::cjreg.ui

import cjxt.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class PublicNavEntryTest {
    @TestCase
    public func testAnonymousShowsLoginNotAdmin(): Unit {
        let json = navJson(None)
        @Expect(json.contains("登录"), true)
        @Expect(json.contains("管理后台"), false)
    }

    @TestCase
    public func testNonAdminLoggedInShowsPortalNotAdmin(): Unit {
        // 普通用户（isAdmin != "1"）不得出现管理入口，但应看到「我的」（用户门户）
        let json = navJson(Some(contextOf([("uid", "7"), ("username", "alice"), ("isAdmin", "0")])))
        @Expect(json.contains("管理后台"), false)
        @Expect(json.contains("我的"), true)
        @Expect(json.contains("登录"), false)
    }

    @TestCase
    public func testAdminSeesBothPortalAndAdmin(): Unit {
        // 管理员登录后：个人门户 + 管理后台都在
        let json = navJson(Some(contextOf([("uid", "1"), ("username", "admin"), ("isAdmin", "1")])))
        @Expect(json.contains("我的"), true)
        @Expect(json.contains("管理后台"), true)
    }

    @TestCase
    public func testAdminShowsAdminEntry(): Unit {
        let json = navJson(Some(contextOf([("uid", "1"), ("username", "admin"), ("isAdmin", "1")])))
        @Expect(json.contains("管理后台"), true)
        // 管理员不需要「登录」项
        @Expect(json.contains("登录"), false)
    }

    @TestCase
    public func testLogoutFallsBackToLoginEntry(): Unit {
        // 登出写空串（layout.logoutMenuItem 的写法）→ 回到「登录」入口
        let json = navJson(Some(contextOf([("isAdmin", "")])))
        @Expect(json.contains("管理后台"), false)
        @Expect(json.contains("登录"), true)
    }
}

func contextOf(pairs: Array<(String, String)>): SessionContext {
    let m = HashMap<String, String>()
    for ((k, v) in pairs) {
        m[k] = v
    }
    SessionContextState(m)
}

func navJson(sctx: Option<SessionContext>): String {
    serializeSubtree(publicNav("/", sctx), HashMap<String, ActionHandler>())
}
