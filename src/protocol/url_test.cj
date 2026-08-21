// 中心仓协议 URL 构造单元测试
package ystyle::cjreg.protocol

import std.unittest.testmacro.*

@Test
func testBuildIndexURL() {
    // 4+ 字符
    @Expect(buildIndexURL("https://x/registry", "jsonvalue", ""), "https://x/registry/index/js/on/jsonvalue")
    @Expect(buildIndexURL("https://x/registry/", "tomlcj", ""), "https://x/registry/index/to/ml/tomlcj")
    // 3 字符
    @Expect(buildIndexURL("https://x/registry", "tea", ""), "https://x/registry/index/te/a/tea")
    @Expect(buildIndexURL("https://x/registry", "dep", ""), "https://x/registry/index/de/p/dep")
    // < 3 字符 → 防御性返回空
    @Expect(buildIndexURL("https://x/registry", "di", ""), "")
    // org 参数
    @Expect(buildIndexURL("https://x/registry", "cordis_core", "ystyle"),
        "https://x/registry/index/co/rd/cordis_core?organization=ystyle")
}

@Test
func testBuildPackageURL() {
    @Expect(buildPackageURL("https://x/registry", "jsonvalue", "1.1.0", ""),
        "https://x/registry/pkg/jsonvalue/1.1.0")
    @Expect(buildPackageURL("https://x/registry", "cordis_core", "0.1.0", "ystyle"),
        "https://x/registry/pkg/cordis_core/0.1.0?organization=ystyle")
    @Expect(buildPackageURL("https://x/registry/", "bstorm", "1.4.3", ""),
        "https://x/registry/pkg/bstorm/1.4.3")
}

@Test
func testIsOfficialRegistry() {
    @Expect(isOfficialRegistry("https://pkg.cangjie-lang.cn/registry"), true)
    @Expect(isOfficialRegistry("https://pkg.cangjie-lang.cn/registry/"), true)
    @Expect(isOfficialRegistry("https://mirror.example.com/registry"), false)
    @Expect(isOfficialRegistry("http://localhost:8060"), false)
}
