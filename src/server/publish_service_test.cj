// 发布/索引/下载服务单元测试
package ystyle::cjreg.server

import ystyle::cjreg.protocol.*
import ystyle::cjreg.index.*
import ystyle::cjreg.store.*
import bstorm.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*
import ystyle::cjreg.auth.util.*
import std.unittest.testmacro.*
import std.collection.*

// 构造一段 [version(1B)][size(4B LE)][data]
func makeSection(version: UInt8, data: Array<Byte>): ArrayList<Byte> {
    let buf = ArrayList<Byte>()
    buf.add(version)
    let size = data.size
    buf.add(UInt8(size & 0xFF))
    buf.add(UInt8((size >> 8) & 0xFF))
    buf.add(UInt8((size >> 16) & 0xFF))
    buf.add(UInt8((size >> 24) & 0xFF))
    for (b in data) {
        buf.add(b)
    }
    return buf
}

func toByteArray(list: ArrayList<Byte>): Array<Byte> {
    list.toArray()
}

func makeStore(): PackageStore {
    PackageStore(Storm.inMemory())
}

func makePublishService(): PublishService {
    PublishService(makeStore(), MemoryBlobStore())
}

// 构造一个合法发布 body：meta（含 index.sha256sum）+ tar
func makePublishBody(org: String, name: String, version: String, sha: String): Array<Byte> {
    let meta = "{\"organization\":\"${org}\",\"name\":\"${name}\",\"version\":\"${version}\"," +
        "\"index\":{\"sha256sum\":\"${sha}\",\"index-version\":1}}"
    let tar: Array<Byte> = [UInt8(31), UInt8(139), UInt8(8), UInt8(0), UInt8(1)]
    let buf = ArrayList<Byte>()
    for (b in makeSection(META_VERSION, meta.toArray())) {
        buf.add(b)
    }
    for (b in makeSection(TARBALL_VERSION, tar)) {
        buf.add(b)
    }
    toByteArray(buf)
}

// 构造带完整展示字段的 meta（官方规格全字段）
func makeMetaFullJson(org: String, name: String, version: String, sha: String): String {
    "{\"organization\":\"${org}\",\"name\":\"${name}\",\"version\":\"${version}\"," +
    "\"cjc-version\":\"1.1.3\",\"description\":\"demo package\"," +
    "\"artifact-type\":\"src\",\"executable\":true," +
    "\"authors\":[\"Tom\",\"Joan\"],\"repository\":\"https://github.com/x/demo\"," +
    "\"homepage\":\"https://demo.example.com\",\"documentation\":\"https://demo.example.com/docs\"," +
    "\"tag\":[\"cangjie\",\"cjpm\"],\"category\":[\"Network\"],\"license\":[\"Apache-2.0\"]," +
    "\"meta-version\":1,\"index\":{\"sha256sum\":\"${sha}\",\"index-version\":1}}"
}

// 全字段 meta + tar 的发布 body（用于入库字段断言）
func makePublishBodyFull(org: String, name: String, version: String): Array<Byte> {
    let tar: Array<Byte> = [UInt8(31), UInt8(139), UInt8(8), UInt8(0), UInt8(1)]
    let meta = makeMetaFullJson(org, name, version, sha256Hex(tar))
    let buf = ArrayList<Byte>()
    for (b in makeSection(META_VERSION, meta.toArray())) {
        buf.add(b)
    }
    for (b in makeSection(TARBALL_VERSION, tar)) {
        buf.add(b)
    }
    toByteArray(buf)
}

// 让 meta 的 sha 与指定 tar 一致
func makePublishBodyWithTar(org: String, name: String, version: String, tar: Array<Byte>): Array<Byte> {
    let sha = sha256Hex(tar)
    let meta = "{\"organization\":\"${org}\",\"name\":\"${name}\",\"version\":\"${version}\"," +
        "\"index\":{\"sha256sum\":\"${sha}\",\"index-version\":1}}"
    let buf = ArrayList<Byte>()
    for (b in makeSection(META_VERSION, meta.toArray())) {
        buf.add(b)
    }
    for (b in makeSection(TARBALL_VERSION, tar)) {
        buf.add(b)
    }
    toByteArray(buf)
}

// 让 meta 的 sha 与 tar 实际一致
func makePublishBodyConsistent(org: String, name: String, version: String): Array<Byte> {
    let tar: Array<Byte> = [UInt8(31), UInt8(139), UInt8(8), UInt8(0), UInt8(1)]
    makePublishBodyWithTar(org, name, version, tar)
}

@Test
func testSha256Hex() {
    let sha = sha256Hex("hello".toArray())
    // sha256("hello") 已知值
    @Expect(sha, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
}

@Test
func testPublishOk() {
    let svc = makePublishService()
    let body = makePublishBodyConsistent("test", "demo", "1.0.0")
    let r = svc.publish("test", "demo", body)
    @Expect(r.outcome == PublishOutcome.Ok, true)
    @Expect(r.pkgId > 0, true)
    // 同版本同 sha → 幂等 Ok
    let r2 = svc.publish("test", "demo", body)
    @Expect(r2.outcome == PublishOutcome.Ok, true)
}

@Test
func testParseMetaFullFields() {
    let meta = makeMetaFullJson("test", "demo", "1.0.0", "abc123")
    let info = parseMetaJson(meta.toArray())
    @Expect(info.isSome(), true)
    let m = info.getOrThrow()
    @Expect(m.org, "test")
    @Expect(m.name, "demo")
    @Expect(m.version, "1.0.0")
    @Expect(m.sha256sum, "abc123")
    @Expect(m.cjcVersion, "1.1.3")
    @Expect(m.description, "demo package")
    @Expect(m.artifactType, "src")
    @Expect(m.executable, true)
    @Expect(m.authors.size, 2)
    @Expect(m.authors[0], "Tom")
    @Expect(m.repository, "https://github.com/x/demo")
    @Expect(m.homepage, "https://demo.example.com")
    @Expect(m.documentation, "https://demo.example.com/docs")
    @Expect(m.tag.size, 2)
    @Expect(m.category.size, 1)
    @Expect(m.license[0], "Apache-2.0")
    @Expect(m.metaVersion, 1)
}

@Test
func testPublishStoresFullMetadata() {
    let svc = makePublishService()
    let body = makePublishBodyFull("test", "demo", "2.0.0")
    let r = svc.publish("test", "demo", body)
    @Expect(r.outcome == PublishOutcome.Ok, true)
    let versions = svc.store.listVersions("test", "demo")
    @Expect(versions.size, 1)
    let d = versions[0]
    @Expect(d.description, "demo package")
    @Expect(d.cjcVersion, "1.1.3")
    @Expect(d.executable, true)
    @Expect(d.authors.size, 2)
    @Expect(d.license.size, 1)
    @Expect(d.metaVersion, 1)
    @Expect(d.sha256 == sha256Hex([UInt8(31), UInt8(139), UInt8(8), UInt8(0), UInt8(1)]), true)
    @Expect(d.tarballSize, 5)
}

@Test
func testPublishInvalidFormat() {
    let svc = makePublishService()
    // 空 body
    let r = svc.publish("test", "demo", Array<Byte>())
    @Expect(r.outcome == PublishOutcome.InvalidFormat, true)
}

@Test
func testPublishMetaMismatch() {
    let svc = makePublishService()
    let body = makePublishBodyConsistent("test", "demo", "1.0.0")
    // URL name 与 meta 不一致
    let r = svc.publish("test", "other", body)
    @Expect(r.outcome == PublishOutcome.MetaMismatch, true)
    // URL org 与 meta 不一致
    let r2 = svc.publish("wrong", "demo", body)
    @Expect(r2.outcome == PublishOutcome.MetaMismatch, true)
}

@Test
func testPublishShaMismatch() {
    let svc = makePublishService()
    // meta 声明的 sha 与实际 tar 不同
    let body = makePublishBody("test", "demo", "1.0.0", "0000000000000000000000000000000000000000000000000000000000000000")
    let r = svc.publish("test", "demo", body)
    @Expect(r.outcome == PublishOutcome.ShaMismatch, true)
}

@Test
func testPublishConflict() {
    let svc = makePublishService()
    // 先发版本 A（tar1）
    let tar1: Array<Byte> = [UInt8(31), UInt8(139), UInt8(8), UInt8(0), UInt8(1)]
    let bodyA = makePublishBodyWithTar("test", "demo", "1.0.0", tar1)
    svc.publish("test", "demo", bodyA)
    // 同版本不同 tar（sha 不同）→ 冲突
    let tar2: Array<Byte> = [UInt8(31), UInt8(139), UInt8(8), UInt8(0), UInt8(99)]
    let bodyB = makePublishBodyWithTar("test", "demo", "1.0.0", tar2)
    let r = svc.publish("test", "demo", bodyB)
    @Expect(r.outcome == PublishOutcome.Conflict, true)
}

@Test
func testIndexAndDownload() {
    let store = makeStore()
    let svc = PublishService(store, MemoryBlobStore())
    let body = makePublishBodyConsistent("test", "demo", "1.0.0")
    svc.publish("test", "demo", body)
    // 再发一个版本
    let body2 = makePublishBodyConsistent("test", "demo", "1.1.0")
    svc.publish("test", "demo", body2)

    // 索引生成
    let idxSvc = IndexService(store)
    let ndjson = idxSvc.generate("test", "demo", false)
    let parsed = parseNDJSON(ndjson)
    @Expect(parsed.size, 2)
    @Expect(parsed[0].version, "1.0.0")
    @Expect(parsed[1].version, "1.1.0")

    // 下载 + 计数
    let dlSvc = DownloadService(store)
    let found = dlSvc.find("test", "demo", "1.0.0")
    @Expect(found.isSome(), true)
    match (found) {
        case Some(d) => @Expect(d.downloadCount, 1)
        case None => ()
    }
    // 再下载一次 → 计数 2
    dlSvc.find("test", "demo", "1.0.0")
    let after = store.getById(found.getOrThrow().id).getOrThrow()
    @Expect(after.downloadCount, 2)
    // 不存在版本 → None
    @Expect(dlSvc.find("test", "demo", "9.9.9").isNone(), true)
}

// 带认证的发布服务（规格：Authorization 携带 publish token）
func makePublishServiceAuth(): (PublishService, String, AuthService) {
    PasswordHash.ITERATIONS = 1000  // 测试提速
    let store = MemoryUserStore()
    let authSvc = AuthService(store, 3600)
    let admin = authSvc.initAdmin("admin", "AdminPass1").getOrThrow()
    let svc = PublishService(makeStore(), MemoryBlobStore(), auth: Some(authSvc))
    (svc, admin.publishToken, authSvc)
}

@Test
func testPublishUnauthorized() {
    let (svc, _, _) = makePublishServiceAuth()
    let body = makePublishBodyConsistent("test", "demo", "1.0.0")
    // 缺失 token → 401
    let r1 = svc.publish("test", "demo", body, "")
    @Expect(r1.outcome == PublishOutcome.Unauthorized, true)
    // 无效 token → 401
    let r2 = svc.publish("test", "demo", body, "publish-fake")
    @Expect(r2.outcome == PublishOutcome.Unauthorized, true)
    // session token 不能发布
    let (_, _, authSvc) = makePublishServiceAuth()
    let (_, sess) = authSvc.login("admin", "AdminPass1").getOrThrow()
    let r3 = svc.publish("test", "demo", body, sess.token)
    @Expect(r3.outcome == PublishOutcome.Unauthorized, true)
}

@Test
func testPublishAuthorizedStoresPublisher() {
    let (svc, token, _) = makePublishServiceAuth()
    let body = makePublishBodyFull("test", "demo", "3.0.0")
    let r = svc.publish("test", "demo", body, token)
    @Expect(r.outcome == PublishOutcome.Ok, true)
    let versions = svc.store.listVersions("test", "demo")
    @Expect(versions.size, 1)
    // 发布者已记录（对齐 cjrepo PublisherID）
    @Expect(versions[0].publisherId > 0, true)
    // 全字段仍入库
    @Expect(versions[0].description, "demo package")
}

// 带权限模型的发布服务（共享 storm：用户表 + 团队/组织数据）
func makePublishServicePerm(): (PublishService, AuthService, AdminDataStore, String) {
    PasswordHash.ITERATIONS = 1000  // 测试提速
    let storm = Storm.inMemory()
    let userStore = BstormUserStore(storm)
    let authSvc = AuthService(userStore, 3600)
    let admin = authSvc.initAdmin("admin", "AdminPass1").getOrThrow()
    let adminData = AdminDataStore(storm)
    let svc = PublishService(makeStore(), MemoryBlobStore(),
        auth: Some(authSvc), adminData: Some(adminData), permissionMode: "team")
    (svc, authSvc, adminData, admin.publishToken)
}

@Test
func testPublishForbiddenNoTeam() {
    let (svc, authSvc, _, adminToken) = makePublishServicePerm()
    // 管理员先建立既有版本（有了版本才谈「新版本」权限）
    let base = makePublishBodyConsistent("test", "demo", "1.0.0")
    @Expect(svc.publish("test", "demo", base, adminToken).outcome == PublishOutcome.Ok, true)
    // 普通用户（非管理员、无团队、非 publisher）发新版本 → 403
    let u = authSvc.createUser("alice", "alice123", false).getOrThrow()
    let body = makePublishBodyConsistent("test", "demo", "1.1.0")
    let r = svc.publish("test", "demo", body, u.publishToken)
    @Expect(r.outcome == PublishOutcome.Forbidden, true)
}

@Test
func testPublishNewPackageClaimAllowedInTeamMode() {
    let (svc, authSvc, _, _) = makePublishServicePerm()
    // 自由命名空间（无团队纳管）：任意有效 token 可认领新包，首次发布者成为 publisher
    let u = authSvc.createUser("alice", "alice123", false).getOrThrow()
    let body = makePublishBodyConsistent("test", "demo", "1.0.0")
    let r = svc.publish("test", "demo", body, u.publishToken)
    @Expect(r.outcome == PublishOutcome.Ok, true)
    let versions = svc.store.listVersions("test", "demo")
    @Expect(versions.size, 1)
    @Expect(versions[0].publisherId, u.id)
}

@Test
func testPublishNewPackageForbiddenWhenGoverned() {
    let (svc, authSvc, adminData, _) = makePublishServicePerm()
    // 组织已被团队纳管（read 级）：外人不得在纳管命名空间「认领」新包
    let orgId = adminData.createOrg("acme", "Acme", 1, 0)
    let teamId = adminData.createTeam("acme-readers", 0, permission: "read")
    adminData.setTeamOrganizations(teamId, [orgId], 0)
    let u = authSvc.createUser("alice", "alice123", false).getOrThrow()
    let r = svc.publish("acme", "lib", makePublishBodyConsistent("acme", "lib", "1.0.0"), u.publishToken)
    @Expect(r.outcome == PublishOutcome.Forbidden, true)
}

@Test
func testPublishNewVersionByPublisherAllowed() {
    let (svc, authSvc, _, _) = makePublishServicePerm()
    // 认领者后续版本走个人发布路径（publisher → write），无需团队
    let u = authSvc.createUser("alice", "alice123", false).getOrThrow()
    let first = svc.publish("test", "demo", makePublishBodyConsistent("test", "demo", "1.0.0"), u.publishToken)
    @Expect(first.outcome == PublishOutcome.Ok, true)
    let r = svc.publish("test", "demo", makePublishBodyConsistent("test", "demo", "1.1.0"), u.publishToken)
    @Expect(r.outcome == PublishOutcome.Ok, true)
    @Expect(svc.store.listVersions("test", "demo").size, 2)
}

@Test
func testPublishForbiddenReadTeam() {
    let (svc, authSvc, adminData, adminToken) = makePublishServicePerm()
    @Expect(svc.publish("test", "demo", makePublishBodyConsistent("test", "demo", "1.0.0"), adminToken).outcome == PublishOutcome.Ok, true)
    let u = authSvc.createUser("bob", "bob12345", false).getOrThrow()
    // 团队关联该组织但权限只有 read → 新版本 403
    let orgId = adminData.createOrg("test", "Test", 1, 0)
    let teamId = adminData.createTeam("readers", 0, permission: "read")
    adminData.setTeamOrganizations(teamId, [orgId], 0)
    adminData.setTeamMembers(teamId, [u.id])
    let r = svc.publish("test", "demo", makePublishBodyConsistent("test", "demo", "1.1.0"), u.publishToken)
    @Expect(r.outcome == PublishOutcome.Forbidden, true)
}

@Test
func testPublishAllowedWriteTeam() {
    let (svc, authSvc, adminData, adminToken) = makePublishServicePerm()
    @Expect(svc.publish("test", "demo", makePublishBodyConsistent("test", "demo", "1.0.0"), adminToken).outcome == PublishOutcome.Ok, true)
    let u = authSvc.createUser("carol", "carol123", false).getOrThrow()
    // 团队关联该组织且权限 write → 允许发新版本，并记录该版本的发布者
    let orgId = adminData.createOrg("test", "Test", 1, 0)
    let teamId = adminData.createTeam("writers", 0, permission: "write")
    adminData.setTeamOrganizations(teamId, [orgId], 0)
    adminData.setTeamMembers(teamId, [u.id])
    let r = svc.publish("test", "demo", makePublishBodyConsistent("test", "demo", "1.1.0"), u.publishToken)
    @Expect(r.outcome == PublishOutcome.Ok, true)
    @Expect(svc.store.listVersions("test", "demo").size, 2)
    @Expect(publisherOfVersion(svc.store, "test", "demo", "1.1.0"), u.id)
}

@Test
func testPublishAllowedByTeamPackageLink() {
    let (svc, authSvc, adminData, adminToken) = makePublishServicePerm()
    @Expect(svc.publish("test", "demo", makePublishBodyConsistent("test", "demo", "1.0.0"), adminToken).outcome == PublishOutcome.Ok, true)
    let u = authSvc.createUser("dave", "dave1234", false).getOrThrow()
    // 团队只关联该包（不关联组织）且权限 write → 允许
    let teamId = adminData.createTeam("pkg-owners", 0, permission: "write")
    let pairs = ArrayList<(String, String)>()
    pairs.add(("test", "demo"))
    adminData.setTeamPackages(teamId, pairs.toArray(), 0)
    adminData.setTeamMembers(teamId, [u.id])
    let r = svc.publish("test", "demo", makePublishBodyConsistent("test", "demo", "1.1.0"), u.publishToken)
    @Expect(r.outcome == PublishOutcome.Ok, true)
}

// 指定版本的发布者（不存在返回 -1）
func publisherOfVersion(store: PackageStore, org: String, name: String, version: String): Int64 {
    for (d in store.listVersions(org, name)) {
        if (d.version == version) {
            return d.publisherId
        }
    }
    -1
}

@Test
func testPublishOverwriteRequiresOverwritePermission() {
    let (svc, authSvc, adminData, _) = makePublishServicePerm()
    let alice = authSvc.createUser("alice", "alice123", false).getOrThrow()
    let tar1: Array<Byte> = [UInt8(31), UInt8(139), UInt8(8), UInt8(0), UInt8(1)]
    let tar2: Array<Byte> = [UInt8(31), UInt8(139), UInt8(8), UInt8(0), UInt8(99)]
    // 登记组织（尚未被任何团队纳管）→ alice 可认领该命名空间下的新包
    let orgId = adminData.createOrg("test", "Test", 1, 0)
    let first = svc.publish("test", "demo", makePublishBodyWithTar("test", "demo", "1.0.0", tar1), alice.publishToken)
    @Expect(first.outcome == PublishOutcome.Ok, true)

    // publisher 自己也没有 overwrite（覆盖属团队权限）→ 403
    let byPublisher = svc.publish("test", "demo", makePublishBodyWithTar("test", "demo", "1.0.0", tar2), alice.publishToken)
    @Expect(byPublisher.outcome == PublishOutcome.Forbidden, true)

    // write 团队不足以覆盖 → 403
    let writer = authSvc.createUser("bob", "bob12345", false).getOrThrow()
    let wTeam = adminData.createTeam("writers", 0, permission: "write")
    adminData.setTeamOrganizations(wTeam, [orgId], 0)
    adminData.setTeamMembers(wTeam, [writer.id])
    let byWriter = svc.publish("test", "demo", makePublishBodyWithTar("test", "demo", "1.0.0", tar2), writer.publishToken)
    @Expect(byWriter.outcome == PublishOutcome.Forbidden, true)

    // overwrite 团队 → 覆盖成功：同版本文档原地更新（不新增），包名所有权仍属首次发布者
    let owner = authSvc.createUser("carol", "carol123", false).getOrThrow()
    let oTeam = adminData.createTeam("overwriters", 0, permission: "overwrite")
    adminData.setTeamOrganizations(oTeam, [orgId], 0)
    adminData.setTeamMembers(oTeam, [owner.id])
    let ok = svc.publish("test", "demo", makePublishBodyWithTar("test", "demo", "1.0.0", tar2), owner.publishToken)
    @Expect(ok.outcome == PublishOutcome.Ok, true)
    let versions = svc.store.listVersions("test", "demo")
    @Expect(versions.size, 1)
    @Expect(versions[0].sha256, sha256Hex(tar2))
    @Expect(versions[0].publisherId, alice.id)
    // 覆盖后同 sha 再发 → 幂等 Ok
    let idem = svc.publish("test", "demo", makePublishBodyWithTar("test", "demo", "1.0.0", tar2), owner.publishToken)
    @Expect(idem.outcome == PublishOutcome.Ok, true)
}

@Test
func testPublishAdminBypassPermission() {
    let (svc, _, _, adminToken) = makePublishServicePerm()
    // 平台管理员直通：纳管命名空间/覆盖均放行
    let tar1: Array<Byte> = [UInt8(31), UInt8(139), UInt8(8), UInt8(0), UInt8(1)]
    let tar2: Array<Byte> = [UInt8(31), UInt8(139), UInt8(8), UInt8(0), UInt8(99)]
    @Expect(svc.publish("ops", "tool", makePublishBodyWithTar("ops", "tool", "1.0.0", tar1), adminToken).outcome == PublishOutcome.Ok, true)
    @Expect(svc.publish("ops", "tool", makePublishBodyWithTar("ops", "tool", "1.0.0", tar2), adminToken).outcome == PublishOutcome.Ok, true)
    @Expect(svc.store.listVersions("ops", "tool")[0].sha256, sha256Hex(tar2))
}

@Test
func testEffectivePermissionLevels() {
    let (svc, authSvc, adminData, _) = makePublishServicePerm()
    let store = svc.store
    let alice = authSvc.createUser("alice", "alice123", false).getOrThrow()
    let bob = authSvc.createUser("bob", "bob12345", false).getOrThrow()
    let carol = authSvc.createUser("carol", "carol123", false).getOrThrow()
    let admin = authSvc.store.getUserByUsername("admin").getOrThrow()

    // 无任何关联 → 0；管理员 → 3（直通）
    @Expect(effectivePermission(store, adminData, alice, "test", "demo"), 0)
    @Expect(effectivePermission(store, adminData, admin, "test", "demo"), 3)

    // 个人发布路径：任一版本 publisherId 命中 → 2
    let d = PackageDoc()
    d.organization = "test"
    d.name = "demo"
    d.version = "1.0.0"
    d.publisherId = alice.id
    store.save(d)
    @Expect(effectivePermission(store, adminData, alice, "test", "demo"), 2)
    @Expect(effectivePermission(store, adminData, bob, "test", "demo"), 0)

    // 团队包级关联 read → 1
    let t1 = adminData.createTeam("pkg-readers", 0, permission: "read")
    let pairs = ArrayList<(String, String)>()
    pairs.add(("test", "demo"))
    adminData.setTeamPackages(t1, pairs.toArray(), 0)
    adminData.setTeamMembers(t1, [bob.id])
    @Expect(effectivePermission(store, adminData, bob, "test", "demo"), 1)

    // 组织级 overwrite → 3（与包级取最高）
    let orgId = adminData.createOrg("acme", "Acme", 1, 0)
    let t2 = adminData.createTeam("acme-owners", 0, permission: "overwrite")
    adminData.setTeamOrganizations(t2, [orgId], 0)
    adminData.setTeamMembers(t2, [carol.id])
    @Expect(effectivePermission(store, adminData, carol, "acme", "lib"), 3)

    // 未知组织名 ≠ 「无组织包(0)」：关联无组织的团队不得越权到未登记组织
    let t3 = adminData.createTeam("no-org", 0, permission: "overwrite")
    adminData.setTeamOrganizations(t3, [0], 0)
    adminData.setTeamMembers(t3, [carol.id])
    @Expect(effectivePermission(store, adminData, carol, "unknown-org", "lib"), 0)
    // 无组织包（org 空串）仍匹配 0
    @Expect(effectivePermission(store, adminData, carol, "", "lib"), 3)
}

@Test
func testCheckReadPermission() {
    let (svc, authSvc, adminData, _) = makePublishServicePerm()
    let store = svc.store
    let alice = authSvc.createUser("alice", "alice123", false).getOrThrow()
    let bob = authSvc.createUser("bob", "bob12345", false).getOrThrow()
    let admin = authSvc.store.getUserByUsername("admin").getOrThrow()

    // 无关联 → 拒绝；管理员 → 允许
    @Expect(checkReadPermission(store, adminData, bob, "test", "demo"), false)
    @Expect(checkReadPermission(store, adminData, admin, "test", "demo"), true)

    // publisher（个人路径 write）→ 可读
    let d = PackageDoc()
    d.organization = "test"
    d.name = "demo"
    d.version = "1.0.0"
    d.publisherId = alice.id
    store.save(d)
    @Expect(checkReadPermission(store, adminData, alice, "test", "demo"), true)

    // 团队 read → 可读
    let orgId = adminData.createOrg("test", "Test", 1, 0)
    let teamId = adminData.createTeam("readers", 0, permission: "read")
    adminData.setTeamOrganizations(teamId, [orgId], 0)
    adminData.setTeamMembers(teamId, [bob.id])
    @Expect(checkReadPermission(store, adminData, bob, "test", "demo"), true)
    // 其他组织/包 → 拒绝
    @Expect(checkReadPermission(store, adminData, bob, "other", "demo"), false)
}

// ===== 包名所有者（模型 B）：版本级 publisher 累加，但仅首个发布者参与权限 =====

@Test
func testPackageOwnerIsFirstPublisherOnly() {
    let (svc, authSvc, adminData, adminToken) = makePublishServicePerm()
    let store = svc.store
    let alice = authSvc.createUser("alice", "alice123", false).getOrThrow()
    let member = authSvc.createUser("bob", "bob12345", false).getOrThrow()

    // alice 认领新包（自由命名空间）→ 成为唯一 owner
    @Expect(svc.publish("test", "demo", makePublishBodyConsistent("test", "demo", "1.0.0"), alice.publishToken).outcome == PublishOutcome.Ok, true)
    @Expect(packageOwner(store, "test", "demo"), alice.id)
    @Expect(isPackagePublisher(store, "test", "demo", alice.id), true)

    // 团队成员发一个新版本 → 该版本 publisherId 记为 bob（事实累加），但 owner 不变
    let orgId = adminData.createOrg("test", "Test", 1, 0)
    let teamId = adminData.createTeam("writers", 0, permission: "write")
    adminData.setTeamOrganizations(teamId, [orgId], 0)
    adminData.setTeamMembers(teamId, [member.id])
    @Expect(svc.publish("test", "demo", makePublishBodyConsistent("test", "demo", "1.1.0"), member.publishToken).outcome == PublishOutcome.Ok, true)
    @Expect(publisherOfVersion(store, "test", "demo", "1.1.0"), member.id)  // 版本级记录照旧
    @Expect(packageOwner(store, "test", "demo"), alice.id)                   // owner 唯一且不变
    @Expect(isPackagePublisher(store, "test", "demo", member.id), false)

    // bob 在团队内：write 来自团队路径（2），不是 owner 身份
    @Expect(effectivePermission(store, adminData, member, "test", "demo"), 2)
    // 退出团队后：不再有任何权限（模型 B 下版本级 publisher 不授予权限）
    adminData.setTeamMembers(teamId, Array<Int64>())
    @Expect(effectivePermission(store, adminData, member, "test", "demo"), 0)
    @Expect(checkReadPermission(store, adminData, member, "test", "demo"), false)

    // owner 自身不受影响
    @Expect(effectivePermission(store, adminData, alice, "test", "demo"), 2)

    // 覆盖不转移所有权（即使覆盖者不是 owner，且覆盖的是最早那条记录）
    let carol = authSvc.createUser("carol", "carol123", false).getOrThrow()
    let oTeam = adminData.createTeam("overwriters", 0, permission: "overwrite")
    adminData.setTeamOrganizations(oTeam, [orgId], 0)
    adminData.setTeamMembers(oTeam, [carol.id])
    let tar2: Array<Byte> = [UInt8(31), UInt8(139), UInt8(8), UInt8(0), UInt8(99)]
    @Expect(svc.publish("test", "demo", makePublishBodyWithTar("test", "demo", "1.0.0", tar2), carol.publishToken).outcome == PublishOutcome.Ok, true)
    @Expect(packageOwner(store, "test", "demo"), alice.id)
    @Expect(publisherOfVersion(store, "test", "demo", "1.0.0"), alice.id)

    // 管理员直通不受模型影响
    @Expect(svc.publish("test", "demo", makePublishBodyConsistent("test", "demo", "2.0.0"), adminToken).outcome == PublishOutcome.Ok, true)
    @Expect(packageOwner(store, "test", "demo"), alice.id)
}

@Test
func testPublishOpenModeAllowsNonTeamUser() {
    // 默认 open 模式：小企业内部先用着——有效 token 即可发布（无需团队授权）
    PasswordHash.ITERATIONS = 1000
    let storm = Storm.inMemory()
    let userStore = BstormUserStore(storm)
    let authSvc = AuthService(userStore, 3600)
    let u = authSvc.createUser("eve", "eve12345", false).getOrThrow()
    let adminData = AdminDataStore(storm)
    let svc = PublishService(makeStore(), MemoryBlobStore(),
        auth: Some(authSvc), adminData: Some(adminData))  // 默认 permissionMode=open
    let body = makePublishBodyConsistent("test", "demo", "1.0.0")
    let r = svc.publish("test", "demo", body, u.publishToken)
    @Expect(r.outcome == PublishOutcome.Ok, true)
    // 发布者仍记录
    let versions = svc.store.listVersions("test", "demo")
    @Expect(versions[0].publisherId, u.id)
    // open 模式下同版本不同 sha 不静默覆盖，仍按冲突处理（覆盖只在 team 模式按权限执行）
    let tar2: Array<Byte> = [UInt8(31), UInt8(139), UInt8(8), UInt8(0), UInt8(99)]
    let conflict = svc.publish("test", "demo", makePublishBodyWithTar("test", "demo", "1.0.0", tar2), u.publishToken)
    @Expect(conflict.outcome == PublishOutcome.Conflict, true)
}
