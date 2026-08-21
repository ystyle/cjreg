// 发布/索引/下载服务单元测试
package ystyle::cjreg.server

import ystyle::cjreg.protocol.*
import ystyle::cjreg.index.*
import ystyle::cjreg.store.*
import bstorm.*
import std.unittest.testmacro.*
import std.collection.*

// 构造一段 [version(1B)][size(4B LE)][data]
func makeSection(version: UInt8, data: Array<Byte>): ArrayList<Byte> {
    let buf = ArrayList<Byte>()
    buf.add(version)
    let size = data.size
    buf.add(UInt8(size & 0xFF))
    buf.add(UInt8((size >> 8) & 0xFF))
    buf.add(UInt8((size >> 16) & 0xFF))
    buf.add(UInt8((size >> 24) & 0xFF))
    for (b in data) {
        buf.add(b)
    }
    return buf
}

func toByteArray(list: ArrayList<Byte>): Array<Byte> {
    list.toArray()
}

func makeStore(): PackageStore {
    PackageStore(Storm.inMemory())
}

func makePublishService(): PublishService {
    PublishService(makeStore())
}

// 构造一个合法发布 body：meta（含 index.sha256sum）+ tar
func makePublishBody(org: String, name: String, version: String, sha: String): Array<Byte> {
    let meta = "{\"organization\":\"${org}\",\"name\":\"${name}\",\"version\":\"${version}\"," +
        "\"index\":{\"sha256sum\":\"${sha}\",\"index-version\":1}}"
    let tar: Array<Byte> = [UInt8(31), UInt8(139), UInt8(8), UInt8(0), UInt8(1)]
    let buf = ArrayList<Byte>()
    for (b in makeSection(META_VERSION, meta.toArray())) {
        buf.add(b)
    }
    for (b in makeSection(TARBALL_VERSION, tar)) {
        buf.add(b)
    }
    toByteArray(buf)
}

// 让 meta 的 sha 与指定 tar 一致
func makePublishBodyWithTar(org: String, name: String, version: String, tar: Array<Byte>): Array<Byte> {
    let sha = sha256Hex(tar)
    let meta = "{\"organization\":\"${org}\",\"name\":\"${name}\",\"version\":\"${version}\"," +
        "\"index\":{\"sha256sum\":\"${sha}\",\"index-version\":1}}"
    let buf = ArrayList<Byte>()
    for (b in makeSection(META_VERSION, meta.toArray())) {
        buf.add(b)
    }
    for (b in makeSection(TARBALL_VERSION, tar)) {
        buf.add(b)
    }
    toByteArray(buf)
}

// 让 meta 的 sha 与 tar 实际一致
func makePublishBodyConsistent(org: String, name: String, version: String): Array<Byte> {
    let tar: Array<Byte> = [UInt8(31), UInt8(139), UInt8(8), UInt8(0), UInt8(1)]
    makePublishBodyWithTar(org, name, version, tar)
}

@Test
func testSha256Hex() {
    let sha = sha256Hex("hello".toArray())
    // sha256("hello") 已知值
    @Expect(sha, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
}

@Test
func testPublishOk() {
    let svc = makePublishService()
    let body = makePublishBodyConsistent("test", "demo", "1.0.0")
    let r = svc.publish("test", "demo", body)
    @Expect(r.outcome == PublishOutcome.Ok, true)
    @Expect(r.pkgId > 0, true)
    // 同版本同 sha → 幂等 Ok
    let r2 = svc.publish("test", "demo", body)
    @Expect(r2.outcome == PublishOutcome.Ok, true)
}

@Test
func testPublishInvalidFormat() {
    let svc = makePublishService()
    // 空 body
    let r = svc.publish("test", "demo", Array<Byte>())
    @Expect(r.outcome == PublishOutcome.InvalidFormat, true)
}

@Test
func testPublishMetaMismatch() {
    let svc = makePublishService()
    let body = makePublishBodyConsistent("test", "demo", "1.0.0")
    // URL name 与 meta 不一致
    let r = svc.publish("test", "other", body)
    @Expect(r.outcome == PublishOutcome.MetaMismatch, true)
    // URL org 与 meta 不一致
    let r2 = svc.publish("wrong", "demo", body)
    @Expect(r2.outcome == PublishOutcome.MetaMismatch, true)
}

@Test
func testPublishShaMismatch() {
    let svc = makePublishService()
    // meta 声明的 sha 与实际 tar 不同
    let body = makePublishBody("test", "demo", "1.0.0", "0000000000000000000000000000000000000000000000000000000000000000")
    let r = svc.publish("test", "demo", body)
    @Expect(r.outcome == PublishOutcome.ShaMismatch, true)
}

@Test
func testPublishConflict() {
    let svc = makePublishService()
    // 先发版本 A（tar1）
    let tar1: Array<Byte> = [UInt8(31), UInt8(139), UInt8(8), UInt8(0), UInt8(1)]
    let bodyA = makePublishBodyWithTar("test", "demo", "1.0.0", tar1)
    svc.publish("test", "demo", bodyA)
    // 同版本不同 tar（sha 不同）→ 冲突
    let tar2: Array<Byte> = [UInt8(31), UInt8(139), UInt8(8), UInt8(0), UInt8(99)]
    let bodyB = makePublishBodyWithTar("test", "demo", "1.0.0", tar2)
    let r = svc.publish("test", "demo", bodyB)
    @Expect(r.outcome == PublishOutcome.Conflict, true)
}

@Test
func testIndexAndDownload() {
    let store = makeStore()
    let svc = PublishService(store)
    let body = makePublishBodyConsistent("test", "demo", "1.0.0")
    svc.publish("test", "demo", body)
    // 再发一个版本
    let body2 = makePublishBodyConsistent("test", "demo", "1.1.0")
    svc.publish("test", "demo", body2)

    // 索引生成
    let idxSvc = IndexService(store)
    let ndjson = idxSvc.generate("test", "demo", false)
    let parsed = parseNDJSON(ndjson)
    @Expect(parsed.size, 2)
    @Expect(parsed[0].version, "1.0.0")
    @Expect(parsed[1].version, "1.1.0")

    // 下载 + 计数
    let dlSvc = DownloadService(store)
    let found = dlSvc.find("test", "demo", "1.0.0")
    @Expect(found.isSome(), true)
    match (found) {
        case Some(d) => @Expect(d.downloadCount, 1)
        case None => ()
    }
    // 再下载一次 → 计数 2
    dlSvc.find("test", "demo", "1.0.0")
    let after = store.getById(found.getOrThrow().id).getOrThrow()
    @Expect(after.downloadCount, 2)
    // 不存在版本 → None
    @Expect(dlSvc.find("test", "demo", "9.9.9").isNone(), true)
}
