// 帮助文档章节单元测试：地址类示例必须来自配置（cjreg.toml），不能写死
package ystyle::cjreg.ui

import ystyle::cjreg.config.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class DocsSiteTest {
    @TestCase
    public func testClientConfigUsesConfiguredRegistry(): Unit {
        let md = docContent("client-config", cfgOf("https://pkg.example.com", UInt16(8064), "open", false))
        @Expect(md.contains("registry = \"https://pkg.example.com\""), true)
        @Expect(md.contains("localhost:8060"), false)
    }

    @TestCase
    public func testQuickstartUsesConfiguredPortAndUrl(): Unit {
        let md = docContent("quickstart", cfgOf("https://pkg.example.com", UInt16(8123), "team", true))
        @Expect(md.contains("cjreg serve -d ./data -p 8123"), true)
        @Expect(md.contains("https://pkg.example.com/admin"), true)
        @Expect(md.contains("https://pkg.example.com/`"), true)   // 用户门户首页
        @Expect(md.contains("/me"), true)                          // 领取 Token 的入口
        @Expect(md.contains("localhost:8060"), false)
        // 配置片段显示真实配置（不是写死的默认值）
        @Expect(md.contains("permission_mode = \"team\""), true)
        @Expect(md.contains("require_auth = true"), true)
    }

    @TestCase
    public func testPermissionDocPointsToPortalToken(): Unit {
        let md = docContent("permission", cfgOf("https://pkg.example.com", UInt16(8060), "open", false))
        @Expect(md.contains("https://pkg.example.com/me"), true)
        @Expect(md.contains("发布 Token"), true)
    }

    @TestCase
    public func testUnknownDocIdFallsBackToQuickstart(): Unit {
        let md = docContent("nope", cfgOf("http://localhost:8060", UInt16(8060), "open", false))
        @Expect(md.contains("快速开始"), true)
    }
}

func cfgOf(publicUrl: String, port: UInt16, mode: String, requireAuth: Bool): CjregConfig {
    let cfg = CjregConfig()
    cfg.publicUrl = publicUrl
    cfg.port = port
    cfg.permissionMode = mode
    cfg.requireAuth = requireAuth
    cfg
}
