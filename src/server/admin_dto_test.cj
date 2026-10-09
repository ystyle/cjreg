// 管理面 DTO 的线格式（wire format）契约测试
//
// DTO 的字段名与字段顺序就是客户端契约，而 `contains(...)` 断言按不住顺序。
// 这里用改造前手工拼串的输出**逐字**做期望值（含 JSON 文本形态），
// 任何字段改名/移位/可选字段出现条件变化都会在这里现形。
package ystyle::cjreg.server

import std.collection.*
import std.unittest.testmacro.*

// ===== 认证与用户 =====

@Test
func testAdminAuthDtosJsonShapes() {
    // 登录回执（token 明文只此一次）
    @Expect(jsonText(LoginResp(7, "alice", true, "tok-1", 1700000000000)),
        "{\"id\":7,\"username\":\"alice\",\"isAdmin\":true,\"token\":\"tok-1\",\"expiresAt\":1700000000000}")
    // 管理端 me
    @Expect(jsonText(AdminMeResp(7, "alice", true, true, "pt-1")),
        "{\"id\":7,\"username\":\"alice\",\"isAdmin\":true,\"isActive\":true,\"publishToken\":\"pt-1\"}")
    // 用户列表是**裸数组**（不是 {total,items}）：外层由 ArrayList 直接序列化
    let rows = ArrayList<UserRowResp>()
    rows.add(UserRowResp(7, "alice", true, false))
    @Expect(jsonText(rows), "[{\"id\":7,\"username\":\"alice\",\"isAdmin\":true,\"isActive\":false}]")
    // 建用户 / 改角色回执
    @Expect(jsonText(UserAdminResp(7, "alice", true)), "{\"id\":7,\"username\":\"alice\",\"isAdmin\":true}")
    // 日志清理 / 跳过计划项
    @Expect(jsonText(DeletedResp(3)), "{\"deleted\":3}")
    @Expect(jsonText(SkipItemResp(42)), "{\"status\":\"ok\",\"itemId\":42}")
}

// ===== 审计日志 =====

@Test
func testAdminLogQueryJsonShape() {
    let items = ArrayList<LogRowDto>()
    items.add(LogRowDto(9, "admin", 1, "admin", "create_user", "ok", "bob", "d", "", "127.0.0.1", "curl", 123))
    @Expect(jsonText(LogQueryResp(1, 0, 50, items)),
        "{\"total\":1,\"offset\":0,\"limit\":50,\"items\":[{\"id\":9,\"kind\":\"admin\",\"actorId\":1," +
        "\"actorName\":\"admin\",\"action\":\"create_user\",\"status\":\"ok\",\"target\":\"bob\"," +
        "\"detail\":\"d\",\"error\":\"\",\"ipAddr\":\"127.0.0.1\",\"userAgent\":\"curl\",\"createdAt\":123}]}")
}

// ===== 包 =====

@Test
func testAdminPackageDtosJsonShapes() {
    let items = ArrayList<AdminPackageDto>()
    items.add(AdminPackageDto(5, "demo", "app", "1.0.0", 0, "abc", 10, 2, 1, 0, 100, 200))
    @Expect(jsonText(AdminPackageListResp(1, items)),
        "{\"total\":1,\"items\":[{\"id\":5,\"organization\":\"demo\",\"name\":\"app\",\"version\":\"1.0.0\"," +
        "\"deletedAt\":0,\"sha256\":\"abc\",\"tarballSize\":10,\"downloads\":2,\"publisherId\":1," +
        "\"upstreamId\":0,\"createdAt\":100,\"updatedAt\":200}]}")

    let detail = PackageVersionDetailDto(5, "demo", "app", "1.0.0", "1.1.0", "d", "src", true,
        ArrayList<String>(["a", "b"]), "r", "h", "doc", ArrayList<String>(["t"]), ArrayList<String>(["c"]),
        ArrayList<String>(["MIT"]), "abc", 10, 2, 1, "alice", 0, "", 0, 100, 200, "# hi", 4, true)
    @Expect(jsonText(detail),
        "{\"id\":5,\"organization\":\"demo\",\"name\":\"app\",\"version\":\"1.0.0\",\"cjcVersion\":\"1.1.0\"," +
        "\"description\":\"d\",\"artifactType\":\"src\",\"executable\":true,\"authors\":[\"a\",\"b\"]," +
        "\"repository\":\"r\",\"homepage\":\"h\",\"documentation\":\"doc\",\"tag\":[\"t\"]," +
        "\"category\":[\"c\"],\"license\":[\"MIT\"],\"sha256\":\"abc\",\"tarballSize\":10,\"downloads\":2," +
        "\"publisherId\":1,\"publisher\":\"alice\",\"upstreamId\":0,\"upstreamName\":\"\",\"deletedAt\":0," +
        "\"createdAt\":100,\"updatedAt\":200,\"readme\":\"# hi\",\"readmeLength\":4,\"artifactPresent\":true}")
}

// ===== 上游 =====

@Test
func testAdminUpstreamDtosJsonShapes() {
    let rows = ArrayList<UpstreamDto>()
    rows.add(UpstreamDto(1, "official", "https://x", true, true, 0, 86400, true, false))
    @Expect(jsonText(rows),
        "[{\"id\":1,\"name\":\"official\",\"url\":\"https://x\",\"enabled\":true,\"isOfficial\":true," +
        "\"priority\":0,\"cacheTtl\":86400,\"proxyEnabled\":true,\"asTarget\":false}]")
    @Expect(jsonText(UpstreamAddedResp(2, "backup", false, true, false)),
        "{\"id\":2,\"name\":\"backup\",\"isOfficial\":false,\"proxyEnabled\":true,\"asTarget\":false}")
}

// ===== resolve 诊断 =====

@Test
func testAdminResolveJsonShapes() {
    // 未命中：selected 是 null（**不是**省略字段），消费方靠它区分「没有候选」与「字段缺失」
    @Expect(jsonText(ResolveResp("crc", "ystyle", "1.0.0", false, false, "", Option<ResolveCandidateDto>.None,
        ArrayList<ResolveCandidateDto>(), ArrayList<String>(["a"]))),
        "{\"name\":\"crc\",\"org\":\"ystyle\",\"require\":\"1.0.0\",\"found\":false,\"replaced\":false," +
        "\"replacedBy\":\"\",\"selected\":null,\"candidates\":[],\"trace\":[\"a\"]}")
    // 命中：selected 与 candidates 同一形态（repo/version/sha256sum/conflict）
    let candidates = ArrayList<ResolveCandidateDto>()
    candidates.add(ResolveCandidateDto("official", "1.0.0", "aa", false))
    @Expect(jsonText(ResolveResp("crc", "ystyle", "1.0.0", true, false, "",
        Some(ResolveCandidateDto("official", "1.0.0", "aa", false)), candidates, ArrayList<String>())),
        "{\"name\":\"crc\",\"org\":\"ystyle\",\"require\":\"1.0.0\",\"found\":true,\"replaced\":false," +
        "\"replacedBy\":\"\",\"selected\":{\"repo\":\"official\",\"version\":\"1.0.0\",\"sha256sum\":\"aa\"," +
        "\"conflict\":false},\"candidates\":[{\"repo\":\"official\",\"version\":\"1.0.0\"," +
        "\"sha256sum\":\"aa\",\"conflict\":false}],\"trace\":[]}")
}

// ===== 发布计划 =====

@Test
func testAdminPlanDtosJsonShapes() {
    let order = ArrayList<PlanItemAnalysisDto>()
    order.add(PlanItemAnalysisDto("crc", "ystyle", "1.0.0", 1, "need_publish", true, "aa", "", "", "", false))
    @Expect(jsonText(PlanAnalyzeResp(true, "", order, false)),
        "{\"target_checked\":true,\"target_error\":\"\",\"publish_order\":[{\"name\":\"crc\"," +
        "\"org\":\"ystyle\",\"version\":\"1.0.0\",\"order\":1,\"category\":\"need_publish\",\"selected\":true," +
        "\"local_sha256\":\"aa\",\"remote_sha256\":\"\",\"requirement\":\"\",\"target_version\":\"\"," +
        "\"target_compared\":false}],\"hasCycle\":false}")

    @Expect(jsonText(PlanExecuteResp(1, 0, 1, 2, false, "", ArrayList<String>(["boom", "bang"]))),
        "{\"success\":1,\"skipped\":0,\"failed\":1,\"total\":2,\"aborted\":false,\"abort_reason\":\"\"," +
        "\"errors\":[\"boom\",\"bang\"]}")

    // SSE 帧的 data 部分（帧结构本身由 publish_plan_events_test 守）
    let rows = ArrayList<PlanProgressItemDto>()
    rows.add(PlanProgressItemDto(11, "demo", "mathUtils", "1.0.0", "completed", ""))
    @Expect(jsonText(PlanProgressDto(7, "running", 1, 2, "e", rows)),
        "{\"planId\":7,\"status\":\"running\",\"completed\":1,\"total\":2,\"lastError\":\"e\"," +
        "\"items\":[{\"id\":11,\"org\":\"demo\",\"name\":\"mathUtils\",\"version\":\"1.0.0\"," +
        "\"status\":\"completed\",\"error\":\"\"}]}")
    @Expect(jsonText(PlanDoneDto(7, "completed")), "{\"planId\":7,\"status\":\"completed\"}")
}

// ===== 服务层结果（三级删除 / 重拉 / 上游探测）=====

@Test
func testServiceResultDtosJsonShapes() {
    @Expect(jsonText(LifecycleResp("ok", "已软删除（可恢复）", 2, false, true)),
        "{\"status\":\"ok\",\"message\":\"已软删除（可恢复）\",\"skippedPlanItems\":2," +
        "\"blobRemoved\":false,\"artifactPresent\":true}")
    @Expect(jsonText(RefetchResp("ok", "已重拉", "aa", "bb", true, 10, 4, "official")),
        "{\"status\":\"ok\",\"message\":\"已重拉\",\"oldSha\":\"aa\",\"newSha\":\"bb\",\"changed\":true," +
        "\"size\":10,\"readmeLength\":4,\"upstream\":\"official\"}")
    @Expect(jsonText(UpstreamProbeResp(7, "official", "https://x", "https://x/index", true, true, true, 200,
        88, 34, true, ArrayList<String>(["cordis_core"]), "", "连通")),
        "{\"upstreamId\":7,\"upstreamName\":\"official\",\"baseUrl\":\"https://x\",\"testedUrl\":" +
        "\"https://x/index\",\"enabled\":true,\"reachable\":true,\"healthy\":true,\"status\":200," +
        "\"latencyMs\":88,\"bodyBytes\":34,\"authUsed\":true,\"packages\":[\"cordis_core\"],\"error\":\"\"," +
        "\"summary\":\"连通\"}")
}

// ===== 用户门户 =====

@Test
func testPortalDtosJsonShapes() {
    @Expect(jsonText(PortalMeResp(7, "alice", "a@x", false, "pt***", "team", "提示")),
        "{\"id\":7,\"username\":\"alice\",\"email\":\"a@x\",\"isAdmin\":false,\"publishTokenMasked\":" +
        "\"pt***\",\"permissionMode\":\"team\",\"permissionHint\":\"提示\"}")
    @Expect(jsonText(PublishTokenResp("t-1")), "{\"publishToken\":\"t-1\"}")

    let pkgs = ArrayList<MyPackageRowDto>()
    pkgs.add(MyPackageRowDto("demo", "app", 2, "1.1.0", true, 300))
    @Expect(jsonText(MyPackageListResp(1, 2, 20, pkgs)),
        "{\"total\":1,\"page\":2,\"size\":20,\"items\":[{\"organization\":\"demo\",\"name\":\"app\"," +
        "\"versionCount\":2,\"latestVersion\":\"1.1.0\",\"isOwner\":true,\"updatedAt\":300}]}")

    let teams = ArrayList<MyTeamRowDto>()
    teams.add(MyTeamRowDto(3, "t1", "团队1", "write", ArrayList<String>(["o1"]), ArrayList<String>(["p1"])))
    @Expect(jsonText(MyTeamsResp("team", teams)),
        "{\"permissionMode\":\"team\",\"items\":[{\"id\":3,\"name\":\"t1\",\"displayName\":\"团队1\"," +
        "\"permission\":\"write\",\"organizations\":[\"o1\"],\"packages\":[\"p1\"]}]}")
}

// ===== 组织（org_service_test 按 contains 断言，这里补字段顺序的逐字契约）=====

@Test
func testOrgDtosJsonShapes() {
    let o = OrgDto(7, "test", "测试组织", "desc", true, 1, 2, 3, 4, 100, 200)
    @Expect(jsonText(o),
        "{\"id\":7,\"name\":\"test\",\"displayName\":\"测试组织\",\"description\":\"desc\"," +
        "\"isDefault\":true,\"ownerId\":1,\"packageCount\":2,\"versionCount\":3,\"teamCount\":4," +
        "\"createdAt\":100,\"updatedAt\":200}")
    let items = ArrayList<OrgDto>()
    items.add(o)
    @Expect(jsonText(OrgListResp(1, items)),
        "{\"total\":1,\"items\":[{\"id\":7,\"name\":\"test\",\"displayName\":\"测试组织\"," +
        "\"description\":\"desc\",\"isDefault\":true,\"ownerId\":1,\"packageCount\":2,\"versionCount\":3," +
        "\"teamCount\":4,\"createdAt\":100,\"updatedAt\":200}]}")
    @Expect(jsonText(OrgListResp(0, ArrayList<OrgDto>())), "{\"total\":0,\"items\":[]}")
    @Expect(jsonText(OrgResultResp("has_packages", "仍有 2 个包", 5, 2)),
        "{\"status\":\"has_packages\",\"message\":\"仍有 2 个包\",\"id\":5,\"affected\":2}")
}

// ===== 转义 =====

// 错误消息/UA 等字段含引号、反斜杠、换行、控制字符时必须仍产出合法 JSON：
// 转义由 JsonWriter 负责（改造前是手工拼串 + escapeJsonStr，漏转义就会写出非法 JSON）
@Test
func testDtoEscapesControlChars() {
    @Expect(jsonText(ErrorResp("a\"b")), "{\"error\":\"a\\\"b\"}")
    @Expect(jsonText(ErrorResp("a\\b")), "{\"error\":\"a\\\\b\"}")
    @Expect(jsonText(ErrorResp("l1\nl2")), "{\"error\":\"l1\\nl2\"}")
    @Expect(jsonText(ErrorResp("t\tt")), "{\"error\":\"t\\tt\"}")
    @Expect(jsonText(ErrorResp("x\u{1}y")), "{\"error\":\"x\\u0001y\"}")
    // detail 为 None 时不出现该字段；为 Some 时按序追加
    @Expect(jsonText(ErrorResp("conflict")), "{\"error\":\"conflict\"}")
    @Expect(jsonText(ErrorResp("conflict", detail: Some("同版本不同 sha"))),
        "{\"error\":\"conflict\",\"detail\":\"同版本不同 sha\"}")
}
