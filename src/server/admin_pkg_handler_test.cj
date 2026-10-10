// 管理 API · 包管理 handler 级测试（列表 / 详情 / 三级删除闭环 / 重拉）
//
// 走真实 HTTP：覆盖软删 → 硬删 → 恢复的生命周期状态机、分页与过滤参数、
// 以及"本地发布的版本不可重拉"这类护栏。
package ystyle::cjreg.server

import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.util.*
import std.collection.*
import std.fs.{Directory, exists}
import std.unittest.*
import std.unittest.testmacro.*

// 用磁盘 blob 的夹具造一个"制品在本地"的版本（硬删/恢复会真去动制品）
func seedPkgWithArtifact(env: HttpEnv, org: String, name: String, version: String,
                         content!: String = "artifact"): Int64 {
    let payload = content.toArray()
    let sum = sha256Hex(payload)
    env.blobStore.put(sum, payload)
    let d = PackageDoc()
    d.organization = org
    d.name = name
    d.version = version
    d.sha256 = sum
    d.artifactType = "src"
    d.tarballSize = payload.size
    d.deletedAt = 0
    d.createdAt = 10
    d.updatedAt = 20
    env.pkgStore.save(d)
    d.id
}

@Test
class AdminPackageApiTest {
    // 列表：组织/名字过滤、includeDeleted 语义、分页窗口、空结果
    @TestCase
    func testListPackagesFiltering(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            let _ = seedPackage(env, "acme", "alpha", "1.0.0")
            let _ = seedPackage(env, "acme", "alpha", "1.1.0")
            let _ = seedPackage(env, "acme", "beta", "2.0.0")
            let _ = seedPackage(env, "other", "gamma", "3.0.0")
            let _ = seedPackage(env, "acme", "gone", "0.1.0", deleted: true)

            // 全量（不含软删）
            let all = httpGet(env, "/api/admin/packages", token: token)
            @Expect(all.status, 200u16)
            @Expect(extractJsonInt(bodyText(all), "total"), 4)

            // 按组织
            let byOrg = httpGet(env, "/api/admin/packages?organization=acme", token: token)
            @Expect(extractJsonInt(bodyText(byOrg), "total"), 3)

            // 按名字
            let byName = httpGet(env, "/api/admin/packages?name=alpha", token: token)
            @Expect(extractJsonInt(bodyText(byName), "total"), 2)

            // 含软删
            let withDeleted = httpGet(env, "/api/admin/packages?includeDeleted=1", token: token)
            @Expect(extractJsonInt(bodyText(withDeleted), "total"), 5)

            // 分页：size=1 只回 1 条（items 非空）
            // 注意：响应体是流，只能读一次 —— 多次断言先把 bodyText 取到变量
            let paged = httpGet(env, "/api/admin/packages?page=1&size=1", token: token)
            let pagedBody = bodyText(paged)
            @Expect(extractJsonInt(pagedBody, "total"), 4)
            @Expect(pagedBody.contains("\"items\""), true)
            @Expect(pagedBody.contains("\"version\""), true)

            // 无命中
            @Expect(extractJsonInt(bodyText(httpGet(env, "/api/admin/packages?name=zzz", token: token)), "total"), 0)
        } finally {
            env.close()
        }
    }

    // 单版本详情：存在 200（含 sha/README/制品可用）；不存在 404；id 非法 404（解析成 0）
    @TestCase
    func testGetPackageVersion(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            let id = seedPackage(env, "acme", "detail", "1.0.0", desc: "详情用")
            let ok = httpGet(env, "/api/admin/packages/${id}", token: token)
            @Expect(ok.status, 200u16)
            let okBody = bodyText(ok)
            @Expect(okBody.contains("详情用"), true)
            @Expect(okBody.contains("artifactPresent"), true)
            @Expect(okBody.contains("\"readmeLength\""), true)

            @Expect(httpGet(env, "/api/admin/packages/99999", token: token).status, 404u16)
            @Expect(httpGet(env, "/api/admin/packages/abc", token: token).status, 404u16)
        } finally {
            env.close()
        }
    }

    // 三级删除闭环：软删 → 可见性变化 → 硬删 → 记录消失
    @TestCase
    func testSoftThenHardDelete(): Unit {
        let env = newHttpEnv(tmpDir: covScratch("lifecycle"))
        try {
            let token = seedAdminToken(env)
            let id = seedPkgWithArtifact(env, "acme", "gone", "1.0.0")

            // 软删
            let soft = httpDelete(env, "/api/admin/packages/${id}", token: token)
            @Expect(soft.status, 200u16)
            @Expect(env.pkgStore.getById(id).getOrThrow().deletedAt > 0, true)

            // 未 includeDeleted 的列表里看不到
            @Expect(extractJsonInt(bodyText(httpGet(env, "/api/admin/packages?name=gone", token: token)), "total"), 0)
            @Expect(extractJsonInt(bodyText(httpGet(env, "/api/admin/packages?name=gone&includeDeleted=1", token: token)), "total"), 1)

            // 硬删（需先软删）
            let hard = httpDelete(env, "/api/admin/packages/${id}/hard", token: token)
            @Expect(hard.status, 200u16)
            @Expect(env.pkgStore.getById(id).isNone(), true)
        } finally {
            env.close()
        }
    }

    // 硬删未软删的版本 → 409（NotDeleted，语义冲突）
    @TestCase
    func testHardDeleteRequiresSoftFirst(): Unit {
        let env = newHttpEnv(tmpDir: covScratch("hard-first"))
        try {
            let token = seedAdminToken(env)
            let id = seedPkgWithArtifact(env, "acme", "still", "1.0.0")
            let resp = httpDelete(env, "/api/admin/packages/${id}/hard", token: token)
            @Expect(resp.status, 409u16)
        } finally {
            env.close()
        }
    }

    // 恢复：软删后 restore 回到正常态；对未软删的版本幂等成功
    @TestCase
    func testRestoreLifecycle(): Unit {
        let env = newHttpEnv(tmpDir: covScratch("restore"))
        try {
            let token = seedAdminToken(env)
            let id = seedPkgWithArtifact(env, "acme", "back", "1.0.0")
            @Expect(httpDelete(env, "/api/admin/packages/${id}", token: token).status, 200u16)
            @Expect(env.pkgStore.getById(id).getOrThrow().deletedAt > 0, true)

            let restored = httpPutJson(env, "/api/admin/packages/${id}/restore", "", token: token)
            @Expect(restored.status, 200u16)
            @Expect(env.pkgStore.getById(id).getOrThrow().deletedAt, 0)

            // 再恢复一次：语义上已是目标状态 → 仍 200（幂等）
            @Expect(httpPutJson(env, "/api/admin/packages/${id}/restore", "", token: token).status, 200u16)
        } finally {
            env.close()
        }
    }

    // 生命周期端点参数与不存在分支：id 非法 400、不存在 404
    @TestCase
    func testLifecycleErrorBranches(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            @Expect(httpDelete(env, "/api/admin/packages/abc", token: token).status, 400u16)
            @Expect(httpDelete(env, "/api/admin/packages/99999", token: token).status, 404u16)
            @Expect(httpDelete(env, "/api/admin/packages/99999/hard", token: token).status, 404u16)
            @Expect(httpPutJson(env, "/api/admin/packages/99999/restore", "", token: token).status, 404u16)
        } finally {
            env.close()
        }
    }

    // 重拉护栏：本地发布的版本本地才是权威 → 409 local_owned（连上游都不问）
    @TestCase
    func testRefetchLocalOwnedRejected(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            let id = seedPackage(env, "acme", "localpkg", "1.0.0")
            let resp = httpPostJson(env, "/api/admin/packages/${id}/refetch", "", token: token)
            @Expect(resp.status, 409u16)
            @Expect(bodyText(resp).contains("local_owned"), true)
        } finally {
            env.close()
        }
    }

    // 重拉参数与不存在分支：id 非法 400、版本不存在 404
    @TestCase
    func testRefetchErrorBranches(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            @Expect(httpPostJson(env, "/api/admin/packages/abc/refetch", "", token: token).status, 400u16)
            @Expect(httpPostJson(env, "/api/admin/packages/99999/refetch", "", token: token).status, 404u16)
        } finally {
            env.close()
        }
    }

    // 审计留痕：软删一次应能在管理日志里查到 delete_package
    @TestCase
    func testLifecycleWritesAudit(): Unit {
        let env = newHttpEnv(tmpDir: covScratch("audit"))
        try {
            let token = seedAdminToken(env)
            let id = seedPkgWithArtifact(env, "acme", "audited", "1.0.0")
            @Expect(httpDelete(env, "/api/admin/packages/${id}", token: token).status, 200u16)
            let logs = httpGet(env, "/api/admin/logs/admin?keyword=delete_package", token: token)
            @Expect(logs.status, 200u16)
            @Expect(bodyText(logs).contains("delete_package"), true)
        } finally {
            env.close()
        }
    }
}
