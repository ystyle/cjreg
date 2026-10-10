// 用户门户只读 API handler 级测试（/api/user/*）
//
// 走真实 HTTP：覆盖 session 鉴权三态、发布 token 重置、我的包（分页/搜索）、我的团队。
package ystyle::cjreg.server

import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.util.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

// 造一个"某用户发布过"的包版本
func seedOwnedPkg(env: HttpEnv, org: String, name: String, version: String, publisherId: Int64): Int64 {
    let d = PackageDoc()
    d.organization = org
    d.name = name
    d.version = version
    d.cjcVersion = "1.1.3"
    d.artifactType = "src"
    d.publisherId = publisherId
    d.deletedAt = 0
    d.createdAt = 1000
    d.updatedAt = 2000
    d.sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
    env.pkgStore.save(d)
    d.id
}

@Test
class UserPortalApiTest {
    // 匿名访问 /api/user/* 一律 401
    @TestCase
    func testAnonymousRejected(): Unit {
        let env = newHttpEnv()
        try {
            @Expect(httpGet(env, "/api/user/me").status, 401u16)
            @Expect(httpPostJson(env, "/api/user/me/publish-token", "").status, 401u16)
            @Expect(httpGet(env, "/api/user/me/packages").status, 401u16)
            @Expect(httpGet(env, "/api/user/me/teams").status, 401u16)
        } finally {
            env.close()
        }
    }

    // 无效 token → 401
    @TestCase
    func testInvalidTokenRejected(): Unit {
        let env = newHttpEnv()
        try {
            @Expect(httpGet(env, "/api/user/me", token: "bogus").status, 401u16)
        } finally {
            env.close()
        }
    }

    // me：普通用户字段齐；发布 token 打码（不回明文）
    @TestCase
    func testMeMasksPublishToken(): Unit {
        let env = newHttpEnv()
        try {
            let adminToken = seedAdminToken(env)
            let userToken = seedPlainUserToken(env, adminToken, username: "alice", password: "AlicePass1")
            let resp = httpGet(env, "/api/user/me", token: userToken)
            @Expect(resp.status, 200u16)
            let body = bodyText(resp)
            @Expect(body.contains("alice"), true)
            @Expect(body.contains("permissionMode"), true)
            // 打码后的 token 不应是 32+ 位明文原样（maskToken 会插省略号）
            @Expect(body.contains("publishToken"), true)
            @Expect(body.contains("\"publishToken\":\"********\""), false)
        } finally {
            env.close()
        }
    }

    // 重置发布 token：返回新明文；旧 token 立即失效，新 token 可发布
    @TestCase
    func testResetPublishTokenInvalidatesOld(): Unit {
        let env = newHttpEnv(mode: "open")
        try {
            let adminToken = seedAdminToken(env)
            let userToken = seedPlainUserToken(env, adminToken, username: "bob", password: "BobPass123")

            let first = httpPostJson(env, "/api/user/me/publish-token", "", token: userToken)
            @Expect(first.status, 200u16)
            let oldPub = extractJsonString(bodyText(first), "publishToken")
            @Expect(oldPub.isEmpty(), false)

            let second = httpPostJson(env, "/api/user/me/publish-token", "", token: userToken)
            @Expect(second.status, 200u16)
            let newPub = extractJsonString(bodyText(second), "publishToken")
            @Expect(newPub.isEmpty(), false)
            @Expect(newPub == oldPub, false)

            // 新 token 可发布
            let art = "x".toArray()
            let okPost = httpPostRaw(env, "/pkg/portalpub?organization=acme",
                publishBody("acme", "portalpub", "1.0.0", art, sha256: sha256Hex(art)), token: newPub)
            @Expect(okPost.status, 200u16)
            // 旧 token 已失效 → 401
            let oldPost = httpPostRaw(env, "/pkg/portalpub2?organization=acme",
                publishBody("acme", "portalpub2", "1.0.0", art, sha256: sha256Hex(art)), token: oldPub)
            @Expect(oldPost.status, 401u16)
        } finally {
            env.close()
        }
    }

    // 我的包：只回自己发过的；搜索按名字/组织；分页参数（含非法回退）
    @TestCase
    func testMyPackages(): Unit {
        let env = newHttpEnv()
        try {
            let adminToken = seedAdminToken(env)
            let userToken = seedPlainUserToken(env, adminToken, username: "carol", password: "CarolPass1")
            let me = bodyText(httpGet(env, "/api/user/me", token: userToken))
            let myId = extractJsonInt(me, "id")
            @Expect(myId > 0, true)

            let _ = seedOwnedPkg(env, "acme", "mine", "1.0.0", myId)
            let _ = seedOwnedPkg(env, "acme", "mine", "1.1.0", myId)
            let _ = seedOwnedPkg(env, "other", "theirs", "1.0.0", 999)

            let all = httpGet(env, "/api/user/me/packages", token: userToken)
            @Expect(all.status, 200u16)
            let allBody = bodyText(all)
            @Expect(allBody.contains("mine"), true)
            @Expect(allBody.contains("theirs"), false)
            @Expect(extractJsonInt(allBody, "total") >= 1, true)

            // 搜索命中
            @Expect(bodyText(httpGet(env, "/api/user/me/packages?q=min", token: userToken)).contains("mine"), true)
            // 搜索不命中
            @Expect(extractJsonInt(bodyText(httpGet(env, "/api/user/me/packages?q=zzz", token: userToken)), "total"), 0)
            // 分页参数（非法值走 fallback，不报错）
            @Expect(httpGet(env, "/api/user/me/packages?page=abc&size=-5", token: userToken).status, 200u16)
            @Expect(httpGet(env, "/api/user/me/packages?page=1&size=1", token: userToken).status, 200u16)
        } finally {
            env.close()
        }
    }

    // 我的团队：无团队时返回空列表；加入团队后能列出（含权限与关联包）
    @TestCase
    func testMyTeams(): Unit {
        let env = newHttpEnv(mode: "team")
        try {
            let adminToken = seedAdminToken(env)
            let userToken = seedPlainUserToken(env, adminToken, username: "dave", password: "DavePass12")
            let myId = extractJsonInt(bodyText(httpGet(env, "/api/user/me", token: userToken)), "id")

            // 初始：无团队
            let empty = httpGet(env, "/api/user/me/teams", token: userToken)
            @Expect(empty.status, 200u16)
            @Expect(bodyText(empty).contains("\"permissionMode\":\"team\""), true)

            // 造一个团队并加入
            let now = auditNowMs()
            let teamId = env.adminData.createTeam("core", now, displayName: "核心组", permission: "write")
            env.adminData.addTeamMember(teamId, myId)
            env.adminData.setTeamPackages(teamId, [("acme", "mine")], now)

            let withTeam = bodyText(httpGet(env, "/api/user/me/teams", token: userToken))
            @Expect(withTeam.contains("core"), true)
            @Expect(withTeam.contains("write"), true)
            @Expect(withTeam.contains("acme::mine"), true)
        } finally {
            env.close()
        }
    }
}
