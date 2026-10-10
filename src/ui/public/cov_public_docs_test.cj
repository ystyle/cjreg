// 公开端帮助文档页单元测试（public_docs.cj + docs_site.cj）
//
// 文档页的契约是「文档里写的地址必须是服务实际配置的地址」：章节里的 registry 示例、
// 门户链接、cjreg.toml 片段全部取自 CjregConfig（public_url / port / permission_mode /
// require_auth），一旦回退到硬编码就会变成「文档说 A、服务在 B」。
// 本文件既断言 config → 正文的注入，也断言章节导航/非法 id 的回退。
package ystyle::cjreg.ui.public

import ystyle::cjreg.ui.*

import cjxt.*
import ystyle::cjreg.config.*
import std.collection.*
import std.reflect.*
import std.unittest.*
import std.unittest.testmacro.*

// ===== 夹具 =====

func mountDocs(state: CjregState, loggedIn!: Bool = false): DocsPage {
    let page = DocsPage()
    let ctxMap = if (loggedIn) { userCtxMap(1, "admin", true) } else { HashMap<String, String>() }
    page.onMount(mountCtx(state, ctxMap))
    page
}

func renderDocs(page: DocsPage): String {
    serializeSubtree(page.render(), HashMap<String, ActionHandler>())
}

func docsState(publicUrl!: String = "http://localhost:8060", port!: UInt16 = 8060,
               mode!: String = "open", requireAuth!: Bool = false): CjregState {
    let state = makePortalState(mode, publicUrl: publicUrl, port: port)
    state.config.requireAuth = requireAuth
    state
}

@Test
public class DocsSiteContentTest {
    // 章节列表：6 个章节，id 与标题一一对应
    @TestCase
    public func testSectionsListed(): Unit {
        let s = docsSections()
        @Expect(s.size, 6)
        let (firstId, firstTitle) = s[0]
        @Expect(firstId, "quickstart")
        @Expect(firstTitle, "快速开始")
        @Expect(docsDefaultId(), "quickstart")
    }

    // id 校验：合法 id 通过，非法/空串不通过
    @TestCase
    public func testDocsIdValid(): Unit {
        @Expect(docsIdValid("quickstart"), true)
        @Expect(docsIdValid("client-config"), true)
        @Expect(docsIdValid("publish"), true)
        @Expect(docsIdValid("multi-repo"), true)
        @Expect(docsIdValid("publish-plan"), true)
        @Expect(docsIdValid("permission"), true)
        @Expect(docsIdValid("nope"), false)
        @Expect(docsIdValid(""), false)
    }

    // docContent：每个合法 id 都有非空正文，且互不相同
    @TestCase
    public func testDocContentForEverySection(): Unit {
        let cfg = CjregConfig()
        let seen = ArrayList<String>()
        for ((sid, _) in docsSections()) {
            let body = docContent(sid, cfg)
            @Expect(body.size > 0, true)
            @Expect(body.startsWith("# "), true)          // markdown 一级标题
            @Expect(seen.contains(body), false)           // 章节内容不重复
            seen.add(body)
        }
        @Expect(seen.size, 6)
    }

    // 非法 id 回退到 quickstart（不返回空串、也不抛异常）
    @TestCase
    public func testUnknownIdFallsBackToQuickstart(): Unit {
        let cfg = CjregConfig()
        @Expect(docContent("nope", cfg), docContent("quickstart", cfg))
        @Expect(docContent("", cfg), docContent("quickstart", cfg))
    }

    // quickstart 正文注入配置：public_url / port / 权限模式 / require_auth
    @TestCase
    public func testQuickstartInjectsConfig(): Unit {
        let cfg = CjregConfig()
        cfg.publicUrl = "https://pkg.example.com"
        cfg.port = 8064
        cfg.permissionMode = "team"
        cfg.requireAuth = true
        let body = docContent("quickstart", cfg)
        @Expect(body.contains("https://pkg.example.com"), true)
        @Expect(body.contains("8064"), true)
        @Expect(body.contains("\"team\""), true)
        @Expect(body.contains("require_auth = true"), true)
        @Expect(body.contains("http://localhost:8060"), false)   // 不回退默认
    }

    // open 模式：mode 文案写 open、require_auth 写 false
    @TestCase
    public func testQuickstartOpenModeDefaults(): Unit {
        let cfg = CjregConfig()     // 默认 open / 8060 / require_auth=false
        let body = docContent("quickstart", cfg)
        @Expect(body.contains("\"open\""), true)
        @Expect(body.contains("require_auth = false"), true)
        @Expect(body.contains("cjreg init -d ./data"), true)
    }

    // 客户端配置章节：registry 示例用配置的对外地址
    @TestCase
    public func testClientConfigUsesPublicUrl(): Unit {
        let cfg = CjregConfig()
        cfg.publicUrl = "https://mirror.internal:9000"
        let body = docContent("client-config", cfg)
        @Expect(body.contains("https://mirror.internal:9000"), true)
        @Expect(body.contains("cangjie-repo.toml"), true)
        @Expect(body.contains("[repository.home]"), true)
        @Expect(body.contains("cjpm.toml"), true)
    }

    // 访问控制章节：门户链接用配置地址
    @TestCase
    public func testPermissionDocUsesPublicUrl(): Unit {
        let cfg = CjregConfig()
        cfg.publicUrl = "https://reg.corp"
        let body = docContent("permission", cfg)
        @Expect(body.contains("https://reg.corp/me"), true)
        @Expect(body.contains("open 模式"), true)
        @Expect(body.contains("team 模式"), true)
        @Expect(body.contains("权限矩阵"), true)
    }

    // 不依赖配置的章节也有实质内容（发布要求 / 多仓 / 发布计划）
    @TestCase
    public func testStaticSectionsHaveContent(): Unit {
        let cfg = CjregConfig()
        let publish = docContent("publish", cfg)
        @Expect(publish.contains("README_zh.md"), true)
        @Expect(publish.contains("发布要求"), true)

        let multi = docContent("multi-repo", cfg)
        @Expect(multi.contains("上游管理"), true)
        @Expect(multi.contains("回源"), true)

        let plan = docContent("publish-plan", cfg)
        @Expect(plan.contains("发布计划"), true)
        @Expect(plan.contains("拓扑"), true)
    }
}

@Test
public class DocsPageRenderTest {
    // 未挂载（state=None）→ 空 div（不崩、也不渲染半截页面）
    @TestCase
    public func testRenderWithoutMount(): Unit {
        let page = DocsPage()
        let json = renderDocs(page)
        @Expect(json.contains("帮助文档"), false)
        @Expect(json.size > 0, true)
    }

    // 默认渲染 quickstart：导航 6 项、正文有「快速开始」的内容
    @TestCase
    public func testDefaultRenderShowsQuickstart(): Unit {
        let state = docsState()
        let json = renderDocs(mountDocs(state))
        @Expect(json.contains("帮助文档"), true)
        @Expect(json.contains("快速开始"), true)
        @Expect(json.contains("客户端配置"), true)
        @Expect(json.contains("发布包"), true)
        @Expect(json.contains("多仓与代理"), true)
        @Expect(json.contains("发布计划"), true)
        @Expect(json.contains("访问控制"), true)
        @Expect(json.contains("docs-nav"), true)
        @Expect(json.contains("docs-content"), true)
    }

    // 切换章节：activeDoc 信号一变，正文跟着变（不需要动作）
    @TestCase
    public func testActiveDocSignalSwitchesContent(): Unit {
        let state = docsState(publicUrl: "https://pkg.example.com")
        let page = mountDocs(state)

        page.activeDoc.set("permission")
        let perm = renderDocs(page)
        @Expect(perm.contains("权限矩阵"), true)
        @Expect(perm.contains("https://pkg.example.com/me"), true)

        page.activeDoc.set("client-config")
        let cfgDoc = renderDocs(page)
        @Expect(cfgDoc.contains("[repository.home]"), true)
        @Expect(cfgDoc.contains("权限矩阵"), false)
    }

    // 非法章节 id：正文回退 quickstart，但导航仍完整（不白屏）
    @TestCase
    public func testInvalidActiveDocFallsBack(): Unit {
        let state = docsState()
        let page = mountDocs(state)
        page.activeDoc.set("not-a-section")
        let json = renderDocs(page)
        @Expect(json.contains("快速开始"), true)
        @Expect(json.contains("发现和使用仓颉语言包") == false, true)  // 首页内容不该串进来
    }

    // 文档地址随服务配置走（同一份代码、不同配置 → 不同正文）
    @TestCase
    public func testContentFollowsServiceConfig(): Unit {
        let a = renderDocs(mountDocs(docsState(publicUrl: "https://a.example.com", port: 8071)))
        let b = renderDocs(mountDocs(docsState(publicUrl: "https://b.example.com", port: 8072)))
        @Expect(a.contains("https://a.example.com"), true)
        @Expect(a.contains("8071"), true)
        @Expect(a.contains("https://b.example.com"), false)
        @Expect(b.contains("https://b.example.com"), true)
    }

    // 文档正文用的是 Markdown 组件（不是纯文本）
    @TestCase
    public func testContentRenderedByMarkdownComponent(): Unit {
        let state = docsState()
        let json = renderDocs(mountDocs(state))
        @Expect(json.contains("markdown"), true)
        @Expect(json.contains("h1"), true)
    }

    // 导航跟随登录态
    @TestCase
    public func testNavFollowsLogin(): Unit {
        let state = docsState()
        @Expect(renderDocs(mountDocs(state)).contains("登录"), true)
        @Expect(renderDocs(mountDocs(state, loggedIn: true)).contains("管理后台"), true)
    }
}
