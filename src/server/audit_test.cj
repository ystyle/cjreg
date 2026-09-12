// 审计辅助单元测试（IP/UA 提取的纯函数部分 + 目标串/转义/kind 解析）
package ystyle::cjreg.server

import std.unittest.testmacro.*

@Test
func testAuditHelpers() {
    // 目标串拼装
    @Expect(auditTarget("test", "demo", "1.0.0"), "test/demo@1.0.0")
    @Expect(auditTarget("", "demo", "1.0.0"), "demo@1.0.0")
    @Expect(auditTarget("test", "demo", ""), "test/demo")
    @Expect(auditTarget("", "demo", ""), "demo")
    // kind 解析
    @Expect(parseAuditKind("publish"), Some("publish"))
    @Expect(parseAuditKind("admin"), Some("admin"))
    @Expect(parseAuditKind("auth"), Some("auth"))
    @Expect(parseAuditKind("all").isNone(), true)
    @Expect(parseAuditKind("").isNone(), true)
    @Expect(parseAuditKind("bogus").isNone(), true)
    // JSON 转义（UA/错误消息里可能有引号、反斜杠、换行）
    @Expect(escapeJsonStr("cjpm/1.1 (linux)"), "cjpm/1.1 (linux)")
    @Expect(escapeJsonStr("a\"b"), "a\\\"b")
    @Expect(escapeJsonStr("a\\b"), "a\\\\b")
    @Expect(escapeJsonStr("l1\nl2"), "l1\\nl2")
    @Expect(escapeJsonStr("x\u{1}y"), "x\\u0001y")
    // 截断
    @Expect(truncateStr("abc", 5), "abc")
    @Expect(truncateStr("abcdef", 3), "abc")
    // 去端口（审计只记地址；裸 IPv6 不动）
    @Expect(stripPort("127.0.0.1:38184"), "127.0.0.1")
    @Expect(stripPort("127.0.0.1"), "127.0.0.1")
    @Expect(stripPort("[::1]:38184"), "::1")
    @Expect(stripPort("2001:db8::1"), "2001:db8::1")
    @Expect(stripPort(" 10.0.0.7:80 "), "10.0.0.7")
    @Expect(stripPort(""), "")
}

