// 密码哈希与 Token 工具单元测试
package ystyle::cjreg.auth.util

import std.unittest.testmacro.*

@Test
func testPasswordHashRoundTrip() {
    PasswordHash.ITERATIONS = 1000  // 测试提速
    let hashed = PasswordHash.hash("mySecret123")
    @Expect(PasswordHash.verify("mySecret123", hashed), true)
    @Expect(PasswordHash.verify("wrongPass", hashed), false)
    @Expect(PasswordHash.verify("mySecret123", "not-a-hash"), false)
}

@Test
func testPasswordHashSaltRandom() {
    PasswordHash.ITERATIONS = 1000  // 测试提速
    let h1 = PasswordHash.hash("samePass")
    let h2 = PasswordHash.hash("samePass")
    // salt 随机 → 两次哈希不同，但都能通过校验
    @Expect(h1 != h2, true)
    @Expect(PasswordHash.verify("samePass", h1), true)
    @Expect(PasswordHash.verify("samePass", h2), true)
}

@Test
func testPasswordHashFormat() {
    PasswordHash.ITERATIONS = 1000  // 测试提速
    let hashed = PasswordHash.hash("pass")
    let parts = hashed.split(":")
    @Expect(parts.size, 2)
    @Expect(parts[0].size, 32)  // 16 字节 salt 的 hex
}

@Test
func testTokenGenerator() {
    let s1 = TokenGenerator.generateSessionToken()
    let s2 = TokenGenerator.generateSessionToken()
    let p1 = TokenGenerator.generatePublishToken()
    @Expect(s1.startsWith("sess-"), true)
    @Expect(p1.startsWith("publish-"), true)
    @Expect(s1 != s2, true)
    @Expect(s1 != p1, true)
    @Expect(s1.size > 10, true)
}

@Test
func testTimestamp() {
    let now = currentTimestamp()
    let future = expiresAt(3600)
    @Expect(future > now, true)
}
