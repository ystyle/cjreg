// 管理界面鉴权守卫单元测试
package ystyle::cjreg.ui

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class AuthGuardTest {
    @TestCase
    public func testRequireAdminDeniedNoContext(): Unit {
        // 无任何会话上下文 → 拒绝并跳转登录页
        let ctx = HashMap<String, String>()
        match (requireAdmin(ctx)) {
            case Some(path) => @Expect(path, "/admin/login")
            case None => @Fail("expected deny with login path")
        }
    }

    @TestCase
    public func testRequireAdminDeniedNonAdmin(): Unit {
        let ctx = HashMap<String, String>()
        ctx["isAdmin"] = "0"
        match (requireAdmin(ctx)) {
            case Some(path) => @Expect(path, "/admin/login")
            case None => @Fail("expected deny with login path")
        }
    }

    @TestCase
    public func testRequireAdminPass(): Unit {
        let ctx = HashMap<String, String>()
        ctx["isAdmin"] = "1"
        @Expect(requireAdmin(ctx).isNone(), true)
    }

    @TestCase
    public func testRequireAdminIgnoresOtherKeys(): Unit {
        // 只有 isAdmin=1 才放行；伪造其他标记无效
        let ctx = HashMap<String, String>()
        ctx["uid"] = "1"
        ctx["authenticated"] = "1"
        match (requireAdmin(ctx)) {
            case Some(path) => @Expect(path, "/admin/login")
            case None => @Fail("expected deny")
        }
    }

    // ===== requireUser：登录即可（普通用户与管理员都放行）=====

    @TestCase
    public func testRequireUserDeniedWhenAnonymous(): Unit {
        let ctx = HashMap<String, String>()
        match (requireUser(ctx)) {
            case Some(path) => @Expect(path, "/user/login")
            case None => @Fail("expected deny with portal login path")
        }
    }

    @TestCase
    public func testRequireUserDeniedWhenLoggedOut(): Unit {
        // 登出写空串（clearSessionContext）→ 与未登录同语义
        let ctx = HashMap<String, String>()
        ctx["uid"] = ""
        ctx["isAdmin"] = ""
        match (requireUser(ctx)) {
            case Some(path) => @Expect(path, "/user/login")
            case None => @Fail("expected deny")
        }
    }

    @TestCase
    public func testRequireUserPassForNormalUser(): Unit {
        let ctx = HashMap<String, String>()
        ctx["uid"] = "7"
        ctx["username"] = "alice"
        ctx["isAdmin"] = "0"
        @Expect(requireUser(ctx).isNone(), true)
    }

    @TestCase
    public func testRequireUserPassForAdmin(): Unit {
        // 管理员同样可访问用户门户
        let ctx = HashMap<String, String>()
        ctx["uid"] = "1"
        ctx["isAdmin"] = "1"
        @Expect(requireUser(ctx).isNone(), true)
    }

    @TestCase
    public func testRequireAdminStillRejectsNormalUser(): Unit {
        // 两个守卫互不越权：普通用户能进门户、不能进管理端
        let ctx = HashMap<String, String>()
        ctx["uid"] = "7"
        ctx["isAdmin"] = "0"
        @Expect(requireUser(ctx).isNone(), true)
        @Expect(requireAdmin(ctx).isSome(), true)
    }
}
