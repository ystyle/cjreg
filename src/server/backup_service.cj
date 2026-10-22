// 在线备份服务：在服务端运行的进程里直接用现有 Storm 做备份，不需要停服。
//
// 为什么能不停机：
// - 复用进程已持有的 Storm；badgercj 的 db.scan(prefix).iterator() 是「一个只读事务 + 一个迭代器」，
//   整库扫一遍就是**同一个快照**，导出的数据行自洽；
// - blobs 是内容寻址、不可变的，备份期间新发布的制品不会被快照引用。
//
// 边界（刻意不做）：恢复不在线做。Badger 对数据目录独占、store 被路由/UI/后台任务到处捕获，
// 运行中替换库等于在进程内重建整套服务。恢复走「上传归档 → 在线校验 → 标记重启应用」。
package ystyle::cjreg.server

import bstorm.*
import std.collection.*
import std.fs.*
import std.sync.*
import std.time.*
import std.sort.*
import gjson
import ystyle::cjreg.store.*

/** 一次在线备份任务的快照（给管理端列表/详情用）。 */
public class BackupJob {
    public let id: String
    public let fileName: String
    public let createdAt: Int64
    public var status: String          // running / done / failed
    public var message: String         // 失败原因 / 完成摘要
    public var totalRows: Int64
    public var blobFiles: Int64
    public var blobBytes: Int64
    public var includeBlobs: Bool
    public var sizeBytes: Int64
    public var finishedAt: Int64

    public init(id: String, fileName: String, createdAt: Int64, includeBlobs: Bool) {
        this.id = id
        this.fileName = fileName
        this.createdAt = createdAt
        this.status = "running"
        this.message = ""
        this.totalRows = 0
        this.blobFiles = 0
        this.blobBytes = 0
        this.includeBlobs = includeBlobs
        this.sizeBytes = 0
        this.finishedAt = 0
    }
}

/**
 * 在线备份调度器：一次只允许一个任务（避免同时扫库把 IO 打满），
 * 备份产物落在 `<dataDir>/backups/`，按保留份数清理最旧的。
 */
public class OnlineBackupService {
    private let storm: Storm
    private let dataDir: String
    private let backupDir: String
    private let keepCount: Int64
    private let mutex = Mutex()
    private var jobs = ArrayList<BackupJob>()

    public init(storm: Storm, dataDir: String, keepCount!: Int64 = 7) {
        this.storm = storm
        this.dataDir = dataDir
        this.backupDir = "${dataDir}/backups"
        this.keepCount = keepCount
    }

    public func dir(): String {
        this.backupDir
    }

    /** 数据目录（恢复标记读写用；不依赖任何全局状态）。 */
    public func dataDirectory(): String {
        this.dataDir
    }

    /** 列出已有备份文件（文件名、字节数、修改时间），按时间倒序。 */
    public func listArchives(): ArrayList<(String, Int64, Int64)> {
        let out = ArrayList<(String, Int64, Int64)>()
        if (!exists(Path(this.backupDir))) {
            return out
        }
        for (info in Directory.readFrom(Path(this.backupDir))) {
            if (info.isDirectory() || !info.name.endsWith(".tar.gz")) {
                continue
            }
            out.add((info.name, info.size, info.lastModificationTime.toUnixTimeStamp().toMilliseconds()))
        }
        // 文件名带时间戳前缀，按名倒序即最新在前
        sort(out, lessThan: { a, b => a[0] > b[0] })
        out
    }

    /** 当前是否有任务在跑。 */
    public func busy(): Bool {
        synchronized(this.mutex) {
            for (j in this.jobs) {
                if (j.status == "running") {
                    return true
                }
            }
            false
        }
    }

    /** 最近的任务（倒序，最多 limit 条）。 */
    public func recentJobs(limit!: Int64 = 20): ArrayList<BackupJob> {
        synchronized(this.mutex) {
            let out = ArrayList<BackupJob>()
            var i = this.jobs.size - 1
            while (i >= 0 && out.size < limit) {
                out.add(this.jobs[i])
                i--
            }
            out
        }
    }

    public func findJob(id: String): ?BackupJob {
        synchronized(this.mutex) {
            for (j in this.jobs) {
                if (j.id == id) {
                    return Some(j)
                }
            }
            None
        }
    }

    /**
     * 启动一次在线备份（后台线程执行，立即返回任务）。同一时间只允许一个任务。
     * 返回值：Some(job) = 已启动；None = 已有任务在跑。
     */
    public func startBackup(includeBlobs: Bool): ?BackupJob {
        synchronized(this.mutex) {
            for (j in this.jobs) {
                if (j.status == "running") {
                    return None
                }
            }
        }
        let now = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
        let stamp = formatStamp(now)
        let fileName = "cjreg-${stamp}.tar.gz"
        let id = "bk-${now}"
        let job = BackupJob(id, fileName, now, includeBlobs)
        synchronized(this.mutex) {
            this.jobs.add(job)
        }
        if (!exists(Path(this.backupDir))) {
            Directory.create(Path(this.backupDir), recursive: true)
        }
        let archivePath = "${this.backupDir}/${fileName}"
        spawn {
            var status = "done"
            var message = ""
            try {
                let r = createBackup(this.storm, this.dataDir, archivePath, includeBlobs: includeBlobs)
                synchronized(this.mutex) {
                    job.totalRows = r.totalRows
                    job.blobFiles = r.blobFiles
                    job.blobBytes = r.blobBytes
                    job.message = if (r.missingBlobs > 0) {
                        "完成；${r.missingBlobs} 个制品在备份期间不可读已跳过"
                    } else {
                        "完成"
                    }
                }
                if (exists(Path(archivePath))) {
                    job.sizeBytes = FileInfo(archivePath).size
                }
            } catch (e: Exception) {
                status = "failed"
                message = e.message
                // 失败不留半截文件（createBackup 内部已清 .part，这里再兜一次）
                if (exists(Path(archivePath))) {
                    try {
                        removeIfExists(Path(archivePath), recursive: false)
                    } catch (ignore: Exception) {
                        ()
                    }
                }
            }
            synchronized(this.mutex) {
                job.status = status
                if (!message.isEmpty()) {
                    job.message = message
                }
                job.finishedAt = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
            }
            if (status == "done") {
                this.prune()
            }
        }
        Some(job)
    }

    /** 删除一个备份文件（任务记录保留）。 */
    public func deleteArchive(fileName: String): Bool {
        let path = "${this.backupDir}/${fileName}"
        if (!exists(Path(path))) {
            return false
        }
        removeIfExists(Path(path), recursive: false)
        true
    }

    /** 归档绝对路径（下载用）；不存在返回 None。 */
    public func archivePath(fileName: String): ?String {
        let path = "${this.backupDir}/${fileName}"
        if (!exists(Path(path))) {
            return None
        }
        Some(path)
    }

    /** 保留最近 keepCount 份，其余删除（只删本服务生成的 cjreg-*.tar.gz）。 */
    private func prune(): Unit {
        if (this.keepCount <= 0) {
            return
        }
        var archives = this.listArchives()
        var i = this.keepCount
        while (i < archives.size) {
            try {
                removeIfExists(Path("${this.backupDir}/${archives[i][0]}"), recursive: false)
            } catch (e: Exception) {
                ()
            }
            i++
        }
    }
}

/** 文件名时间戳：20261022-154500（UTC，避免时区歧义；管理端展示时转本地）。 */
func formatStamp(ms: Int64): String {
    DateTime.fromUnixTimeStamp(Duration.millisecond * ms).format("yyyyMMdd-HHmmss")
}

// ===== 启动时应用「待恢复」标记 =====
//
// 恢复不在线做（Badger 独占数据目录 + store 被全进程持有）。管理端只上传+校验+写标记，
// 真正的替换发生在这里：**在打开数据库之前**执行，失败自动回滚并拒绝启动（不静默跑旧库）。

/** 启动期应用恢复的结果。 */
public class AppliedRestore {
    public let applied: Bool
    public let fileName: String
    public let message: String

    init(applied: Bool, fileName: String, message: String) {
        this.applied = applied
        this.fileName = fileName
        this.message = message
    }
}

/**
 * 检查并应用 `<dataDir>/.restore-pending`（若有）。
 *
 * 步骤：
 * 1. 读标记（归档文件名 + 时间）；归档不存在 → 清标记、跳过（不阻塞启动）；
 * 2. 先把现有 `cjreg.db` 与 `blobs/` 挪到 `<dataDir>/.pre-restore-<ts>/`；
 * 3. 调用 `restoreBackup(force: true)` 解压归档；
 * 4. 任何失败 → 把备份目录挪回去、删掉半成品、清标记，返回 applied=false（调用方据此退出）；
 * 5. 成功 → 清标记（`.pre-restore-*` 保留，供人工回滚）。
 *
 * 必须在 `Storm.open` **之前**调用。
 */
public func applyPendingRestore(dataDir: String): AppliedRestore {
    let markerPath = "${dataDir}/.restore-pending"
    if (!exists(Path(markerPath))) {
        return AppliedRestore(false, "", "")
    }
    var fileName = ""
    var markerAt: Int64 = 0
    try {
        let f = File(markerPath, Read)
        let n = Int64(f.length)
        let buf = Array<Byte>(n, repeat: 0)
        f.read(buf)
        f.close()
        let r = gjson.parse(String.fromUtf8(buf))
        fileName = r.get("file").toString()
        markerAt = r.get("at").int()
    } catch (e: Exception) {
        removeQuietly(markerPath)
        return AppliedRestore(false, "", "恢复标记无法解析，已清除：${e.message}")
    }
    if (fileName.isEmpty()) {
        removeQuietly(markerPath)
        return AppliedRestore(false, "", "")
    }
    // 标记里的归档可能已被清理（保留策略）；backups/ 与数据目录同级
    let archive = "${dataDir}/backups/${fileName}"
    if (!exists(Path(archive))) {
        removeQuietly(markerPath)
        return AppliedRestore(false, fileName, "待恢复的归档不存在（${archive}），已清除标记并正常启动")
    }
    println("cjreg: 检测到待应用恢复 ${fileName}（标记于 ${markerAt}），开始替换数据目录…")

    let staging = "${dataDir}/.pre-restore-${markerAt}"
    var movedDb = false
    var movedBlobs = false
    if (exists(Path(staging))) {
        try {
            removeIfExists(Path(staging), recursive: true)
        } catch (e: Exception) {
            return AppliedRestore(false, fileName, "旧的回滚目录无法清理（${staging}）：${e.message}")
        }
    }
    try {
        Directory.create(Path(staging), recursive: true)
        let dbPath = "${dataDir}/cjreg.db"
        if (exists(Path(dbPath))) {
            rename(dbPath, to: "${staging}/cjreg.db")
            movedDb = true
        }
        let blobsPath = "${dataDir}/blobs"
        if (exists(Path(blobsPath))) {
            rename(blobsPath, to: "${staging}/blobs")
            movedBlobs = true
        }
    } catch (e: Exception) {
        // 挪动就失败：尽量还原，拒绝继续
        rollbackMove(staging, dataDir, movedDb, movedBlobs)
        return AppliedRestore(false, fileName, "无法移走现有数据目录（是否仍有进程在用？）：${e.message}")
    }

    try {
        let r = restoreBackup(dataDir, archive, force: true, checkOnly: false)
        removeQuietly(markerPath)
        println("cjreg: 恢复完成（${r.totalRows} 行，缺失制品 ${r.missingBlobs} 个）；旧数据留在 ${staging}")
        return AppliedRestore(true, fileName, "恢复完成：${r.totalRows} 行")
    } catch (e: Exception) {
        // 回滚：删掉半成品，把旧数据挪回
        rollbackRestoreFailure(dataDir)
        rollbackMove(staging, dataDir, movedDb, movedBlobs)
        removeQuietly(markerPath)
        return AppliedRestore(false, fileName, "恢复失败已回滚：${e.message}")
    }
}

private func rollbackMove(staging: String, dataDir: String, movedDb: Bool, movedBlobs: Bool): Unit {
    if (movedDb) {
        try {
            rename("${staging}/cjreg.db", to: "${dataDir}/cjreg.db")
        } catch (e: Exception) {
            println("cjreg: 严重：回滚 cjreg.db 失败（旧数据在 ${staging}/cjreg.db）：${e.message}")
        }
    }
    if (movedBlobs) {
        try {
            rename("${staging}/blobs", to: "${dataDir}/blobs")
        } catch (e: Exception) {
            println("cjreg: 严重：回滚 blobs 失败（旧数据在 ${staging}/blobs）：${e.message}")
        }
    }
}

private func rollbackRestoreFailure(dataDir: String): Unit {
    let dbPath = "${dataDir}/cjreg.db"
    if (exists(Path(dbPath))) {
        try {
            removeIfExists(Path(dbPath), recursive: true)
        } catch (e: Exception) {
            println("cjreg: 回滚时无法删除半成品数据库：${e.message}")
        }
    }
    let blobsPath = "${dataDir}/blobs"
    if (exists(Path(blobsPath))) {
        try {
            removeIfExists(Path(blobsPath), recursive: true)
        } catch (e: Exception) {
            println("cjreg: 回滚时无法删除半成品制品目录：${e.message}")
        }
    }
}

private func removeQuietly(path: String): Unit {
    if (exists(Path(path))) {
        try {
            removeIfExists(Path(path), recursive: false)
        } catch (e: Exception) {
            ()
        }
    }
}
