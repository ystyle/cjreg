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

@Test
func testCreateUserWithEmailAndAdmin() {
    PasswordHash.ITERATIONS = 1000  // 测试提速
    let svc = makeService()
    let _ = svc.initAdmin("admin", "AdminPass1")
    // 带邮箱创建普通用户
    let u = svc.createUser("alice", "AlicePass1", false, email: "alice@example.com")
    match (u) {
        case Some(x) =>
            @Expect(x.username, "alice")
            @Expect(x.email, "alice@example.com")
            @Expect(x.isAdmin, false)
            @Expect(x.isActive, true)
            @Expect(x.publishToken.startsWith("publish-"), true)
        case None => @Fail("createUser should succeed")
    }
    // 创建管理员
    let admin = svc.createUser("bob", "BobPass1", true)
    match (admin) {
        case Some(x) => @Expect(x.isAdmin, true)
        case None => @Fail("createUser admin should succeed")
    }
}

@Test
func testSetUserActiveAndDelete() {
    PasswordHash.ITERATIONS = 1000  // 测试提速
    let svc = makeService()
    let _ = svc.initAdmin("admin", "AdminPass1")
    let alice = svc.createUser("alice", "AlicePass1", false).getOrThrow()
    let aliceId = alice.id

    // 禁用 → 登录失败
    @Expect(svc.setUserActive(aliceId, false), true)
    @Expect(svc.login("alice", "AlicePass1").isNone(), true)
    @Expect(svc.setUserActive(aliceId, true), true)
    @Expect(svc.login("alice", "AlicePass1").isSome(), true)

    // 删除普通用户
    @Expect(svc.deleteUser(aliceId), true)
    @Expect(svc.store.getUserByUsername("alice").isNone(), true)

    // 管理员受保护（不可删除）
    let admin = svc.store.getUserByUsername("admin").getOrThrow()
    @Expect(svc.deleteUser(admin.id), false)

    // 不存在的用户
    @Expect(svc.deleteUser(999), false)
    @Expect(svc.setUserActive(999, false), false)
}

// ===== 多管理员：提升/降级 + 「最后一个启用管理员」保护 =====

@Test
func testSetUserAdminPromoteAndDemote() {
    PasswordHash.ITERATIONS = 1000  // 测试提速
    let svc = makeService()
    let _ = svc.initAdmin("admin", "AdminPass1")
    let alice = svc.createUser("alice", "AlicePass1", false).getOrThrow()

    // 提升普通用户为管理员
    @Expect(svc.setUserAdmin(alice.id, true), true)
    @Expect(svc.store.getUser(alice.id).getOrThrow().isAdmin, true)
    @Expect(svc.countActiveAdmins(), 2)
    // 提升后可用管理员入口登录
    @Expect(svc.login("alice", "AlicePass1").isSome(), true)

    // 幂等：目标状态与当前一致 → true 且无副作用
    @Expect(svc.setUserAdmin(alice.id, true), true)
    @Expect(svc.countActiveAdmins(), 2)

    // 存在第二个启用管理员时可降级
    @Expect(svc.setUserAdmin(alice.id, false), true)
    @Expect(svc.store.getUser(alice.id).getOrThrow().isAdmin, false)
    @Expect(svc.countActiveAdmins(), 1)

    // 不存在的用户
    @Expect(svc.setUserAdmin(999, true), false)
    @Expect(svc.setUserAdmin(999, false), false)
}

@Test
func testLastActiveAdminProtection() {
    PasswordHash.ITERATIONS = 1000  // 测试提速
    let svc = makeService()
    let admin = svc.initAdmin("admin", "AdminPass1").getOrThrow()
    @Expect(svc.countActiveAdmins(), 1)
    @Expect(svc.isLastActiveAdmin(admin.id), true)

    // 唯一启用管理员：既不可降级也不可禁用，状态保持不变
    @Expect(svc.setUserAdmin(admin.id, false), false)
    @Expect(svc.setUserActive(admin.id, false), false)
    let after = svc.store.getUser(admin.id).getOrThrow()
    @Expect(after.isAdmin, true)
    @Expect(after.isActive, true)
    // 管理端仍可登录（未锁死）
    @Expect(svc.login("admin", "AdminPass1").isSome(), true)

    // 出现第二个启用管理员 → 保护解除
    let alice = svc.createUser("alice", "AlicePass1", true).getOrThrow()
    @Expect(svc.countActiveAdmins(), 2)
    @Expect(svc.isLastActiveAdmin(admin.id), false)
    @Expect(svc.setUserAdmin(alice.id, false), true)
    @Expect(svc.setUserAdmin(alice.id, true), true)

    // 已禁用的管理员不占用「启用管理员」名额
    @Expect(svc.setUserActive(alice.id, false), true)
    @Expect(svc.countActiveAdmins(), 1)
    @Expect(svc.isLastActiveAdmin(alice.id), false)
    @Expect(svc.setUserAdmin(alice.id, false), true)
    // 仍然只剩一个启用管理员 → 继续受保护
    @Expect(svc.setUserActive(admin.id, false), false)
    @Expect(svc.setUserAdmin(admin.id, false), false)

    // 非管理员不受该约束
    let bob = svc.createUser("bob", "BobPass1", false).getOrThrow()
    @Expect(svc.setUserActive(bob.id, false), true)
    @Expect(svc.setUserActive(bob.id, true), true)
}

@Test
func testRecoverAdmin() {
    PasswordHash.ITERATIONS = 1000  // 测试提速
    let svc = makeService()
    let _ = svc.initAdmin("admin", "AdminPass1")
    let alice = svc.createUser("alice", "AlicePass1", false).getOrThrow()

    // 参数缺失 / 用户不存在 → 拒绝（应急恢复不创建新用户）
    @Expect(svc.recoverAdmin("", "Pass123").isNone(), true)
    @Expect(svc.recoverAdmin("alice", "").isNone(), true)
    @Expect(svc.recoverAdmin("nobody", "Pass123").isNone(), true)

    // 普通用户 → 重置口令 + 强制启用管理员
    match (svc.recoverAdmin("alice", "RescuePass1")) {
        case Some(u) =>
            @Expect(u.username, "alice")
            @Expect(u.isAdmin, true)
            @Expect(u.isActive, true)
        case None => @Fail("recoverAdmin should succeed for existing user")
    }
    @Expect(svc.login("alice", "RescuePass1").isSome(), true)
    @Expect(svc.login("alice", "AlicePass1").isNone(), true)

    // 模拟锁死现场：两个启用管理员时禁用 + 降级 alice；应急恢复应同时修回身份与启用状态
    @Expect(svc.setUserActive(alice.id, false), true)
    @Expect(svc.setUserAdmin(alice.id, false), true)
    let locked = svc.store.getUser(alice.id).getOrThrow()
    @Expect(locked.isAdmin, false)
    @Expect(locked.isActive, false)
    @Expect(svc.recoverAdmin("alice", "RescuePass2").isSome(), true)
    let rescued = svc.store.getUser(alice.id).getOrThrow()
    @Expect(rescued.isAdmin, true)
    @Expect(rescued.isActive, true)
    @Expect(svc.login("alice", "RescuePass2").isSome(), true)
}

