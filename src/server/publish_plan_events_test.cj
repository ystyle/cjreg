// 迭代 2 的两项验收：① 索引等待必须「版本出现 **且 SHA256 一致**」才算就绪；
// ② 发布计划进度事件序列（running 只有 progress；终态补 done）。
package ystyle::cjreg.server

import ystyle::cjreg.store.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

// 索引 NDJSON 的一行（字段名对齐索引协议：name/version/sha256sum）
func indexLine(name: String, version: String, sha: String): String {
    "{\"name\":\"${name}\",\"version\":\"${version}\",\"sha256sum\":\"${sha}\",\"deps\":[]}"
}

@Test
func testIndexHasVersionWithShaRequiresMatchingSha() {
    let body = indexLine("a", "1.0.0", "aaaa") + "\n" + indexLine("a", "1.0.1", "bbbb")
    // 版本在、sha 一致 → 就绪
    @Expect(indexHasVersionWithSha(body, "a", "1.0.0", "aaaa"), true)
    // 版本在、sha 不一致 → **不就绪**（目标仓可能先收录过同版本的别的产物）
    @Expect(indexHasVersionWithSha(body, "a", "1.0.0", "cccc"), false)
    // 期望 sha 为空 / 索引没带 sha → 退化为「版本存在」
    @Expect(indexHasVersionWithSha(body, "a", "1.0.0", ""), true)
    // 版本不在 → 不就绪
    @Expect(indexHasVersionWithSha(body, "a", "9.9.9", "aaaa"), false)
}

@Test
func testWaitIndexReadyRejectsMismatchedSha() {
    // 目标仓始终返回「版本在、sha 是旧的」：期望 sha 不匹配 → 必须超时（不一定假就绪）
    let staleSha = { _: String, _: String => IndexProbe(200, indexLine("a", "1.0.0", "oldsha")) }
    // pollTimeoutSec = 1：契约里 0 表示「一直等」，这里要的是"等不到就超时"
    let code = waitIndexReady(staleSha, "", "a", "1.0.0", 1,
        sha: "newsha", ladder: [0], steadySec: 0)
    @Expect(code == WAIT_TIMEOUT, true)

    // 目标仓返回一致 sha → 立即就绪
    let freshSha = { _: String, _: String => IndexProbe(200, indexLine("a", "1.0.0", "newsha")) }
    let code2 = waitIndexReady(freshSha, "", "a", "1.0.0", 1,
        sha: "newsha", ladder: [0], steadySec: 0)
    @Expect(code2 == WAIT_READY, true)
}

@Test
func testPlanEventsPayloadRunningHasNoDone() {
    let plan = PlanDoc()
    plan.id = 7
    plan.status = "running"
    plan.totalCount = 2
    plan.completedCount = 1
    let items = ArrayList<PlanItemDoc>()
    let a = PlanItemDoc()
    a.id = 11
    a.packageOrg = "demo"
    a.packageName = "mathUtils"
    a.packageVersion = "1.0.0"
    a.status = "completed"
    items.add(a)
    let b = PlanItemDoc()
    b.id = 12
    b.packageOrg = "demo"
    b.packageName = "strUtils"
    b.packageVersion = "1.0.0"
    b.status = "waiting_index"
    items.add(b)

    let s = buildPlanEventsPayload(plan, items)
    @Expect(s.startsWith("event: progress\n"), true)
    @Expect(s.contains("\"planId\":7"), true)
    @Expect(s.contains("\"status\":\"running\""), true)
    @Expect(s.contains("\"completed\":1"), true)
    @Expect(s.contains("\"name\":\"mathUtils\""), true)
    @Expect(s.contains("\"status\":\"waiting_index\""), true)
    // running 不是终态：不发 done，客户端会自动重连取下一份快照
    @Expect(s.contains("event: done"), false)
    // SSE 事件必须以空行结束
    @Expect(s.endsWith("\n\n"), true)
    // 帧逐字契约：`event: progress` + `data: <紧凑 JSON>` + 空行；data 的字段顺序即契约
    @Expect(s, "event: progress\ndata: {\"planId\":7,\"status\":\"running\",\"completed\":1,\"total\":2," +
        "\"lastError\":\"\",\"items\":[{\"id\":11,\"org\":\"demo\",\"name\":\"mathUtils\"," +
        "\"version\":\"1.0.0\",\"status\":\"completed\",\"error\":\"\"},{\"id\":12,\"org\":\"demo\"," +
        "\"name\":\"strUtils\",\"version\":\"1.0.0\",\"status\":\"waiting_index\",\"error\":\"\"}]}\n\n")
}

@Test
func testPlanEventsPayloadTerminalEmitsDone() {
    let plan = PlanDoc()
    plan.id = 9
    plan.status = "completed"
    plan.totalCount = 1
    plan.completedCount = 1
    let s = buildPlanEventsPayload(plan, ArrayList<PlanItemDoc>())
    @Expect(s.contains("event: progress"), true)
    @Expect(s.contains("event: done"), true)
    @Expect(s.contains("\"status\":\"completed\""), true)
    // 终态帧逐字契约：progress 快照之后紧跟 done 帧（各以空行结束）
    @Expect(s, "event: progress\ndata: {\"planId\":9,\"status\":\"completed\",\"completed\":1,\"total\":1," +
        "\"lastError\":\"\",\"items\":[]}\n\nevent: done\ndata: {\"planId\":9,\"status\":\"completed\"}\n\n")
    // 计划级错误也要带给客户端（刷新页面后仍能解释为什么停下来）
    let failed = PlanDoc()
    failed.id = 10
    failed.status = "failed"
    failed.lastError = "目标仓 429 限流"
    let s2 = buildPlanEventsPayload(failed, ArrayList<PlanItemDoc>())
    @Expect(s2.contains("429"), true)
    @Expect(s2.contains("event: done"), true)
}
