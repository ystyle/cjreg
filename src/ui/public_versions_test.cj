// 公开端版本历史元信息（制品大小 / sha256 缩写）单元测试
//
// 版本历史行现在展示：版本号 + 「最新」+ 收录/发布时间 + 制品大小 + sha256 缩写（悬停完整值）。
// 纯函数便于断言，避免为了测渲染去搭 LifecycleContext。
package ystyle::cjreg.ui

import ystyle::cjreg.store.*
import std.unittest.testmacro.*

// 1. 字节文案：B / KB / MB / GB 四档 + 边界
@Test
func testFormatBytesTextBoundaries() {
    @Expect(formatBytesText(0), "0 B")
    @Expect(formatBytesText(-1), "0 B")
    @Expect(formatBytesText(512), "512 B")
    @Expect(formatBytesText(1024), "1 KB")
    @Expect(formatBytesText(40299), "39 KB")           // 生产实测值：zip 1.0.6
    @Expect(formatBytesText(1024 * 1024), "1 MB")
    @Expect(formatBytesText(1024 * 1024 * 1024), "1 GB")
}

// 2. sha256 缩写：只留 12 位，短值原样返回
@Test
func testShortShaText() {
    let full = "e0b33e71376cf0e1868b62cff6a7940025af5d261f299132b175b6bad9ee8ff6"
    @Expect(shortShaText(full), "e0b33e71376c")
    @Expect(shortShaText(full).size, 12)
    @Expect(shortShaText("abc"), "abc")
    @Expect(shortShaText(""), "")
}

// 3. 版本大小文案：没补过 size（老回源版本为 0）就空串，不留占位符
@Test
func testVersionSizeText() {
    let d = PackageDoc()
    d.tarballSize = 0
    @Expect(versionSizeText(d), "")
    d.tarballSize = 40299
    @Expect(versionSizeText(d), "39 KB")
}
