// 在线备份服务单测：在线备份成功、并发保护、保留策略、文件名白名单、待恢复标记
package ystyle::cjreg.server

import bstorm.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*
import ystyle::cjreg.auth.util.*

func prepareBackupServiceDir(dir: String): Storm {
    removeIfExists(dir, recursive: true)
    Directory.create(dir, recursive: true)
    let storm = Storm.open(dir + "/cjreg.db", syncWrites: true)
    let users = BstormUserStore(storm)
    PasswordHash.ITERATIONS = 1000
    let auth = AuthService(users, 3600)
    @Expect(auth.initAdmin("admin", "AdminPass1").isSome(), true)
    let pkgs = PackageStore(storm)
    let doc = PackageDoc()
    doc.id = 1
    doc.organization = "demo"
    doc.name = "demo-app"
    doc.version = "1.0.0"
    doc.indexJson = "{}"
    pkgs.save(doc)
    storm
}

@Test
func testOnlineBackupCreatesArchive() {
    let dir = "/tmp/cjreg-online-backup"
    let storm = prepareBackupServiceDir(dir)
    let svc = OnlineBackupService(storm, dir, keepCount: 3)
    @Expect(svc.busy(), false)
    let job = svc.startBackup(false)
    @Expect(job.isSome(), true)
    // 后台线程执行：轮询等它结束（单测里数据量很小，通常毫秒级）
    var waited: Int64 = 0
    while (svc.busy() && waited < 200) {
        sleep(Duration.millisecond * 50)
        waited++
    }
    @Expect(svc.busy(), false)
    let archives = svc.listArchives()
    @Expect(archives.size, 1)
    @Expect(archives[0][0].endsWith(".tar.gz"), true)
    @Expect(archives[0][1] > 0, true)
    // 归档能被校验通过
    match (svc.archivePath(archives[0][0])) {
        case Some(p) =>
            let r = restoreBackup("", p, checkOnly: true)
            @Expect(r.totalRows > 0, true)
        case None => @Fail("归档路径取不到")
    }
    // 最近任务里有一条 done
    let jobs = svc.recentJobs()
    @Expect(jobs.size, 1)
    @Expect(jobs[0].status, "done")
    storm.close()
    removeIfExists(dir, recursive: true)
}

@Test
func testBackupRejectsConcurrentStart() {
    let dir = "/tmp/cjreg-online-backup2"
    let storm = prepareBackupServiceDir(dir)
    let svc = OnlineBackupService(storm, dir, keepCount: 3)
    let first = svc.startBackup(true)
    @Expect(first.isSome(), true)
    // 第一次还在跑（或已结束）：只要在跑就必须拒绝
    if (svc.busy()) {
        @Expect(svc.startBackup(true).isNone(), true)
    }
    var waited: Int64 = 0
    while (svc.busy() && waited < 200) {
        sleep(Duration.millisecond * 50)
        waited++
    }
    storm.close()
    removeIfExists(dir, recursive: true)
}

@Test
func testBackupPruneKeepsNewest() {
    let dir = "/tmp/cjreg-online-backup3"
    let storm = prepareBackupServiceDir(dir)
    let svc = OnlineBackupService(storm, dir, keepCount: 2)
    // 手工造 4 个归档文件（名字按时间递增），触发一次备份后应只留最新的 2 个
    Directory.create(Path(dir + "/backups"), recursive: true)
    let names = ["cjreg-20260101-010101.tar.gz", "cjreg-20260102-010101.tar.gz",
                 "cjreg-20260103-010101.tar.gz", "cjreg-20260104-010101.tar.gz"]
    for (n in names) {
        let f = File(dir + "/backups/" + n, Write)
        f.write("x".toArray())
        f.close()
    }
    @Expect(svc.listArchives().size, 4)
    let _ = svc.startBackup(false)
    var waited: Int64 = 0
    while (svc.busy() && waited < 200) {
        sleep(Duration.millisecond * 50)
        waited++
    }
    // 新备份 + 保留最近 2 份 → 总数应为 2
    @Expect(svc.listArchives().size, 2)
    storm.close()
    removeIfExists(dir, recursive: true)
}

@Test
func testArchiveNameWhitelist() {
    // 允许：服务生成 + 上传临时文件
    @Expect(safeArchiveName("cjreg-20261022-153000.tar.gz"), true)
    @Expect(safeArchiveName("upload-1699999999999.tar.gz"), true)
    // 拒绝：目录穿越、外来名字、非 tar.gz
    @Expect(safeArchiveName("../etc/passwd.tar.gz"), false)
    @Expect(safeArchiveName("cjreg-20261022.tar.gz/../x.tar.gz"), false)
    @Expect(safeArchiveName("evil.tar.gz"), false)
    @Expect(safeArchiveName("cjreg-20261022-153000.zip"), false)
}

@Test
func testApplyPendingRestoreNoop() {
    // 没有标记文件时：不做事、不报错
    let dir = "/tmp/cjreg-online-backup4"
    removeIfExists(dir, recursive: true)
    Directory.create(dir, recursive: true)
    let r = applyPendingRestore(dir)
    @Expect(r.applied, false)
    @Expect(r.fileName, "")
    // 标记指向不存在的归档：清标记并跳过（不阻塞启动）
    let f = File(dir + "/.restore-pending", Write)
    f.write("{\"file\":\"cjreg-20260101-010101.tar.gz\",\"at\":123}".toArray())
    f.close()
    let r2 = applyPendingRestore(dir)
    @Expect(r2.applied, false)
    @Expect(exists(Path(dir + "/.restore-pending")), false)
    removeIfExists(dir, recursive: true)
}
