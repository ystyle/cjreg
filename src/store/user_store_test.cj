// BstormUserStore 单元测试（持久化 + auth 集成）
package ystyle::cjreg.store

import bstorm.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*
import ystyle::cjreg.auth.util.*
import std.unittest.testmacro.*
import std.collection.*

func makeUserStore(): BstormUserStore {
    BstormUserStore(Storm.inMemory())
}

func makeService(store: UserStore): AuthService {
    AuthService(store, 3600)
}

@Test
func testUserPersist() {
    let store = makeUserStore()
    let svc = makeService(store)
    // initAdmin（空库创建管理员）
    PasswordHash.ITERATIONS = 1000
    let admin = svc.initAdmin("admin", "AdminPass1")
    @Expect(admin.isSome(), true)

    // 从同一 store 重新查（模拟重启）
    let reloaded = store.getUserByUsername("admin")
    match (reloaded) {
        case Some(u) =>
            @Expect(u.isAdmin, true)
            @Expect(u.isActive, true)
            @Expect(u.publishToken.startsWith("publish-"), true)
        case None => @Fail("user should persist")
    }
    // 登录（校验密码）
    let r = svc.login("admin", "AdminPass1")
    @Expect(r.isSome(), true)
}

@Test
func testTokenPersist() {
    let store = makeUserStore()
    let svc = makeService(store)
    PasswordHash.ITERATIONS = 1000
    svc.initAdmin("admin", "AdminPass1")
    let (_, token) = svc.login("admin", "AdminPass1").getOrThrow()

    // token 持久化，从 store 直接读
    let stored = store.getToken(token.token)
    @Expect(stored.isSome(), true)
    match (stored) {
        case Some(t) =>
            @Expect(t.kind, "session")
            @Expect(t.userId, token.userId)
        case None => ()
    }
    // 校验 token 仍有效
    @Expect(svc.validateSessionToken(token.token).isSome(), true)
    // 登出后 token 被删
    svc.logout(token.token)
    @Expect(store.getToken(token.token).isNone(), true)
}

@Test
func testIsEmptyAndInitGuard() {
    let store = makeUserStore()
    @Expect(store.isEmpty(), true)
    let svc = makeService(store)
    PasswordHash.ITERATIONS = 1000
    svc.initAdmin("admin", "AdminPass1")
    @Expect(store.isEmpty(), false)
    // 已初始化 → 拒绝再 initAdmin
    @Expect(svc.initAdmin("admin2", "Pass123").isNone(), true)
}

@Test
func testPublishTokenCheck() {
    let store = makeUserStore()
    let svc = makeService(store)
    PasswordHash.ITERATIONS = 1000
    let admin = svc.initAdmin("admin", "AdminPass1").getOrThrow()
    // 发布 token 校验走 listAllUsers
    @Expect(svc.validatePublishToken(admin.publishToken).isSome(), true)
    @Expect(svc.validatePublishToken("publish-fake").isNone(), true)
}

@Test
func testMutationsPersistToStore() {
    // 回归：修改类操作（禁用/改密/重置 token）必须 saveUser 持久化。
    // MemoryUserStore 因引用共享恰好生效，Bstorm 的 getUser 返回副本，
    // 不 saveUser 时重新查询仍是旧值。
    PasswordHash.ITERATIONS = 1000  // 测试提速
    let storm = Storm.inMemory()
    let store = BstormUserStore(storm)
    let svc = AuthService(store, 3600)
    let _ = svc.initAdmin("admin", "AdminPass1")
    let alice = svc.createUser("alice", "AlicePass1", false).getOrThrow()

    // 禁用后重新查询（新副本）应为禁用；再启用回来
    @Expect(svc.setUserActive(alice.id, false), true)
    let re1 = store.getUser(alice.id).getOrThrow()
    @Expect(re1.isActive, false)
    @Expect(svc.setUserActive(alice.id, true), true)

    // 重置 token 后重新查询应为新 token
    let oldToken = alice.publishToken
    let newToken = svc.resetPublishToken(alice.id).getOrThrow()
    @Expect(newToken != oldToken, true)
    let re2 = store.getUser(alice.id).getOrThrow()
    @Expect(re2.publishToken, newToken)

    // 改密后重新查询 hash 变化且新密码可登录
    @Expect(svc.changePassword(alice.id, "NewPass99"), true)
    @Expect(svc.login("alice", "NewPass99").isSome(), true)
    @Expect(svc.login("alice", "AlicePass1").isNone(), true)
}

@Test
func testChangePasswordBstormVerify() {
    PasswordHash.ITERATIONS = 1000  // 测试提速
    let storm = Storm.inMemory()
    let store = BstormUserStore(storm)
    let svc = AuthService(store, 3600)
    let _ = svc.initAdmin("admin", "AdminPass1")
    let alice = svc.createUser("alice", "AlicePass1", false).getOrThrow()
    let oldHash = alice.passwordHash

    @Expect(svc.changePassword(alice.id, "NewPass99"), true)
    let re = store.getUser(alice.id).getOrThrow()
    @Expect(re.passwordHash != oldHash, true)
    @Expect(re.passwordHash.contains(":"), true)
    @Expect(PasswordHash.verify("NewPass99", re.passwordHash), true)
}
