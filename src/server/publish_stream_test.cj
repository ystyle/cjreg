// 流式发布的单测：覆盖正常路径与三条异常路径（sha 不符 / 传输中断 / 段头非法），
// 并断言临时文件不残留、库内不出现半成品 blob。
//
// 测试用数据只在仓内 .smoke/ 下自建自清（生产数据目录在 ~/docker，不参与测试）。
package ystyle::cjreg.server

import ystyle::cjreg.protocol.*
import ystyle::cjreg.store.*
import std.io.*
import std.fs.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

// 可控的输入流：可按块上限返回（模拟网络短读），也可在读到第 n 字节后"断流"
class FakeStream <: InputStream {
    let data: Array<Byte>
    let chunk: Int64
    var pos: Int64 = 0

    init(data: Array<Byte>, chunk!: Int64 = 1) {
        this.data = data
        this.chunk = chunk
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (this.pos >= this.data.size) {
            return 0
        }
        var n = buffer.size
        if (n > this.chunk) {
            n = this.chunk
        }
        let remain = this.data.size - this.pos
        if (n > remain) {
            n = remain
        }
        var i: Int64 = 0
        while (i < n) {
            buffer[i] = this.data[this.pos + i]
            i++
        }
        this.pos += n
        return n
    }
}

func streamTmpDir(tag: String): String {
    let dir = ".smoke/publish-stream-" + tag
    if (exists(dir)) {
        removeIfExists(dir, recursive: true)
    }
    Directory.create(dir, recursive: true)
    return dir
}

@Test
func testIntakeAndStreamPublishOk() {
    let dir = streamTmpDir("ok")
    let tmp = dir + "/.tmp-body"
    let body = makePublishBodyFull("s", "spok", "1.0.0")
    let stream = FakeStream(body, chunk: 7)  // 故意用很小的块，逼出短读路径
    let intake = intakePublishBody(stream, tmp)
    @Expect(intake.isSome(), true)
    let r = intake.getOrThrow()
    @Expect(r.metaData.size > 0, true)
    @Expect(r.size, 5)  // 测试体里的 tar 只有 5 字节

    let svc = PublishService(makeStore(), DiskBlobStore(dir))
    let res = svc.publishStream("s", "spok", r.metaData, r.sha256, r.size, tmp, "")
    @Expect(res.outcome == PublishOutcome.Ok, true)
    @Expect(svc.blobStore.has(r.sha256), true)      // 制品已原子进位
    @Expect(!exists(tmp), true)                      // 临时文件已 rename 走
    removeIfExists(dir, recursive: true)
}

@Test
func testStreamPublishShaMismatchCleansTmp() {
    let dir = streamTmpDir("sha")
    let tmp = dir + "/.tmp-body"
    // meta 里声明的 sha 与实际制品不符
    let tar: Array<Byte> = [UInt8(1), UInt8(2), UInt8(3), UInt8(4)]
    let meta = "{\"organization\":\"s\",\"name\":\"ssha\",\"version\":\"1.0.0\"," +
        "\"index\":{\"sha256sum\":\"deadbeef\",\"index-version\":1}}"
    let buf = ArrayList<Byte>()
    for (b in makeSection(META_VERSION, meta.toArray())) {
        buf.add(b)
    }
    for (b in makeSection(TARBALL_VERSION, tar)) {
        buf.add(b)
    }
    let body = toByteArray(buf)

    let intake = intakePublishBody(FakeStream(body, chunk: 3), tmp)
    @Expect(intake.isSome(), true)
    let r = intake.getOrThrow()
    let svc = PublishService(makeStore(), DiskBlobStore(dir))
    let res = svc.publishStream("s", "ssha", r.metaData, r.sha256, r.size, tmp, "")
    @Expect(res.outcome == PublishOutcome.ShaMismatch, true)
    @Expect(exists(tmp), false)                    // 临时文件必须已被清理
    @Expect(svc.blobStore.has(r.sha256), false)
    @Expect(svc.blobStore.has("deadbeef"), false)  // 库内不得出现半成品
    @Expect(svc.store.listVersions("s", "ssha").size, 0)
    removeIfExists(dir, recursive: true)
}

@Test
func testIntakeTruncatedBodyReturnsNone() {
    let dir = streamTmpDir("trunc")
    let tmp = dir + "/.tmp-body"
    let full = makePublishBodyFull("s", "strunc", "1.0.0")
    // 砍掉尾部 3 字节：制品段声明的长度读不满 → 必须返回 None（调用方据此回 400 并清临时文件）
    let cut = full[0..(full.size - 3)]
    let intake = intakePublishBody(FakeStream(cut, chunk: 5), tmp)
    @Expect(intake.isNone(), true)
    removeIfExists(tmp, recursive: false)
    removeIfExists(dir, recursive: true)
}

@Test
func testIntakeRejectsBadHeaderAndOversizeMeta() {
    let dir = streamTmpDir("bad")
    let tmp = dir + "/.tmp-body"
    // 1) 段版本错误
    let badVersion: Array<Byte> = [UInt8(9), UInt8(1), UInt8(0), UInt8(0), UInt8(0), UInt8(1)]
    @Expect(intakePublishBody(FakeStream(badVersion, chunk: 2), tmp).isNone(), true)
    // 2) meta 段声明超过上限
    let huge = Int64(META_MAX_BYTES) + 1
    let head: Array<Byte> = [META_VERSION,
        UInt8(huge & 0xFF), UInt8((huge >> 8) & 0xFF), UInt8((huge >> 16) & 0xFF), UInt8((huge >> 24) & 0xFF)]
    @Expect(intakePublishBody(FakeStream(head, chunk: 2), tmp).isNone(), true)
    // 3) 空流
    @Expect(intakePublishBody(FakeStream(Array<Byte>(), chunk: 2), tmp).isNone(), true)
    removeIfExists(tmp, recursive: false)
    removeIfExists(dir, recursive: true)
}

@Test
func testClaimFileIsIdempotentBySha() {
    let dir = streamTmpDir("claim")
    let store = DiskBlobStore(dir)
    let a = dir + "/.tmp-a"
    let b = dir + "/.tmp-b"
    let payload: Array<Byte> = [UInt8(7), UInt8(7), UInt8(7)]
    let sha = sha256Hex(payload)
    let fa = File(a, Write)
    fa.write(payload)
    fa.close()
    let fb = File(b, Write)
    fb.write(payload)
    fb.close()
    store.claimFile(sha, a)
    @Expect(store.has(sha), true)
    @Expect(exists(a), false)
    store.claimFile(sha, b)   // 同一内容第二次认领：丢弃临时文件，不报错、不覆盖
    @Expect(store.has(sha), true)
    @Expect(exists(b), false)
    let back = store.get(sha)
    @Expect(back.isSome(), true)
    @Expect(back.getOrThrow().size, 3)
    removeIfExists(dir, recursive: true)
}

@Test
func testStreamPublishSameVersionDifferentShaIsRejectedInOpenMode() {
    let dir = streamTmpDir("overwrite")
    let store = makeStore()
    let svc = PublishService(store, DiskBlobStore(dir))
    // 第一次发布
    let tar1: Array<Byte> = [UInt8(1), UInt8(2), UInt8(3)]
    let body1 = makeBodyWithTar("s", "sow", "1.0.0", tar1)
    let r1 = mustIntake(body1, dir + "/.tmp-1")
    let res1 = svc.publishStream("s", "sow", r1.metaData, r1.sha256, r1.size, dir + "/.tmp-1", "")
    @Expect(res1.outcome == PublishOutcome.Ok, true)
    // open 模式下同版本不同 sha 必须被拒（既有语义：不静默覆盖），临时文件不残留
    let tar2: Array<Byte> = [UInt8(9), UInt8(9), UInt8(9), UInt8(9)]
    let body2 = makeBodyWithTar("s", "sow", "1.0.0", tar2)
    let r2 = mustIntake(body2, dir + "/.tmp-2")
    let res2 = svc.publishStream("s", "sow", r2.metaData, r2.sha256, r2.size, dir + "/.tmp-2", "")
    @Expect(res2.outcome == PublishOutcome.Conflict, true)
    @Expect(res2.pkgId, res1.pkgId)              // 仍指向同一文档
    @Expect(!exists(dir + "/.tmp-2"), true)      // 被拒时临时文件必须清掉
    @Expect(svc.blobStore.has(r2.sha256), false) // 不得把被拒的制品写进库
    removeIfExists(dir, recursive: true)
}

// 组一个「meta 的 sha 与制品一致」的发布体（指定制品内容）
func makeBodyWithTar(org: String, name: String, version: String, tar: Array<Byte>): Array<Byte> {
    let meta = "{\"organization\":\"${org}\",\"name\":\"${name}\",\"version\":\"${version}\"," +
        "\"index\":{\"sha256sum\":\"${sha256Hex(tar)}\",\"index-version\":1}}"
    let buf = ArrayList<Byte>()
    for (b in makeSection(META_VERSION, meta.toArray())) {
        buf.add(b)
    }
    for (b in makeSection(TARBALL_VERSION, tar)) {
        buf.add(b)
    }
    toByteArray(buf)
}

func mustIntake(body: Array<Byte>, tmp: String): IntakeResult {
    let r = intakePublishBody(FakeStream(body, chunk: 64), tmp)
    if (r.isNone()) {
        @Fail("intake 应当成功")
    }
    return r.getOrThrow()
}
