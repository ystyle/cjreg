// 代理回源 · HTTP 传输层测试（proxy_http.cj）
//
// 用本地 stub stdx 服务当"上游"（127.0.0.1 + 端口 0），不打外网：
// 覆盖 200 / 非 200 带状态码 / 重定向跟随 / 重定向超限 / 传输层失败 / 流式读 /
// POST 二进制与响应正文截断 / 请求构造的 Authorization 头。
package ystyle::cjreg.server

import tang.*
import stdx.net.http.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

// 一个可编程的 stub 上游：按路径返回不同状态码/正文/重定向
func startStubUpstream(): (String, Server, ArrayList<String>, ArrayList<String>) {
    // 记录收到的 Authorization 头，供断言
    let seenAuth = ArrayList<String>()
    let seenPath = ArrayList<String>()
    let app = Tang()
    app.get("/ok", { ctx =>
        seenAuth.add(ctx.getHeader("Authorization") ?? "")
        seenPath.add(ctx.request.url.path)
        ctx.responseBuilder.body("hello-body")
    })
    app.get("/missing", { ctx =>
        ctx.responseBuilder.status(404u16).body("gone")
    })
    app.get("/boom", { ctx =>
        ctx.responseBuilder.status(500u16).body("server-error")
    })
    app.get("/redirect", { ctx =>
        // 302 到 /ok（覆盖重定向跟随分支）
        ctx.responseBuilder.status(302u16).header("Location", "/ok").body("")
    })
    app.get("/loop", { ctx =>
        // 永远重定向到自己（覆盖"重定向次数过多"）
        ctx.responseBuilder.status(302u16).header("Location", "/loop").body("")
    })
    app.get("/redirect-noloc", { ctx =>
        // 302 但没有 Location（覆盖"给了重定向却拿不到目标"）
        ctx.responseBuilder.status(302u16).body("")
    })
    app.get("/big", { ctx =>
        // 超过一次 read 缓冲的正文（覆盖分块循环读）
        let sb = StringBuilder()
        for (_ in 0..2000) {
            sb.append("0123456789")
        }
        ctx.responseBuilder.body(sb.toString())
    })
    app.post("/post", { ctx =>
        seenAuth.add(ctx.getHeader("Authorization") ?? "")
        let n = ctx.bodyRaw().size
        ctx.responseBuilder.status(201u16).body("received-${n}")
    })
    app.post("/post-error", { ctx =>
        // 失败时正文必须带出来（截断 300 字符）
        let sb = StringBuilder()
        for (_ in 0..400) {
            sb.append("E")
        }
        ctx.responseBuilder.status(429u16).body(sb.toString())
    })
    let (base, server, client) = startInProcServer(app)
    // client 不需要，直接关掉（stub 只被 httpGet 访问）
    client.close()
    (base, server, seenAuth, seenPath)
}

@Test
class ProxyHttpTransportTest {
    // GET 200：正文正确取到；Authorization 头按 token 传入
    @TestCase
    func testHttpGetOkAndAuthHeader(): Unit {
        let (base, server, seenAuth, _) = startStubUpstream()
        try {
            let bytes = httpGet(base + "/ok", "")
            @Expect(bytes.isSome(), true)
            @Expect(String.fromUtf8(bytes.getOrThrow()), "hello-body")
            @Expect(seenAuth[0], "")

            let withToken = httpGet(base + "/ok", "tok-123")
            @Expect(withToken.isSome(), true)
            @Expect(seenAuth[1], "tok-123")
        } finally {
            server.closeGracefully()
        }
    }

    // GET 非 200：一律 None（httpGet 的既有口径）
    @TestCase
    func testHttpGetNon200ReturnsNone(): Unit {
        let (base, server, _, _) = startStubUpstream()
        try {
            @Expect(httpGet(base + "/missing", "").isNone(), true)
            @Expect(httpGet(base + "/boom", "").isNone(), true)
        } finally {
            server.closeGracefully()
        }
    }

    // 传输层失败（连不上）→ None，不抛异常
    @TestCase
    func testHttpGetUnreachableReturnsNone(): Unit {
        // 127.0.0.1:9（discard）通常没有监听 → 连接被拒
        @Expect(httpGet("http://127.0.0.1:9/nothing", "").isNone(), true)
    }

    // 302 跟随：最终拿到 /ok 的正文
    @TestCase
    func testHttpGetFollowsRedirect(): Unit {
        let (base, server, _, seenPath) = startStubUpstream()
        try {
            let bytes = httpGet(base + "/redirect", "")
            @Expect(bytes.isSome(), true)
            @Expect(String.fromUtf8(bytes.getOrThrow()), "hello-body")
            // 重定向目标是相对路径 → 请求的是 /ok
            @Expect(seenPath.size > 0, true)
        } finally {
            server.closeGracefully()
        }
    }

    // 302 无 Location → None（拿不到目标就不算成功）
    @TestCase
    func testHttpGetRedirectWithoutLocationReturnsNone(): Unit {
        let (base, server, _, _) = startStubUpstream()
        try {
            @Expect(httpGet(base + "/redirect-noloc", "").isNone(), true)
        } finally {
            server.closeGracefully()
        }
    }

    // 重定向成环 → 超过 5 跳后放弃（None），不会无限循环
    @TestCase
    func testHttpGetRedirectLoopGivesUp(): Unit {
        let (base, server, _, _) = startStubUpstream()
        try {
            @Expect(httpGet(base + "/loop", "").isNone(), true)
        } finally {
            server.closeGracefully()
        }
    }

    // 大正文：分块循环读要拼全
    @TestCase
    func testHttpGetLargeBody(): Unit {
        let (base, server, _, _) = startStubUpstream()
        try {
            let bytes = httpGet(base + "/big", "")
            @Expect(bytes.isSome(), true)
            @Expect(bytes.getOrThrow().size, 20000)
        } finally {
            server.closeGracefully()
        }
    }

    // 带状态码 GET：200 带正文；404/500 保留真实状态码与正文
    @TestCase
    func testHttpGetWithStatus(): Unit {
        let (base, server, _, _) = startStubUpstream()
        try {
            let ok = httpGetWithStatus(base + "/ok", "")
            @Expect(ok.status, 200)
            @Expect(String.fromUtf8(ok.body), "hello-body")

            let missing = httpGetWithStatus(base + "/missing", "")
            @Expect(missing.status, 404)
            @Expect(String.fromUtf8(missing.body), "gone")

            let boom = httpGetWithStatus(base + "/boom", "")
            @Expect(boom.status, 500)
            @Expect(String.fromUtf8(boom.body), "server-error")
        } finally {
            server.closeGracefully()
        }
    }

    // 带状态码 GET：重定向跟随；成环 → status=0 且 error 说明原因
    //
    // 实测（本仓）要注意：stdx 的 Client 自身就会跟随重定向（上限 10 次），成环时
    // **抛 HttpException("Redirect loop exceed 10 times.")**，在 httpGetWithStatus 里
    // 落到 catch 分支（status=0 + error）——即它自己的 5 跳计数通常先碰不到。
    // 这里按真实行为断言：只要能区分「没问到」就不影响调用方语义。
    @TestCase
    func testHttpGetWithStatusRedirectAndLoop(): Unit {
        let (base, server, _, _) = startStubUpstream()
        try {
            let followed = httpGetWithStatus(base + "/redirect", "")
            @Expect(followed.status, 200)
            @Expect(String.fromUtf8(followed.body), "hello-body")

            let looped = httpGetWithStatus(base + "/loop", "")
            @Expect(looped.status, 0)
            @Expect(looped.error.isEmpty(), false)
        } finally {
            server.closeGracefully()
        }
    }

    // 带状态码 GET：传输层失败 → status=0 且 error 非空（调用方靠它区分「没问到」与「404」）
    @TestCase
    func testHttpGetWithStatusTransportFailure(): Unit {
        let out = httpGetWithStatus("http://127.0.0.1:9/nothing", "")
        @Expect(out.status, 0)
        @Expect(out.error.isEmpty(), false)
    }

    // 流式 GET：能分块读出完整正文
    @TestCase
    func testHttpGetStream(): Unit {
        let (base, server, _, _) = startStubUpstream()
        try {
            match (httpGetStream(base + "/big", "")) {
                case Some(st) =>
                    let bytes = readStreamToBytes(st)
                    @Expect(bytes.size, 20000)
                case None => @Fail("stream should be available for 200 response")
            }
            // 非 200 → None
            @Expect(httpGetStream(base + "/missing", "").isNone(), true)
        } finally {
            server.closeGracefully()
        }
    }

    // 流式 GET：传输层失败 → None
    @TestCase
    func testHttpGetStreamUnreachable(): Unit {
        @Expect(httpGetStream("http://127.0.0.1:9/nothing", "").isNone(), true)
    }

    // POST 二进制：2xx 判成功并带回正文；Authorization 头带上
    @TestCase
    func testHttpPostBinarySuccess(): Unit {
        let (base, server, seenAuth, _) = startStubUpstream()
        try {
            let (ok, code, text) = httpPostBinary(base + "/post", "payload".toArray(), "post-token")
            @Expect(ok, true)
            @Expect(code, 201)
            @Expect(text, "received-7")
            @Expect(seenAuth[0], "post-token")
        } finally {
            server.closeGracefully()
        }
    }

    // POST 失败：状态码与正文都要带出来（正文截断 300 字符 + 省略号）
    @TestCase
    func testHttpPostBinaryFailureKeepsBody(): Unit {
        let (base, server, _, _) = startStubUpstream()
        try {
            let (ok, code, text) = httpPostBinary(base + "/post-error", "x".toArray(), "")
            @Expect(ok, false)
            @Expect(code, 429)
            @Expect(text.size, 303)   // 300 + "..."
            @Expect(text.endsWith("..."), true)
        } finally {
            server.closeGracefully()
        }
    }

    // POST 传输层失败：回 (false, 0, 错误原因)，不再只给 "HTTP 0"
    @TestCase
    func testHttpPostBinaryTransportFailure(): Unit {
        let (ok, code, text) = httpPostBinary("http://127.0.0.1:9/post", "x".toArray(), "")
        @Expect(ok, false)
        @Expect(code, 0)
        @Expect(text.isEmpty(), false)
    }

    // readStreamToBytes：空流与多块流
    @TestCase
    func testReadStreamToBytes(): Unit {
        let empty = readStreamToBytes(BytesStream(Array<Byte>()))
        @Expect(empty.size, 0)
        let payload = "abcdefghij".toArray()
        @Expect(readStreamToBytes(BytesStream(payload)).size, 10)
    }

    // 客户端构造：http 与 https（https 走 TLS TrustAll 分支，不实际发请求）
    @TestCase
    func testBuildHttpClientBranches(): Unit {
        let plain = buildHttpClient("http://127.0.0.1:9/")
        plain.close()
        let secure = buildHttpClient("https://example.invalid/")
        secure.close()
    }
}
