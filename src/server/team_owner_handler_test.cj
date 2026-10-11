// 团队 owner 自助：handler 级测试（真实 HTTP）
//
// 这一层守的是**越权**（§7.4 约束 1：服务端守卫，UI 隐藏不算安全）：
// 非 owner / owner 但自助未开 / 匿名 —— 对门户 API 一律被拒；
// 管理员走同一批端点必须成功（超集）。
package ystyle::cjreg.server

import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import std.collection.*
import std.convert.*
import std.unittest.*
import std.unittest.testmacro.*

// 用管理端 API 建团队并指定 owner / 自助开关，返回 teamId（-1 = 失败）
func mkTeamViaApi(env: HttpEnv, adminToken: String, name: String,
                  ownerName!: String = "", selfService!: Bool = false,
                  permission!: String = "read"): Int64 {
    var ownerId: Int64 = 0
    if (!ownerName.isEmpty()) {
        let users = bodyText(httpGet(env, "/api/admin/users", token: adminToken))
        ownerId = extractUserIdByName(users, ownerName)
    }
    let body = "{\"name\":\"" + name + "\",\"displayName\":\"" + name + "\",\"permission\":\"" + permission +
        "\",\"ownerId\":" + ownerId.toString() + ",\"selfService\":" + (if (selfService) { "true" } else { "false" }) + "}"
    let resp = httpPostJson(env, "/api/admin/teams", body, token: adminToken)
    if (resp.status != 200u16) {
        return -1
    }
    extractJsonInt(bodyText(resp), "teamId")
}

// 在用户列表 JSON 里按用户名找 id（列表是裸数组，元素形如 {"id":N,"username":"..",...}）
func extractUserIdByName(usersJson: String, name: String): Int64 {
    let idx = usersJson.indexOf("\"username\":\"" + name + "\"")
    match (idx) {
        case Some(i) =>
            // 往前找最近的 "id":
            let head = usersJson[0..i]
            let idIdx = head.lastIndexOf("\"id\":")
            match (idIdx) {
                case Some(j) =>
                    let rest = head[(j + 5)..head.size]
                    var end = 0
                    while (end < rest.size && rest[end] >= 48 && rest[end] <= 57) {
                        end++
                    }
                    if (end == 0) {
                        return 0
                    }
                    match (Int64.tryParse(rest[0..end])) {
                        case Some(v) => v
                        case None => 0
                    }
                case None => 0
            }
        case None => 0
    }
}

@Test
class TeamAdminApiTest {
    // 管理端团队 CRUD：创建（带 owner+自助）→ 列表 → 开关自助 → 删除
    @TestCase
    func testAdminTeamCrud(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            let _ = seedPlainUserToken(env, token, username: "owner1", password: "Owner1Pass")
            let tid = mkTeamViaApi(env, token, "core", ownerName: "owner1", selfService: true, permission: "write")
            @Expect(tid > 0, true)

            // 列表里能看到该团队，且带 owner 名与自助状态
            let list = bodyText(httpGet(env, "/api/admin/teams", token: token))
            @Expect(list.contains("core"), true)
            @Expect(list.contains("owner1"), true)
            @Expect(list.contains("\"selfService\":true"), true)

            // 关掉自助
            let off = httpPutJson(env, "/api/admin/teams/${tid}/self-service", "{\"enabled\":false}", token: token)
            @Expect(off.status, 200u16)
            @Expect(bodyText(httpGet(env, "/api/admin/teams", token: token)).contains("\"selfService\":false"), true)

            // 删除
            @Expect(httpDelete(env, "/api/admin/teams/${tid}", token: token).status, 200u16)
            @Expect(bodyText(httpGet(env, "/api/admin/teams", token: token)).contains("core"), false)
        } finally {
            env.close()
        }
    }

    // 校验分支：缺 name 400 / 重名 409 / owner 不存在或禁用 400 / body 非法 400 / 不存在 404
    @TestCase
    func testAdminTeamValidation(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            @Expect(httpPostJson(env, "/api/admin/teams", "{\"displayName\":\"x\"}", token: token).status, 400u16)
            @Expect(httpPostJson(env, "/api/admin/teams", "junk", token: token).status, 400u16)
            @Expect(httpPostJson(env, "/api/admin/teams", "{\"name\":\"dup\"}", token: token).status, 200u16)
            @Expect(httpPostJson(env, "/api/admin/teams", "{\"name\":\"dup\"}", token: token).status, 409u16)
            // owner 不存在
            @Expect(httpPostJson(env, "/api/admin/teams",
                "{\"name\":\"badowner\",\"ownerId\":99999}", token: token).status, 400u16)
            // 更新/删除/开关 不存在的团队 → 404
            @Expect(httpPutJson(env, "/api/admin/teams/99999", "{\"displayName\":\"y\"}", token: token).status, 404u16)
            @Expect(httpDelete(env, "/api/admin/teams/99999", token: token).status, 404u16)
            @Expect(httpPutJson(env, "/api/admin/teams/99999/self-service", "{\"enabled\":true}",
                token: token).status, 404u16)
        } finally {
            env.close()
        }
    }

    // 约束 2：开启自助前必须已有 owner（否则开了也没人能用）
    @TestCase
    func testSelfServiceRequiresOwner(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            let tid = mkTeamViaApi(env, token, "noowner")   // 不带 owner
            @Expect(tid > 0, true)
            let resp = httpPutJson(env, "/api/admin/teams/${tid}/self-service", "{\"enabled\":true}", token: token)
            @Expect(resp.status, 400u16)
            @Expect(bodyText(resp).contains("所有者"), true)
        } finally {
            env.close()
        }
    }

    // 管理端成员读写（requireAdmin）+ 成员列表标注 owner
    @TestCase
    func testAdminMemberReadWrite(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            let _ = seedPlainUserToken(env, token, username: "boss", password: "BossPass12")
            let _ = seedPlainUserToken(env, token, username: "worker", password: "WorkerPass1")
            let tid = mkTeamViaApi(env, token, "withowner", ownerName: "boss", selfService: true)
            @Expect(tid > 0, true)

            // owner 自动入队
            let members = bodyText(httpGet(env, "/api/admin/teams/${tid}/members", token: token))
            @Expect(members.contains("boss"), true)
            @Expect(members.contains("\"isOwner\":true"), true)

            // 加成员
            let bossId = extractUserIdByName(bodyText(httpGet(env, "/api/admin/users", token: token)), "boss")
            let workerId = extractUserIdByName(bodyText(httpGet(env, "/api/admin/users", token: token)), "worker")
            @Expect(workerId > 0, true)
            let add = httpPostJson(env, "/api/admin/teams/${tid}/members",
                "{\"userId\":" + workerId.toString() + "}", token: token)
            @Expect(add.status, 200u16)
            @Expect(bodyText(httpGet(env, "/api/admin/teams/${tid}/members", token: token)).contains("worker"), true)

            // 移出
            @Expect(httpDelete(env, "/api/admin/teams/${tid}/members/${workerId}", token: token).status, 200u16)
            @Expect(bodyText(httpGet(env, "/api/admin/teams/${tid}/members", token: token)).contains("worker"), false)

            // owner 不可移出 → 400 + 明确文案
            let rmOwner = httpDelete(env, "/api/admin/teams/${tid}/members/${bossId}", token: token)
            @Expect(rmOwner.status, 400u16)
            @Expect(bodyText(rmOwner).contains("转让"), true)
        } finally {
            env.close()
        }
    }

    // 匿名/非管理员访问管理端团队端点 → 401 / 403
    @TestCase
    func testAdminTeamEndpointsRequireAdmin(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            let userToken = seedPlainUserToken(env, token, username: "plainu", password: "PlainPass1")
            @Expect(httpGet(env, "/api/admin/teams").status, 401u16)
            @Expect(httpGet(env, "/api/admin/teams", token: userToken).status, 403u16)
            @Expect(httpPostJson(env, "/api/admin/teams", "{\"name\":\"x\"}", token: userToken).status, 403u16)
        } finally {
            env.close()
        }
    }
}

@Test
class TeamPortalSelfServiceApiTest {
    // ★ 越权核心：非 owner 用门户 API 管团队 → 403，且数据不变
    @TestCase
    func testNonOwnerCannotManageViaPortal(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            let ownerToken = seedPlainUserToken(env, token, username: "theowner", password: "OwnerPass1")
            let otherToken = seedPlainUserToken(env, token, username: "outsider", password: "OutPass123")
            let victim = seedPlainUserToken(env, token, username: "victim", password: "VictimPass1")
            let tid = mkTeamViaApi(env, token, "guarded", ownerName: "theowner", selfService: true)
            @Expect(tid > 0, true)
            let victimId = extractUserIdByName(bodyText(httpGet(env, "/api/admin/users", token: token)), "victim")

            // 非 owner 加人 → 403
            let r = httpPostJson(env, "/api/user/me/teams/${tid}/members",
                "{\"userId\":" + victimId.toString() + "}", token: otherToken)
            @Expect(r.status, 403u16)
            @Expect(bodyText(r).contains("not_team_owner"), true)
            // 数据确实没变
            @Expect(bodyText(httpGet(env, "/api/admin/teams/${tid}/members", token: token)).contains("victim"), false)

            // 非 owner 转让 → 403
            @Expect(httpPostJson(env, "/api/user/me/teams/${tid}/transfer",
                "{\"userId\":" + victimId.toString() + "}", token: otherToken).status, 403u16)
            // 非 owner 移除 → 403
            let ownerId = extractUserIdByName(bodyText(httpGet(env, "/api/admin/users", token: token)), "theowner")
            @Expect(httpDelete(env, "/api/user/me/teams/${tid}/members/${ownerId}", token: otherToken).status, 403u16)

            // owner 本人做同样的事 → 成功（证明拒绝不是"端点坏了"）
            let ok = httpPostJson(env, "/api/user/me/teams/${tid}/members",
                "{\"userId\":" + victimId.toString() + "}", token: ownerToken)
            @Expect(ok.status, 200u16)
            @Expect(bodyText(httpGet(env, "/api/admin/teams/${tid}/members", token: token)).contains("victim"), true)
        } finally {
            env.close()
        }
    }

    // ★ 约束 2：owner 但 selfService 关 → 403 self_service_disabled
    @TestCase
    func testOwnerBlockedWhenSelfServiceOff(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            let ownerToken = seedPlainUserToken(env, token, username: "offowner", password: "OffPass123")
            let _ = seedPlainUserToken(env, token, username: "target1", password: "Target1Pass")
            // selfService = false（默认）
            let tid = mkTeamViaApi(env, token, "offteam", ownerName: "offowner", selfService: false)
            @Expect(tid > 0, true)
            let targetId = extractUserIdByName(bodyText(httpGet(env, "/api/admin/users", token: token)), "target1")

            let r = httpPostJson(env, "/api/user/me/teams/${tid}/members",
                "{\"userId\":" + targetId.toString() + "}", token: ownerToken)
            @Expect(r.status, 403u16)
            // 响应体是流，只能读一次 —— 多次断言先取到变量
            let rBody = bodyText(r)
            @Expect(rBody.contains("self_service_disabled"), true)
            @Expect(rBody.contains("未开启"), true)

            // 管理员开启后，同一请求就通了（证明开关是唯一差别）
            @Expect(httpPutJson(env, "/api/admin/teams/${tid}/self-service", "{\"enabled\":true}",
                token: token).status, 200u16)
            @Expect(httpPostJson(env, "/api/user/me/teams/${tid}/members",
                "{\"userId\":" + targetId.toString() + "}", token: ownerToken).status, 200u16)
        } finally {
            env.close()
        }
    }

    // ★ 匿名访问门户团队端点 → 401
    @TestCase
    func testPortalTeamEndpointsRequireAuth(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            let tid = mkTeamViaApi(env, token, "anon", ownerName: "admin", selfService: true)
            @Expect(tid > 0, true)
            @Expect(httpGet(env, "/api/user/me/teams/${tid}/members").status, 401u16)
            @Expect(httpPostJson(env, "/api/user/me/teams/${tid}/members", "{\"userId\":1}").status, 401u16)
            @Expect(httpDelete(env, "/api/user/me/teams/${tid}/members/1").status, 401u16)
            @Expect(httpPostJson(env, "/api/user/me/teams/${tid}/transfer", "{\"userId\":1}").status, 401u16)
        } finally {
            env.close()
        }
    }

    // ★ 约束 1/3：管理员走同一批门户端点必须成功（超集），即使不是 owner、自助也关着
    @TestCase
    func testAdminIsSupersetViaPortalApi(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            let _ = seedPlainUserToken(env, token, username: "someowner", password: "SomePass12")
            let _ = seedPlainUserToken(env, token, username: "adminadds", password: "AdminAdds1")
            // 团队 owner 是别人、自助关
            let tid = mkTeamViaApi(env, token, "adminsuper", ownerName: "someowner", selfService: false)
            @Expect(tid > 0, true)
            let addId = extractUserIdByName(bodyText(httpGet(env, "/api/admin/users", token: token)), "adminadds")

            // 管理员用**门户端点**加人 —— 应当放行
            let r = httpPostJson(env, "/api/user/me/teams/${tid}/members",
                "{\"userId\":" + addId.toString() + "}", token: token)
            @Expect(r.status, 200u16)
            @Expect(bodyText(httpGet(env, "/api/admin/teams/${tid}/members", token: token)).contains("adminadds"), true)
        } finally {
            env.close()
        }
    }

    // owner 自助全链路：加人 → 列出 → 转让 → 自己失去管理权
    @TestCase
    func testOwnerSelfServiceFullFlow(): Unit {
        let env = newHttpEnv()
        try {
            let adminToken = seedAdminToken(env)
            let ownerToken = seedPlainUserToken(env, adminToken, username: "flowowner", password: "FlowPass12")
            let memberToken = seedPlainUserToken(env, adminToken, username: "flowmember", password: "FlowMem123")
            let tid = mkTeamViaApi(env, adminToken, "flow", ownerName: "flowowner", selfService: true)
            @Expect(tid > 0, true)
            let memberId = extractUserIdByName(bodyText(httpGet(env, "/api/admin/users", token: adminToken)), "flowmember")

            // 加人
            @Expect(httpPostJson(env, "/api/user/me/teams/${tid}/members",
                "{\"userId\":" + memberId.toString() + "}", token: ownerToken).status, 200u16)
            // 成员可见（自己的团队列表）
            @Expect(bodyText(httpGet(env, "/api/user/me/teams", token: memberToken)).contains("flow"), true)
            // 成员不是 owner → 不能自助
            @Expect(httpPostJson(env, "/api/user/me/teams/${tid}/members",
                "{\"userId\":1}", token: memberToken).status, 403u16)

            // 转让给成员 → 成功
            let tr = httpPostJson(env, "/api/user/me/teams/${tid}/transfer",
                "{\"userId\":" + memberId.toString() + "}", token: ownerToken)
            @Expect(tr.status, 200u16)
            // 新 owner 可自助，旧 owner 不再可以（但仍是成员）
            @Expect(httpPostJson(env, "/api/user/me/teams/${tid}/members",
                "{\"userId\":" + memberId.toString() + "}", token: memberToken).status, 200u16)
            @Expect(httpPostJson(env, "/api/user/me/teams/${tid}/members",
                "{\"userId\":1}", token: ownerToken).status, 403u16)
        } finally {
            env.close()
        }
    }

    // 参数与边界：团队不存在 404、用户不存在 404、转让给非成员 400
    @TestCase
    func testPortalSelfServiceErrors(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            let ownerToken = seedPlainUserToken(env, token, username: "errsowner", password: "ErrsPass12")
            let _ = seedPlainUserToken(env, token, username: "nonmember", password: "NonMem123")
            let tid = mkTeamViaApi(env, token, "errs", ownerName: "errsowner", selfService: true)
            @Expect(tid > 0, true)
            let nonMemberId = extractUserIdByName(bodyText(httpGet(env, "/api/admin/users", token: token)), "nonmember")

            // 用户不存在 → 404
            @Expect(httpPostJson(env, "/api/user/me/teams/${tid}/members",
                "{\"userId\":99999}", token: ownerToken).status, 404u16)
            // 转让给非成员 → 400
            let tr = httpPostJson(env, "/api/user/me/teams/${tid}/transfer",
                "{\"userId\":" + nonMemberId.toString() + "}", token: ownerToken)
            @Expect(tr.status, 400u16)
            @Expect(bodyText(tr).contains("not_a_member"), true)
            // 团队不存在 → 404（canManageTeam 就拦下了）
            @Expect(httpGet(env, "/api/user/me/teams/99999/members", token: ownerToken).status, 404u16)
        } finally {
            env.close()
        }
    }

    // 约束 5：owner 自助操作写审计（actor = owner，detail 带 teamId 与 via）
    @TestCase
    func testSelfServiceWritesAudit(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            let ownerToken = seedPlainUserToken(env, token, username: "auditowner", password: "AuditPass1")
            let _ = seedPlainUserToken(env, token, username: "auditmember", password: "AuditMem1")
            let tid = mkTeamViaApi(env, token, "auditteam", ownerName: "auditowner", selfService: true)
            @Expect(tid > 0, true)
            let mid = extractUserIdByName(bodyText(httpGet(env, "/api/admin/users", token: token)), "auditmember")

            let _ = httpPostJson(env, "/api/user/me/teams/${tid}/members",
                "{\"userId\":" + mid.toString() + "}", token: ownerToken)

            let logs = bodyText(httpGet(env, "/api/admin/logs/admin?keyword=add_team_member", token: token))
            @Expect(logs.contains("add_team_member"), true)
            @Expect(logs.contains("auditowner"), true)
            @Expect(logs.contains("via=owner"), true)
        } finally {
            env.close()
        }
    }

    // 越权失败也要留痕（便于发现扫描/误用）
    @TestCase
    func testDeniedAccessIsNotWrittenButDataIntact(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            let _ = seedPlainUserToken(env, token, username: "denyowner", password: "DenyPass12")
            let otherToken = seedPlainUserToken(env, token, username: "denyother", password: "DenyOth123")
            let tid = mkTeamViaApi(env, token, "denyteam", ownerName: "denyowner", selfService: true)
            @Expect(tid > 0, true)
            let before = bodyText(httpGet(env, "/api/admin/teams/${tid}/members", token: token))
            // 非 owner 连发三次不同操作
            let _ = httpPostJson(env, "/api/user/me/teams/${tid}/members", "{\"userId\":1}", token: otherToken)
            let _ = httpDelete(env, "/api/user/me/teams/${tid}/members/1", token: otherToken)
            let _ = httpPostJson(env, "/api/user/me/teams/${tid}/transfer", "{\"userId\":1}", token: otherToken)
            let after = bodyText(httpGet(env, "/api/admin/teams/${tid}/members", token: token))
            @Expect(after, before)
        } finally {
            env.close()
        }
    }
}

@Test
class TeamAdminApiExtraTest {
    // PUT /api/admin/teams/:id 的各条分支：局部更新、owner 变更（含非法）、清空 owner
    @TestCase
    func testAdminUpdateTeamBranches(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            let _ = seedPlainUserToken(env, token, username: "u1", password: "U1Pass123")
            let _ = seedPlainUserToken(env, token, username: "u2", password: "U2Pass123")
            let tid = mkTeamViaApi(env, token, "upd", ownerName: "u1", selfService: true, permission: "read")
            @Expect(tid > 0, true)
            let uid2 = extractUserIdByName(bodyText(httpGet(env, "/api/admin/users", token: token)), "u2")

            // ① 局部更新：只改 displayName，permission 与 selfService 保持
            let r1 = httpPutJson(env, "/api/admin/teams/${tid}", "{\"displayName\":\"改名了\"}", token: token)
            @Expect(r1.status, 200u16)
            let list = bodyText(httpGet(env, "/api/admin/teams", token: token))
            @Expect(list.contains("改名了"), true)
            @Expect(list.contains("\"permission\":\"read\""), true)
            @Expect(list.contains("\"selfService\":true"), true)

            // ② 显式关闭 selfService
            let r2 = httpPutJson(env, "/api/admin/teams/${tid}", "{\"selfService\":false}", token: token)
            @Expect(r2.status, 200u16)
            @Expect(bodyText(httpGet(env, "/api/admin/teams", token: token)).contains("\"selfService\":false"), true)

            // ③ owner 变更为非成员 → 400（只能转给现有成员）
            let r3 = httpPutJson(env, "/api/admin/teams/${tid}", "{\"ownerId\":" + uid2.toString() + "}", token: token)
            @Expect(r3.status, 400u16)
            @Expect(bodyText(r3).contains("成员"), true)

            // ④ 清空 owner（ownerId = 0）
            let r4 = httpPutJson(env, "/api/admin/teams/${tid}", "{\"ownerId\":0}", token: token)
            @Expect(r4.status, 200u16)
            @Expect(bodyText(httpGet(env, "/api/admin/teams", token: token)).contains("\"ownerId\":0"), true)

            // ⑤ body 非法 → 400
            @Expect(httpPutJson(env, "/api/admin/teams/${tid}", "junk", token: token).status, 400u16)
        } finally {
            env.close()
        }
    }

    // 管理端关联端点：GET 空 → PUT 组织 → PUT 包 → 校验失败分支
    @TestCase
    func testAdminTeamLinks(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            let tid = mkTeamViaApi(env, token, "links")
            @Expect(tid > 0, true)

            // 初始为空
            let empty = httpGet(env, "/api/admin/teams/${tid}/links", token: token)
            @Expect(empty.status, 200u16)
            @Expect(bodyText(empty).contains("\"organizationIds\":[]"), true)

            // 建组织并关联
            let orgResp = httpPostJson(env, "/api/admin/organizations", "{\"name\":\"linkorg\"}", token: token)
            let orgId = extractJsonInt(bodyText(orgResp), "id")
            @Expect(orgId > 0, true)
            let setOrgs = httpPutJson(env, "/api/admin/teams/${tid}/links",
                "{\"organizationIds\":[" + orgId.toString() + "]}", token: token)
            @Expect(setOrgs.status, 200u16)
            @Expect(bodyText(httpGet(env, "/api/admin/teams/${tid}/links", token: token)).contains(orgId.toString()), true)

            // 关联不存在的组织 → 400
            @Expect(httpPutJson(env, "/api/admin/teams/${tid}/links",
                "{\"organizationIds\":[99999]}", token: token).status, 400u16)

            // 关联不存在的包 → 400
            @Expect(httpPutJson(env, "/api/admin/teams/${tid}/links",
                "{\"packages\":[{\"organization\":\"x\",\"name\":\"ghost\"}]}", token: token).status, 400u16)

            // body 非法 → 400
            @Expect(httpPutJson(env, "/api/admin/teams/${tid}/links", "junk", token: token).status, 400u16)
            // 团队不存在 → 404
            @Expect(httpGet(env, "/api/admin/teams/99999/links", token: token).status, 404u16)
            @Expect(httpPutJson(env, "/api/admin/teams/99999/links", "{}", token: token).status, 404u16)

            // 成员端点：不存在团队 404 / 加不存在的用户 404 / 非法 userId 400
            @Expect(httpGet(env, "/api/admin/teams/99999/members", token: token).status, 404u16)
            @Expect(httpPostJson(env, "/api/admin/teams/${tid}/members",
                "{\"userId\":99999}", token: token).status, 404u16)
            @Expect(httpPostJson(env, "/api/admin/teams/${tid}/members", "junk", token: token).status, 400u16)
            @Expect(httpPostJson(env, "/api/admin/teams/99999/members", "{\"userId\":1}",
                token: token).status, 404u16)
        } finally {
            env.close()
        }
    }

    // 门户关联端点：owner 自助 PUT/GET；非 owner 403；非法 body 400
    @TestCase
    func testPortalTeamLinks(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            let ownerToken = seedPlainUserToken(env, token, username: "linkown", password: "LinkOwn12")
            let otherToken = seedPlainUserToken(env, token, username: "linkother", password: "LinkOth12")
            let tid = mkTeamViaApi(env, token, "plinks", ownerName: "linkown", selfService: true)
            @Expect(tid > 0, true)
            let orgResp = httpPostJson(env, "/api/admin/organizations", "{\"name\":\"plinkorg\"}", token: token)
            let orgId = extractJsonInt(bodyText(orgResp), "id")

            // owner 设组织关联 → 200；GET 能看到
            let set = httpPutJson(env, "/api/user/me/teams/${tid}/links",
                "{\"organizationIds\":[" + orgId.toString() + "]}", token: ownerToken)
            @Expect(set.status, 200u16)
            @Expect(bodyText(httpGet(env, "/api/user/me/teams/${tid}/links", token: ownerToken)).contains(orgId.toString()), true)

            // 非 owner → 403；GET 也 403
            @Expect(httpPutJson(env, "/api/user/me/teams/${tid}/links",
                "{\"organizationIds\":[]}", token: otherToken).status, 403u16)
            @Expect(httpGet(env, "/api/user/me/teams/${tid}/links", token: otherToken).status, 403u16)

            // owner 清空关联 → 200
            @Expect(httpPutJson(env, "/api/user/me/teams/${tid}/links",
                "{\"organizationIds\":[]}", token: ownerToken).status, 200u16)

            // 非法 body → 400
            @Expect(httpPutJson(env, "/api/user/me/teams/${tid}/links", "junk", token: ownerToken).status, 400u16)
            // 团队不存在 → 404
            @Expect(httpGet(env, "/api/user/me/teams/99999/links", token: ownerToken).status, 404u16)
        } finally {
            env.close()
        }
    }

    // 管理端自助开关的更多分支：body 非法 400
    @TestCase
    func testSelfServiceBodyValidation(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            let _ = seedPlainUserToken(env, token, username: "ssown", password: "SsOwn123")
            let tid = mkTeamViaApi(env, token, "ssval", ownerName: "ssown", selfService: false)
            @Expect(httpPutJson(env, "/api/admin/teams/${tid}/self-service", "junk", token: token).status, 400u16)
            // 关闭自助不需要 owner（只有开启才要求）
            @Expect(httpPutJson(env, "/api/admin/teams/${tid}/self-service", "{\"enabled\":false}",
                token: token).status, 200u16)
        } finally {
            env.close()
        }
    }
}
