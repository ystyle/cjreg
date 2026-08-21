// 版本区间匹配单元测试
package ystyle::cjreg.semver_range

import semver.*
import std.unittest.testmacro.*
import std.collection.*

func mustParse(v: String): SemVer {
    let o = SemVer.tryParse(v)
    match (o) {
        case Some(sv) => return sv
        case None => throw Exception("cannot parse version: ${v}")
    }
}

@Test
func testExactMatch() {
    @Expect(versionSatisfies("1.2.3", "1.2.3"), true)
    @Expect(versionSatisfies("1.2.4", "1.2.3"), false)
    @Expect(versionSatisfies("1.2.3", "=1.2.3"), true)
    @Expect(versionSatisfies("1.2.3", "==1.2.3"), true)
}

@Test
func testRangeBracket() {
    // [1.0.0, 2.0.0)
    @Expect(versionSatisfies("1.0.0", "[1.0.0, 2.0.0)"), true)
    @Expect(versionSatisfies("1.9.9", "[1.0.0, 2.0.0)"), true)
    @Expect(versionSatisfies("2.0.0", "[1.0.0, 2.0.0)"), false)
    @Expect(versionSatisfies("0.9.9", "[1.0.0, 2.0.0)"), false)
    // [1.0.0, 2.0.0]
    @Expect(versionSatisfies("2.0.0", "[1.0.0, 2.0.0]"), true)
    // (1.0.0, 2.0.0)
    @Expect(versionSatisfies("1.0.0", "(1.0.0, 2.0.0)"), false)
    @Expect(versionSatisfies("1.0.1", "(1.0.0, 2.0.0)"), true)
    // 单侧开区间 (, 2.0.0]
    @Expect(versionSatisfies("0.0.1", "(, 2.0.0]"), true)
    @Expect(versionSatisfies("2.0.1", "(, 2.0.0]"), false)
    // [1.0.0,)
    @Expect(versionSatisfies("3.0.0", "[1.0.0,)"), true)
    @Expect(versionSatisfies("0.9.0", "[1.0.0,)"), false)
}

@Test
func testComparators() {
    @Expect(versionSatisfies("1.5.0", ">=1.0.0"), true)
    @Expect(versionSatisfies("0.9.0", ">=1.0.0"), false)
    @Expect(versionSatisfies("1.0.0", ">=1.0.0"), true)
    @Expect(versionSatisfies("1.0.0", ">1.0.0"), false)
    @Expect(versionSatisfies("1.0.1", ">1.0.0"), true)
    @Expect(versionSatisfies("1.0.0", "<=1.0.0"), true)
    @Expect(versionSatisfies("1.0.1", "<=1.0.0"), false)
    @Expect(versionSatisfies("0.5.0", "<1.0.0"), true)
    @Expect(versionSatisfies("1.0.0", "<1.0.0"), false)
}

@Test
func testCaret() {
    // ^1.2.3
    @Expect(versionSatisfies("1.2.3", "^1.2.3"), true)
    @Expect(versionSatisfies("1.2.4", "^1.2.3"), true)
    @Expect(versionSatisfies("1.9.0", "^1.2.3"), true)
    @Expect(versionSatisfies("2.0.0", "^1.2.3"), false)
    // ^0.2.3
    @Expect(versionSatisfies("0.2.3", "^0.2.3"), true)
    @Expect(versionSatisfies("0.2.9", "^0.2.3"), true)
    @Expect(versionSatisfies("0.3.0", "^0.2.3"), false)
    // ^0.0.3
    @Expect(versionSatisfies("0.0.3", "^0.0.3"), true)
    @Expect(versionSatisfies("0.0.4", "^0.0.3"), false)
}

@Test
func testTilde() {
    // ~1.2.3
    @Expect(versionSatisfies("1.2.3", "~1.2.3"), true)
    @Expect(versionSatisfies("1.2.9", "~1.2.3"), true)
    @Expect(versionSatisfies("1.3.0", "~1.2.3"), false)
    @Expect(versionSatisfies("2.0.0", "~1.2.3"), false)
    // ~1.2
    @Expect(versionSatisfies("1.2.0", "~1.2"), true)
    @Expect(versionSatisfies("1.3.0", "~1.2"), false)
    // ~1
    @Expect(versionSatisfies("1.9.9", "~1"), true)
    @Expect(versionSatisfies("2.0.0", "~1"), false)
}

@Test
func testOrAlternatives() {
    // 逗号 = 或
    @Expect(versionSatisfies("1.0.0", "1.0.0, 2.0.0"), true)
    @Expect(versionSatisfies("2.0.0", "1.0.0, 2.0.0"), true)
    @Expect(versionSatisfies("1.5.0", "1.0.0, 2.0.0"), false)
    // || 或
    @Expect(versionSatisfies("3.0.0", ">=1.0.0 || <0.5.0"), true)
    @Expect(versionSatisfies("0.1.0", ">=1.0.0 || <0.5.0"), true)
    @Expect(versionSatisfies("0.6.0", ">=1.0.0 || <0.5.0"), false)
    // 区间内逗号不计
    @Expect(versionSatisfies("1.5.0", "[1.0.0, 2.0.0), [3.0.0, 4.0.0)"), true)
    @Expect(versionSatisfies("3.5.0", "[1.0.0, 2.0.0), [3.0.0, 4.0.0)"), true)
    @Expect(versionSatisfies("2.5.0", "[1.0.0, 2.0.0), [3.0.0, 4.0.0)"), false)
}

@Test
func testPrerelease() {
    // 精确预发布
    @Expect(versionSatisfies("1.2.3-beta.1", "1.2.3-beta.1"), true)
    @Expect(versionSatisfies("1.2.3-beta.2", "1.2.3-beta.1"), false)
    // 预发布版本低于正式版
    @Expect(versionSatisfies("1.2.3-beta.1", "1.2.3"), false)
    @Expect(versionSatisfies("1.2.3", "1.2.3-beta.1"), false)
    // 带预发布端点的区间
    @Expect(versionSatisfies("1.2.3-beta.2", "[1.2.3-beta.1, 1.3.0)"), true)
    @Expect(versionSatisfies("1.3.0", "[1.2.3-beta.1, 1.3.0)"), false)
    // 无预发布端点不匹配预发布版本
    @Expect(versionSatisfies("1.2.3-beta.1", ">=1.2.0"), false)
}

@Test
func testCompareVersions() {
    @Expect(compareVersions("1.0.0", "2.0.0"), -1)
    @Expect(compareVersions("2.0.0", "1.0.0"), 1)
    @Expect(compareVersions("1.2.3", "1.2.3"), 0)
    @Expect(compareVersions("1.0.0-alpha", "1.0.0"), -1)
    @Expect(compareVersions("1.0.0", "1.0.0-alpha"), 1)
}

@Test
func testInsertSorted() {
    let list = ArrayList<String>()
    insertSorted(list, "1.2.0")
    insertSorted(list, "1.0.0")
    insertSorted(list, "1.1.0")
    insertSorted(list, "1.0.0")  // 去重
    @Expect(list.size, 3)
    @Expect(list[0], "1.0.0")
    @Expect(list[1], "1.1.0")
    @Expect(list[2], "1.2.0")
}

@Test
func testBestMatch() {
    let list = ArrayList<String>(["1.0.0", "1.5.0", "2.0.0"])
    let m = bestMatch(list, "[1.0.0, 2.0.0)")
    match (m) {
        case Some(v) => @Expect(v, "1.5.0")
        case None => @Fail("expected match")
    }
    let m2 = bestMatch(list, "3.0.0")
    match (m2) {
        case Some(_) => @Fail("should not match")
        case None => @Expect(true, true)
    }
}

@Test
func testInvalidRequirement() {
    @Expect(versionSatisfies("1.0.0", ""), false)
    @Expect(versionSatisfies("1.0.0", "abc"), false)
    @Expect(versionSatisfies("abc", "1.0.0"), false)
    let r = VersionReq.parse("   ")
    @Expect(r.isNone(), true)
}
