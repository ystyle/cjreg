// 包存储单元测试（bstorm inMemory）
package ystyle::cjreg.store

import bstorm.*
import std.unittest.testmacro.*
import std.collection.*

func makeStore(): PackageStore {
    let storm = Storm.inMemory()
    PackageStore(storm)
}

func makeDoc(name: String, version: String, publisher: Int64): PackageDoc {
    let d = PackageDoc()
    d.organization = "test"
    d.name = name
    d.version = version
    d.cjcVersion = "1.1.0"
    d.publisherId = publisher
    d.indexJson = "{\"name\":\"${name}\"}"
    d
}

@Test
func testSaveAndGet() {
    let store = makeStore()
    let d = makeDoc("demo", "1.0.0", 1)
    store.save(d)
    let got = store.getById(d.id)
    match (got) {
        case Some(g) =>
            @Expect(g.name, "demo")
            @Expect(g.version, "1.0.0")
            @Expect(g.publisherId, 1)
            @Expect(g.indexJson.contains("demo"), true)
        case None => @Fail("get should succeed")
    }
}

@Test
func testListVersions() {
    let store = makeStore()
    store.save(makeDoc("demo", "1.0.0", 1))
    store.save(makeDoc("demo", "1.1.0", 2))
    store.save(makeDoc("other", "1.0.0", 1))

    let versions = store.listVersions("test", "demo")
    @Expect(versions.size, 2)
    // 按 org 过滤
    let none = store.listVersions("wrong", "demo")
    @Expect(none.size, 0)
}

@Test
func testDownloadCount() {
    let store = makeStore()
    let d = makeDoc("demo", "1.0.0", 1)
    store.save(d)
    store.incrDownload(d)
    store.incrDownload(d)
    let got = store.getById(d.id).getOrThrow()
    @Expect(got.downloadCount, 2)
}

@Test
func testSoftDeleteRestore() {
    let store = makeStore()
    let d = makeDoc("demo", "1.0.0", 1)
    store.save(d)
    store.softDelete(d, 1000)
    let deleted = store.getById(d.id).getOrThrow()
    @Expect(deleted.deletedAt, 1000)
    store.restore(deleted)
    let restored = store.getById(d.id).getOrThrow()
    @Expect(restored.deletedAt, 0)
}
