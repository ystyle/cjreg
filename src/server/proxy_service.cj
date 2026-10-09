// 代理回源（多仓核心）：ProxyService 的字段/构造 + 出网 GET 的唯一注入点
// 各域在同包文件里以 extend 展开：proxy_index.cj（索引取用与探测）/ proxy_artifact.cj（制品回源与 Range 分块）；
// 制品存储实现见 proxy_blob.cj，HTTP 传输层见 proxy_http.cj
package ystyle::cjreg.server

import ystyle::cjreg.protocol.*
import ystyle::cjreg.index.*
import ystyle::cjreg.config.*
import ystyle::cjreg.store.*
import stdx.net.http.*
import stdx.crypto.digest.SHA256
import stdx.encoding.hex.toHexString
import stdx.net.tls.*
import stdx.net.tls.common.*
import stdx.encoding.url.URL
import std.collection.*
import std.io.*
import std.fs.*
import std.convert.*

// 回源结果
public enum ProxyOutcome {
    | HitLocal       // 本地命中
    | FetchedFromUpstream  // 上游回源成功
    | NotFound       // 本地与所有上游都未命中
    | UpstreamError  // 上游全部失败

    public operator func ==(other: ProxyOutcome): Bool {
        match (this) {
            case ProxyOutcome.HitLocal => match (other) {
                case ProxyOutcome.HitLocal => true
                case _ => false
            }
            case ProxyOutcome.FetchedFromUpstream => match (other) {
                case ProxyOutcome.FetchedFromUpstream => true
                case _ => false
            }
            case ProxyOutcome.NotFound => match (other) {
                case ProxyOutcome.NotFound => true
                case _ => false
            }
            case ProxyOutcome.UpstreamError => match (other) {
                case ProxyOutcome.UpstreamError => true
                case _ => false
            }
        }
    }
}

// 代理服务：按优先级多上游回源
public class ProxyService {
    public var pkgStore: PackageStore
    public var blobStore: BlobStore
    public var upstreamSvc: UpstreamService
    // 可注入的出网 GET（单测离线注入 stub；默认走真实 httpGet）
    public var httpFetch: ?(String, String) -> ?Array<Byte> = None

    // 流式回源的临时文件目录（必须与 blob 同目录，rename 才能原子进位）。
    // 留空则回源保持"整包读入"的旧行为（内存 blob 模式与不需要流式的测试场景）。
    public var tmpDir: String = ""

    public init(pkgStore: PackageStore, blobStore: BlobStore, upstreamSvc: UpstreamService,
                tmpDir!: String = "") {
        this.pkgStore = pkgStore
        this.blobStore = blobStore
        this.upstreamSvc = upstreamSvc
        this.tmpDir = tmpDir
    }

    // 出网 GET 的唯一出口：测试注入点 + 后续打点都集中在这里
    public func fetchBytes(url: String, token: String): ?Array<Byte> {
        match (this.httpFetch) {
            case Some(f) => f(url, token)
            case None => httpGet(url, token)
        }
    }
}
