// 发布体的**流式**接收：段头 → meta 段 → 段头 → 制品。
//
// 为什么需要它：官方协议允许单段 500 MB，而此前 `POST /pkg` 用 `ctx.bodyRaw()` 把整个请求体读进内存
// 再切片，峰值内存 ≈ 包体 2–3 倍；仓颉运行时 GC 堆默认 256 MB，40 MiB 以上的包就可能触顶。
// 这里改为边读边算：制品按固定块喂 SHA256，同时写入临时文件；读满后由调用方比对 meta 里声明的
// sha256sum，一致才 rename 进位（内容寻址，天然去重且原子可见）。
//
// 格式（对齐 cjrepo internal/protocol/parser.go）：
//   [meta 段]    meta-version(1B) + size(4B LE) + meta-data.json
//   [tar 段]     tar-version(1B)  + size(4B LE) + .cjp 制品
package ystyle::cjreg.protocol

import std.io.*
import std.fs.*
import stdx.crypto.digest.SHA256
import stdx.encoding.hex.toHexString

// 流式读的块大小：1 MiB（吞吐与内存的折中）
public let INTAKE_BLOCK_SIZE: Int64 = 1024 * 1024
// meta 段上限：meta-data.json 正常几 KB，给足余量的同时挡住"声明一个超大 meta 段"的放大攻击
public let META_MAX_BYTES: Int64 = 64 * 1024 * 1024

// 一次流式接收的结果：meta 原文、制品 sha256（十六进制）、制品长度
public struct IntakeResult {
    public let metaData: Array<Byte>
    public let sha256: String
    public let size: Int64

    public init(metaData: Array<Byte>, sha256: String, size: Int64) {
        this.metaData = metaData
        this.sha256 = sha256
        this.size = size
    }
}

// 读满 n 字节；不足（截断）返回 None
func readExactly(reader: InputStream, n: Int64): ?Array<Byte> {
    if (n < 0) {
        return None
    }
    let buf = Array<Byte>(n, repeat: 0)
    var got: Int64 = 0
    while (got < n) {
        let r = reader.read(buf[got..n])
        if (r <= 0) {
            return None  // 客户端截断
        }
        got += r
    }
    return Some(buf)
}

// 从流式请求体接收一次发布；格式非法 / 超限 / 截断 → None（调用方负责删除临时文件并回 400）
public func intakePublishBody(reader: InputStream, tmpPath: String): ?IntakeResult {
    // 段 1：meta
    let h1 = readExactly(reader, HEADER_SIZE)
    if (h1.isNone()) {
        return None
    }
    let head1 = h1.getOrThrow()
    if (head1[0] != META_VERSION) {
        return None
    }
    let metaLen = Int64(readLE32(head1, 1))
    if (metaLen <= 0 || metaLen > META_MAX_BYTES) {
        return None
    }
    let metaOpt = readExactly(reader, metaLen)
    if (metaOpt.isNone()) {
        return None
    }

    // 段 2：制品
    let h2 = readExactly(reader, HEADER_SIZE)
    if (h2.isNone()) {
        return None
    }
    let head2 = h2.getOrThrow()
    if (head2[0] != TARBALL_VERSION) {
        return None
    }
    let tarLen = Int64(readLE32(head2, 1))
    if (tarLen <= 0 || tarLen > MAX_FILE_SIZE) {
        return None
    }

    // 制品：按块读 → 同时喂 SHA256 与临时文件（内存占用与包体无关）
    let sha = SHA256()
    var out: ?File = None
    try {
        out = Some(File(tmpPath, Write))
    } catch (e: Exception) {
        println("[cjreg] 临时制品文件创建失败 ${tmpPath}: ${e.toString()}")
        return None
    }
    let f = out.getOrThrow()
    let buf = Array<Byte>(INTAKE_BLOCK_SIZE, repeat: 0)
    var remaining = tarLen
    try {
        while (remaining > 0) {
            let want = if (remaining < INTAKE_BLOCK_SIZE) { remaining } else { INTAKE_BLOCK_SIZE }
            let r = reader.read(buf[0..want])
            if (r <= 0) {
                f.close()
                return None  // 传输中断：临时文件由调用方删除
            }
            sha.write(buf[0..r])
            f.write(buf[0..r])
            remaining -= r
        }
    } catch (e: Exception) {
        println("[cjreg] 制品流式落盘失败 ${tmpPath}: ${e.toString()}")
        try {
            f.close()
        } catch (_: Exception) {
            ()
        }
        return None
    }
    try {
        f.close()
    } catch (e: Exception) {
        println("[cjreg] 临时制品文件关闭失败 ${tmpPath}: ${e.toString()}")
        return None
    }
    return Some(IntakeResult(metaOpt.getOrThrow(), toHexString(sha.finish()), tarLen))
}
