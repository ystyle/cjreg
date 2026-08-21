// HTTP 服务端（tang）：发布/下载/索引 三端点 + 管理 API 挂载点
// 业务逻辑在 publish_service/index_service/download_service（纯逻辑已单测）
package ystyle::cjreg.server

import tang.*
import ystyle::cjreg.protocol.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.config.*
import std.collection.*
import stdx.encoding.json.stream.*
import std.io.*

// 组装 HTTP 服务：官方协议三端点 + 健康检查 + 管理 API
public func buildServer(
    store: PackageStore,
    admin: ?AdminService,
    port: UInt16
): Tang {
    let app = Tang()
    let publishSvc = PublishService(store)
    let indexSvc = IndexService(store)
    let downloadSvc = DownloadService(store)

    // 健康检查（自有端点，非官方协议）
    app.get("/api/health", { ctx =>
        ctx.writeString("{\"status\":\"ok\"}")
    })

    // 发布 POST /pkg/:name[?organization=]
    app.post("/pkg/:name", { ctx =>
        let name = ctx.param("name")
        let org = ctx.query("organization") ?? ""
        let body = ctx.bodyRaw()
        let result = publishSvc.publish(org, name, body)
        match (result.outcome) {
            case PublishOutcome.Ok =>
                ctx.status(200u16).writeStringWithCode(200u16, "{\"status\":\"ok\",\"id\":${result.pkgId}}")
            case PublishOutcome.InvalidFormat =>
                ctx.status(400u16).writeStringWithCode(400u16, "{\"error\":\"invalid data format\"}")
            case PublishOutcome.MetaMismatch =>
                ctx.status(400u16).writeStringWithCode(400u16, "{\"error\":\"${result.message}\"}")
            case PublishOutcome.ShaMismatch =>
                ctx.status(400u16).writeStringWithCode(400u16, "{\"error\":\"${result.message}\"}")
            case PublishOutcome.Conflict =>
                ctx.status(409u16).writeStringWithCode(409u16, "{\"error\":\"conflict\",\"detail\":\"${result.message}\"}")
            case PublishOutcome.BadRequest =>
                ctx.status(400u16).writeStringWithCode(400u16, "{\"error\":\"${result.message}\"}")
        }
    })

    // 下载 GET /pkg/:name/:version[?organization=]
    app.get("/pkg/:name/:version", { ctx =>
        let name = ctx.param("name")
        let version = ctx.param("version")
        let org = ctx.query("organization") ?? ""
        let doc = downloadSvc.find(org, name, version)
        match (doc) {
            case Some(d) =>
                ctx.attachment("${name}-${version}.cjp")
                    .set("Content-Type", "application/x-gzip")
                // TODO(M3)：从 blob 存储取真实制品字节；当前返回占位
                let placeholder: Array<Byte> = [UInt8(31), UInt8(139)]
                ctx.write(placeholder)
            case None =>
                ctx.status(404u16).writeStringWithCode(404u16, "{\"error\":\"not found\"}")
        }
    })

    // 索引 GET /index/:mo/:du/:name[?organization=]
    app.get("/index/:mo/:du/:name", { ctx =>
        let name = ctx.param("name")
        let org = ctx.query("organization") ?? ""
        let ndjson = indexSvc.generate(org, name, false)
        if (ndjson.isEmpty()) {
            ctx.status(404u16).writeStringWithCode(404u16, "{\"error\":\"not found\"}")
        } else {
            ctx.contentType("application/x-ndjson").writeString(ndjson)
        }
    })

    // 管理 API（可选：传入了 admin 服务才注册）
    match (admin) {
        case Some(adm) =>
            app.post("/api/admin/login", { ctx => adm.login(ctx) })
            app.post("/api/admin/logout", { ctx => adm.logout(ctx) })
            app.get("/api/admin/me", { ctx => adm.me(ctx) })
            app.get("/api/admin/users", { ctx => adm.listUsers(ctx) })
            app.post("/api/admin/users", { ctx => adm.createUser(ctx) })
            app.get("/api/admin/upstreams", { ctx => adm.listUpstreams(ctx) })
            app.post("/api/admin/upstreams", { ctx => adm.addUpstream(ctx) })
            app.delete("/api/admin/upstreams/:id", { ctx => adm.deleteUpstream(ctx) })
        case None => ()
    }

    app.setPort(port)
    return app
}

// 兼容：无管理 API 的构建（仅官方协议 + 健康检查）
public func buildServer(store: PackageStore, port: UInt16): Tang {
    buildServer(store, None, port)
}
