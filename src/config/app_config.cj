// cjreg 服务端配置（单一来源：配置文件）
//
// 配置只从一个地方来，避免「文件 + 环境变量」两套口径：
//   路径：-c/--config <path>（显式指定）或 <dataDir>/cjreg.toml（约定位置）；都不存在则用默认值。
//   字段：见 configTemplate()——`cjreg init` 会在数据目录生成一份带注释的模板。
//
// 例外：CJREG_SEED_DEMO=1 是**开发调试开关**（往空库注入演示包），不属于部署配置，仍走环境变量。
package ystyle::cjreg.config

import tomlcj.*
import std.fs.*
import std.convert.*

// 默认站点名称（未配置 site_name 时的品牌文字与标签标题）
public let DEFAULT_SITE_NAME = "cjreg"

// 站点名称归一：空白回落默认值（避免配置成空串把品牌文字弄没）
public func normalizeSiteName(raw: String): String {
    let v = raw.trimAscii()
    if (v.isEmpty()) {
        return DEFAULT_SITE_NAME
    }
    v
}

// 服务端运行配置
public class CjregConfig {
    // 对外访问地址（含协议/端口）——用户门户与帮助文档里的 registry 示例用它
    // 未配置时由监听端口推导为 http://localhost:<port>
    public var publicUrl: String = ""
    // 监听端口（命令行 -p/--port 优先）
    public var port: UInt16 = 8060
    // 发布权限模式：open（默认，有效 token 即发布）/ team（双路径裁决）
    public var permissionMode: String = "open"
    // 下载/索引是否需要认证 + read 权限（私有仓）
    public var requireAuth: Bool = false
    // HTTP 请求体上限（字节）：stdx 默认仅 2MB，会让大包发布被拒（413/连接重置）
    // 默认 500MiB（对齐官方「单段 ≤ 500MB」规格）；≤0 表示不限制（私有仓可按需调整）
    public var maxRequestBytes: Int64 = 500 * 1024 * 1024
    // 站点名称：浏览器标签标题 + 页面品牌文字（公开端 nav / 后台侧栏 / 登录页）
    // 空 = 用默认 "cjreg"
    public var siteName: String = DEFAULT_SITE_NAME
    // 实际加载到的配置文件路径（空 = 未使用配置文件，全默认值）
    public var configPath: String = ""

    public init() {}
}

// 解析最终配置：配置文件（可缺省）→ 命令行端口覆盖 → 推导 publicUrl
// cliPort: Some 表示命令行显式传了 -p（优先级最高）
public func resolveConfig(configPath: String, cliPort: ?UInt16): CjregConfig {
    let cfg = match (loadConfigFile(configPath)) {
        case Some(c) => c
        case None => CjregConfig()
    }
    match (cliPort) {
        case Some(p) => cfg.port = p
        case None => ()
    }
    if (cfg.publicUrl.isEmpty()) {
        cfg.publicUrl = "http://localhost:${cfg.port}"
    }
    cfg
}

// 读取配置文件（不存在/解析失败返回 None；文件内字段缺省时取默认值）
public func loadConfigFile(path: String): ?CjregConfig {
    if (path.isEmpty() || !exists(path)) {
        return None
    }
    let cfg = CjregConfig()
    cfg.configPath = path
    try {
        let file = File(path, Read)
        let obj = Decoder(file).decode()
        file.close()
        let server = subObject(obj, "server")
        let url = readStr(server, "public_url")
        if (!url.isEmpty()) {
            cfg.publicUrl = trimTrailingUrl(url)
        }
        let mode = readStr(server, "permission_mode")
        if (!mode.isEmpty()) {
            cfg.permissionMode = normalizeMode(mode)
        }
        cfg.requireAuth = readBool(server, "require_auth", false)
        let mrb = readInt(server, "max_request_bytes", cfg.maxRequestBytes)
        cfg.maxRequestBytes = mrb
        let p = readInt(server, "port", 0)
        if (p > 0 && p <= 65535) {
            cfg.port = UInt16(p)
        }
        let site = readStr(server, "site_name")
        if (!site.isEmpty()) {
            cfg.siteName = normalizeSiteName(site)
        }
    } catch (e: Exception) {
        return None  // 解析失败按「未配置」处理（不阻断启动）
    }
    Some(cfg)
}

// 权限模式归一（未知值一律降级为 open，避免拼错就静默变严格）
public func normalizeMode(v: String): String {
    if (v == "team") { "team" } else { "open" }
}

// 对外地址去掉尾部斜杠（拼接 /registry 之类时避免出现 //）
public func trimTrailingUrl(v: String): String {
    var s = v.trimAscii()
    while (s.size > 0 && s[s.size - 1] == 47u8) {  // 47u8 = '/'
        s = s[0..s.size - 1]
    }
    s
}

// 配置文件模板（`cjreg init` 写入数据目录；仓库根 cjreg.toml.example 同内容）
public func configTemplate(port: UInt16): String {
    "# cjreg 服务端配置。\n"
    + "# 位置：-c/--config 指定的路径，或数据目录下的 cjreg.toml；不存在时全部走默认值。\n"
    + "\n"
    + "[server]\n"
    + "# 站点名称：浏览器标签标题 + 页面品牌文字（公开端导航 / 后台侧栏 / 登录页）\n"
    + "site_name = \"${DEFAULT_SITE_NAME}\"\n"
    + "\n"
    + "# 对外访问地址（含协议与端口）——用户门户与帮助文档里的 registry 示例用它\n"
    + "public_url = \"http://localhost:${port}\"\n"
    + "\n"
    + "# 监听端口（命令行 -p/--port 优先）\n"
    + "port = ${port}\n"
    + "\n"
    + "# 发布权限模式：open = 有效 token 即可发布（默认）；team = 双路径裁决（owner/团队 + read/write/overwrite）\n"
    + "permission_mode = \"open\"\n"
    + "\n"
    + "# 下载/索引是否需要有效 token + read 权限（私有仓建议 true）\n"
    + "require_auth = false\n"
    + "\n"
    + "# HTTP 请求体上限（字节）。stdx 默认仅 2MB，会让大包发布被拒（413/连接重置）；\n"
    + "# 默认 500MiB 对齐官方「单段 ≤ 500MB」规格；-1 = 不限制（按需调整）\n"
    + "# 注意：该上限还受仓颉 GC 堆限制（默认 256MB）——发布 30MB 以上的包前请设置环境变量\n"
    + "#   export cjHeapSize=2GB cjGCThreshold=1GB cjGCInterval=100ms\n"
    + "max_request_bytes = 524288000\n"
}

// ===== TOML 读取辅助（对齐 cjdep 的容错风格：类型不符取默认值）=====

func subObject(obj: TomlObject, key: String): TomlObject {
    match (obj.get(key)) {
        case Some(tv) =>
            try {
                return tv.asObject()
            } catch (e: Exception) {
                TomlObject()
            }
        case None => TomlObject()
    }
}

func readStr(obj: TomlObject, key: String): String {
    match (obj.get(key)) {
        case Some(tv) =>
            try {
                tv.asString().value
            } catch (e: Exception) {
                ""
            }
        case None => ""
    }
}

func readBool(obj: TomlObject, key: String, fallback: Bool): Bool {
    match (obj.get(key)) {
        case Some(tv) =>
            try {
                tv.asBool().value
            } catch (e: Exception) {
                fallback
            }
        case None => fallback
    }
}

func readInt(obj: TomlObject, key: String, fallback: Int64): Int64 {
    match (obj.get(key)) {
        case Some(tv) =>
            try {
                tv.asInt().value
            } catch (e: Exception) {
                fallback
            }
        case None => fallback
    }
}
