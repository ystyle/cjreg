// 制品流式读取的单测：下载路径改成流式后，正确性必须由"分块读回内容一致"来守。
//
// 重点覆盖：磁盘/内存两种实现的往返、**按小块多次读**（证明不依赖整包缓冲）、
// 以及制品不存在时返回 None（下载侧据此回 404）。
package ystyle::cjreg.server

import std.io.*
import std.fs.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

func streamTmp(tag: String): String {
    let dir = ".smoke/blob-stream-" + tag
    if (exists(dir)) {
        removeIfExists(dir, recursive: true)
    }
    Directory.create(dir, recursive: true)
    return dir
}

// 用小缓冲把流读完（不借助 readStreamToBytes，避免掩盖"是否真分块"）
func drain(stream: InputStream, bufSize: Int64): Array<Byte> {
    let out = ArrayList<Byte>()
    let buf = Array<Byte>(bufSize, repeat: 0)
    while (true) {
        let n = stream.read(buf)
        if (n <= 0) {
            break
        }
        var i: Int64 = 0
        while (i < n) {
            out.add(buf[i])
            i++
        }
    }
    out.toArray()
}

@Test
func testDiskBlobStreamRoundTrip() {
    let dir = streamTmp("roundtrip")
    let store = DiskBlobStore(dir)
    let payload: Array<Byte> = [UInt8(7), UInt8(8), UInt8(9), UInt8(10), UInt8(11)]
    let sha = sha256Hex(payload)
    store.put(sha, payload)

    let st = store.stream(sha)
    @Expect(st.isSome(), true)
    let back = drain(st.getOrThrow(), 2)   // 缓冲比制品还小 → 必然多次 read
    @Expect(back.size, payload.size)
    @Expect(sha256Hex(back), sha)
    removeIfExists(dir, recursive: true)
}

@Test
func testDiskBlobStreamChunkedLargeArtifact() {
    // 8 MiB 制品：按 64 KiB 分块读回，内容与 sha 必须一致
    let dir = streamTmp("large")
    let store = DiskBlobStore(dir)
    let payload = Array<Byte>(8 * 1024 * 1024, repeat: UInt8(42))
    let sha = sha256Hex(payload)
    store.put(sha, payload)

    let st = store.stream(sha)
    @Expect(st.isSome(), true)
    let back = drain(st.getOrThrow(), 64 * 1024)
    @Expect(back.size, payload.size)
    @Expect(sha256Hex(back), sha)
    removeIfExists(dir, recursive: true)
}

@Test
func testDiskBlobStreamMissingReturnsNone() {
    let dir = streamTmp("missing")
    let store = DiskBlobStore(dir)
    @Expect(store.stream("deadbeef").isNone(), true)
    removeIfExists(dir, recursive: true)
}

@Test
func testMemoryBlobStreamChunked() {
    let store = MemoryBlobStore()
    let payload = Array<Byte>(100 * 1024, repeat: UInt8(3))
    let sha = sha256Hex(payload)
    store.put(sha, payload)
    let st = store.stream(sha)
    @Expect(st.isSome(), true)
    @Expect(sha256Hex(drain(st.getOrThrow(), 4096)), sha)
    @Expect(store.stream("nope").isNone(), true)
}

@Test
func testStreamSeesLatestAfterClaimFile() {
    // 流式认领（流式发布路径）之后必须能立刻流式读回：两条链路共用同一个 sha 定位
    let dir = streamTmp("claim")
    let store = DiskBlobStore(dir)
    let tmp = dir + "/.tmp-x"
    let payload = Array<Byte>(32 * 1024, repeat: UInt8(5))
    let sha = sha256Hex(payload)
    let f = File(tmp, Write)
    f.write(payload)
    f.close()
    store.claimFile(sha, tmp)
    let st = store.stream(sha)
    @Expect(st.isSome(), true)
    @Expect(sha256Hex(drain(st.getOrThrow(), 1024)), sha)
    removeIfExists(dir, recursive: true)
}
