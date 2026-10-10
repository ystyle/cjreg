// 公开端包详情页渲染单元测试（public_detail.cj）
//
// 详情页有两处只靠"看页面"根本发现不了的契约，这里都守住：
//   ① 版本列表必须**按 semver 降序**（且最新版本是被选中展示的那个）——旧实现把版本集合
//      按数据库遍历顺序摊开，出现 1.0.10 排在 1.0.9 下面；
//   ② 路由参数 `/packages/[name]` 支持两种写法：`org::name` 与裸 `name`；裸名时不按组织过滤
//      （否则同名的另一组织包会被整页藏掉）。
// 依赖 tab 的三类依赖（源码/测试/构建脚本）分别来自索引 NDJSON，空时给各自的中文空态。
package ystyle::cjreg.ui.public

import ystyle::cjreg.ui.*

import cjxt.*
import ystyle::cjreg.store.*
import ystyle::cjreg.index.*
import std.collection.*
import std.reflect.*
import std.unittest.*
import std.unittest.testmacro.*

// ===== 夹具 =====

// 详情页挂载上下文：带路由参数 name（onMount 从 route.params 取）
func mountDetail(state: CjregState, name: String, loggedIn!: Bool = false): PublicPackageDetail {
    let page = PublicPackageDetail()
    let states = HashMap<String, AppState>()
    states.add(TypeInfo.of<CjregState>().qualifiedName, state)
    let params = HashMap<String, String>()
    params.add("name", name)
    let sctx: SessionContext = SessionContextState(if (loggedIn) { userCtxMap(1, "admin", true) } else { HashMap<String, String>() })
    page.onMount(LifecycleContext("sid-detail", params, Option<String>.None, Option<String>.None,
        states: states, sessionContext: Some(sctx)))
    page
}

func renderDetail(page: PublicPackageDetail): String {
    serializeSubtree(page.render(), HashMap<String, ActionHandler>())
}

func seedDetailPkg(state: CjregState, org: String, name: String, version: String,
                   readme!: String = "", desc!: String = "", cjc!: String = "",
                   artifact!: String = "src", executable!: Bool = false,
                   categories!: Array<String> = Array<String>(),
                   tags!: Array<String> = Array<String>(),
                   licenses!: Array<String> = Array<String>(),
                   authors!: Array<String> = Array<String>(),
                   repo!: String = "", homepage!: String = "", documentation!: String = "",
                   size!: Int64 = 0, sha!: String = "", downloads!: Int64 = 0,
                   upstream!: Int64 = 0, createdAt!: Int64 = 1000, updatedAt!: Int64 = 2000,
                   indexJson!: String = ""): PackageDoc {
    let d = PackageDoc()
    d.organization = org
    d.name = name
    d.version = version
    d.readme = readme
    d.description = desc
    d.cjcVersion = cjc
    d.artifactType = artifact
    d.executable = executable
    d.repository = repo
    d.homepage = homepage
    d.documentation = documentation
    d.tarballSize = size
    d.sha256 = sha
    d.downloadCount = downloads
    d.upstreamId = upstream
    d.createdAt = createdAt
    d.updatedAt = updatedAt
    d.indexJson = indexJson
    d.category = ArrayList<String>(categories)
    d.tag = ArrayList<String>(tags)
    d.license = ArrayList<String>(licenses)
    d.authors = ArrayList<String>(authors)
    state.pkgStore.save(d)
    d
}

// 造一条索引 NDJSON：指定三类依赖
func indexJsonWithDeps(deps!: Array<(String, String, String, String, String)> = Array<(String, String, String, String, String)>(),
                       testDeps!: Array<(String, String, String, String, String)> = Array<(String, String, String, String, String)>(),
                       scriptDeps!: Array<(String, String, String, String, String)> = Array<(String, String, String, String, String)>()): String {
    let idx = PackageIndex()
    idx.organization = "ystyle"
    idx.name = "demo"
    idx.version = "1.0.0"
    idx.cjcVersion = "1.1.0"
    idx.sha256sum = "abc"
    for ((n, r, t, m, o) in deps) {
        idx.dependencies.add(DependencyEntry(n, r, t, m, o))
    }
    for ((n, r, t, m, o) in testDeps) {
        idx.testDependencies.add(DependencyEntry(n, r, t, m, o))
    }
    for ((n, r, t, m, o) in scriptDeps) {
        idx.scriptDependencies.add(DependencyEntry(n, r, t, m, o))
    }
    generateNDJSON(ArrayList<PackageIndex>([idx]))
}

func detailActionCtx(state: CjregState): (ActionContext, ArrayList<String>) {
    let nav = ArrayList<String>()
    let router = Router("sid-detail", { p => nav.add(p) })
    let states = HashMap<String, AppState>()
    states.add(TypeInfo.of<CjregState>().qualifiedName, state)
    (ActionContext("sid-detail", HashMap<String, String>(), HashMap<String, String>(), router, sessionStates: states), nav)
}

@Test
public class PublicDetailVersionOrderTest {
    // 版本历史必须 semver 降序；1.0.10 要排在 1.0.9 之上（字符串序会反）
    @TestCase
    public func testVersionsSortedDescendingSemver(): Unit {
        let state = makePortalState("team")
        seedDetailPkg(state, "ystyle", "crc", "1.0.9")
        seedDetailPkg(state, "ystyle", "crc", "1.0.10")
        seedDetailPkg(state, "ystyle", "crc", "1.0.2")

        let page = mountDetail(state, "ystyle::crc")
        let rows = page.versionRows.get()
        @Expect(rows.size, 3)
        @Expect(rows[0].version, "1.0.10")   // 最新在前
        @Expect(rows[1].version, "1.0.9")
        @Expect(rows[2].version, "1.0.2")

        // latest() 取第一条（页面标题、tag、安装片段都用它）
        @Expect(page.latest().getOrThrow().version, "1.0.10")
    }

    // 软删版本不出现在版本历史里
    @TestCase
    public func testDeletedVersionsExcluded(): Unit {
        let state = makePortalState("team")
        seedDetailPkg(state, "ystyle", "crc", "1.0.0")
        let gone = seedDetailPkg(state, "ystyle", "crc", "9.9.9")
        gone.deletedAt = 1
        state.pkgStore.save(gone)

        let page = mountDetail(state, "ystyle::crc")
        @Expect(page.versionRows.get().size, 1)
        @Expect(page.versionRows.get()[0].version, "1.0.0")
        @Expect(renderDetail(page).contains("9.9.9"), false)
    }

    // 同名不同组织：带 org 时只留该 org，裸名时两个 org 的都算（不被组织过滤掉）
    @TestCase
    public func testOrgScopingAndBareName(): Unit {
        let state = makePortalState("team")
        seedDetailPkg(state, "ystyle", "dup", "1.0.0", desc: "ystyle 的 dup")
        seedDetailPkg(state, "acme", "dup", "2.0.0", desc: "acme 的 dup")

        let scoped = mountDetail(state, "ystyle::dup")
        @Expect(scoped.versionRows.get().size, 1)
        @Expect(scoped.versionRows.get()[0].organization, "ystyle")
        @Expect(renderDetail(scoped).contains("2.0.0"), false)

        let bare = mountDetail(state, "dup")
        @Expect(bare.pkgOrg, "")                  // 裸名：org 为空
        @Expect(bare.versionRows.get().size, 2)   // 两个组织的同名包都在
        @Expect(bare.latest().getOrThrow().version, "2.0.0")
    }

    // 包不存在 → 「未找到该包」空态（仍带导航）
    @TestCase
    public func testUnknownPackageShowsNotFound(): Unit {
        let state = makePortalState("team")
        let page = mountDetail(state, "nope::missing")
        let json = renderDetail(page)
        @Expect(json.contains("未找到该包"), true)
        @Expect(json.contains("包信息"), false)      // 没有侧栏
        @Expect(json.contains("首页"), true)          // 导航还在
    }

    // 无路由参数（params 里没有 name）：不加载、按未找到处理，不抛异常
    @TestCase
    public func testMissingRouteParamDoesNotThrow(): Unit {
        let state = makePortalState("team")
        seedDetailPkg(state, "ystyle", "crc", "1.0.0")
        let page = PublicPackageDetail()
        page.onMount(mountCtx(state, HashMap<String, String>()))   // mountCtx 的 params 为空
        @Expect(page.pkgName, "")
        @Expect(page.versionRows.get().size, 0)
        @Expect(renderDetail(page).contains("未找到该包"), true)
    }
}

@Test
public class PublicDetailRenderTest {
    // 头部：包名、最新版本 Tag、描述；空描述给「暂无描述」
    @TestCase
    public func testHeaderShowsNameVersionAndDescription(): Unit {
        let state = makePortalState("team")
        seedDetailPkg(state, "ystyle", "crc", "1.0.0", desc: "CRC 校验库")
        let json = renderDetail(mountDetail(state, "ystyle::crc"))
        @Expect(json.contains("ystyle::crc"), true)
        @Expect(json.contains("1.0.0"), true)
        @Expect(json.contains("CRC 校验库"), true)
        @Expect(json.contains("详情"), false)      // 结构上有「返回」按钮

        // 空描述
        let state2 = makePortalState("team")
        seedDetailPkg(state2, "ystyle", "nodesc", "1.0.0")
        @Expect(renderDetail(mountDetail(state2, "ystyle::nodesc")).contains("暂无描述"), true)
    }

    // 侧栏「包信息」：组织（空 → 默认）、SDK 版本（空则不渲染）、类型、可执行、协议、分类、标签、作者、外链、大小
    @TestCase
    public func testSidebarInfoItems(): Unit {
        let state = makePortalState("team")
        seedDetailPkg(state, "ystyle", "full", "2.3.4",
            cjc: "1.1.0", artifact: "src", executable: true,
            categories: ["Utility", "Network"], tags: ["cangjie", "crc"],
            licenses: ["MIT", "Apache-2.0"], authors: ["alice", "bob"],
            repo: "https://atomgit.com/ystyle/full", homepage: "https://ystyle.top/full",
            documentation: "https://ystyle.top/full/docs", size: 40299, downloads: 1500)
        let json = renderDetail(mountDetail(state, "ystyle::full"))
        @Expect(json.contains("SDK 版本"), true)
        @Expect(json.contains("1.1.0"), true)
        @Expect(json.contains("源码"), true)
        @Expect(json.contains("可执行"), true)
        @Expect(json.contains("MIT"), true)
        @Expect(json.contains("Apache-2.0"), true)
        @Expect(json.contains("工具类"), true)     // 分类中文标签
        @Expect(json.contains("网络"), true)
        @Expect(json.contains("cangjie"), true)
        @Expect(json.contains("alice, bob"), true) // 作者用 ", " 连接
        @Expect(json.contains("https://atomgit.com/ystyle/full"), true)
        @Expect(json.contains("https://ystyle.top/full"), true)
        @Expect(json.contains("https://ystyle.top/full/docs"), true)
        @Expect(json.contains("39 KB"), true)      // 包大小文案
        @Expect(json.contains("1k"), true)         // 下载次数文案（1500 → 1k）
    }

    // 侧栏可选项缺失时不渲染对应行（不是渲染空值）
    @TestCase
    public func testSidebarOmitsEmptyOptionalItems(): Unit {
        let state = makePortalState("team")
        // 组织也为空：这样「组织」一栏才走「默认」回退分支
        seedDetailPkg(state, "", "bare", "1.0.0")   // 除了名字版本全空
        let json = renderDetail(mountDetail(state, "bare"))
        @Expect(json.contains("SDK 版本"), false)
        @Expect(json.contains("协议"), false)
        @Expect(json.contains("标签"), false)
        @Expect(json.contains("作者"), false)
        @Expect(json.contains("仓库"), false)
        @Expect(json.contains("主页"), false)
        @Expect(json.contains("包大小"), false)      // size=0
        // 但「组织」「类型」「下载次数」是固定项
        @Expect(json.contains("组织"), true)
        @Expect(json.contains("默认"), true)         // 空组织显示「默认」
        @Expect(json.contains("类型"), true)
        @Expect(json.contains("下载次数"), true)
        @Expect(json.contains("0"), true)
    }

    // 二进制制品：类型 Tag 走「二进制」
    @TestCase
    public func testBinaryArtifactLabel(): Unit {
        let state = makePortalState("team")
        seedDetailPkg(state, "ystyle", "bin", "1.0.0", artifact: "bin", cjc: "1.1.0", executable: true)
        let json = renderDetail(mountDetail(state, "ystyle::bin"))
        @Expect(json.contains("二进制"), true)
    }

    // 头部 meta：优先「更新于」；分类/标签非空时也进 header meta
    @TestCase
    public func testHeaderMetaUsesUpdateTimeAndShowsCategory(): Unit {
        let state = makePortalState("team")
        seedDetailPkg(state, "ystyle", "meta", "1.0.0", updatedAt: 1700000000000,
            categories: ["Utility"], tags: ["mytag"])
        let json = renderDetail(mountDetail(state, "ystyle::meta"))
        @Expect(json.contains("更新于 "), true)
        @Expect(json.contains("时间"), true)
        @Expect(json.contains("分类"), true)
        @Expect(json.contains("标签"), true)
        @Expect(json.contains("mytag"), true)
    }

    // 头部时间：没有 updatedAt 时退回版本时间文案；本地发布 → 「发布于」，回源 → 「收录于」
    @TestCase
    public func testHeaderMetaFallsBackToVersionTime(): Unit {
        let state = makePortalState("team")
        seedDetailPkg(state, "ystyle", "local", "1.0.0", updatedAt: 0, createdAt: 1700000000000, upstream: 0)
        seedDetailPkg(state, "ystyle", "mirror", "1.0.0", updatedAt: 0, createdAt: 1700000000000, upstream: 7)
        @Expect(renderDetail(mountDetail(state, "ystyle::local")).contains("发布于 "), true)
        @Expect(renderDetail(mountDetail(state, "ystyle::mirror")).contains("收录于 "), true)
    }

    // 版本历史行：最新 Tag、时间文案、大小、sha 缩写 + 悬停完整值
    @TestCase
    public func testVersionHistoryRowDetails(): Unit {
        let state = makePortalState("team")
        let full = "e0b33e71376cf0e1868b62cff6a7940025af5d261f299132b175b6bad9ee8ff6"
        seedDetailPkg(state, "ystyle", "crc", "1.0.0", sha: full, size: 40299, upstream: 0)
        seedDetailPkg(state, "ystyle", "crc", "1.0.1", upstream: 0)
        // 版本历史在独立的 TabPane 里：cjxt Tabs 只渲染激活 pane，不切就看不到
        let page = mountDetail(state, "ystyle::crc")
        page.activeTab.set("versions")
        let json = renderDetail(page)
        @Expect(json.contains("最新"), true)
        @Expect(json.contains("发布于 "), true)
        @Expect(json.contains("39 KB"), true)
        @Expect(json.contains("e0b33e71376c"), true)     // 12 位缩写
        @Expect(json.contains(full), true)               // title 悬停完整值
        // 没有 sha/size 的版本行不渲染那两个 span
        @Expect(json.contains("sha256 "), true)
    }

    // 安装片段：有 org → 'org::name'；无 org → name
    @TestCase
    public func testInstallTomlSnippet(): Unit {
        let state = makePortalState("team")
        seedDetailPkg(state, "ystyle", "crc", "1.0.0")
        let p = mountDetail(state, "ystyle::crc")
        @Expect(p.installToml(p.latest().getOrThrow(), "ystyle", "crc"), "'ystyle::crc' = \"1.0.0\"")
        @Expect(p.installToml(p.latest().getOrThrow(), "", "crc"), "crc = \"1.0.0\"")
        let json = renderDetail(p)
        @Expect(json.contains("添加到 cjpm.toml 的 dependencies 部分"), true)
        @Expect(json.contains("使用指南"), true)
    }

    // README 分支：有 README → Markdown 渲染；无 README → 「暂无 README 文档」
    @TestCase
    public func testReadmeRenderingBranches(): Unit {
        let state = makePortalState("team")
        seedDetailPkg(state, "ystyle", "withreadme", "1.0.0",
            readme: "# 标题\n\n这是 **加粗** 与 `code` 内容。\n")
        let withMd = renderDetail(mountDetail(state, "ystyle::withreadme"))
        @Expect(withMd.contains("概览"), true)
        @Expect(withMd.contains("加粗"), true)
        @Expect(withMd.contains("暂无 README 文档"), false)

        let state2 = makePortalState("team")
        seedDetailPkg(state2, "ystyle", "noreadme", "1.0.0")
        let noMd = renderDetail(mountDetail(state2, "ystyle::noreadme"))
        @Expect(noMd.contains("暂无 README 文档"), true)
    }

    // 三个内容 tab 都在（概览 / 依赖 / 版本历史）
    @TestCase
    public func testContentTabsPresent(): Unit {
        let state = makePortalState("team")
        seedDetailPkg(state, "ystyle", "crc", "1.0.0")
        let json = renderDetail(mountDetail(state, "ystyle::crc"))
        @Expect(json.contains("概览"), true)
        @Expect(json.contains("依赖"), true)
        @Expect(json.contains("版本历史"), true)
        @Expect(json.contains("el-tabs"), true)
    }

    // 导航跟随登录态
    @TestCase
    public func testNavFollowsLogin(): Unit {
        let state = makePortalState("team")
        seedDetailPkg(state, "ystyle", "crc", "1.0.0")
        @Expect(renderDetail(mountDetail(state, "ystyle::crc")).contains("登录"), true)
        @Expect(renderDetail(mountDetail(state, "ystyle::crc", loggedIn: true)).contains("管理后台"), true)
    }

    // 「返回」跳到 /packages
    @TestCase
    public func testBackButtonPushesPackages(): Unit {
        let state = makePortalState("team")
        seedDetailPkg(state, "ystyle", "crc", "1.0.0")
        let page = mountDetail(state, "ystyle::crc")
        let (actx, nav) = detailActionCtx(state)
        let _ = page.gotoPackages(actx)
        @Expect(nav.size, 1)
        @Expect(nav[0], "/packages")
    }
}

@Test
public class PublicDetailDependencyTest {
    // 三类依赖分别渲染（源码 / 测试 / 构建脚本），并带目标/模式/产物类型元信息
    @TestCase
    public func testDependencyTabsFromIndexJson(): Unit {
        let state = makePortalState("team")
        seedDetailPkg(state, "ystyle", "demo", "1.0.0", indexJson: indexJsonWithDeps(
            deps: [("net", "1.0.0", "x86_64-unknown-linux-gnu", "release", "static")],
            testDeps: [("unittest-helper", "0.1.0", "", "", "")],
            scriptDeps: [("build-tool", "2.0.0", "", "", "")]))
        let page = mountDetail(state, "ystyle::demo")
        page.activeTab.set("dependencies")
        // 三个子 tab 的标题始终在（标签栏），但内容只渲染激活的那个 —— 逐个切过去看
        let sourceJson = renderDetail(page)
        @Expect(sourceJson.contains("源码依赖"), true)
        @Expect(sourceJson.contains("测试依赖"), true)
        @Expect(sourceJson.contains("构建脚本依赖"), true)
        @Expect(sourceJson.contains("net"), true)
        // depEntry 的 meta 行：目标/模式/类型
        @Expect(sourceJson.contains("目标: x86_64-unknown-linux-gnu"), true)
        @Expect(sourceJson.contains("模式: release"), true)
        @Expect(sourceJson.contains("类型: static"), true)

        // 测试依赖子 tab
        page.depTab.set("test")
        let testJson = renderDetail(page)
        @Expect(testJson.contains("unittest-helper"), true)
        @Expect(testJson.contains("net"), false)     // 源码依赖已随 pane 切走

        // 构建脚本依赖子 tab
        page.depTab.set("script")
        let scriptJson = renderDetail(page)
        @Expect(scriptJson.contains("build-tool"), true)
        @Expect(scriptJson.contains("unittest-helper"), false)
    }

    // 索引里没有依赖 → 三个 tab 各自的空态文案
    @TestCase
    public func testEmptyDependencyPlaceholders(): Unit {
        let state = makePortalState("team")
        seedDetailPkg(state, "ystyle", "demo", "1.0.0", indexJson: indexJsonWithDeps())
        let page = mountDetail(state, "ystyle::demo")
        page.activeTab.set("dependencies")
        @Expect(renderDetail(page).contains("暂无源码依赖"), true)
        // 空态的测试/构建脚本依赖要切到对应子 tab 才在 DOM 里
        page.depTab.set("test")
        @Expect(renderDetail(page).contains("暂无测试依赖"), true)
        page.depTab.set("script")
        @Expect(renderDetail(page).contains("暂无构建脚本依赖"), true)
    }

    // indexJson 为空 → parseIndex 返回 None → 三类依赖都退化为空态（而不是抛异常）
    @TestCase
    public func testMissingIndexJsonFallsBackToEmptyDeps(): Unit {
        let state = makePortalState("team")
        seedDetailPkg(state, "ystyle", "demo", "1.0.0", indexJson: "")
        let page = mountDetail(state, "ystyle::demo")
        let p = page.latest().getOrThrow()
        @Expect(page.parseIndex(p).isNone(), true)
        page.activeTab.set("dependencies")
        let json = renderDetail(page)
        @Expect(json.contains("暂无源码依赖"), true)
    }

    // 依赖只有部分字段 → meta 行只渲染非空的那些，且不崩
    @TestCase
    public func testPartialDependencyMeta(): Unit {
        let state = makePortalState("team")
        seedDetailPkg(state, "ystyle", "demo", "1.0.0", indexJson: indexJsonWithDeps(
            deps: [("only-name", "1.0.0", "", "", "")]))
        let page = mountDetail(state, "ystyle::demo")
        page.activeTab.set("dependencies")
        let json = renderDetail(page)
        @Expect(json.contains("only-name"), true)
        @Expect(json.contains("目标: "), false)   // 空字段不渲染
        @Expect(json.contains("模式: "), false)
        @Expect(json.contains("类型: "), false)
    }

    // 依赖名可点：跳到 /packages/<dep.name>
    @TestCase
    public func testDependencyEntryNavigation(): Unit {
        let state = makePortalState("team")
        let page = mountDetail(state, "ystyle::demo")
        let dep = DependencyEntry("net", "1.0.0", "", "", "")
        let node = page.depEntry(dep)
        @Expect(serializeSubtree(node, HashMap<String, ActionHandler>()).contains("net"), true)
        // 组件级事件在 expandTree 后可见
        let expanded = serializeSubtree(RenderContext.expandTree(node, ""), HashMap<String, ActionHandler>())
        @Expect(expanded.contains("dep-item"), true)
    }
}
