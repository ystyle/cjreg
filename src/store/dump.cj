// 只读导出（dump）：把数据库里的数据行按表导出成 JSONL，用于升级前后比对与灾备快照。
//
// 设计约束：
// - **只读**：直接扫原始 key，不经过 schema 登记，因此不会触发 v1 → v2 的索引迁移，
//   也不会写数据行；唯一的写动作是输出目录里的文件；
// - 不依赖表结构：按数据 key 的 `<table>:primary:<id>` 形状发现表，v1 旧库也能直接导；
// - 内部 key（`__schema:` / `__idx:` / `__uniq:` 等 `__` 开头的族）不导出；
// - 制品（blobs）是内容寻址的独立目录，不在这里导出内容，manifest 里只记目录与文件数。
package ystyle::cjreg.store

import bstorm.*
import std.collection.*
import std.fs.*
import std.time.*

/** 单表导出统计。 */
public class DumpTableStat {
    public let table: String
    public let file: String
    public let rows: Int64
    public let bytes: Int64

    init(table: String, file: String, rows: Int64, bytes: Int64) {
        this.table = table
        this.file = file
        this.rows = rows
        this.bytes = bytes
    }
}

/** 一次 dump 的结果。 */
public class DumpResult {
    public let outDir: String
    public let totalRows: Int64
    public let tables: ArrayList<DumpTableStat>

    init(outDir: String, totalRows: Int64, tables: ArrayList<DumpTableStat>) {
        this.outDir = outDir
        this.totalRows = totalRows
        this.tables = tables
    }
}

/**
 * 把 `storm` 数据库里的全部数据行导出到 `outDir`。
 *
 * 输出：每张表一个 `<table>.jsonl`（每行 `{"_id":"...","_json":<原始 JSON>}`），
 * 外加 `manifest.json`（时间、总行数、每表行数/字节数、blobs 目录统计）。
 * 调用方负责先打开 Storm，并在导出后 close。
 */
public func dumpDatabase(storm: Storm, outDir: String, dataDir!: String = ""): DumpResult {
    if (exists(Path(outDir))) {
        removeIfExists(Path(outDir), recursive: true)
    }
    Directory.create(Path(outDir), recursive: true)

    let kvs = storm.scanRawBytes(Array<Byte>())
    // 按表分组（记录在 kvs 里的下标）；同时保留首次出现的顺序，输出稳定、方便 diff
    let grouped = HashMap<String, ArrayList<Int64>>()
    let order = ArrayList<String>()
    for (i in 0..kvs.size) {
        // 内部族（__schema/__idx/__uniq/__nidx/__meta）的 key 是二进制，先按字节挡掉，
        // 否则 String.fromUtf8 会因非法 UTF-8 抛异常
        let kb = kvs[i].keyBytes
        if (kb.size >= 2 && kb[0] == 0x5F && kb[1] == 0x5F) {
            continue
        }
        let keyText = String.fromUtf8(kb)
        match (dataRowTableOf(keyText)) {
            case Some(table) =>
                if (!grouped.contains(table)) {
                    let list = ArrayList<Int64>()
                    grouped[table] = list
                    order.add(table)
                }
                grouped[table].add(i)
            case None => ()
        }
    }

    let tables = ArrayList<DumpTableStat>()
    var totalRows: Int64 = 0
    for (table in order) {
        let indexes = grouped[table].toArray()
        let fileName = dumpFileName(table)
        let sb = StringBuilder()
        for (idx in indexes) {
            let keyText = String.fromUtf8(kvs[idx].keyBytes)
            let id = splitIdOf(keyText)
            sb.append("{\"_id\":\"")
            sb.append(escapeJsonString(id))
            sb.append("\",\"_json\":")
            sb.append(String.fromUtf8(kvs[idx].value))
            sb.append("}\n")
        }
        let content = sb.toString().toArray()
        let f = File("${outDir}/${fileName}", Write)
        f.write(content)
        f.close()
        tables.add(DumpTableStat(table, fileName, indexes.size, Int64(content.size)))
        totalRows += indexes.size
    }

    // manifest：文件清单 + blobs 目录统计（blobs 内容本身不在 dump 包里）
    let manifest = StringBuilder()
    manifest.append("{\n")
    manifest.append("  \"generatedAt\": ${nowMs()},\n")
    manifest.append("  \"totalRows\": ${totalRows},\n")
    manifest.append("  \"tables\": [")
    for (i in 0..tables.size) {
        if (i > 0) {
            manifest.append(",")
        }
        let t = tables[i]
        manifest.append("\n    {\"table\": \"${escapeJsonString(t.table)}\", \"file\": \"${t.file}\", \"rows\": ${t.rows}, \"bytes\": ${t.bytes}}")
    }
    manifest.append("\n  ],\n")
    maybeAppendBlobStats(manifest, dataDir)
    manifest.append("}\n")
    let mf = File("${outDir}/manifest.json", Write)
    mf.write(manifest.toString().toArray())
    mf.close()

    DumpResult(outDir, totalRows, tables)
}

/** 从 `<table>:primary:<id>` 里取表名；内部族（`__` 开头）与非数据 key 返回 none。 */
func dataRowTableOf(keyText: String): ?String {
    let marker = ":primary:"
    match (keyText.indexOf(marker)) {
        case Some(pos) =>
            if (pos <= 0) {
                return None
            }
            let table = keyText[0..pos]
            if (table.startsWith("__") || table.isEmpty()) {
                return None
            }
            return Some(table)
        case None => return None
    }
}

/** 数据 key 里的 id 部分（`<table>:primary:` 之后）。 */
func splitIdOf(keyText: String): String {
    let marker = ":primary:"
    match (keyText.indexOf(marker)) {
        case Some(pos) => keyText[(pos + marker.size)..]
        case None => keyText
    }
}

/** 文件名清洗：表名可能带命名空间冒号，统一换成下划线；只保留常见安全字符。 */
func dumpFileName(table: String): String {
    let out = StringBuilder()
    for (r in table.toRuneArray()) {
        let c = r.toString()
        let safe = (r >= r'a' && r <= r'z') || (r >= r'A' && r <= r'Z') || (r >= r'0' && r <= r'9') || c == "_" || c == "-" || c == "."
        out.append(if (safe) { c } else { "_" })
    }
    "${out.toString()}.jsonl"
}

/** JSON 字符串转义（只处理 id：引号/反斜杠/控制字符，其余原样保留 UTF-8）。 */
func escapeJsonString(s: String): String {
    let out = StringBuilder()
    for (r in s.toRuneArray()) {
        let c = r.toString()
        if (c == "\"") {
            out.append("\\\"")
        } else if (c == "\\") {
            out.append("\\\\")
        } else if (c == "\n") {
            out.append("\\n")
        } else if (c == "\r") {
            out.append("\\r")
        } else if (c == "\t") {
            out.append("\\t")
        } else if (r < r' ') {
            let v = Int64(r.toString().toArray()[0])
            out.append("\\u00")
            out.append(hexDigit(v >> 4))
            out.append(hexDigit(v & 0x0F))
        } else {
            out.append(c)
        }
    }
    out.toString()
}

private func hexDigit(v: Int64): String {
    match (v) {
        case 0 => "0"
        case 1 => "1"
        case 2 => "2"
        case 3 => "3"
        case 4 => "4"
        case 5 => "5"
        case 6 => "6"
        case 7 => "7"
        case 8 => "8"
        case 9 => "9"
        case 10 => "a"
        case 11 => "b"
        case 12 => "c"
        case 13 => "d"
        case 14 => "e"
        case _ => "f"
    }
}

/** blobs 目录统计（只数文件，不导出内容）。 */
private func maybeAppendBlobStats(manifest: StringBuilder, dataDir: String): Unit {
    var blobsDir = ""
    var count: Int64 = 0
    if (!dataDir.isEmpty()) {
        blobsDir = "${dataDir}/blobs"
        if (exists(Path(blobsDir))) {
            let entries = Directory.readFrom(Path(blobsDir))
            count = Int64(entries.size)
        }
    }
    manifest.append("  \"blobs\": {\"dir\": \"${escapeJsonString(blobsDir)}\", \"files\": ${count}}\n")
}

private func nowMs(): Int64 {
    DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
}
