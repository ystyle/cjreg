// 索引 NDJSON 单元测试
package ystyle::cjreg.index

import std.unittest.testmacro.*
import std.collection.*

func makeIndex(name: String, version: String, sha: String, yanked: Bool): PackageIndex {
    let idx = PackageIndex()
    idx.organization = "test"
    idx.name = name
    idx.version = version
    idx.cjcVersion = "1.1.0"
    idx.sha256sum = sha
    idx.yanked = yanked
    idx.indexVersion = 1
    return idx
}

@Test
func testGenerateAndParseRoundTrip() {
    let idx = makeIndex("demo", "1.0.0", "abc123", false)
    let dep = DependencyEntry("org::dep", "[1.0.0, 2.0.0)", "x86_64-unknown-linux-gnu", "debug", "static")
    idx.dependencies.add(dep)
    idx.testDependencies.add(DependencyEntry("mock", "1.0.0", "", "", ""))

    let indexes = ArrayList<PackageIndex>([idx])
    let ndjson = generateNDJSON(indexes)

    // 每行一个 JSON
    let lines = ndjson.trimAsciiEnd().split("\n")
    @Expect(lines.size, 1)
    @Expect(lines[0].contains("\"name\":\"demo\""), true)
    @Expect(lines[0].contains("\"target\":\"x86_64-unknown-linux-gnu\""), true)
    @Expect(lines[0].contains("\"index-version\":1"), true)

    // 解析回来
    let parsed = parseNDJSON(ndjson)
    @Expect(parsed.size, 1)
    let p = parsed[0]
    @Expect(p.name, "demo")
    @Expect(p.version, "1.0.0")
    @Expect(p.sha256sum, "abc123")
    @Expect(p.dependencies.size, 1)
    @Expect(p.dependencies[0].name, "org::dep")
    @Expect(p.dependencies[0].target, "x86_64-unknown-linux-gnu")
    @Expect(p.dependencies[0].mode, "debug")
    @Expect(p.dependencies[0].outputType, "static")
    @Expect(p.testDependencies.size, 1)
    @Expect(p.testDependencies[0].name, "mock")
    @Expect(p.indexVersion, 1)
}

@Test
func testParseMultipleLines() {
    let body = "{\"name\":\"a\",\"version\":\"1.0.0\",\"sha256sum\":\"s1\",\"yanked\":false,\"index-version\":1}\n" +
        "{\"name\":\"a\",\"version\":\"1.1.0\",\"sha256sum\":\"s2\",\"yanked\":false,\"index-version\":1}\n" +
        "\n" +
        "not-json-line\n"
    let parsed = parseNDJSON(body)
    @Expect(parsed.size, 2)
    @Expect(parsed[0].version, "1.0.0")
    @Expect(parsed[1].version, "1.1.0")
}

@Test
func testFindIndexVersion() {
    let indexes = ArrayList<PackageIndex>()
    indexes.add(makeIndex("a", "1.0.0", "s1", false))
    indexes.add(makeIndex("a", "1.1.0", "s2", true))  // yanked

    let found = findIndexVersion(indexes, "1.0.0")
    @Expect(found.isSome(), true)
    match (found) {
        case Some(i) => @Expect(i.sha256sum, "s1")
        case None => ()
    }
    // yanked 版本找不到
    @Expect(findIndexVersion(indexes, "1.1.0").isNone(), true)
    // 不存在版本
    @Expect(findIndexVersion(indexes, "9.9.9").isNone(), true)
}

@Test
func testIndexVersionStringCompat() {
    // 官方索引实际返回 index-version 为字符串 "1"
    let body = "{\"name\":\"a\",\"version\":\"1.0.0\",\"sha256sum\":\"s1\",\"yanked\":false,\"index-version\":\"1\"}\n"
    let parsed = parseNDJSON(body)
    @Expect(parsed.size, 1)
    @Expect(parsed[0].indexVersion, 1)
    @Expect(parsed[0].version, "1.0.0")
}

@Test
func testFullOfficialEntry() {
    // 官方完整索引条目（含 test/script-dependencies、cjc-version、字符串 index-version）
    let line = "{\"organization\":\"\",\"name\":\"jsonvalue\",\"version\":\"1.0.1\",\"dependencies\":[],\"sha256sum\":\"ffa3a7c57f8aa57e2ef3bae9b241f1d38479aecb07e176995ab4c2f0b5d3d4eb\",\"yanked\":false,\"test-dependencies\":[],\"script-dependencies\":[],\"cjc-version\":\"1.0.0\",\"index-version\":\"1\"}"
    let parsed = parseNDJSON(line + "\n")
    @Expect(parsed.size, 1)
    @Expect(parsed[0].name, "jsonvalue")
    @Expect(parsed[0].version, "1.0.1")
    @Expect(parsed[0].indexVersion, 1)
}
