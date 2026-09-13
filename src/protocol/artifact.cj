// 制品内容提取：.cjp（gzip + tar）内的 README 与 cjpm.toml
//
// 为什么必须在服务端从制品里提取：
//   - 官方发布协议（见 binary.cj）是「meta-data.json 段 + .cjp 段」，**README 不在 meta 里**；
//   - 索引协议（NDJSON）只带 name/version/deps/sha256sum，**展示字段一律不在索引里**；
//   - 于是「回源聚合落库」的包只有索引字段 —— 列表页描述全空、详情页没有 README。
// 制品本身带着 README.md 与 cjpm.toml（description/license/authors/repository/tag…），
// 上传与回源时顺手提取，是唯一可靠来源（对齐 cjrepo internal/handlers/publish.go extractReadmeFromTarball）。
//
// 失败绝不阻断发布：提取失败只写 error，调用方记录后继续。
package ystyle::cjreg.protocol

import std.collection.*
import std.io.*
import stdx.compress.zlib.*
import ystyle::tar.{Header, Reader, TarException}
import tomlcj.{Decoder, TomlArray, TomlObject, TomlValue}

// 制品内提取结果
public class ArtifactFiles {
    // README 正文（README_zh.md 优先，其次 README.md）
    public var readme: String = ""
    // 包根 cjpm.toml 原文（最浅层那份）
    public var cjpmToml: String = ""
    // 归档条目数（诊断用）
    public var entries: Int64 = 0
    // 硬失败：gzip/tar 打不开、归档中途损坏（非 EOF）。非空时 readme/cjpmToml 可能为空
    public var error: String = ""
    // 软提示：能打开但没找到 README（合法的数据缺口，不算失败）
    public var note: String = ""

    public init() {}

    // 无硬失败
    public func ok(): Bool {
        return this.error.isEmpty()
    }
}

// 从 .cjp 制品提取 README 与 cjpm.toml（不抛异常）
public func extractArtifactFiles(tarball: Array<Byte>): ArtifactFiles {
    let out = ArtifactFiles()
    if (tarball.size == 0) {
        out.error = "empty artifact"
        return out
    }
    var gz: ?DecompressInputStream = None
    try {
        let stream = DecompressInputStream(ByteBuffer(tarball), wrap: GzipFormat, bufLen: 8192)
        gz = Some(stream)
        let reader = Reader(stream)
        var readmeZh = ""
        var readme = ""
        var toml = ""
        var tomlDepth: Int64 = -1
        while (true) {
            var hdr: ?Header = None
            try {
                hdr = Some(reader.next())
            } catch (e: TarException) {
                // 正常结束 = 两个零块（tar 约定）；其余 TarException 是归档损坏 → 让调用方看见
                if (e.msg != "EOF") {
                    out.error = "tar: " + e.toString()
                }
                break
            }
            let h = hdr.getOrThrow()
            out.entries++
            let low = h.name.toAsciiLower()
            let wantReadmeZh = matchesName(low, "readme_zh.md")
            let wantReadme = matchesName(low, "readme.md")
            let wantToml = matchesName(low, "cjpm.toml")
            if (!wantReadmeZh && !wantReadme && !wantToml) {
                // 必须读干每个条目的内容：tar.Reader 的 padding 依赖「调用方读完当前条目」，
                // 少读一个字节，后续 header 全部错位（README 就再也找不到了）。
                skipEntry(reader, h.size)
                continue
            }
            let text = readEntry(reader, h.size)
            if (wantReadmeZh && readmeZh.isEmpty()) {
                readmeZh = text
            } else if (wantReadme && readme.isEmpty()) {
                readme = text
            } else if (wantToml) {
                // 取层级最浅的 cjpm.toml（包根那份；测试夹具里可能还有更深的）
                let depth = pathDepth(h.name)
                if (tomlDepth < 0 || depth < tomlDepth) {
                    tomlDepth = depth
                    toml = text
                }
            }
        }
        out.readme = if (!readmeZh.isEmpty()) { readmeZh } else { readme }
        out.cjpmToml = toml
        if (out.readme.isEmpty()) {
            out.note = "no README.md/README_zh.md in artifact"
        }
    } catch (e: Exception) {
        out.error = "gzip: " + e.toString()
    } finally {
        match (gz) {
            case Some(s) =>
                try {
                    s.close()
                } catch (e: Exception) {
                    ()  // close 失败不影响已提取内容（资源由 GC 兜底）
                }
            case None => ()
        }
    }
    return out
}

// 制品内 cjpm.toml 能提供的展示字段（= 官方 meta-data.json 里展示字段的上游）
public class CjpmDisplayMeta {
    public var description: String = ""
    public var authors: ArrayList<String> = ArrayList<String>()
    public var repository: String = ""
    public var homepage: String = ""
    public var documentation: String = ""
    public var tag: ArrayList<String> = ArrayList<String>()
    public var category: ArrayList<String> = ArrayList<String>()
    public var license: ArrayList<String> = ArrayList<String>()
    // package.output-type（"executable" → 可执行程序）
    public var outputType: String = ""
    // 非空 = cjpm.toml 解析失败或没有 [package] 段
    public var error: String = ""

    public init() {}

    public func ok(): Bool {
        return this.error.isEmpty()
    }
}

// 解析制品内 cjpm.toml 的 [package] 展示字段（不抛异常；缺失字段留空）
public func parseCjpmDisplayMeta(tomlText: String): CjpmDisplayMeta {
    let meta = CjpmDisplayMeta()
    if (tomlText.trimAscii().isEmpty()) {
        meta.error = "empty cjpm.toml"
        return meta
    }
    try {
        let obj = Decoder(ByteBuffer(tomlText.toArray())).decode()
        let pkg = match (obj.get("package")) {
            case Some(tv) =>
                try {
                    tv.asObject()
                } catch (e: Exception) {
                    meta.error = "no [package] table"
                    return meta
                }
            case None =>
                meta.error = "no [package] table"
                return meta
        }
        meta.description = readTomlStr(pkg, "description")
        meta.repository = readTomlStr(pkg, "repository")
        meta.homepage = readTomlStr(pkg, "homepage")
        meta.documentation = readTomlStr(pkg, "documentation")
        meta.authors = readTomlStrArray(pkg, "authors")
        meta.tag = readTomlStrArray(pkg, "tag")
        meta.category = readTomlStrArray(pkg, "category")
        meta.license = readTomlStrArray(pkg, "license")
        meta.outputType = readTomlStr(pkg, "output-type")
    } catch (e: Exception) {
        meta.error = "toml: " + e.toString()
    }
    return meta
}

// 名字匹配：等于 basename，或以 "/basename" 结尾（两侧都已转小写）
func matchesName(lowerPath: String, lowerBase: String): Bool {
    if (lowerPath == lowerBase) {
        return true
    }
    if (lowerPath.size <= lowerBase.size) {
        return false
    }
    let cut = lowerPath.size - lowerBase.size
    return lowerPath[cut - 1] == 47u8 && lowerPath[cut..] == lowerBase
}

// 路径深度（'/' 个数；"a/b/c" → 2）
func pathDepth(name: String): Int64 {
    var d: Int64 = 0
    for (i in 0..name.size) {
        if (name[i] == 47u8) {
            d++
        }
    }
    return d
}

// 读干当前条目内容并返回其文本（size 为 tar header 声明的大小）
func readEntry(reader: Reader<DecompressInputStream>, size: Int64): String {
    if (size <= 0) {
        return ""
    }
    let acc = ArrayList<Byte>()
    let chunk = Array<Byte>(65536, repeat: 0u8)
    var remaining = size
    while (remaining > 0) {
        let want = if (remaining < chunk.size) { remaining } else { chunk.size }
        let n = reader.read(chunk[0..want])
        if (n <= 0) {
            break  // 提前枯竭：归档被截断，返回已读部分
        }
        for (i in 0..n) {
            acc.add(chunk[i])
        }
        remaining -= n
    }
    return String.fromUtf8(acc.toArray())
}

// 跳过当前条目内容（仍要读干，保证后续 header 对齐）
func skipEntry(reader: Reader<DecompressInputStream>, size: Int64): Unit {
    if (size <= 0) {
        return
    }
    let chunk = Array<Byte>(65536, repeat: 0u8)
    var remaining = size
    while (remaining > 0) {
        let want = if (remaining < chunk.size) { remaining } else { chunk.size }
        let n = reader.read(chunk[0..want])
        if (n <= 0) {
            return
        }
        remaining -= n
    }
}

func readTomlStr(obj: TomlObject, key: String): String {
    match (obj.get(key)) {
        case Some(tv) =>
            try {
                tv.asString().value
            } catch (e: Exception) {
                ""
            }
        case None => ""
    }
}

func readTomlStrArray(obj: TomlObject, key: String): ArrayList<String> {
    let out = ArrayList<String>()
    match (obj.get(key)) {
        case Some(tv) =>
            try {
                let arr: TomlArray = tv.asArray()
                for (i in 0..arr.size) {
                    match (arr.get(i)) {
                        case Some(item) =>
                            try {
                                out.add(item.asString().value)
                            } catch (e: Exception) {
                                ()  // 数组里混入非字符串：跳过该项
                            }
                        case None => ()
                    }
                }
            } catch (e: Exception) {
                ()  // 类型不符：当作没有该字段
            }
        case None => ()
    }
    return out
}
