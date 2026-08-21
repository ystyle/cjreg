// 官方发布二进制格式解析单元测试
package ystyle::cjreg.protocol

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

func metaBytes(): Array<Byte> {
    "{\"name\":\"demo\",\"version\":\"1.0.0\"}".toArray()
}

func tarBytes(): Array<Byte> {
    // 模拟 .cjp 制品（非真实 tar.gz，仅字节）
    [UInt8(31), UInt8(139), UInt8(8), UInt8(0), UInt8(1)]
}

@Test
func testParsePublishDataOk() {
    let buf = ArrayList<Byte>()
    let meta = metaBytes()
    let tar = tarBytes()
    for (b in makeSection(META_VERSION, meta)) {
        buf.add(b)
    }
    for (b in makeSection(TARBALL_VERSION, tar)) {
        buf.add(b)
    }
    let parsed = parsePublishData(toByteArray(buf))
    match (parsed) {
        case Some(pd) =>
            @Expect(pd.metaData.size, meta.size)
            @Expect(pd.tarball.size, tar.size)
            @Expect(pd.metaData[0], meta[0])
            @Expect(pd.tarball[0], tar[0])
        case None => @Fail("parse should succeed")
    }
}

@Test
func testParsePublishDataEmpty() {
    // 空数据 → 失败
    @Expect(parsePublishData(Array<Byte>()).isNone(), true)
}

@Test
func testParseVersionMismatch() {
    let buf = ArrayList<Byte>()
    for (b in makeSection(UInt8(9), metaBytes())) {
        buf.add(b)
    }
    for (b in makeSection(TARBALL_VERSION, tarBytes())) {
        buf.add(b)
    }
    @Expect(parsePublishData(toByteArray(buf)).isNone(), true)
}

@Test
func testParseTruncated() {
    // 只有 meta 段没有 tar 段 → 失败
    let buf = ArrayList<Byte>()
    for (b in makeSection(META_VERSION, metaBytes())) {
        buf.add(b)
    }
    @Expect(parsePublishData(toByteArray(buf)).isNone(), true)
}

@Test
func testReadSectionTooLarge() {
    // size 声明过大（> 实际数据）→ 失败
    let data: Array<Byte> = [
        UInt8(1),
        UInt8(255), UInt8(255), UInt8(255), UInt8(127),  // 2147483647（Int32 max）
    ]
    @Expect(readSection(data, 0, META_VERSION).isNone(), true)
}
