// 制品内容提取（README / cjpm.toml）单元测试
package ystyle::cjreg.protocol

import std.unittest.testmacro.*
import std.collection.*
import std.io.*
import stdx.compress.zlib.*
import ystyle::tar.*

// 构造 .cjp 夹具：tar → gzip（与 cjpm bundle 产物同构）
func buildCjp(entries: ArrayList<(String, Array<Byte>)>): Array<Byte> {
    let tarBuf = ByteBuffer()
    let tw = Writer(tarBuf)
    for ((n, d) in entries) {
        tw.writeFile(n, d)
    }
    tw.close()
    let out = ByteBuffer()
    let gz = CompressOutputStream(out, wrap: GzipFormat)
    gz.write(tarBuf.bytes())
    gz.close()
    return out.bytes()
}

func entry(name: String, text: String): (String, Array<Byte>) {
    (name, text.toArray())
}

func cjpOf(entries: ArrayList<(String, Array<Byte>)>): Array<Byte> {
    buildCjp(entries)
}

// 1. 正常提取：README.md + cjpm.toml（真实制品的目录前缀形态）
@Test
func testExtractReadmeAndCjpmToml() {
    let es = ArrayList<(String, Array<Byte>)>()
    es.add(entry("demo-1.0.0/cjpm.toml", "[package]\n  name = \"demo\"\n"))
    es.add(entry("demo-1.0.0/src/main.cj", "package demo\n"))
    es.add(entry("demo-1.0.0/README.md", "# demo\n\nhello\n"))
    let f = extractArtifactFiles(cjpOf(es))
    @Expect(f.ok(), true)
    @Expect(f.readme, "# demo\n\nhello\n")
    @Expect(f.cjpmToml, "[package]\n  name = \"demo\"\n")
    @Expect(f.entries, 3)
}

// 2. README_zh.md 优先于 README.md
@Test
func testReadmeZhWins() {
    let es = ArrayList<(String, Array<Byte>)>()
    es.add(entry("demo-1.0.0/README.md", "english"))
    es.add(entry("demo-1.0.0/README_zh.md", "中文"))
    let f = extractArtifactFiles(cjpOf(es))
    @Expect(f.readme, "中文")
}

// 3. 大小写不敏感（cjrepo 用 EqualFold；制作者可能写成 readme.md / ReadMe.MD）
@Test
func testReadmeCaseInsensitive() {
    let es = ArrayList<(String, Array<Byte>)>()
    es.add(entry("demo-1.0.0/readme.md", "lower"))
    let f = extractArtifactFiles(cjpOf(es))
    @Expect(f.readme, "lower")
    let es2 = ArrayList<(String, Array<Byte>)>()
    es2.add(entry("demo/ReadMe.MD", "mixed"))
    @Expect(extractArtifactFiles(cjpOf(es2)).readme, "mixed")
}

// 4. 无 README：不是硬失败（note 提示，error 为空）
@Test
func testNoReadmeIsNoteNotError() {
    let es = ArrayList<(String, Array<Byte>)>()
    es.add(entry("demo-1.0.0/cjpm.toml", "[package]\n"))
    let f = extractArtifactFiles(cjpOf(es))
    @Expect(f.ok(), true)
    @Expect(f.readme, "")
    @Expect(f.note.isEmpty(), false)
}

// 5. 大文件在 README 之前：验证跳过条目时读干净（否则后续 header 错位、README 丢失）
@Test
func testSkipLargeEntryKeepsAlignment() {
    let es = ArrayList<(String, Array<Byte>)>()
    // 200KB > 64KB 分块，必须多轮读干
    let big = Array<Byte>(200_000, repeat: UInt8(65))
    es.add(("demo-1.0.0/src/big.cj", big))
    es.add(entry("demo-1.0.0/README.md", "after big"))
    let f = extractArtifactFiles(cjpOf(es))
    @Expect(f.ok(), true)
    @Expect(f.readme, "after big")
}

// 6. 取最浅层的 cjpm.toml（包根那份，而非测试夹具里的深层同名文件）
@Test
func testShallowestCjpmTomlWins() {
    let es = ArrayList<(String, Array<Byte>)>()
    es.add(entry("demo-1.0.0/tests/fixture/cjpm.toml", "[package]\n  name = \"nested\"\n"))
    es.add(entry("demo-1.0.0/cjpm.toml", "[package]\n  name = \"root\"\n"))
    let f = extractArtifactFiles(cjpOf(es))
    @Expect(f.cjpmToml, "[package]\n  name = \"root\"\n")
}

// 7. 非法制品（非 gzip）→ 硬失败可见，而不是静默返回空
@Test
func testBrokenArtifactReported() {
    let f = extractArtifactFiles("not a gzip at all".toArray())
    @Expect(f.ok(), false)
    @Expect(f.error.isEmpty(), false)
}

// 8. 空制品
@Test
func testEmptyArtifact() {
    let f = extractArtifactFiles(Array<Byte>())
    @Expect(f.ok(), false)
    @Expect(f.error, "empty artifact")
}

// 9. cjpm.toml 展示字段解析（description/license/authors/repository/tag/category）
@Test
func testParseCjpmDisplayMeta() {
    let sb = StringBuilder()
    sb.append("[package]\n")
    sb.append("  name = \"demo\"\n")
    sb.append("  description = \"演示包\"\n")
    sb.append("  license = [\"MIT\"]\n")
    sb.append("  authors = [\"ystyle\"]\n")
    sb.append("  repository = \"https://atomgit.com/ystyle/demo\"\n")
    sb.append("  homepage = \"https://ystyle.top/demo\"\n")
    sb.append("  tag = [\"json\", \"rpc\"]\n")
    sb.append("  category = [\"Network\"]\n")
    let m = parseCjpmDisplayMeta(sb.toString())
    @Expect(m.ok(), true)
    @Expect(m.description, "演示包")
    @Expect(m.repository, "https://atomgit.com/ystyle/demo")
    @Expect(m.homepage, "https://ystyle.top/demo")
    @Expect(m.license.size, 1)
    @Expect(m.license[0], "MIT")
    @Expect(m.authors[0], "ystyle")
    @Expect(m.tag.size, 2)
    @Expect(m.tag[1], "rpc")
    @Expect(m.category[0], "Network")
}

// 10. 缺字段/缺 [package]：不抛异常，error 可见
@Test
func testParseCjpmDisplayMetaFallbacks() {
    let noPkg = parseCjpmDisplayMeta("[dependencies]\n  \"a\" = \"1.0.0\"\n")
    @Expect(noPkg.ok(), false)
    @Expect(noPkg.error, "no [package] table")
    let empty = parseCjpmDisplayMeta("")
    @Expect(empty.ok(), false)
    let partial = parseCjpmDisplayMeta("[package]\n  name = \"demo\"\n")
    @Expect(partial.ok(), true)
    @Expect(partial.description, "")
    @Expect(partial.license.size, 0)
}
