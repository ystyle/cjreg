// 持久化集成测试：init 建管理员 → 重开 Storm → 查用户/登录
package ystyle::cjreg.store

import bstorm.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*
import ystyle::cjreg.auth.util.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.*

@Test
func testPersistentUserAcrossReopen() {
    let dir = "/tmp/cjreg-persist-test"
    removeIfExists(dir, recursive: true)
    Directory.create(dir, recursive: true)

    // 第一次：建 store + 创建管理员
    var storm = Storm.open(dir + "/cjreg.db")
    var store = BstormUserStore(storm)
    var svc = AuthService(store, 3600)
    PasswordHash.ITERATIONS = 1000
    let admin = svc.initAdmin("admin", "AdminPass1")
    @Expect(admin.isSome(), true)
    @Expect(store.listAllUsers().size, 1)
    storm.close()

    // 第二次：重开（模拟 serve）
    storm = Storm.open(dir + "/cjreg.db")
    store = BstormUserStore(storm)
    @Expect(store.listAllUsers().size, 1)
    let reloaded = store.getUserByUsername("admin")
    @Expect(reloaded.isSome(), true)
    match (reloaded) {
        case Some(u) =>
            @Expect(u.isAdmin, true)
            @Expect(u.passwordHash.contains(":"), true)
        case None => @Fail("user lost after reopen")
    }
    // 登录
    svc = AuthService(store, 3600)
    let r = svc.login("admin", "AdminPass1")
    @Expect(r.isSome(), true)
    storm.close()
}
