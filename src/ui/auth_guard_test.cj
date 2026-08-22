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
}
