// 认证服务单元测试
package ystyle::cjreg.auth

import ystyle::cjreg.auth.model.*
import ystyle::cjreg.auth.util.*
import std.unittest.testmacro.*

func makeService(): AuthService {
    let store = MemoryUserStore()
    AuthService(store, 3600)  // session TTL 1 小时
}

@Test
func testInitAdmin() {
    PasswordHash.ITERATIONS = 1000  // 测试提速
    let svc = makeService()
    // 空库创建首个管理员
    let admin = svc.initAdmin("admin", "AdminPass1")
    match (admin) {
        case Some(u) =>
            @Expect(u.username, "admin")
            @Expect(u.isAdmin, true)
            @Expect(u.isActive, true)
            @Expect(u.publishToken.startsWith("publish-"), true)
        case None => @Fail("initAdmin should succeed on empty store")
    }
    // 已初始化 → 拒绝
    @Expect(svc.initAdmin("admin2", "Pass123").isNone(), true)
    // 空用户名/密码 → 拒绝
    let svc2 = makeService()
    @Expect(svc2.initAdmin("", "pass").isNone(), true)
    @Expect(svc2.initAdmin("user", "").isNone(), true)
}

@Test
func testLoginSuccess() {
    PasswordHash.ITERATIONS = 1000  // 测试提速
    let svc = makeService()
    let admin = svc.initAdmin("admin", "AdminPass1")
    @Expect(admin.isSome(), true)

    let result = svc.login("admin", "AdminPass1")
    match (result) {
        case Some((user, token)) =>
            @Expect(user.username, "admin")
            @Expect(token.kind, "session")
            @Expect(token.token.startsWith("sess-"), true)
            @Expect(token.userId, user.id)
            @Expect(token.isValid(), true)
        case None => @Fail("login should succeed with correct password")
    }
}

@Test
func testLoginFailures() {
    PasswordHash.ITERATIONS = 1000  // 测试提速
    let svc = makeService()
    svc.initAdmin("admin", "AdminPass1")
    // 密码错误
    @Expect(svc.login("admin", "WrongPass").isNone(), true)
    // 用户不存在
    @Expect(svc.login("nobody", "AdminPass1").isNone(), true)
    // 空参数
    @Expect(svc.login("", "").isNone(), true)
}

@Test
func testValidateSessionToken() {
    PasswordHash.ITERATIONS = 1000  // 测试提速
    let svc = makeService()
    svc.initAdmin("admin", "AdminPass1")
    let (_, token) = svc.login("admin", "AdminPass1").getOrThrow()

    // 有效 token
    let u = svc.validateSessionToken(token.token)
    @Expect(u.isSome(), true)
    match (u) {
        case Some(user) => @Expect(user.username, "admin")
        case None => ()
    }
    // 乱写的 token
    @Expect(svc.validateSessionToken("sess-fake").isNone(), true)
    // 发布 token 不能当 session 用
    @Expect(svc.validateSessionToken("publish-abc").isNone(), true)
}

@Test
func testLogoutInvalidatesToken() {
    PasswordHash.ITERATIONS = 1000  // 测试提速
    let svc = makeService()
    svc.initAdmin("admin", "AdminPass1")
    let (_, token) = svc.login("admin", "AdminPass1").getOrThrow()
    @Expect(svc.validateSessionToken(token.token).isSome(), true)
    svc.logout(token.token)
    @Expect(svc.validateSessionToken(token.token).isNone(), true)
}

@Test
func testExpiredToken() {
    PasswordHash.ITERATIONS = 1000  // 测试提速
    let store = MemoryUserStore()
    let svc = AuthService(store, -10)  // TTL 已过期
    svc.initAdmin("admin", "AdminPass1")
    let (_, token) = svc.login("admin", "AdminPass1").getOrThrow()
    @Expect(token.isValid(), false)
    @Expect(svc.validateSessionToken(token.token).isNone(), true)
}

@Test
func testPublishToken() {
    PasswordHash.ITERATIONS = 1000  // 测试提速
    let svc = makeService()
    let admin = svc.initAdmin("admin", "AdminPass1").getOrThrow()

    // 用户的发布 token 可发布
    let u = svc.validatePublishToken(admin.publishToken)
    @Expect(u.isSome(), true)
    match (u) {
        case Some(user) => @Expect(user.username, "admin")
        case None => ()
    }
    // 错误 token 拒绝
    @Expect(svc.validatePublishToken("publish-fake").isNone(), true)
    // session token 不能发布
    let (_, sess) = svc.login("admin", "AdminPass1").getOrThrow()
    @Expect(svc.validatePublishToken(sess.token).isNone(), true)
}

@Test
func testUserLifecycle() {
    PasswordHash.ITERATIONS = 1000  // 测试提速
    let svc = makeService()
    svc.initAdmin("admin", "AdminPass1")

    // 创建普通用户
    let user = svc.createUser("alice", "AlicePass1", false)
    match (user) {
        case Some(u) =>
            @Expect(u.isAdmin, false)
            @Expect(u.isActive, true)
        case None => @Fail("createUser should succeed")
    }
    // 重名拒绝
    @Expect(svc.createUser("alice", "x", false).isNone(), true)

    // 普通用户登录
    let r = svc.login("alice", "AlicePass1")
    @Expect(r.isSome(), true)
    match (r) {
        case Some((u, t)) =>
            @Expect(u.username, "alice")
            @Expect(t.kind, "session")
        case None => ()
    }

    // 修改密码后旧密码失效
    let aliceId = user.getOrThrow().id
    @Expect(svc.changePassword(aliceId, "NewPass99"), true)
    @Expect(svc.login("alice", "AlicePass1").isNone(), true)
    @Expect(svc.login("alice", "NewPass99").isSome(), true)

    // 重置发布 token
    let oldToken = user.getOrThrow().publishToken
    let newToken = svc.resetPublishToken(aliceId)
    match (newToken) {
        case Some(t) =>
            @Expect(t.startsWith("publish-"), true)
            @Expect(t != oldToken, true)
        case None => @Fail("resetPublishToken should succeed")
    }
}
