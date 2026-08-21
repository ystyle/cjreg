// 官方发布二进制格式解析（对齐 cjrepo internal/protocol/parser.go）
// 格式：[meta 段] meta-version(1B) + size(4B LE) + meta-data.json bytes
//       [tar 段]  index-version(1B) + size(4B LE) + .cjp bytes
package ystyle::cjreg.protocol

import std.collection.*

public let META_VERSION: UInt8 = 1
public let TARBALL_VERSION: UInt8 = 1
public let HEADER_SIZE: Int64 = 5  // 1 byte version + 4 bytes size
public let MAX_FILE_SIZE: Int64 = 500 * 1024 * 1024  // 500MB

// 发布请求：meta-data.json 与 .cjp 制品字节
public class PublishData {
    public var metaData: Array<Byte>
    public var tarball: Array<Byte>

    public init(metaData: Array<Byte>, tarball: Array<Byte>) {
        this.metaData = metaData
        this.tarball = tarball
    }
}

// 解析 cjpm publish 二进制数据；格式非法返回 None
public func parsePublishData(data: Array<Byte>): ?PublishData {
    var offset: Int64 = 0
    let meta = readSection(data, offset, META_VERSION)
    if (meta.isNone()) {
        return None
    }
    offset += HEADER_SIZE + (meta.getOrThrow()).size
    let tar = readSection(data, offset, TARBALL_VERSION)
    if (tar.isNone()) {
        return None
    }
    return Some(PublishData(meta.getOrThrow(), tar.getOrThrow()))
}

// 读取一个数据段：[version(1B)][size(4B LE)][data(size)]
// 返回读取后的数据；非法返回 None
public func readSection(data: Array<Byte>, offset: Int64, expectedVersion: UInt8): ?Array<Byte> {
    if (offset + HEADER_SIZE > data.size) {
        return None  // 数据不完整
    }
    let version = data[offset]
    if (version != expectedVersion) {
        return None  // 段版本不匹配
    }
    let size = readLE32(data, offset + 1)
    if (size < 0 || Int64(size) > MAX_FILE_SIZE) {
        return None  // 长度非法
    }
    if (offset + HEADER_SIZE + Int64(size) > data.size) {
        return None  // 数据不足
    }
    return Some(data[offset + HEADER_SIZE..offset + HEADER_SIZE + Int64(size)])
}

// 读 4 字节小端 Int32
func readLE32(data: Array<Byte>, offset: Int64): Int32 {
    let b0 = Int32(data[offset])
    let b1 = Int32(data[offset + 1])
    let b2 = Int32(data[offset + 2])
    let b3 = Int32(data[offset + 3])
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

// SHA-256（小端 hex 串）——制品校验用
// TODO(M2)：接入 stdx.crypto，当前先提供占位以对齐协议签名
public func calculateSHA256(data: Array<Byte>): String {
    return ""
}
