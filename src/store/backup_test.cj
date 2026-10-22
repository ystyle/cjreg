// 完整备份/恢复单测：含制品的备份、元数据备份、校验模式、拒绝覆盖非空目录
package ystyle::cjreg.store

import bstorm.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.*
import stdx.crypto.digest.SHA256
import stdx.encoding.hex.toHexString
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*
import ystyle::cjreg.auth.util.*

func testSha256(data: Array<Byte>): String {
    let sha = SHA256()
    sha.write(data)
    toHexString(sha.finish())
}

func writeTestFile(path: String, content: String): Unit {
    let f = File(path, Write)
    f.write(content.toArray())
    f.close()
}

func readTestFile(path: String): String {
    let f = File(path, Read)
    let data = Array<Byte>(Int64(f.length), repeat: 0)
    f.read(data)
    f.close()
    String.fromUtf8(data)
}

func prepareSourceData(dir: String, withBlob!: Bool): String {
    removeIfExists(dir, recursive: true)
    Directory.create(dir, recursive: true)
    let storm = Storm.open(dir + "/cjreg.db", syncWrites: true)
    let users = BstormUserStore(storm)
    PasswordHash.ITERATIONS = 1000
    let auth = AuthService(users, 3600)
    @Expect(auth.initAdmin("admin", "AdminPass1").isSome(), true)
    let pkgs = PackageStore(storm)
    var sha = ""
    if (withBlob) {
        let artifact = "fake-artifact-bytes".toArray()
        sha = testSha256(artifact)
        Directory.create(Path(dir + "/blobs"), recursive: true)
        writeTestFile(dir + "/blobs/" + sha, "fake-artifact-bytes")
    }
    let doc = PackageDoc()
    doc.id = 1
    doc.organization = "demo"
    doc.name = "demo-app"
    doc.version = "1.0.0"
    doc.indexJson = "{}"
    doc.sha256 = sha
    doc.tarballSize = Int64(sha.size)
    pkgs.save(doc)
    storm.close()
    sha
}

@Test
func testBackupRestoreWithBlobs() {
    let src = "/tmp/cjreg-backup-test-src"
    let dst = "/tmp/cjreg-backup-test-dst"
    let archive = "/tmp/cjreg-backup-test.tar.gz"
    removeIfExists(dst, recursive: true)
    removeIfExists(Path(archive), recursive: false)
    let sha = prepareSourceData(src, withBlob: true)

    var storm = Storm.open(src + "/cjreg.db", syncWrites: true)
    let backup = createBackup(storm, src, archive, includeBlobs: true)
    storm.close()
    @Expect(backup.totalRows, 2)
    @Expect(backup.blobFiles, 1)
    @Expect(backup.includeBlobs, true)
    @Expect(exists(Path(archive)), true)

    // 只校验：不写目标目录
    let checked = restoreBackup(dst, archive, checkOnly: true)
    @Expect(checked.totalRows, 2)
    @Expect(checked.blobFiles, 1)
    @Expect(exists(Path(dst + "/cjreg.db")), false)

    // 正式恢复
    let restored = restoreBackup(dst, archive, checkOnly: false)
    @Expect(restored.totalRows, 2)
    @Expect(restored.missingBlobs, 0)
    @Expect(exists(Path(dst + "/blobs/" + sha)), true)
    @Expect(readTestFile(dst + "/blobs/" + sha), "fake-artifact-bytes")

    // 恢复后的库可用：用户查询（username 索引）与包版本查询（name 索引）
    storm = Storm.open(dst + "/cjreg.db", syncWrites: true)
    let users = BstormUserStore(storm)
    @Expect(users.getUserByUsername("admin").isSome(), true)
    let pkgs = PackageStore(storm)
    let versions = pkgs.listVersions("demo", "demo-app")
    @Expect(versions.size, 1)
    @Expect(versions[0].sha256, sha)
    storm.close()

    // 非空目录必须拒绝（除非 --force）
    var refused = false
    try {
        restoreBackup(dst, archive, checkOnly: false)
    } catch (e: Exception) {
        refused = true
    }
    @Expect(refused, true)

    removeIfExists(src, recursive: true)
    removeIfExists(dst, recursive: true)
    removeIfExists(Path(archive), recursive: false)
}

@Test
func testBackupWithoutBlobsReportsMissing() {
    let src = "/tmp/cjreg-backup-test-src2"
    let dst = "/tmp/cjreg-backup-test-dst2"
    let archive = "/tmp/cjreg-backup-test2.tar.gz"
    removeIfExists(dst, recursive: true)
    removeIfExists(Path(archive), recursive: false)
    prepareSourceData(src, withBlob: true)

    var storm = Storm.open(src + "/cjreg.db", syncWrites: true)
    let backup = createBackup(storm, src, archive, includeBlobs: false)
    storm.close()
    @Expect(backup.includeBlobs, false)

    let restored = restoreBackup(dst, archive, checkOnly: false)
    @Expect(restored.totalRows, 2)
    // 包文档引用了制品，但备份没带制品内容 → 恢复后应报告 1 个缺失
    @Expect(restored.missingBlobs, 1)

    removeIfExists(src, recursive: true)
    removeIfExists(dst, recursive: true)
    removeIfExists(Path(archive), recursive: false)
}
