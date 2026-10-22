// dump（只读导出）单测：内容正确、内部族不导出、dump 不改数据
package ystyle::cjreg.store

import bstorm.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*
import ystyle::cjreg.auth.util.*

func readTextFile(path: String): String {
    let f = File(path, Read)
    let data = Array<Byte>(Int64(f.length), repeat: 0)
    f.read(data)
    f.close()
    String.fromUtf8(data)
}

@Test
func testDumpDatabase() {
    let dir = "/tmp/cjreg-dump-test"
    let out = "/tmp/cjreg-dump-test-out"
    removeIfExists(dir, recursive: true)
    removeIfExists(out, recursive: true)
    Directory.create(dir, recursive: true)

    // 造数：1 个用户 + 1 个包（各一张表）
    var storm = Storm.open(dir + "/cjreg.db", syncWrites: true)
    let userStore = BstormUserStore(storm)
    PasswordHash.ITERATIONS = 1000
    let auth = AuthService(userStore, 3600)
    @Expect(auth.initAdmin("admin", "AdminPass1").isSome(), true)
    let pkgStore = PackageStore(storm)
    let doc = PackageDoc()
    doc.id = 1
    doc.organization = "demo"
    doc.name = "demo-app"
    doc.version = "1.0.0"
    doc.indexJson = "{}"
    pkgStore.save(doc)
    storm.close()

    // dump（只读扫描）
    storm = Storm.open(dir + "/cjreg.db", syncWrites: true)
    let result = dumpDatabase(storm, out, dataDir: dir)
    storm.close()
    @Expect(result.totalRows, 2)
    @Expect(result.tables.size, 2)
    @Expect(exists(Path(out + "/manifest.json")), true)
    @Expect(exists(Path(out + "/user_doc.jsonl")), true)
    @Expect(exists(Path(out + "/package_doc.jsonl")), true)
    // 内部族（__schema/__idx 等）不导出
    @Expect(exists(Path(out + "/__schema.jsonl")), false)

    let userText = readTextFile(out + "/user_doc.jsonl")
    @Expect(userText.contains("\"admin\""), true)
    @Expect(userText.startsWith("{"), true)
    let pkgText = readTextFile(out + "/package_doc.jsonl")
    @Expect(pkgText.contains("demo-app"), true)
    @Expect(pkgText.contains("demo"), true)
    let manifest = readTextFile(out + "/manifest.json")
    @Expect(manifest.contains("\"totalRows\": 2"), true)

    // dump 之后数据保持原样
    storm = Storm.open(dir + "/cjreg.db", syncWrites: true)
    let reloaded = BstormUserStore(storm)
    @Expect(reloaded.getUserByUsername("admin").isSome(), true)
    let pkgs = PackageStore(storm)
    @Expect(pkgs.listVersions("demo", "demo-app").size, 1)
    storm.close()
    removeIfExists(dir, recursive: true)
    removeIfExists(out, recursive: true)
}
