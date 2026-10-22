// 完整备份 / 恢复（P2）：DB 数据行（JSONL）+ blobs 清单（可选连制品内容）打成 tar.gz。
//
// 与 dump 的关系：dump 是「只读导出成目录」，用于升级前后 diff；
// backup 在 dump 的同一份数据行之上加装制品与清单，产出单个可搬运的归档，restore 直接还原。
//
// 归档布局（tar.gz）：
//   manifest.json              {"format":"cjreg-backup/1","generatedAt":…,"totalRows":…,"tables":[…],"includeBlobs":…}
//   blobs.manifest.jsonl       每行 {"sha256":"…","size":N}
//   <table>.jsonl              每行一个原始 JSON 文档（与 dump 相同格式）
//   blobs/<sha256>             制品内容（仅在 includeBlobs=true 时）
package ystyle::cjreg.store

import bstorm.*
import std.collection.*
import std.fs.*
import std.io.*
import gjson
import stdx.compress.zlib.*
import stdx.crypto.digest.SHA256
import stdx.encoding.hex.toHexString
import ystyle::tar.*

public let BACKUP_FORMAT: String = "cjreg-backup/1"

/** 一次备份的结果。 */
public class BackupResult {
    public let archive: String
    public let totalRows: Int64
    public let tables: ArrayList<DumpTableStat>
    public let blobFiles: Int64
    public let blobBytes: Int64
    public let includeBlobs: Bool

    init(archive: String, totalRows: Int64, tables: ArrayList<DumpTableStat>, blobFiles: Int64, blobBytes: Int64, includeBlobs: Bool) {
        this.archive = archive
        this.totalRows = totalRows
        this.tables = tables
        this.blobFiles = blobFiles
        this.blobBytes = blobBytes
        this.includeBlobs = includeBlobs
    }
}

/** 一次恢复/校验的结果。 */
public class RestoreResult {
    public let dataDir: String
    public let totalRows: Int64
    public let tables: ArrayList<DumpTableStat>
    public let blobFiles: Int64
    public let missingBlobs: Int64
    public let checkOnly: Bool

    init(dataDir: String, totalRows: Int64, tables: ArrayList<DumpTableStat>, blobFiles: Int64, missingBlobs: Int64, checkOnly: Bool) {
        this.dataDir = dataDir
        this.totalRows = totalRows
        this.tables = tables
        this.blobFiles = blobFiles
        this.missingBlobs = missingBlobs
        this.checkOnly = checkOnly
    }
}

/**
 * 生成完整备份归档（tar.gz）。
 *
 * `includeBlobs`：是否把 `dataDir/blobs` 里的制品内容一起打进去。
 * 备份前需先停服务；调用方负责打开/关闭 Storm。
 */
public func createBackup(storm: Storm, dataDir: String, archivePath: String, includeBlobs!: Bool = true): BackupResult {
    let tmpDir = "${archivePath}.part"
    if (exists(Path(tmpDir))) {
        removeIfExists(Path(tmpDir), recursive: true)
    }
    let dump = dumpDatabase(storm, tmpDir, dataDir: dataDir)

    // 制品清单（文件名即 sha256）
    let blobEntries = ArrayList<(String, Int64)>()
    var blobBytes: Int64 = 0
    if (exists(Path("${dataDir}/blobs"))) {
        for (info in Directory.readFrom(Path("${dataDir}/blobs"))) {
            if (info.isDirectory()) {
                continue
            }
            blobEntries.add((info.name, info.size))
            blobBytes += info.size
        }
    }

    let out = File(archivePath, Write)
    try {
        let gz = CompressOutputStream(out, wrap: GzipFormat, bufLen: 8192)
        let tw = Writer(gz)
        try {
            // manifest：数据行统计 + 制品清单统计（内容在 blobs.manifest.jsonl / blobs/ 下）
            let manifest = buildBackupManifest(dump, blobEntries.size, blobBytes, includeBlobs)
            tw.writeFile("manifest.json", manifest.toArray())

            // 数据行（dump 产物里已经有每表一个 jsonl）
            for (stat in dump.tables) {
                tw.writeFile(stat.file, readAllBytes("${tmpDir}/${stat.file}"))
            }

            // 制品清单
            let bm = StringBuilder()
            for ((name, size) in blobEntries) {
                bm.append("{\"sha256\":\"${escapeJsonString(name)}\",\"size\":${size}}\n")
            }
            tw.writeFile("blobs.manifest.jsonl", bm.toString().toArray())

            // 制品内容（可选）
            if (includeBlobs) {
                for ((name, _) in blobEntries) {
                    tw.writeFile("blobs/${name}", readAllBytes("${dataDir}/blobs/${name}"))
                }
            }
        } finally {
            tw.close()
            gz.close()
        }
    } finally {
        out.close()
    }
    removeIfExists(Path(tmpDir), recursive: true)
    BackupResult(archivePath, dump.totalRows, dump.tables, Int64(blobEntries.size), blobBytes, includeBlobs)
}

/**
 * 从备份归档恢复到 `dataDir`。
 *
 * 语义：
 * - 目标目录必须为空（或只有 `cjreg.toml`）：存在 `cjreg.db` 时拒绝，除非 `force`（会先删掉
 *   目标目录里的 `cjreg.db` 与 `blobs/`，保留 `cjreg.toml`）；
 * - 数据行按原 id/token 写入（JSON 里自带主键），索引由 bstorm 正常维护；
 * - 归档里若带制品内容，逐个校验文件名（sha256）与内容一致后才落盘；
 * - `checkOnly`：只读校验归档（行数/manifest/制品 sha），不写任何文件。
 */
public func restoreBackup(dataDir: String, archivePath: String, force!: Bool = false, checkOnly!: Bool = false): RestoreResult {
    if (!exists(Path(archivePath))) {
        throw Exception("备份文件不存在: ${archivePath}")
    }
    let dbPath = "${dataDir}/cjreg.db"
    if (!checkOnly) {
        if (exists(Path(dbPath))) {
            if (!force) {
                throw Exception("目标目录已有数据库（${dbPath}）：请换空目录，或加 --force 覆盖（会删除现有 cjreg.db 与 blobs）")
            }
            removeIfExists(Path(dbPath), recursive: true)
            if (exists(Path("${dataDir}/blobs"))) {
                removeIfExists(Path("${dataDir}/blobs"), recursive: true)
            }
        }
        if (!exists(Path(dataDir))) {
            Directory.create(Path(dataDir), recursive: true)
        }
    }

    let archiveBytes = readAllBytes(archivePath)
    let gz = DecompressInputStream(ByteBuffer(archiveBytes), wrap: GzipFormat, bufLen: 8192)
    let tr = Reader(gz)
    var manifestText = ""
    let tableLines = HashMap<String, ArrayList<String>>()
    let tableOrder = ArrayList<String>()
    var blobCount: Int64 = 0
    var blobsDirPrepared = false
    var storm: ?Storm = None
    if (!checkOnly) {
        // 恢复写库：v2 的 schema 由 @Model 自动登记
        storm = Some(Storm.open(dbPath, syncWrites: true))
    }
    try {
        while (true) {
            let hdr = try {
                tr.next()
            } catch (e: TarException) {
                if (e.msg != "EOF") {
                    throw Exception("归档损坏（tar: ${e.msg}）")
                }
                break
            }
            let name = hdr.name
            if (name == "manifest.json") {
                manifestText = String.fromUtf8(readTarEntry(tr, hdr.size))
            } else if (name == "blobs.manifest.jsonl") {
                // 仅作信息保留；实际校验以下面 blobs/<sha> 与包的 sha256 引用为准
                let _ = readTarEntry(tr, hdr.size)
            } else if (name.startsWith("blobs/")) {
                let sha = name["blobs/".size..]
                let data = readTarEntry(tr, hdr.size)
                let actual = sha256Hex(data)
                if (actual != sha) {
                    throw Exception("制品校验失败（${sha} 内容 sha256=${actual}）")
                }
                blobCount++
                if (!checkOnly) {
                    if (!blobsDirPrepared) {
                        if (exists(Path("${dataDir}/blobs"))) {
                            removeIfExists(Path("${dataDir}/blobs"), recursive: true)
                        }
                        Directory.create(Path("${dataDir}/blobs"), recursive: true)
                        blobsDirPrepared = true
                    }
                    let f = File("${dataDir}/blobs/${sha}", Write)
                    f.write(data)
                    f.close()
                }
            } else if (name.endsWith(".jsonl")) {
                let table = name[0..(name.size - 6)]
                if (!isKnownTable(table)) {
                    throw Exception("备份里有未知表 '${table}'（当前版本不认识），拒绝恢复以免丢数据")
                }
                let text = String.fromUtf8(readTarEntry(tr, hdr.size))
                let lines = splitJsonLines(text)
                if (!checkOnly) {
                    restoreTable(storm.getOrThrow(), table, lines)
                }
                tableLines[table] = lines
                tableOrder.add(table)
            } else {
                // 未知条目：读干，保证后续 header 不错位
                let _ = readTarEntry(tr, hdr.size)
            }
        }
    } finally {
        match (storm) {
            case Some(s) => s.close()
            case None => ()
        }
        try {
            gz.close()
        } catch (e: Exception) {
            ()
        }
    }

    if (manifestText.isEmpty()) {
        throw Exception("备份里缺少 manifest.json")
    }
    let m = gjson.parse(manifestText)
    if (m.get("format").toString() != BACKUP_FORMAT) {
        throw Exception("备份格式不认识: '${m.get("format").toString()}'（期望 ${BACKUP_FORMAT}）")
    }
    let expectedRows = m.get("totalRows").int()
    let tables = ArrayList<DumpTableStat>()
    var actualRows: Int64 = 0
    for (table in tableOrder) {
        let n = Int64(tableLines[table].size)
        actualRows += n
        tables.add(DumpTableStat(table, "${table}.jsonl", n, 0))
    }
    if (actualRows != expectedRows) {
        throw Exception("行数校验失败：manifest 声明 ${expectedRows}，实际恢复 ${actualRows}")
    }

    let missing = if (checkOnly) { 0 } else { countMissingBlobs(dataDir) }
    RestoreResult(dataDir, actualRows, tables, blobCount, missing, checkOnly)
}

/** 备份归档的 manifest 文本。 */
func buildBackupManifest(dump: DumpResult, blobFiles: Int64, blobBytes: Int64, includeBlobs: Bool): String {
    let m = StringBuilder()
    m.append("{\n")
    m.append("  \"format\": \"${BACKUP_FORMAT}\",\n")
    m.append("  \"generatedAt\": ${nowMs()},\n")
    m.append("  \"totalRows\": ${dump.totalRows},\n")
    m.append("  \"includeBlobs\": ${includeBlobs},\n")
    m.append("  \"blobs\": {\"files\": ${blobFiles}, \"bytes\": ${blobBytes}},\n")
    m.append("  \"tables\": [")
    for (i in 0..dump.tables.size) {
        if (i > 0) {
            m.append(",")
        }
        let t = dump.tables[i]
        m.append("\n    {\"table\": \"${escapeJsonString(t.table)}\", \"file\": \"${t.file}\", \"rows\": ${t.rows}, \"bytes\": ${t.bytes}}")
    }
    m.append("\n  ]\n")
    m.append("}\n")
    m.toString()
}

func readAllBytes(path: String): Array<Byte> {
    let f = File(path, Read)
    let n = Int64(f.length)
    let data = Array<Byte>(n, repeat: 0)
    var got: Int64 = 0
    while (got < n) {
        let r = f.read(data[got..n])
        if (r <= 0) {
            break
        }
        got += r
    }
    f.close()
    data[0..got]
}

func readTarEntry<T>(tr: Reader<T>, size: Int64): Array<Byte> where T <: InputStream {
    let data = Array<Byte>(size, repeat: 0)
    var got: Int64 = 0
    while (got < size) {
        let n = tr.read(data[got..size])
        if (n <= 0) {
            break
        }
        got += n
    }
    data[0..got]
}

/** 按行切 JSONL（JSON 字符串里的换行已转义成 `\n`，不会出现裸换行）。 */
func splitJsonLines(text: String): ArrayList<String> {
    let out = ArrayList<String>()
    for (line in text.split("\n")) {
        let t = line.trimAscii()
        if (!t.isEmpty()) {
            out.add(t)
        }
    }
    out
}

/** 恢复一张表：按 1000 行/事务批量写（syncWrites 下逐条 save 的提交开销太大）。 */
func restoreTable(storm: Storm, table: String, lines: ArrayList<String>): Unit {
    let batchSize: Int64 = 1000
    var i: Int64 = 0
    while (i < lines.size) {
        let start = i
        let stop = if (i + batchSize < lines.size) { i + batchSize } else { lines.size }
        storm.update({ txn: Txn =>
            for (j in start..stop) {
                restoreRowInTxn(storm, txn, table, lines[j])
            }
        })
        i = stop
    }
}

/** 恢复一行：按表名解码成对应 @Model 再写入事务（保留原主键、由 bstorm 维护索引）。 */
func restoreRowInTxn(storm: Storm, txn: Txn, table: String, line: String): Unit {
    let bytes = line.toArray()
    match (table) {
        case "user_doc" => txn.save(storm.decode<UserDoc>(bytes))
        case "user_token_doc" => txn.save(storm.decode<UserTokenDoc>(bytes))
        case "package_doc" => txn.save(storm.decode<PackageDoc>(bytes))
        case "upstream_doc" => txn.save(storm.decode<UpstreamDoc>(bytes))
        case "org_doc" => txn.save(storm.decode<OrgDoc>(bytes))
        case "team_doc" => txn.save(storm.decode<TeamDoc>(bytes))
        case "team_organization_doc" => txn.save(storm.decode<TeamOrganizationDoc>(bytes))
        case "team_package_doc" => txn.save(storm.decode<TeamPackageDoc>(bytes))
        case "team_member_doc" => txn.save(storm.decode<TeamMemberDoc>(bytes))
        case "log_doc" => txn.save(storm.decode<LogDoc>(bytes))
        case "plan_doc" => txn.save(storm.decode<PlanDoc>(bytes))
        case "plan_item_doc" => txn.save(storm.decode<PlanItemDoc>(bytes))
        case _ => throw Exception("未知表 '${table}'")
    }
}

func isKnownTable(table: String): Bool {
    match (table) {
        case "user_doc" | "user_token_doc" | "package_doc" | "upstream_doc" | "org_doc" | "team_doc" |
            "team_organization_doc" | "team_package_doc" | "team_member_doc" | "log_doc" | "plan_doc" | "plan_item_doc" => true
        case _ => false
    }
}

/** 恢复后统计缺失的制品（包文档引用了 sha256 但 blobs 目录里没有）。 */
func countMissingBlobs(dataDir: String): Int64 {
    var missing: Int64 = 0
    let dbPath = "${dataDir}/cjreg.db"
    if (!exists(Path(dbPath))) {
        return 0
    }
    let storm = Storm.open(dbPath, syncWrites: true)
    try {
        for (doc in storm.all<PackageDoc>()) {
            if (doc.sha256.isEmpty()) {
                continue
            }
            if (!exists(Path("${dataDir}/blobs/${doc.sha256}"))) {
                missing++
            }
        }
    } finally {
        storm.close()
    }
    missing
}

func sha256Hex(data: Array<Byte>): String {
    let sha = SHA256()
    sha.write(data)
    toHexString(sha.finish())
}
