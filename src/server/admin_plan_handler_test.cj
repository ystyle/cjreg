// 管理 API · 发布计划与 resolve 诊断 handler 级测试
//
// 覆盖 resolve 诊断端点、analyze（含目标仓对照参数）、execute 的校验分支、
// SSE 进度流端点（决赛演示点）、跳过单项的归属校验。
package ystyle::cjreg.server

import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.config.*
import stdx.net.http.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

// 从 SSE 响应体里取某个 event 行之后的 data 行
func sseDataOf(body: String, event: String): String {
    let marker = "event: " + event
    match (body.indexOf(marker)) {
        case Some(i) =>
            let rest = body[i..body.size]
            match (rest.indexOf("data: ")) {
                case Some(j) =>
                    let from = rest[(j + 6)..rest.size]
                    match (from.indexOf("\n")) {
                        case Some(k) => from[0..k]
                        case None => from
                    }
                case None => ""
            }
        case None => ""
    }
}

@Test
class AdminPlanResolveApiTest {
    // resolve 诊断：缺 name → 400；给了 name 但本地没有 → 200（found=false，语义化结果）
    @TestCase
    func testResolveBranch(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            @Expect(httpGet(env, "/api/admin/resolve", token: token).status, 400u16)

            let resp = httpGet(env, "/api/admin/resolve?name=ghost&organization=acme&require=1.0.0", token: token)
            @Expect(resp.status, 200u16)
            let body = bodyText(resp)
            @Expect(body.contains("\"found\":false"), true)
            // selected 未命中时是显式 null（消费方靠它区分「没有候选」与「字段缺失」）
            @Expect(body.contains("\"selected\":null"), true)

            // resolve 的候选来自上游索引（fetchIndex），本地包不构成候选；
            // 无可用上游时 found 保持 false，但候选/trace 结构仍完整返回
            let _ = seedPackage(env, "acme", "here", "1.0.0")
            let hit = bodyText(httpGet(env, "/api/admin/resolve?name=here&organization=acme", token: token))
            @Expect(hit.contains("\"candidates\""), true)
            @Expect(hit.contains("\"trace\""), true)
        } finally {
            env.close()
        }
    }

    // analyze：缺 packages → 400；给了合法 packages → 200 且带拓扑序
    @TestCase
    func testAnalyzeBranches(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            @Expect(httpPostJson(env, "/api/admin/publish-plans/analyze", "{}", token: token).status, 400u16)
            @Expect(httpPostJson(env, "/api/admin/publish-plans/analyze", "junk", token: token).status, 400u16)

            let _ = seedPackage(env, "acme", "liba", "1.0.0")
            let body = "{\"packages\":[{\"organization\":\"acme\",\"name\":\"liba\",\"version\":\"1.0.0\"}]}"
            let resp = httpPostJson(env, "/api/admin/publish-plans/analyze", body, token: token)
            @Expect(resp.status, 200u16)
            let out = bodyText(resp)
            @Expect(out.contains("liba"), true)
            @Expect(out.contains("hasCycle"), true)
            // 目标仓对照字段是 snake_case（target_checked / target_error / publish_order）
            @Expect(out.contains("target_checked"), true)
            @Expect(out.contains("publish_order"), true)
        } finally {
            env.close()
        }
    }

    // execute：缺 target_url → 400；packages 指向本地不存在的包 → 400（no packages found locally）
    @TestCase
    func testExecuteValidationBranches(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            let noTarget = "{\"packages\":[{\"organization\":\"acme\",\"name\":\"x\",\"version\":\"1.0.0\"}]}"
            @Expect(httpPostJson(env, "/api/admin/publish-plans/execute", noTarget, token: token).status, 400u16)

            let _ = seedPackage(env, "acme", "real", "1.0.0")
            // 目标 URL 指向不可达地址：execute 会走到网络发送并失败/中止，但校验分支已覆盖
            let withTarget = "{\"packages\":[{\"organization\":\"acme\",\"name\":\"real\",\"version\":\"1.0.0\"}]," +
                "\"target_url\":\"http://127.0.0.1:9/registry\"}"
            let resp = httpPostJson(env, "/api/admin/publish-plans/execute", withTarget, token: token)
            // 网络不可达 → 执行器退避重试后报失败（仍返回 200 并带 report）
            @Expect(resp.status, 200u16)
            @Expect(bodyText(resp).contains("total"), true)
        } finally {
            env.close()
        }
    }

    // SSE 进度流：未认证 401、id 非法 400、计划不存在 404、存在时 event-stream + 快照帧
    @TestCase
    func testPlanEventsSse(): Unit {
        let env = newHttpEnv()
        try {
            @Expect(httpGet(env, "/api/admin/publish-plans/1/events").status, 401u16)

            let token = seedAdminToken(env)
            @Expect(httpGet(env, "/api/admin/publish-plans/abc/events", token: token).status, 400u16)
            @Expect(httpGet(env, "/api/admin/publish-plans/99999/events", token: token).status, 404u16)

            // 造一个计划（含一个条目）
            let now = auditNowMs()
            let planId = env.adminData.createPlan("演示计划", 0, 1, 0, now)
            let itemId = env.adminData.addPlanItem(planId, 0, "acme", "streamed", "1.0.0", 0, "", false)
            env.adminData.updatePlanItem(itemId, "completed", "", now)
            // done 帧只在计划进入终态（completed/failed）时追加 —— 造一个已完成计划
            env.adminData.updatePlanStatus(planId, "completed", 1, now)

            let resp = httpGet(env, "/api/admin/publish-plans/${planId}/events", token: token)
            @Expect(resp.status, 200u16)
            @Expect(headerOf(resp, "content-type").contains("text/event-stream"), true)
            @Expect(headerOf(resp, "cache-control"), "no-cache")
            let body = bodyText(resp)
            @Expect(body.contains("event: progress"), true)
            // 终态计划应带 done 帧
            @Expect(body.contains("event: done"), true)
            @Expect(sseDataOf(body, "done").contains("\"planId\""), true)
        } finally {
            env.close()
        }
    }

    // 跳过单项：id 非法 400；计划/条目不存在 404；归属不匹配 404；正常跳过 200
    @TestCase
    func testSkipPlanItem(): Unit {
        let env = newHttpEnv()
        try {
            let token = seedAdminToken(env)
            @Expect(httpPostJson(env, "/api/admin/publish-plans/abc/items/1/skip", "", token: token).status, 400u16)
            @Expect(httpPostJson(env, "/api/admin/publish-plans/1/items/99999/skip", "", token: token).status, 404u16)

            let now = auditNowMs()
            let planA = env.adminData.createPlan("A", 0, 1, 0, now)
            let planB = env.adminData.createPlan("B", 0, 1, 0, now)
            let item = env.adminData.addPlanItem(planA, 0, "acme", "skippable", "1.0.0", 0, "", false)

            // 归属校验：拿 B 的 planId 去改 A 的条目 → 404
            @Expect(httpPostJson(env, "/api/admin/publish-plans/${planB}/items/${item}/skip", "",
                token: token).status, 404u16)

            // 正确归属 → 200，条目状态变 skipped
            let ok = httpPostJson(env, "/api/admin/publish-plans/${planA}/items/${item}/skip", "", token: token)
            @Expect(ok.status, 200u16)
            @Expect(env.adminData.getPlanItem(item).getOrThrow().status, "skipped")
        } finally {
            env.close()
        }
    }

    // 目标仓 token 解析（纯函数）：显式优先；否则按 URL 匹配上游表
    @TestCase
    func testResolveTargetToken(): Unit {
        let ups = ArrayList<Upstream>()
        ups.add(Upstream(7, "mirror", "http://mirror.local/registry", true, 0, "stored-token", false, 0, 0))

        // 显式传入优先
        @Expect(resolveTargetToken("explicit", "http://mirror.local/registry", ups), "explicit")
        // 按 URL 匹配取上游 token
        @Expect(resolveTargetToken("", "http://mirror.local/registry", ups), "stored-token")
        // 匹配不到 → 空
        @Expect(resolveTargetToken("", "http://nowhere.local/registry", ups), "")
    }
}
