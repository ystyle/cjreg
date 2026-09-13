// 站点名称（site_name）配置 + 品牌文字 单元测试
//
// 背景：cjxt 的 AppConfig 支持 title，但 cjreg 没接 → 浏览器标签一直显示默认的「cjxt App」，
// 品牌文字（公开端导航 / 后台侧栏 / 登录页）也是硬编码的「cjreg」。
// 现在统一由 [server] site_name 驱动（默认 cjreg）。
package ystyle::cjreg.ui

import ystyle::cjreg.config.*
import cjxt.*
import cjxt.macros.*
import std.collection.*
import std.unittest.testmacro.*

// 1. 站名归一小函数：空白回落默认值
@Test
func testNormalizeSiteName() {
    @Expect(DEFAULT_SITE_NAME, "cjreg")
    @Expect(normalizeSiteName(""), "cjreg")
    @Expect(normalizeSiteName("   "), "cjreg")
    @Expect(normalizeSiteName("  ystyle 仓 "), "ystyle 仓")
}

// 2. 侧栏品牌文字用站点名（显式传参：不依赖全局状态，测试可重复）
@Test
func testAdminSidebarUsesSiteName() {
    let json = serializeSubtree(adminSidebar("/admin", siteName: "ystyle-reg"),
        HashMap<String, ActionHandler>())
    @Expect(json.contains("ystyle-reg 管理"), true)
    @Expect(json.contains("cjreg 管理"), false)
}

// 3. 未显式传参时回落到包级注入值；注入空串回落默认
@Test
func testAdminSidebarFallsBackToInjectedName() {
    setSiteName("injected-name")
    let json = serializeSubtree(adminSidebar("/admin"), HashMap<String, ActionHandler>())
    @Expect(json.contains("injected-name 管理"), true)
    setSiteName("")   // 空白 → 默认
    let json2 = serializeSubtree(adminSidebar("/admin"), HashMap<String, ActionHandler>())
    @Expect(json2.contains("${DEFAULT_SITE_NAME} 管理"), true)
}

// 4. 公开端导航品牌同样跟站点名走
@Test
func testPublicNavUsesSiteName() {
    let json = serializeSubtree(publicNav("/packages", None, siteName: "my-registry"),
        HashMap<String, ActionHandler>())
    @Expect(json.contains("my-registry"), true)
}
