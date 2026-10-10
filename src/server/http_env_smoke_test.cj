// HTTP 夹具自证：进程内起真实服务 → 真实请求 → 状态码/报文断言
//
// 这条用例守的是**夹具本身**：如果它挂了，后面所有 handler 级用例都会误报，
// 所以先证明「路由可达、鉴权生效、DTO 序列化正确」这三件事。
package ystyle::cjreg.server

import std.unittest.*
import std.unittest.testmacro.*

@Test
class HttpEnvSmokeTest {
    // 健康检查：最小可达性（不依赖任何 store 状态）
    @TestCase
    func testHealthEndpoint(): Unit {
        let env = newHttpEnv()
        try {
            let resp = httpGet(env, "/api/health")
            @Expect(resp.status, 200u16)
            @Expect(headerOf(resp, "content-type"), "application/json; charset=utf-8")
            @Expect(bodyText(resp), "{\"status\":\"ok\"}")
        } finally {
            env.close()
        }
    }

    // 管理登录：走真实 PBKDF2 校验 → session token
    @TestCase
    func testAdminLoginAndMe(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            @Expect(token.isEmpty(), false)

            let me = httpGet(env, "/api/admin/me", token: token)
            @Expect(me.status, 200u16)
            @Expect(extractJsonString(bodyText(me), "username"), "admin")
        } finally {
            env.close()
        }
    }

    // 未认证访问管理端点 → 401（守鉴权链路没被夹具绕过）
    @TestCase
    func testAdminEndpointRejectsAnonymous(): Unit {
        let env = newHttpEnv()
        try {
            let resp = httpGet(env, "/api/admin/users")
            @Expect(resp.status, 401u16)
        } finally {
            env.close()
        }
    }

    // 公开读 API：本地包出现在列表里（守 DTO 序列化与读模型联通）
    @TestCase
    func testPublicPackagesListsSeededPackage(): Unit {
        let env = newHttpEnv()
        try {
            let _ = seedPackage(env, "acme", "demo", "1.0.0", desc: "示例")
            let resp = httpGet(env, "/api/packages?organization=acme")
            @Expect(resp.status, 200u16)
            let body = bodyText(resp)
            @Expect(body.contains("\"demo\""), true)
        } finally {
            env.close()
        }
    }

    // 协议端点：索引分片不匹配必须 400（官方仓同款护栏，夹具要能看见）
    @TestCase
    func testIndexShardMismatchRejected(): Unit {
        let env = newHttpEnv()
        try {
            let _ = seedPackage(env, "acme", "crc", "1.0.0")
            // 分片规则：mo = name[0..2]、du = name[2..4]（cr + c）
            let ok = httpGet(env, "/index/cr/c/crc?organization=acme")
            @Expect(ok.status, 200u16)
            let bad = httpGet(env, "/index/xx/yy/crc?organization=acme")
            @Expect(bad.status, 400u16)
        } finally {
            env.close()
        }
    }
}
