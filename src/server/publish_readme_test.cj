// 发布路径 README 提取单测：制品（.cjp）→ PackageDoc.readme → 公开详情 JSON
//
// 背景：官方 meta-data.json 与索引协议都不含 README，服务端只能从制品里提取。
// 提取失败**绝不阻断发布**（这是硬约束：README 缺失不能把包发不上去）。
package ystyle::cjreg.server

import ystyle::cjreg.protocol.*
import ystyle::cjreg.store.*
import std.unittest.testmacro.*
import std.collection.*
import std.io.*
import stdx.compress.zlib.*
import ystyle::tar.*

// 造一个带 README 的真制品（tar → gzip，与 cjpm bundle 产物同构）
func cjpWithReadme(pkgDir: String, readme: String): Array<Byte> {
    cjpWithReadmeAndToml(pkgDir, readme, "[package]\n  name = \"${pkgDir}\"\n")
}

// 同上，但自定义制品内的 cjpm.toml（展示字段来源）
func cjpWithReadmeAndToml(pkgDir: String, readme: String, toml: String): Array<Byte> {
    let tarBuf = ByteBuffer()
    let tw = Writer(tarBuf)
    tw.writeFile("${pkgDir}/cjpm.toml", toml.toArray())
    tw.writeFile("${pkgDir}/src/main.cj", "package demo\n".toArray())
    tw.writeFile("${pkgDir}/README.md", readme.toArray())
    tw.close()
    let out = ByteBuffer()
    let gz = CompressOutputStream(out, wrap: GzipFormat)
    gz.write(tarBuf.bytes())
    gz.close()
    out.bytes()
}

// 造一个没有 README 的真制品
func cjpWithoutReadme(pkgDir: String): Array<Byte> {
    let tarBuf = ByteBuffer()
    let tw = Writer(tarBuf)
    tw.writeFile("${pkgDir}/cjpm.toml", "[package]\n  name = \"demo\"\n".toArray())
    tw.close()
    let out = ByteBuffer()
    let gz = CompressOutputStream(out, wrap: GzipFormat)
    gz.write(tarBuf.bytes())
    gz.close()
    out.bytes()
}

// 1. 新发布：制品内 README 落到 doc.readme
@Test
func testPublishExtractsReadme() {
    let svc = makePublishService()
    let body = makePublishBodyWithTar("acme", "demo", "1.0.0", cjpWithReadme("demo-1.0.0", "# demo\n\n正文\n"))
    let r = svc.publish("acme", "demo", body)
    @Expect(r.outcome == PublishOutcome.Ok, true)
    let versions = svc.store.listVersions("acme", "demo")
    @Expect(versions.size, 1)
    @Expect(versions[0].readme, "# demo\n\n正文\n")
}

// 2. 制品内无 README：照常发布，readme 为空（不阻断）
@Test
func testPublishWithoutReadmeStillSucceeds() {
    let svc = makePublishService()
    let body = makePublishBodyWithTar("acme", "demo", "1.0.0", cjpWithoutReadme("demo-1.0.0"))
    let r = svc.publish("acme", "demo", body)
    @Expect(r.outcome == PublishOutcome.Ok, true)
    @Expect(svc.store.listVersions("acme", "demo")[0].readme, "")
}

// 3. 制品不是 gzip（提取硬失败）：照常发布，只是没有 README
@Test
func testPublishBrokenArtifactStillSucceeds() {
    let svc = makePublishService()
    let broken: Array<Byte> = [UInt8(1), UInt8(2), UInt8(3), UInt8(4)]
    let r = svc.publish("acme", "demo", makePublishBodyWithTar("acme", "demo", "1.0.0", broken))
    @Expect(r.outcome == PublishOutcome.Ok, true)
    @Expect(svc.store.listVersions("acme", "demo")[0].readme, "")
}

// 4. 覆盖发布：README 随新制品刷新（team 模式允许覆盖，见 AGENTS.md 预演说明）
@Test
func testOverwriteRefreshesReadme() {
    let svc = PublishService(makeStore(), MemoryBlobStore(), permissionMode: "team")
    let body1 = makePublishBodyWithTar("acme", "demo", "1.0.0", cjpWithReadme("demo-1.0.0", "old readme"))
    @Expect(svc.publish("acme", "demo", body1).outcome == PublishOutcome.Ok, true)
    let body2 = makePublishBodyWithTar("acme", "demo", "1.0.0", cjpWithReadme("demo-1.0.0", "new readme"))
    let r2 = svc.publish("acme", "demo", body2)
    @Expect(r2.outcome == PublishOutcome.Ok, true)
    let versions = svc.store.listVersions("acme", "demo")
    @Expect(versions.size, 1)
    @Expect(versions[0].readme, "new readme")
}

// 5. 端到端到公开详情：发布 → 详情 JSON 带 README（handler 取最新未软删版本的 readme）
@Test
func testPublicDetailJsonCarriesExtractedReadme() {
    let svc = makePublishService()
    let body = makePublishBodyWithTar("acme", "demo", "1.0.0", cjpWithReadme("demo-1.0.0", "# 公开详情 README"))
    @Expect(svc.publish("acme", "demo", body).outcome == PublishOutcome.Ok, true)
    // 与 public_handler.packageDetail 相同口径：取最新未软删版本的 readme
    let rows = publicVersions(svc.store, "acme", "demo", { _ => "tester" })
    @Expect(rows.size, 1)
    var readme = ""
    for (d in svc.store.listVersions("acme", "demo")) {
        if (d.deletedAt == 0 && d.version == rows[0].version) {
            readme = d.readme
        }
    }
    @Expect(readme, "# 公开详情 README")
    let json = publicPackageDetailJson("acme", "demo", rows, readme)
    @Expect(json.contains("# 公开详情 README"), true)
}
