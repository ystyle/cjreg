// 进程内 HTTP 测试夹具（handler 层测试共用）
//
// 为什么需要：handler 层（server.cj 的协议端点、admin_*/public/user handler）的输入是
// TangHttpContext，响应断言要看真实状态码与报文。这里不造假 context，而是**起一个真实的
// 进程内 stdx Server**（127.0.0.1 + 端口 0 随机绑定），用真实 Client 发请求 ——
// 走的正是生产那条路径（路由匹配、鉴权、DTO 序列化、状态码）。
//
// 为什么放在 `*_test.cj`：既要用同包 test_stores_test.cj 的内存库夹具，又要被 cjcov 排除
// （覆盖率分母只算生产代码，测试代码不计入）。
//
// 生命周期：内存态 Storm 很重且被后台线程持有（见 test_stores_test.cj 的说明），
// 服务与客户端同样持有 socket —— 夹具创建时先关掉上一代，用例结束调 env.close()，
// 避免累计后触发 OOM（docs/verification.md §4.7）。
package ystyle::cjreg.server

import tang.*
import bstorm.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.util.*
import ystyle::cjreg.auth.model.*
import ystyle::cjreg.config.*
import ystyle::cjreg.index.*
import stdx.net.http.*
import std.collection.*
import std.convert.*
import std.fs.{Directory, exists}
import std.io.StringReader
import std.sync.*

// afterBind 回调与主线程之间的握手
class PortHolder {
    var value: UInt16 = 0
}

// 起真实服务：端口 0 让内核分配，避免与生产实例/其它用例抢端口
func startInProcServer(app: Tang): (String, Server, Client) {
    let lock = Mutex()
    let cond = synchronized(lock) { lock.condition() }
    let holder = PortHolder()
    let server = ServerBuilder()
        .distributor(app.getRouter())
        .addr("127.0.0.1")
        .port(0)
        .build()
    server.afterBind({ =>
        synchronized(lock) {
            holder.value = server.port
            cond.notifyAll()
        }
    })
    spawn { => server.serve() }
    synchronized(lock) {
        while (holder.value == 0) {
            cond.wait(timeout: 5 * Duration.second)
        }
    }
    (("http://127.0.0.1:" + holder.value.toString()), server, ClientBuilder().build())
}

// 上一代服务/客户端：新建夹具时统一关闭，防止用例中途失败 return 时泄漏。
//
// ⚠️ 同样是**线程局部**的：unittest 用多个 worker 线程并发跑用例，进程级列表会让
// 一个用例建夹具时把别的用例正在用的 server/client 一起关掉（症状与内存库那条一致：
// 「全量跑间歇失败、单独跑全绿」，且失败点每次漂移）。
// 内存库的生命周期交给线程局部的 beginTestStores()/testStorm()，见 test_stores_test.cj。
let liveServers = ThreadLocal<ArrayList<Server>>()
let liveClients = ThreadLocal<ArrayList<Client>>()

func covServerList(): ArrayList<Server> {
    match (liveServers.get()) {
        case Some(l) => l
        case None =>
            let l = ArrayList<Server>()
            liveServers.set(Some(l))
            l
    }
}

func covClientList(): ArrayList<Client> {
    match (liveClients.get()) {
        case Some(l) => l
        case None =>
            let l = ArrayList<Client>()
            liveClients.set(Some(l))
            l
    }
}

func closeTestServers(): Unit {
    let clients = covClientList()
    for (c in clients) {
        try {
            c.close()
        } catch (_: Exception) {
            ()
        }
    }
    clients.clear()
    let servers = covServerList()
    for (s in servers) {
        try {
            s.closeGracefully()
        } catch (_: Exception) {
            ()
        }
    }
    servers.clear()
}

// handler 测试的完整运行环境：真实 store + 真实服务 + 真实 client
class HttpEnv {
    let storm: Storm
    let pkgStore: PackageStore
    let userStore: BstormUserStore
    let upStore: BstormUpstreamStore
    let authSvc: AuthService
    let adminData: AdminDataStore
    let blobStore: BlobStore
    let proxySvc: ProxyService
    let admin: AdminService
    let app: Tang
    let server: Server
    let client: Client
    let base: String
    let config: CjregConfig
    let tmpDir: String

    init(storm: Storm, pkgStore: PackageStore, userStore: BstormUserStore, upStore: BstormUpstreamStore,
         authSvc: AuthService, adminData: AdminDataStore, blobStore: BlobStore, proxySvc: ProxyService,
         admin: AdminService, app: Tang, server: Server, client: Client, base: String,
         config: CjregConfig, tmpDir: String) {
        this.storm = storm
        this.pkgStore = pkgStore
        this.userStore = userStore
        this.upStore = upStore
        this.authSvc = authSvc
        this.adminData = adminData
        this.blobStore = blobStore
        this.proxySvc = proxySvc
        this.admin = admin
        this.app = app
        this.server = server
        this.client = client
        this.base = base
        this.config = config
        this.tmpDir = tmpDir
    }

    func close(): Unit {
        try {
            this.client.close()
        } catch (_: Exception) {
            ()
        }
        try {
            this.server.closeGracefully()
        } catch (_: Exception) {
            ()
        }

    }
}

// 夹具工厂：mode = permission_mode（open / team），requireAuth 决定读路径是否要鉴权
//
// tmpDir 非空时用 **DiskBlobStore**（生产同款）：制品落真实文件。这条很重要 ——
// 下载 handler 把 InputStream 直接交给响应体，stdx 需要能确定长度（File 可以，
// 自定义 InputStream 会报 "Unknown body size for Content-Length"），
// 所以"下载成功"这类断言只有走磁盘实现才与生产语义一致。
func newHttpEnv(mode!: String = "open", requireAuth!: Bool = false,
                maxRequestBytes!: Int64 = 10 * 1024 * 1024,
                tmpDir!: String = ""): HttpEnv {
    closeTestServers()
    beginTestStores()
    PasswordHash.ITERATIONS = 1000  // 测试提速（PBKDF2 默认迭代数很慢）
    let storm = testStorm()
    let pkgStore = PackageStore(storm)
    let userStore = BstormUserStore(storm)
    let upStore = BstormUpstreamStore(storm)
    let authSvc = AuthService(userStore, 3600)
    let adminData = AdminDataStore(storm)
    var blobStore: BlobStore = MemoryBlobStore()
    if (!tmpDir.isEmpty()) {
        let _ = covScratch("_")  // 确保父目录存在
        if (!exists(tmpDir)) {
            Directory.create(tmpDir, recursive: true)
        }
        blobStore = DiskBlobStore(tmpDir)
    }
    let upSvc = UpstreamService(upStore)
    let proxySvc = ProxyService(pkgStore, blobStore, upSvc, tmpDir: tmpDir)
    let admin = AdminService(authSvc, upSvc, userStore, upStore, ResolveService(upSvc), Some(proxySvc),
        PublishPlanService(pkgStore), PublishExecutor(pkgStore, blobStore),
        adminData: Some(adminData), pkgStore: Some(pkgStore), blobStore: Some(blobStore))
    let cfg = CjregConfig()
    cfg.permissionMode = mode
    cfg.requireAuth = requireAuth
    cfg.maxRequestBytes = maxRequestBytes
    cfg.publicUrl = "http://127.0.0.1:0"
    let app = buildServer(pkgStore, Some(admin), Some(upSvc), blobStore,
        config: cfg, adminData: Some(adminData), tmpDir: tmpDir)
    let (base, server, client) = startInProcServer(app)
    covServerList().add(server)
    covClientList().add(client)
    HttpEnv(storm, pkgStore, userStore, upStore, authSvc, adminData, blobStore, proxySvc,
        admin, app, server, client, base, cfg, tmpDir)
}

// 本次测试进程内可用的 scratch 目录（放工作区 .smoke 下，已被 gitignore）
// 已存在时复用：Directory.create 对已存在路径会抛 FSException，不能无条件建。
func covScratch(name: String): String {
    let dir = "./.smoke/http-cov/" + name
    if (!exists(dir)) {
        Directory.create(dir, recursive: true)
    }
    dir
}

// ===== 请求辅助 =====

func httpGet(env: HttpEnv, path: String, token!: String = ""): HttpResponse {
    let b = HttpRequestBuilder().get().url(env.base + path)
    if (!token.isEmpty()) {
        b.header("Authorization", "Bearer " + token)
    }
    env.client.send(b.build())
}

func httpPostJson(env: HttpEnv, path: String, body: String, token!: String = ""): HttpResponse {
    let b = HttpRequestBuilder().post().url(env.base + path)
        .header("Content-Type", "application/json; charset=utf-8")
    if (!token.isEmpty()) {
        b.header("Authorization", "Bearer " + token)
    }
    env.client.send(b.body(body).build())
}

// 裸 token 形态（官方发布规格 Authorization: <publishToken>，不带 Bearer）
func httpPostRaw(env: HttpEnv, path: String, body: Array<Byte>, token!: String = "",
                 contentType!: String = "application/octet-stream", bearer!: Bool = false): HttpResponse {
    let b = HttpRequestBuilder().post().url(env.base + path).header("Content-Type", contentType)
    if (!token.isEmpty()) {
        b.header("Authorization", if (bearer) { "Bearer " + token } else { token })
    }
    env.client.send(b.body(body).build())
}

func httpPutJson(env: HttpEnv, path: String, body: String, token!: String = ""): HttpResponse {
    let b = HttpRequestBuilder().put().url(env.base + path)
        .header("Content-Type", "application/json; charset=utf-8")
    if (!token.isEmpty()) {
        b.header("Authorization", "Bearer " + token)
    }
    env.client.send(b.body(body).build())
}

func httpDelete(env: HttpEnv, path: String, token!: String = ""): HttpResponse {
    let b = HttpRequestBuilder().delete().url(env.base + path)
    if (!token.isEmpty()) {
        b.header("Authorization", "Bearer " + token)
    }
    env.client.send(b.build())
}

// 文本响应体（读到底，兼容 content-length 与 chunked）
func bodyText(resp: HttpResponse): String {
    try {
        StringReader(resp.body).readToEnd()
    } catch (_: Exception) {
        ""
    }
}

// 二进制响应体（流式下载断言 sha 用）：分块读到 EOF
func bodyBytes(resp: HttpResponse): Array<Byte> {
    let out = ArrayList<UInt8>()
    let buf = Array<UInt8>(64 * 1024, repeat: 0)
    while (true) {
        let n = resp.body.read(buf)
        if (n <= 0) {
            break
        }
        for (i in 0..n) {
            out.add(buf[i])
        }
    }
    out.toArray()
}

// 响应头取值（不存在返回 ""）
func headerOf(resp: HttpResponse, name: String): String {
    for ((k, vs) in resp.headers) {
        if (k == name) {
            for (v in vs) {
                return v
            }
        }
    }
    ""
}

// ===== 身份辅助 =====

// 建管理员并登录，返回 session token
func seedAdminToken(env: HttpEnv, username!: String = "admin",
                    password!: String = "AdminPass1"): String {
    let _ = env.authSvc.initAdmin(username, password)
    loginToken(env, username, password)
}

// 走真实 /api/admin/login 换 session token
func loginToken(env: HttpEnv, username: String, password: String): String {
    let resp = httpPostJson(env, "/api/admin/login",
        "{\"username\":\"" + username + "\",\"password\":\"" + password + "\"}")
    extractJsonString(bodyText(resp), "token")
}

// 用 session token 换一个发布 token（走用户门户的重置端点，返回的是明文新 token）
func publishTokenOf(env: HttpEnv, sessionToken: String): String {
    let resp = httpPostJson(env, "/api/user/me/publish-token", "", token: sessionToken)
    extractJsonString(bodyText(resp), "publishToken")
}

// 从 JSON 文本里取字符串字段值（测试断言辅助；找不到返回 ""）
func extractJsonString(json: String, key: String): String {
    let needle = "\"" + key + "\":\""
    match (json.indexOf(needle)) {
        case Some(i) =>
            let rest = json[(i + needle.size)..json.size]
            match (rest.indexOf("\"")) {
                case Some(end) => rest[0..end]
                case None => ""
            }
        case None => ""
    }
}

// 从 JSON 文本里取整数字段值（找不到返回 -1）
func extractJsonInt(json: String, key: String): Int64 {
    let needle = "\"" + key + "\":"
    match (json.indexOf(needle)) {
        case Some(i) =>
            let rest = json[(i + needle.size)..json.size]
            var end = 0
            while (end < rest.size && rest[end] >= 48 && rest[end] <= 57) {  // '0'..'9'
                end++
            }
            if (end == 0) {
                return -1
            }
            match (Int64.tryParse(rest[0..end])) {
                case Some(v) => v
                case None => -1
            }
        case None => -1
    }
}

// 造一个本地发布态的包版本（indexJson 走协议自己的序列化器，不手工拼）
func seedPackage(env: HttpEnv, org: String, name: String, version: String,
                 desc!: String = "", deleted!: Bool = false): Int64 {
    let d = PackageDoc()
    d.organization = org
    d.name = name
    d.version = version
    d.description = desc
    d.cjcVersion = "1.1.3"
    d.artifactType = "src"
    d.deletedAt = if (deleted) { 1 } else { 0 }
    d.createdAt = 1000
    d.updatedAt = 2000
    d.sha256 = "0000000000000000000000000000000000000000000000000000000000000000"
    d.tarballSize = 12345
    let idx = PackageIndex()
    idx.organization = org
    idx.name = name
    idx.version = version
    idx.cjcVersion = d.cjcVersion
    idx.sha256sum = d.sha256
    d.indexJson = generateNDJSON(ArrayList<PackageIndex>([idx]))
    env.pkgStore.save(d)
    d.id
}
