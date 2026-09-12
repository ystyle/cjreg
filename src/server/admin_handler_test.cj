// 管理 API handler 单元测试：JSON body 解析（创建用户 / 角色变更）
package ystyle::cjreg.server

import std.unittest.testmacro.*

func toBytes(s: String): Array<Byte> {
    s.toArray()
}

@Test
func testParseCreateUserBody() {
    // 管理员 + 邮箱
    let body = toBytes("{\"username\":\"alice\",\"password\":\"AlicePass1\",\"isAdmin\":true,\"email\":\"alice@example.com\"}")
    match (parseJsonBody<CreateUserRequest>(body, { r => CreateUserRequest.fromJson(r) })) {
        case Some(r) =>
            @Expect(r.username, "alice")
            @Expect(r.password, "AlicePass1")
            @Expect(r.isAdmin, true)
            @Expect(r.email, "alice@example.com")
        case None => @Fail("valid JSON body should parse")
    }

    // 省略 isAdmin → 默认普通用户（与旧行为兼容）
    let plain = toBytes("{\"username\":\"bob\",\"password\":\"BobPass1\"}")
    match (parseJsonBody<CreateUserRequest>(plain, { r => CreateUserRequest.fromJson(r) })) {
        case Some(r) =>
            @Expect(r.username, "bob")
            @Expect(r.isAdmin, false)
            @Expect(r.email, "")
        case None => @Fail("body without isAdmin should parse")
    }

    // 未知字段忽略
    let extra = toBytes("{\"username\":\"carol\",\"password\":\"CarolPass1\",\"nickname\":\"cc\"}")
    match (parseJsonBody<CreateUserRequest>(extra, { r => CreateUserRequest.fromJson(r) })) {
        case Some(r) => @Expect(r.username, "carol")
        case None => @Fail("unknown fields should be skipped")
    }
}

@Test
func testParseSetUserAdminBody() {
    // 显式 false 必须与「字段缺失」区分开（false = 降级，缺失 = 400）
    let demote = toBytes("{\"isAdmin\":false}")
    match (parseJsonBody<SetUserAdminRequest>(demote, { r => SetUserAdminRequest.fromJson(r) })) {
        case Some(r) =>
            match (r.isAdmin) {
                case Some(v) => @Expect(v, false)
                case None => @Fail("explicit false should be captured")
            }
        case None => @Fail("valid body should parse")
    }

    let promote = toBytes("{\"isAdmin\":true}")
    match (parseJsonBody<SetUserAdminRequest>(promote, { r => SetUserAdminRequest.fromJson(r) })) {
        case Some(r) =>
            match (r.isAdmin) {
                case Some(v) => @Expect(v, true)
                case None => @Fail("explicit true should be captured")
            }
        case None => @Fail("valid body should parse")
    }

    // 字段缺失
    let absent = toBytes("{\"other\":1}")
    match (parseJsonBody<SetUserAdminRequest>(absent, { r => SetUserAdminRequest.fromJson(r) })) {
        case Some(r) => @Expect(r.isAdmin.isNone(), true)
        case None => @Fail("empty payload should still parse")
    }
}

@Test
func testParseJsonBodyRejectsBadInput() {
    // 空 body
    @Expect(parseJsonBody<CreateUserRequest>(Array<Byte>(), { r => CreateUserRequest.fromJson(r) }).isNone(), true)
    // 非 JSON
    @Expect(parseJsonBody<CreateUserRequest>(toBytes("username=alice"), { r => CreateUserRequest.fromJson(r) }).isNone(), true)
    // 顶层非对象
    @Expect(parseJsonBody<CreateUserRequest>(toBytes("[]"), { r => CreateUserRequest.fromJson(r) }).isNone(), true)
    // 字段类型不符（isAdmin 给了字符串）
    @Expect(parseJsonBody<CreateUserRequest>(toBytes("{\"isAdmin\":\"yes\"}"), { r => CreateUserRequest.fromJson(r) }).isNone(), true)
    // 截断的 JSON
    @Expect(parseJsonBody<CreateUserRequest>(toBytes("{\"username\":\"alice\""), { r => CreateUserRequest.fromJson(r) }).isNone(), true)
}
