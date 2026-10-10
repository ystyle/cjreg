// 管理 API handler 级测试（用户 / 组织 / 上游 / 日志）
//
// 走真实 HTTP：覆盖 requireAdmin 的三态（匿名 401 / 非管理员 403 / 管理员通过）、
// 参数校验、冲突与不存在分支、以及各端点的响应体形状。
package ystyle::cjreg.server

import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

// 造一个「非管理员」用户的 session token（走真实登录）
func seedPlainUserToken(env: HttpEnv, adminToken: String, username!: String = "alice",
                        password!: String = "AlicePass1"): String {
    let resp = httpPostJson(env, "/api/admin/users",
        "{\"username\":\"" + username + "\",\"password\":\"" + password + "\",\"isAdmin\":false}",
        token: adminToken)
    if (resp.status != 200u16) {
        return ""
    }
    loginToken(env, username, password)
}

@Test
class AdminUsersApiTest {
    // 匿名访问管理端点 → 401（requireAdmin 的 None 分支）
    @TestCase
    func testAnonymousRejected(): Unit {
        let env = newHttpEnv()
        try {
            @Expect(httpGet(env, "/api/admin/users").status, 401u16)
            @Expect(httpGet(env, "/api/admin/organizations").status, 401u16)
            @Expect(httpGet(env, "/api/admin/upstreams").status, 401u16)
            @Expect(httpGet(env, "/api/admin/logs/admin").status, 401u16)
        } finally {
            env.close()
        }
    }

    // 普通用户访问管理端点 → 403（requireAdmin 的 isAdmin=false 分支）
    @TestCase
    func testNonAdminRejected(): Unit {
        let env = newHttpEnv()
        try {
            let adminToken = seedAdminToken(env)
            let userToken = seedPlainUserToken(env, adminToken)
            @Expect(userToken.isEmpty(), false)
            @Expect(httpGet(env, "/api/admin/users", token: userToken).status, 403u16)
        } finally {
            env.close()
        }
    }

    // 用户列表：裸数组契约（外部脚本按 Array 解析）
    @TestCase
    func testListUsersBareArrayContract(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            let resp = httpGet(env, "/api/admin/users", token: token)
            @Expect(resp.status, 200u16)
            let body = bodyText(resp)
            @Expect(body.startsWith("["), true)
            @Expect(body.contains("\"admin\""), true)
        } finally {
            env.close()
        }
    }

    // 创建用户：成功 200；重复用户名 409；缺字段 400；body 非法 400
    @TestCase
    func testCreateUserBranches(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            let ok = httpPostJson(env, "/api/admin/users",
                "{\"username\":\"bob\",\"password\":\"BobPass123\",\"isAdmin\":false,\"email\":\"b@x.cn\"}", token: token)
            @Expect(ok.status, 200u16)
            @Expect(extractJsonString(bodyText(ok), "username"), "bob")

            let dup = httpPostJson(env, "/api/admin/users",
                "{\"username\":\"bob\",\"password\":\"BobPass123\"}", token: token)
            @Expect(dup.status, 409u16)

            let missing = httpPostJson(env, "/api/admin/users", "{\"username\":\"carol\"}", token: token)
            @Expect(missing.status, 400u16)

            let bad = httpPostJson(env, "/api/admin/users", "not-json", token: token)
            @Expect(bad.status, 400u16)
        } finally {
            env.close()
        }
    }

    // 角色变更：提升 200；显式 false 与非管理员用户；缺字段 400；id 非法 400；用户不存在 404
    @TestCase
    func testSetUserAdminBranches(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            let created = httpPostJson(env, "/api/admin/users",
                "{\"username\":\"dave\",\"password\":\"DavePass12\",\"isAdmin\":false}", token: token)
            @Expect(created.status, 200u16)
            let uid = extractJsonInt(bodyText(created), "id")
            @Expect(uid > 0, true)

            // 提升
            let promote = httpPutJson(env, "/api/admin/users/${uid}/admin", "{\"isAdmin\":true}", token: token)
            @Expect(promote.status, 200u16)
            @Expect(bodyText(promote).contains("\"isAdmin\":true"), true)

            // 再降级（此时 admin 自己也是管理员，不会撞「最后一个管理员」）
            let demote = httpPutJson(env, "/api/admin/users/${uid}/admin", "{\"isAdmin\":false}", token: token)
            @Expect(demote.status, 200u16)

            // 缺 isAdmin 字段 → 400（与显式 false 区分）
            let absent = httpPutJson(env, "/api/admin/users/${uid}/admin", "{\"other\":1}", token: token)
            @Expect(absent.status, 400u16)

            // body 非法 → 400
            let bad = httpPutJson(env, "/api/admin/users/${uid}/admin", "junk", token: token)
            @Expect(bad.status, 400u16)

            // id 非法 → 400
            @Expect(httpPutJson(env, "/api/admin/users/abc/admin", "{\"isAdmin\":true}", token: token).status, 400u16)

            // 用户不存在 → 404
            @Expect(httpPutJson(env, "/api/admin/users/99999/admin", "{\"isAdmin\":true}", token: token).status, 404u16)
        } finally {
            env.close()
        }
    }

    // 最后一个启用管理员不可被降级 → 409
    @TestCase
    func testCannotRevokeLastAdmin(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            let me = httpGet(env, "/api/admin/me", token: token)
            let myId = extractJsonInt(bodyText(me), "id")
            @Expect(myId > 0, true)
            let resp = httpPutJson(env, "/api/admin/users/${myId}/admin", "{\"isAdmin\":false}", token: token)
            @Expect(resp.status, 409u16)
        } finally {
            env.close()
        }
    }

    // 登录：成功 / 口令错误 401 / 缺字段 400 / body 非法 400 / me 未认证 401
    @TestCase
    func testLoginAndMeBranches(): Unit {
        let env = newHttpEnv()
        try {
            let _ = seedAdminToken(env)
            @Expect(httpPostJson(env, "/api/admin/login",
                "{\"username\":\"admin\",\"password\":\"wrong\"}").status, 401u16)
            @Expect(httpPostJson(env, "/api/admin/login",
                "{\"username\":\"admin\"}").status, 400u16)
            @Expect(httpPostJson(env, "/api/admin/login", "junk").status, 400u16)
            @Expect(httpGet(env, "/api/admin/me").status, 401u16)

            let token = loginToken(env, "admin", "AdminPass1")
            let me = httpGet(env, "/api/admin/me", token: token)
            @Expect(me.status, 200u16)
            @Expect(extractJsonString(bodyText(me), "username"), "admin")

            // 登出后 session 失效 → 401
            @Expect(httpPostJson(env, "/api/admin/logout", "", token: token).status, 200u16)
            @Expect(httpGet(env, "/api/admin/me", token: token).status, 401u16)
        } finally {
            env.close()
        }
    }
}

@Test
class AdminOrgApiTest {
    // 组织 CRUD 全链路：创建 → 列表 → 详情 → 更新 → 删除
    @TestCase
    func testOrgCrudLifecycle(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)

            let created = httpPostJson(env, "/api/admin/organizations",
                "{\"name\":\"acme\",\"displayName\":\"Acme Inc\",\"description\":\"示例组织\"}", token: token)
            @Expect(created.status, 200u16)
            let orgId = extractJsonInt(bodyText(created), "id")
            @Expect(orgId > 0, true)

            let list = httpGet(env, "/api/admin/organizations", token: token)
            @Expect(list.status, 200u16)
            @Expect(bodyText(list).contains("Acme Inc"), true)

            let detail = httpGet(env, "/api/admin/organizations/${orgId}", token: token)
            @Expect(detail.status, 200u16)
            @Expect(bodyText(detail).contains("acme"), true)

            // 局部更新：只改 description，返回 OrgResultResp（status/message/id/affected），
            // 之后详情里能看到新描述、displayName 保持
            let updated = httpPutJson(env, "/api/admin/organizations/${orgId}",
                "{\"description\":\"改过的描述\"}", token: token)
            @Expect(updated.status, 200u16)
            @Expect(extractJsonString(bodyText(updated), "status"), "ok")
            let afterUpdate = bodyText(httpGet(env, "/api/admin/organizations/${orgId}", token: token))
            @Expect(afterUpdate.contains("改过的描述"), true)
            @Expect(afterUpdate.contains("Acme Inc"), true)

            let removed = httpDelete(env, "/api/admin/organizations/${orgId}", token: token)
            @Expect(removed.status, 200u16)
            @Expect(httpGet(env, "/api/admin/organizations/${orgId}", token: token).status, 404u16)
        } finally {
            env.close()
        }
    }

    // 不一致 / 缺字段 / 不存在的分支
    @TestCase
    func testOrgErrorBranches(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)

            // 缺 name → 400
            @Expect(httpPostJson(env, "/api/admin/organizations", "{\"displayName\":\"X\"}", token: token).status, 400u16)
            // body 非法 → 400
            @Expect(httpPostJson(env, "/api/admin/organizations", "junk", token: token).status, 400u16)
            // 重复名 → 409
            @Expect(httpPostJson(env, "/api/admin/organizations", "{\"name\":\"dup\"}", token: token).status, 200u16)
            @Expect(httpPostJson(env, "/api/admin/organizations", "{\"name\":\"dup\"}", token: token).status, 409u16)
            // 详情不存在 → 404；id 非数字也落到 404（解析失败按 id=0 查，查不到即 not found）
            @Expect(httpGet(env, "/api/admin/organizations/99999", token: token).status, 404u16)
            @Expect(httpGet(env, "/api/admin/organizations/abc", token: token).status, 404u16)
            // 更新不存在 → 404（OrgOutcome.NotFound）
            let missing = httpPutJson(env, "/api/admin/organizations/99999", "{\"displayName\":\"Y\"}", token: token)
            @Expect(missing.status, 404u16)
            // 删除不存在的组织 → 404（OrgOutcome.NotFound）。
            // 注意与「删除上游」不同：那边把 not found 与 official protected 合并成 409，
            // 这边是 404 —— 两条契约各自被用例钉住，别顺手"统一"掉。
            @Expect(httpDelete(env, "/api/admin/organizations/99999", token: token).status, 404u16)
        } finally {
            env.close()
        }
    }
}

@Test
class AdminUpstreamApiTest {
    // 上游 CRUD：新增（含两个能力开关）→ 列表 → 局部更新 → 测试连通 → 删除
    @TestCase
    func testUpstreamCrudLifecycle(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)

            let added = httpPostJson(env, "/api/admin/upstreams",
                "{\"name\":\"mirror\",\"url\":\"http://127.0.0.1:9/registry\",\"priority\":\"5\"," +
                "\"proxy_enabled\":true,\"as_target\":true}", token: token)
            @Expect(added.status, 200u16)
            let upId = extractJsonInt(bodyText(added), "id")
            @Expect(upId > 0, true)

            let list = httpGet(env, "/api/admin/upstreams", token: token)
            @Expect(list.status, 200u16)
            @Expect(bodyText(list).contains("mirror"), true)

            // 局部更新：只翻开关，url 不可改
            let updated = httpPutJson(env, "/api/admin/upstreams/${upId}",
                "{\"proxyEnabled\":false,\"asTarget\":false}", token: token)
            @Expect(updated.status, 200u16)

            let afterUpdate = bodyText(httpGet(env, "/api/admin/upstreams", token: token))
            @Expect(afterUpdate.contains("\"proxyEnabled\":false"), true)

            // 连通性测试：地址不可达 → 端点自身仍 200（结果体里带 reachable=false）
            let probed = httpPostJson(env, "/api/admin/upstreams/${upId}/test", "", token: token)
            @Expect(probed.status, 200u16)
            @Expect(bodyText(probed).contains("reachable"), true)

            @Expect(httpDelete(env, "/api/admin/upstreams/${upId}", token: token).status, 200u16)
        } finally {
            env.close()
        }
    }

    // 参数校验：缺 name/url、body 非法、更新/删除/测试不存在、id 非法
    @TestCase
    func testUpstreamErrorBranches(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            @Expect(httpPostJson(env, "/api/admin/upstreams", "{\"name\":\"only-name\"}", token: token).status, 400u16)
            @Expect(httpPostJson(env, "/api/admin/upstreams", "{\"url\":\"http://x/y\"}", token: token).status, 400u16)
            @Expect(httpPostJson(env, "/api/admin/upstreams", "junk", token: token).status, 400u16)
            @Expect(httpPutJson(env, "/api/admin/upstreams/99999", "{\"enabled\":false}", token: token).status, 404u16)
            // 删除不存在的上游：契约是 409（"not found or official protected"），官方上游也走这一支
            @Expect(httpDelete(env, "/api/admin/upstreams/99999", token: token).status, 409u16)
            @Expect(httpPostJson(env, "/api/admin/upstreams/99999/test", "", token: token).status, 404u16)
            @Expect(httpDelete(env, "/api/admin/upstreams/abc", token: token).status, 400u16)
        } finally {
            env.close()
        }
    }
}

@Test
class AdminLogsApiTest {
    // 审计日志：有记录时可查；kind 非法 / 清理端点分支
    @TestCase
    func testLogsQueryAndClean(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            // 产生一条审计：创建用户
            let _ = httpPostJson(env, "/api/admin/users",
                "{\"username\":\"logged\",\"password\":\"LoggedPass1\"}", token: token)

            let logs = httpGet(env, "/api/admin/logs/admin", token: token)
            @Expect(logs.status, 200u16)
            @Expect(bodyText(logs).contains("create_user"), true)

            // 关键字过滤
            let filtered = httpGet(env, "/api/admin/logs/admin?keyword=create_user", token: token)
            @Expect(filtered.status, 200u16)

            // 清理：保留天数很大 = 不删（端点自身成功）
            let cleaned = httpPostJson(env, "/api/admin/logs/clean", "{\"beforeDays\":3650}", token: token)
            @Expect(cleaned.status, 200u16)

            // 非法 body → 400
            @Expect(httpPostJson(env, "/api/admin/logs/clean", "junk", token: token).status, 400u16)
        } finally {
            env.close()
        }
    }
}
