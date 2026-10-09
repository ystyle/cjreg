// 代理回源 · 制品存储：BlobStore 接口（内容寻址）与内存 / 磁盘两种实现，
// 以及内存 blob 的流式包装
package ystyle::cjreg.server

import ystyle::cjreg.protocol.*
import ystyle::cjreg.index.*
import ystyle::cjreg.config.*
import ystyle::cjreg.store.*
import stdx.net.http.*
import stdx.crypto.digest.SHA256
import stdx.encoding.hex.toHexString
import stdx.net.tls.*
import stdx.net.tls.common.*
import stdx.encoding.url.URL
import std.collection.*
import std.io.*
import std.fs.*
import std.convert.*

// 制品字节存储接口（blob 内容寻址；M4 先内存/后续落盘）
public interface BlobStore {
    func put(sha256: String, data: Array<Byte>): Unit
    func get(sha256: String): ?Array<Byte>
    // 删除制品（硬删除时联动清理）；返回是否真的删掉了
    func remove(sha256: String): Bool
    // 制品是否存在（恢复时校验「tarball 仍在」）
    // 注意：不能叫 exists——DiskBlobStore 内部要用 std.fs.exists(path)，
    // 同名成员会让方法体里的 exists(...) 解析成自身递归（实测触发 Out of memory）
    func has(sha256: String): Bool
    // 原子认领一个已写好的临时文件为制品：目标已存在（内容寻址去重）则丢弃临时文件，
    // 否则 rename 进位 —— 先落临时文件再 rename，读者不会看到半成品。
    // 供**流式发布**使用：制品不再整包驻留内存。
    func claimFile(sha256: String, tmpPath: String): Unit
    // 流式读取制品：下载路径用它把字节直接接到 HTTP 响应，**不整包驻留内存**。
    // 返回 None 表示制品不存在。
    func stream(sha256: String): ?InputStream
}

// 把内存中的制品包装成 InputStream（内存 blob 模式用；磁盘模式直接返回 File 流）
class BytesStream <: InputStream {
    let data: Array<Byte>
    var pos: Int64 = 0

    init(data: Array<Byte>) {
        this.data = data
    }

    public func read(buffer: Array<Byte>): Int64 {
        if (this.pos >= this.data.size) {
            return 0
        }
        var n = buffer.size
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

public class MemoryBlobStore <: BlobStore {
    public var blobs: HashMap<String, Array<Byte>>

    public init() {
        this.blobs = HashMap<String, Array<Byte>>()
    }

    public func put(sha256: String, data: Array<Byte>): Unit {
        this.blobs.add(sha256, data)
    }

    public func stream(sha256: String): ?InputStream {
        match (this.blobs.get(sha256)) {
            case Some(d) => Some(BytesStream(d))
            case None => None
        }
    }

    public func claimFile(sha256: String, tmpPath: String): Unit {
        // 内存实现只能把临时文件读回来（生产流式路径走 DiskBlobStore，不经过这里）
        try {
            let f = File(tmpPath, Read)
            let bytes = readToEnd(f)
            f.close()
            this.blobs.add(sha256, bytes)
            removeIfExists(tmpPath, recursive: false)
        } catch (e: Exception) {
            println("[blob] claimFile failed ${sha256}: ${e.message}")
        }
    }

    public func get(sha256: String): ?Array<Byte> {
        if (this.blobs.contains(sha256)) {
            return Some(this.blobs.get(sha256).getOrThrow())
        }
        return None
    }

    public func remove(sha256: String): Bool {
        if (this.blobs.contains(sha256)) {
            this.blobs.remove(sha256)
            return true
        }
        return false
    }

    public func has(sha256: String): Bool {
        this.blobs.contains(sha256)
    }
}

// 磁盘制品存储（持久化到 dataDir/blobs/{sha256}）
public class DiskBlobStore <: BlobStore {
    public var dir: String

    public init(dir: String) {
        this.dir = dir
        if (exists(dir)) {
            return
        }
        try {
            Directory.create(dir, recursive: true)
        } catch (e: Exception) {
            // 竞态下别的进程刚建好 → 不算失败；真建不出来（权限/磁盘满）才报 —— 这是持久化路径的
            // 起点，静默会让后续每次 put 各自报错、丢掉根因。
            if (!exists(dir)) {
                println("[cjreg] 制品目录创建失败 " + dir + ": " + e.toString())
            }
        }
    }

    public func put(sha256: String, data: Array<Byte>): Unit {
        try {
            let f = File(dir + "/" + sha256, Write)
            f.write(data)
            f.close()
        } catch (e: Exception) {
            println("[blob] put failed ${sha256}: ${e.message}")
        }
    }

    public func stream(sha256: String): ?InputStream {
        let path = dir + "/" + sha256
        if (!exists(path)) {
            return None
        }
        try {
            return Some(File(path, Read))
        } catch (e: Exception) {
            println("[cjreg] 制品流式打开失败 " + path + ": " + e.toString())
            return None
        }
    }

    public func claimFile(sha256: String, tmpPath: String): Unit {
        let target = dir + "/" + sha256
        try {
            if (exists(target)) {
                removeIfExists(tmpPath, recursive: false)  // 内容寻址天然幂等：同一制品已在盘上
                return
            }
            rename(tmpPath, to: target)  // 原子进位
        } catch (e: Exception) {
            println("[blob] claimFile failed ${sha256}: ${e.message}")
        }
    }

    public func get(sha256: String): ?Array<Byte> {
        let path = dir + "/" + sha256
        if (!exists(path)) {
            return None
        }
        try {
            let f = File(path, Read)
            let bytes = readToEnd(f)
            f.close()
            return Some(bytes)
        } catch (e: Exception) {
            // 制品在盘上但读失败（被截断/权限/IO 错）此前被当成「制品不存在」，
            // 上层据此报「制品缺失（sha=…）」——把 IO 故障误报成数据丢失。
            println("[cjreg] 制品读取失败 " + path + ": " + e.toString())
            return None
        }
    }

    public func remove(sha256: String): Bool {
        let path = dir + "/" + sha256
        if (!exists(path)) {
            return false
        }
        try {
            removeIfExists(path, recursive: false)
            return true
        } catch (e: Exception) {
            println("[blob] remove failed ${sha256}: ${e.message}")
            return false
        }
    }

    public func has(sha256: String): Bool {
        exists(dir + "/" + sha256)
    }
}
