// 上游连通性测试单元测试：索引正文包名扫描 + HTTP 结果分类（不依赖网络）
package ystyle::cjreg.server

import ystyle::cjreg.config.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.model.*
import std.unittest.testmacro.*
import std.collection.*

func makeUpstream(id: Int64, name: String, url: String, token: String, enabled: Bool): Upstream {
    Upstream(id, name, url, enabled, 300, token, false, 0, 0)
}

@Test
func testScanPackageNamesFromIndex() {
    let ndjson = "{\"organization\":\"test\",\"name\":\"mathUtils\",\"version\":\"1.0.0\"}\n" +
        "{\"organization\":\"test\",\"name\":\"strUtils\",\"version\":\"1.0.0\"}\n" +
        "{\"organization\":\"test\",\"name\":\"mathUtils\",\"version\":\"1.1.0\"}\n"
    let names = scanPackageNames(ndjson, 5)
    @Expect(names.size, 2)          // 去重
    @Expect(names[0], "mathUtils")
    @Expect(names[1], "strUtils")
    // 限制条数
    @Expect(scanPackageNames(ndjson, 1).size, 1)
    // 无 name 字段 / 空正文
    @Expect(scanPackageNames("", 5).size, 0)
    @Expect(scanPackageNames("{\"version\":\"1.0.0\"}", 5).size, 0)
    // name 为空串不收录
    @Expect(scanPackageNames("{\"name\":\"\"}", 5).size, 0)
    // 带空格的 JSON 也能扫到
    let spaced = "{ \"name\" : \"demo\" }"
    @Expect(scanPackageNames(spaced, 5).size, 1)
}

@Test
func testClassifyProbeOutcomes() {
    let up = makeUpstream(1, "official", "https://pkg.example.com/registry", "", true)
    // 无响应 → 不可达
    let dead = classifyProbe(up, "https://pkg.example.com/registry", false, 0, 120, 0, "", "connect timeout")
    @Expect(dead.reachable, false)
    @Expect(dead.healthy, false)
    @Expect(dead.status, 0)
    @Expect(dead.error, "connect timeout")
    @Expect(probeSummary(dead).contains("不可达"), true)
    // 200 + 包名（指定包）→ 健康
    let body = "{\"name\":\"demo\"}\n"
    let ok = classifyProbe(up, "https://x/index/de/mo/demo", true, 200, 42, body.size, body, "")
    @Expect(ok.reachable, true)
    @Expect(ok.healthy, true)
    @Expect(ok.status, 200)
    @Expect(ok.latencyMs, 42)
    @Expect(ok.packages.size, 1)
    @Expect(probeSummary(ok).contains("连通"), true)
    // 404（指定包）→ 连通但非健康，原因说明该上游未收录
    let nf = classifyProbe(up, "https://x/index/de/mo/demo", true, 404, 30, 0, "", "")
    @Expect(nf.reachable, true)
    @Expect(nf.healthy, false)
    @Expect(nf.error, "该上游未收录此包（404）")
    // 401/403 → 认证失败
    let denied = classifyProbe(up, "https://x/index/de/mo/demo", true, 401, 20, 0, "", "")
    @Expect(denied.reachable, true)
    @Expect(denied.error, "认证失败（401）")
    // 500 → 上游错误
    let bad = classifyProbe(up, "https://x/index/de/mo/demo", true, 500, 20, 0, "", "")
    @Expect(bad.error, "上游返回 500")
    // 200 但索引为空（指定包）→ 非健康
    let empty = classifyProbe(up, "https://x/index/de/mo/demo", true, 200, 15, 0, "", "")
    @Expect(empty.healthy, false)
    @Expect(empty.error, "索引为空")
    // 基地址探测：200 即健康（不要求包名）
    let base = classifyProbe(up, "https://pkg.example.com/registry", false, 200, 10, 12, "<html>", "")
    @Expect(base.healthy, true)
    @Expect(base.packages.size, 0)
}

@Test
func testClassifyProbeAuthFlagAndDisabled() {
    let withToken = makeUpstream(2, "private", "https://priv.example.com", "secret-token", false)
    let r = classifyProbe(withToken, "https://priv.example.com", false, 200, 5, 10, "ok", "")
    @Expect(r.authUsed, true)
    @Expect(r.enabled, false)     // 禁用上游照测，但结果标注
    @Expect(r.upstreamName, "private")
    @Expect(r.baseUrl, "https://priv.example.com")
    let noToken = makeUpstream(3, "public", "https://pub.example.com", "", true)
    @Expect(classifyProbe(noToken, "https://pub.example.com", false, 200, 5, 10, "ok", "").authUsed, false)
}

@Test
func testUpstreamProbeJsonShape() {
    let up = makeUpstream(7, "official", "https://pkg.example.com/registry", "t", true)
    let r = classifyProbe(up, "https://pkg.example.com/registry/index/co/rd/cordis_core", true, 200, 88,
        34, "{\"name\":\"cordis_core\"}\n", "")
    let json = upstreamProbeJson(r)
    @Expect(json.contains("\"upstreamId\":7"), true)
    @Expect(json.contains("\"upstreamName\":\"official\""), true)
    @Expect(json.contains("\"healthy\":true"), true)
    @Expect(json.contains("\"status\":200"), true)
    @Expect(json.contains("\"latencyMs\":88"), true)
    @Expect(json.contains("\"bodyBytes\":34"), true)
    @Expect(json.contains("\"authUsed\":true"), true)
    @Expect(json.contains("\"packages\":[\"cordis_core\"]"), true)
    @Expect(json.contains("\"summary\":\"连通"), true)
    // 含引号的错误信息被转义
    let dead = classifyProbe(up, "https://x", false, 0, 1, 0, "", "dial \"tcp\": refused")
    @Expect(upstreamProbeJson(dead).contains("dial \\\"tcp\\\": refused"), true)
}

@Test
func testTrimTrailingUrl() {
    @Expect(trimTrailing("https://a/b/"), "https://a/b")
    @Expect(trimTrailing("https://a/b///"), "https://a/b")
    @Expect(trimTrailing("  https://a/b  "), "https://a/b")
    @Expect(trimTrailing("https://a/b"), "https://a/b")
    @Expect(trimTrailing("/"), "")
}
