// API 响应 DTO 与序列化助手
// 响应体由 tang 的 json/jsonWithCode 直接序列化进响应流（JsonWriter → 响应体），
// handler 不再手工拼 JSON 字符串，也不在中间多落一份 JSON 文本
package ystyle::cjreg.server

import tang.*
import std.io.*
import std.collection.*
import stdx.encoding.json.stream.*

// 写 JSON 响应：content-type + 状态码 + DTO 直接进响应体
public func writeDto<T>(ctx: TangHttpContext, code: UInt16, dto: T): Unit where T <: JsonSerializable {
    ctx.contentType("application/json; charset=utf-8").jsonWithCode(code, dto)
}

// DTO → JSON 文本
// 只用于 SSE 帧（event/data 是文本，插不进 jsonWithCode 的响应体）与测试断言；
// 普通响应请直接用 writeDto
public func jsonText<T>(dto: T): String where T <: JsonSerializable {
    let bb = ByteBuffer()
    let w = JsonWriter(bb)
    dto.toJson(w)
    w.flush()
    bb.seek(Begin(0))
    String.fromUtf8(readToEnd(bb))
}

// {"status":"ok"}
public class OkResp <: JsonSerializable {
    public init() {}

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("status").writeValue("ok")
        w.endObject()
    }
}

// {"status":"ok","id":N}
public class OkIdResp <: JsonSerializable {
    public let id: Int64

    public init(id: Int64) {
        this.id = id
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("status").writeValue("ok")
        w.writeName("id").writeValue(id)
        w.endObject()
    }
}

// {"error":"...","detail":"..."}：detail 缺省时不输出该字段
public class ErrorResp <: JsonSerializable {
    public let error: String
    public let detail: ?String

    public init(error: String, detail!: ?String = None) {
        this.error = error
        this.detail = detail
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("error").writeValue(error)
        match (detail) {
            case Some(d) => w.writeName("detail").writeValue(d)
            case None => ()
        }
        w.endObject()
    }
}
