// 服务端配置文件单元测试（解析 / 默认值 / 命令行端口优先 / 模板）
package ystyle::cjreg.config

import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

func writeTempConfig(name: String, content: String): String {
    let dir = "/tmp/cjreg-config-test"
    if (!exists(dir)) {
        Directory.create(dir, recursive: true)  // 已存在时再 create 会抛 FsException
    }
    let path = "${dir}/${name}"
    let f = File(path, Write)
    f.write(content.toArray())
    f.close()
    path
}

@Test
public class AppConfigTest {
    @TestCase
    public func testLoadConfigFileFields(): Unit {
        let path = writeTempConfig("full.toml", """
[server]
public_url = "https://pkg.example.com/"
port = 9000
permission_mode = "team"
require_auth = true
""")
        match (loadConfigFile(path)) {
            case Some(c) =>
                @Expect(c.publicUrl, "https://pkg.example.com")  // 去尾部斜杠
                @Expect(c.port, UInt16(9000))
                @Expect(c.permissionMode, "team")
                @Expect(c.requireAuth, true)
                @Expect(c.configPath, path)
            case None => @Fail("配置文件应能解析")
        }
    }

    @TestCase
    public func testLoadConfigFilePartialUsesDefaults(): Unit {
        // 只配 public_url：其余字段保持默认（open / 8060 / require_auth=false）
        let path = writeTempConfig("partial.toml", """
[server]
public_url = "http://registry.internal"
""")
        match (loadConfigFile(path)) {
            case Some(c) =>
                @Expect(c.publicUrl, "http://registry.internal")
                @Expect(c.port, UInt16(8060))
                @Expect(c.permissionMode, "open")
                @Expect(c.requireAuth, false)
            case None => @Fail("配置文件应能解析")
        }
    }

    @TestCase
    public func testLoadConfigFileMissingOrBroken(): Unit {
        @Expect(loadConfigFile("").isNone(), true)
        @Expect(loadConfigFile("/tmp/cjreg-config-test/not-exists.toml").isNone(), true)
        // 解析失败按「未配置」处理，不阻断启动
        let broken = writeTempConfig("broken.toml", "this is not = = toml\n")
        @Expect(loadConfigFile(broken).isNone(), true)
    }

    @TestCase
    public func testMaxRequestBytesDefaultsAndOverride(): Unit {
        // 默认 500MiB（对齐官方单段 ≤ 500MB；stdx 默认 2MB 会让大包发布 413）
        @Expect(resolveConfig("/tmp/cjreg-config-test/absent.toml", None).maxRequestBytes, 500 * 1024 * 1024)
        let path = writeTempConfig("maxbody.toml", """
[server]
max_request_bytes = -1
""")
        match (loadConfigFile(path)) {
            case Some(c) => @Expect(c.maxRequestBytes, -1)
            case None => @Fail("配置文件应能解析")
        }
    }

    @TestCase
    public func testPermissionModeNormalizedOrFallsBack(): Unit {
        // 未知模式（含大小写不符）一律降级 open，避免拼错就静默变严格
        let path = writeTempConfig("badmode.toml", """
[server]
permission_mode = "TEAM"
""")
        match (loadConfigFile(path)) {
            case Some(c) => @Expect(c.permissionMode, "open")
            case None => @Fail("配置文件应能解析")
        }
        @Expect(normalizeMode("team"), "team")
        @Expect(normalizeMode("open"), "open")
        @Expect(normalizeMode("strict"), "open")
    }

    @TestCase
    public func testCliPortOverridesConfigPort(): Unit {
        let path = writeTempConfig("port.toml", """
[server]
port = 9000
permission_mode = "team"
""")
        // 命令行未给 -p：用配置文件端口，public_url 未配则按该端口推导
        let fromFile = resolveConfig(path, None)
        @Expect(fromFile.port, UInt16(9000))
        @Expect(fromFile.publicUrl, "http://localhost:9000")
        @Expect(fromFile.permissionMode, "team")

        // 命令行给了 -p：端口以命令行为准，推导地址同步
        let fromCli = resolveConfig(path, Some(UInt16(9100)))
        @Expect(fromCli.port, UInt16(9100))
        @Expect(fromCli.publicUrl, "http://localhost:9100")

        // 配置里写了 public_url 则不被推导覆盖
        let withUrl = writeTempConfig("url.toml", """
[server]
public_url = "https://pkg.example.com"
port = 9000
""")
        @Expect(resolveConfig(withUrl, Some(UInt16(9100))).publicUrl, "https://pkg.example.com")
        @Expect(resolveConfig(withUrl, Some(UInt16(9100))).port, UInt16(9100))
    }

    @TestCase
    public func testDefaultsWithoutConfigFile(): Unit {
        let cfg = resolveConfig("/tmp/cjreg-config-test/absent.toml", None)
        @Expect(cfg.configPath, "")
        @Expect(cfg.port, UInt16(8060))
        @Expect(cfg.permissionMode, "open")
        @Expect(cfg.requireAuth, false)
        @Expect(cfg.publicUrl, "http://localhost:8060")
    }

    @TestCase
    public func testTrimTrailingUrl(): Unit {
        @Expect(trimTrailingUrl("http://x/"), "http://x")
        @Expect(trimTrailingUrl("http://x///"), "http://x")
        @Expect(trimTrailingUrl("  http://x  "), "http://x")
        @Expect(trimTrailingUrl(""), "")
        @Expect(trimTrailingUrl("/"), "")
    }

    @TestCase
    public func testConfigTemplateCoversAllFields(): Unit {
        let t = configTemplate(UInt16(8123))
        @Expect(t.contains("[server]"), true)
        @Expect(t.contains("public_url"), true)
        @Expect(t.contains("port = 8123"), true)
        @Expect(t.contains("permission_mode"), true)
        @Expect(t.contains("require_auth"), true)
        @Expect(t.contains("site_name"), true)
        // 模板本身是合法 TOML，且能被解析回同样的默认值
        let path = writeTempConfig("template.toml", t)
        match (loadConfigFile(path)) {
            case Some(c) =>
                @Expect(c.port, UInt16(8123))
                @Expect(c.permissionMode, "open")
                @Expect(c.requireAuth, false)
                @Expect(c.publicUrl, "http://localhost:8123")
                @Expect(c.siteName, DEFAULT_SITE_NAME)
            case None => @Fail("模板应是合法 TOML")
        }
    }

    @TestCase
    public func testSiteNameFromConfigOrDefault(): Unit {
        // 未配置 → 默认 cjreg（浏览器标签别再看 "cjxt App"）
        let plain = writeTempConfig("nositename.toml", "[server]\nport = 8060\n")
        match (loadConfigFile(plain)) {
            case Some(c) => @Expect(c.siteName, "cjreg")
            case None => @Fail("应能解析")
        }
        // 配置了就按配置走（两端空白裁掉）
        let custom = writeTempConfig("sitename.toml", "[server]\nsite_name = \"  ystyle 仓 \"\n")
        match (loadConfigFile(custom)) {
            case Some(c) => @Expect(c.siteName, "ystyle 仓")
            case None => @Fail("应能解析")
        }
        // 配成空白 → 回落默认，不会把品牌文字弄没
        let blank = writeTempConfig("blanksite.toml", "[server]\nsite_name = \"   \"\n")
        match (loadConfigFile(blank)) {
            case Some(c) => @Expect(c.siteName, DEFAULT_SITE_NAME)
            case None => @Fail("应能解析")
        }
    }
}
