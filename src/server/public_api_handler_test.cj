// 公开只读 API handler 级测试（/api/stats、/api/packages[*]、/api/organizations）
//
// 走真实 HTTP：覆盖开放/私有仓两种鉴权口径、查询参数（q/organization/category/sort/page/size）、
// 包级 read 权限过滤，以及命中/未命中分支。
package ystyle::cjreg.server

import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

// 造一个带展示字段的包版本（公开读模型要看描述/分类/组织）
func seedPublicPkg(env: HttpEnv, org: String, name: String, version: String,
                   desc!: String = "", category!: String = "", downloads!: Int64 = 0,
                   deleted!: Bool = false): Int64 {
    let d = PackageDoc()
    d.organization = org
    d.name = name
    d.version = version
    d.description = desc
    d.cjcVersion = "1.1.3"
    d.artifactType = "src"
    d.downloadCount = downloads
    d.deletedAt = if (deleted) { 1 } else { 0 }
    d.createdAt = 1000
    d.updatedAt = 2000
    d.sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
    if (!category.isEmpty()) {
        d.category.add(category)
    }
    env.pkgStore.save(d)
    d.id
}

@Test
class PublicReadApiTest {
    // 统计端点：开放仓匿名可用，字段齐
    @TestCase
    func testStatsOpenMode(): Unit {
        let env = newHttpEnv()
        try {
            let _ = seedPublicPkg(env, "acme", "one", "1.0.0")
            let resp = httpGet(env, "/api/stats")
            @Expect(resp.status, 200u16)
            let body = bodyText(resp)
            @Expect(body.contains("packages"), true)
            @Expect(body.contains("users"), true)
        } finally {
            env.close()
        }
    }

    // 包列表：组织过滤 + 软删不可见 + 描述出现在结果里
    @TestCase
    func testListPackagesFiltering(): Unit {
        let env = newHttpEnv()
        try {
            let _ = seedPublicPkg(env, "acme", "visible", "1.0.0", desc: "看得见")
            let _ = seedPublicPkg(env, "acme", "hidden", "1.0.0", deleted: true)
            let _ = seedPublicPkg(env, "other", "elsewhere", "1.0.0")

            let all = bodyText(httpGet(env, "/api/packages"))
            @Expect(all.contains("visible"), true)
            @Expect(all.contains("hidden"), false)

            let byOrg = bodyText(httpGet(env, "/api/packages?organization=acme"))
            @Expect(byOrg.contains("visible"), true)
            @Expect(byOrg.contains("elsewhere"), false)
        } finally {
            env.close()
        }
    }

    // 包列表：q 关键字（名称/描述/组织）、org::name 语法、分类 OR、排序键、分页参数
    @TestCase
    func testListPackagesQueryParams(): Unit {
        let env = newHttpEnv()
        try {
            let _ = seedPublicPkg(env, "acme", "jsonrpc", "0.7.6", desc: "RPC 框架", category: "Web", downloads: 5)
            let _ = seedPublicPkg(env, "acme", "jsonvalue", "1.0.0", desc: "JSON 解析", category: "JSON", downloads: 50)
            let _ = seedPublicPkg(env, "beta", "tomlcj", "1.0.0", desc: "TOML", category: "Config")

            // 按名称
            @Expect(bodyText(httpGet(env, "/api/packages?q=jsonrpc")).contains("jsonrpc"), true)
            // org::name 语法
            let scoped = bodyText(httpGet(env, "/api/packages?q=beta::tomlcj"))
            @Expect(scoped.contains("tomlcj"), true)
            @Expect(scoped.contains("jsonrpc"), false)
            // 分类（逗号分隔 OR）
            let byCat = bodyText(httpGet(env, "/api/packages?category=Web,JSON"))
            @Expect(byCat.contains("jsonrpc"), true)
            @Expect(byCat.contains("jsonvalue"), true)
            @Expect(byCat.contains("tomlcj"), false)
            // 排序键：downloads / name / updated 都不该报错
            @Expect(httpGet(env, "/api/packages?sort=downloads").status, 200u16)
            @Expect(httpGet(env, "/api/packages?sort=name").status, 200u16)
            @Expect(httpGet(env, "/api/packages?sort=updated").status, 200u16)
            // 分页参数（含非法值走 fallback）
            @Expect(httpGet(env, "/api/packages?page=1&size=2").status, 200u16)
            @Expect(httpGet(env, "/api/packages?page=abc&size=xyz").status, 200u16)
            // 无命中
            @Expect(extractJsonInt(bodyText(httpGet(env, "/api/packages?q=zzz-nope")), "total"), 0)
        } finally {
            env.close()
        }
    }

    // 包详情：存在 200（含版本列表）；不存在 404
    @TestCase
    func testPackageDetailBranches(): Unit {
        let env = newHttpEnv()
        try {
            let _ = seedPublicPkg(env, "acme", "detailed", "1.0.0", desc: "详情")
            let _ = seedPublicPkg(env, "acme", "detailed", "1.1.0", desc: "详情新")

            let ok = httpGet(env, "/api/packages/detailed?organization=acme")
            @Expect(ok.status, 200u16)
            let body = bodyText(ok)
            @Expect(body.contains("1.0.0"), true)
            @Expect(body.contains("1.1.0"), true)

            @Expect(httpGet(env, "/api/packages/ghost?organization=acme").status, 404u16)
        } finally {
            env.close()
        }
    }

    // 版本详情：存在 200；版本不存在 404
    @TestCase
    func testVersionDetailBranches(): Unit {
        let env = newHttpEnv()
        try {
            let _ = seedPublicPkg(env, "acme", "versioned", "1.0.0")
            let ok = httpGet(env, "/api/packages/versioned/1.0.0?organization=acme")
            @Expect(ok.status, 200u16)
            @Expect(bodyText(ok).contains("1.0.0"), true)

            @Expect(httpGet(env, "/api/packages/versioned/9.9.9?organization=acme").status, 404u16)
        } finally {
            env.close()
        }
    }

    // 组织列表：有数据的组织出现在结果里
    @TestCase
    func testOrganizations(): Unit {
        let env = newHttpEnv()
        try {
            let _ = seedPublicPkg(env, "acme", "inorg", "1.0.0")
            let _ = env.adminData.createOrg("acme", "Acme Inc", 1, auditNowMs())
            let resp = httpGet(env, "/api/organizations")
            @Expect(resp.status, 200u16)
            @Expect(bodyText(resp).contains("acme"), true)
        } finally {
            env.close()
        }
    }

    // 私有仓（require_auth=true）：匿名一律 401；带有效 token 可通过
    @TestCase
    func testRequireAuthMode(): Unit {
        let env = newHttpEnv(requireAuth: true)
        try {
            @Expect(httpGet(env, "/api/stats").status, 401u16)
            @Expect(httpGet(env, "/api/packages").status, 401u16)
            @Expect(httpGet(env, "/api/organizations").status, 401u16)

            let token = seedAdminToken(env)
            @Expect(httpGet(env, "/api/stats", token: token).status, 200u16)
            @Expect(httpGet(env, "/api/packages", token: token).status, 200u16)
            @Expect(httpGet(env, "/api/organizations", token: token).status, 200u16)
        } finally {
            env.close()
        }
    }

    // 私有仓 + 无效 token → 401
    @TestCase
    func testRequireAuthInvalidToken(): Unit {
        let env = newHttpEnv(requireAuth: true)
        try {
            @Expect(httpGet(env, "/api/stats", token: "bogus").status, 401u16)
        } finally {
            env.close()
        }
    }

    // 私有仓包级权限：管理员直通读；无权限的普通用户对未授权包 403
    @TestCase
    func testPackageLevelReadPermission(): Unit {
        let env = newHttpEnv(requireAuth: true)
        try {
            let adminToken = seedAdminToken(env)
            let _ = seedPublicPkg(env, "secretorg", "secretpkg", "1.0.0")

            // 管理员是超集：可读
            @Expect(httpGet(env, "/api/packages/secretpkg?organization=secretorg", token: adminToken).status, 200u16)

            // 普通用户（无团队/包授权）→ 403
            let userToken = seedPlainUserToken(env, adminToken, username: "plain", password: "PlainPass1")
            @Expect(userToken.isEmpty(), false)
            @Expect(httpGet(env, "/api/packages/secretpkg?organization=secretorg", token: userToken).status, 403u16)
        } finally {
            env.close()
        }
    }
}
