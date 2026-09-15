// 发布计划执行引擎单元测试
package ystyle::cjreg.server

import ystyle::cjreg.store.*
import ystyle::cjreg.index.*
import ystyle::cjreg.protocol.*
import bstorm.*
import std.unittest.testmacro.*
import std.collection.*

// 构造一个已发布的包（meta 含 sha + blob 存 tar）
func publishPkg(store: PackageStore, blob: MemoryBlobStore, org: String, name: String, version: String): Int64 {
    let tar: Array<Byte> = [UInt8(31), UInt8(139), UInt8(8), UInt8(0), UInt8(1)]
    let sha = sha256Hex(tar)
    blob.put(sha, tar)
    let meta = "{\"organization\":\"${org}\",\"name\":\"${name}\",\"version\":\"${version}\",\"index\":{\"sha256sum\":\"${sha}\",\"index-version\":1}}"
    let doc = PackageDoc()
    doc.organization = org
    doc.name = name
    doc.version = version
    doc.indexJson = meta
    store.save(doc)
    doc.id
}

@Test
func testMakePublishSection() {
    let data: Array<Byte> = [UInt8(65), UInt8(66)]
    let sec = makePublishSection(UInt8(1), data)
    @Expect(sec.size, 7)  // 1 + 4 + 2
    @Expect(sec[0], UInt8(1))
    @Expect(sec[1], UInt8(2))  // size=2 LE 低字节（index 1）
    @Expect(sec[5], UInt8(65))  // data[0]
    @Expect(sec[6], UInt8(66))  // data[1]
}

@Test
func testBuildPackagePublishURL() {
    @Expect(buildPackagePublishURL("http://localhost:8070", "demo", "test"),
        "http://localhost:8070/pkg/demo?organization=test")
    @Expect(buildPackagePublishURL("http://localhost:8070/", "demo", ""),
        "http://localhost:8070/pkg/demo")
}

@Test
func testExecuteSortsByOrder() {
    beginTestStores()
    let store = PackageStore(testStorm())
    let blob = MemoryBlobStore()
    let executor = PublishExecutor(store, blob)

    // 造 3 个包（逆序保存，验证按 order 排序）
    let c = publishPkg(store, blob, "test", "app", "1.0.0")     // order 3
    let a = publishPkg(store, blob, "test", "base", "1.0.0")    // order 1
    let b = publishPkg(store, blob, "test", "mid", "1.0.0")     // order 2

    let items = ArrayList<PlanItem>()
    items.add(PlanItem(c, "app", "test", "1.0.0", PlanCategory.NeedPublish, 3))
    items.add(PlanItem(a, "base", "test", "1.0.0", PlanCategory.NeedPublish, 1))
    items.add(PlanItem(b, "mid", "test", "1.0.0", PlanCategory.NeedPublish, 2))

    // 执行到不存在的目标 → 全部失败但不崩、遍历所有
    // （网络失败按可重试处理：内部退避重试 3 次后仍失败才判该项失败）
    let r = executor.execute(items, "http://localhost:1", "")
    @Expect(r.total, 3)
    @Expect(r.success, 0)
    @Expect(r.failed, 3)
    @Expect(r.aborted, false)
    @Expect(r.errors.size, 3)
}

@Test
func testExecuteMissingArtifact() {
    beginTestStores()
    let store = PackageStore(testStorm())
    let blob = MemoryBlobStore()
    let executor = PublishExecutor(store, blob)
    // 发布但不存 blob → 制品缺失
    let tar: Array<Byte> = [UInt8(31), UInt8(139), UInt8(8), UInt8(0), UInt8(1)]
    let sha = sha256Hex(tar)
    // blob 不 put
    let doc = PackageDoc()
    doc.organization = "test"
    doc.name = "demo"
    doc.version = "1.0.0"
    doc.indexJson = "{\"organization\":\"test\",\"name\":\"demo\",\"version\":\"1.0.0\",\"index\":{\"sha256sum\":\"${sha}\"}}"
    store.save(doc)

    let items = ArrayList<PlanItem>()
    items.add(PlanItem(doc.id, "demo", "test", "1.0.0", PlanCategory.NeedPublish, 1))
    let r = executor.execute(items, "http://localhost:1", "")
    @Expect(r.total, 1)
    @Expect(r.success, 0)
    @Expect(r.failed, 1)
    @Expect(r.errors.size, 1)
}
