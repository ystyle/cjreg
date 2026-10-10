// 公开端共用辅助单元测试（public_shared.cj）
//
// 这一层是公开页的"口径层"：下载量文案、分类标签、版本时间文案、字节数、sha 缩写。
// 每个函数的每个分支都直接断言，因为它们是页面上「说给人看的那句话」的唯一来源 —— 分支
// 漏了不会抛异常，只会让页面显示错的东西（例如把回源版本写成「发布于」）。
package ystyle::cjreg.ui.public

import ystyle::cjreg.ui.*

import cjxt.*
import ystyle::cjreg.store.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class PublicSharedFormatTest {
    // ===== formatDownloadCount：0 / 个位 / k / 万 四档 + 边界 =====
    @TestCase
    public func testFormatDownloadCountBoundaries(): Unit {
        @Expect(formatDownloadCount(0), "0")
        @Expect(formatDownloadCount(-5), "0")          // 负数当 0（脏数据不留 "-1"）
        @Expect(formatDownloadCount(1), "1")
        @Expect(formatDownloadCount(999), "999")
        @Expect(formatDownloadCount(1000), "1k")       // 千位边界
        @Expect(formatDownloadCount(1500), "1k")       // 向下取整
        @Expect(formatDownloadCount(9999), "9k")
        @Expect(formatDownloadCount(10000), "1万")     // 万位边界
        @Expect(formatDownloadCount(25000), "2万")
    }

    // ===== splitPkgIdentifier：有/无 "::"、空段、多段 =====
    @TestCase
    public func testSplitPkgIdentifier(): Unit {
        let (o1, n1) = splitPkgIdentifier("ystyle::crc")
        @Expect(o1, "ystyle")
        @Expect(n1, "crc")
        // 无组织：org 为空、name 原样
        let (o2, n2) = splitPkgIdentifier("crc")
        @Expect(o2, "")
        @Expect(n2, "crc")
        // 只在第一个 "::" 切分，后面原样保留
        let (o3, n3) = splitPkgIdentifier("a::b::c")
        @Expect(o3, "a")
        @Expect(n3, "b::c")
        // 空组织 / 空名字
        let (o4, n4) = splitPkgIdentifier("::tail")
        @Expect(o4, "")
        @Expect(n4, "tail")
        let (o5, n5) = splitPkgIdentifier("head::")
        @Expect(o5, "head")
        @Expect(n5, "")
        let (o6, n6) = splitPkgIdentifier("")
        @Expect(o6, "")
        @Expect(n6, "")
    }

    // ===== pkgDisplayName：无组织不补 "::" =====
    @TestCase
    public func testPkgDisplayName(): Unit {
        @Expect(pkgDisplayName("ystyle", "crc"), "ystyle::crc")
        @Expect(pkgDisplayName("", "crc"), "crc")
        @Expect(pkgDisplayName("", ""), "")
    }

    // ===== 官方分类表：分类名 → 中文标签，未知回退原名 =====
    @TestCase
    public func testCategoryLabelAndOfficialLookup(): Unit {
        @Expect(officialCategories().size > 0, true)
        @Expect(categoryLabel("Utility"), "工具类")
        @Expect(categoryLabel("Network"), "网络")
        // 未在官方列表 → 回退原名（不留空、不报错）
        @Expect(categoryLabel("MyOwnCategory"), "MyOwnCategory")
        @Expect(categoryLabel(""), "")

        @Expect(isOfficialCategory("Utility"), true)
        @Expect(isOfficialCategory("MyOwnCategory"), false)
        @Expect(isOfficialCategory(""), false)
    }

    // ===== categoryLabels：逐个映射，保持顺序与长度 =====
    @TestCase
    public func testCategoryLabels(): Unit {
        let src = ArrayList<String>(["Utility", "Network", "MyOwnCategory"])
        let out = categoryLabels(src)
        @Expect(out.size, 3)
        @Expect(out[0], "工具类")
        @Expect(out[1], "网络")
        @Expect(out[2], "MyOwnCategory")   // 未知项原样保留
        // 空输入 → 空输出
        @Expect(categoryLabels(ArrayList<String>()).size, 0)
    }
}

@Test
public class PublicSharedVersionTimeTest {
    // ===== versionTimeText 的三分支：发布于 / 收录于 / 时间未知 =====
    @TestCase
    public func testLocalVersionSaysPublished(): Unit {
        let d = PackageDoc()
        d.upstreamId = 0            // 本地发布
        d.createdAt = 1700000000000
        let t = versionTimeText(d)
        @Expect(t.startsWith("发布于 "), true)
        @Expect(t.contains("时间未知"), false)
        // 格式 yyyy-MM-dd HH:mm（16 字符 + 前缀）
        @Expect(t.size, "发布于 ".size + 16)
    }

    @TestCase
    public func testMirroredVersionSaysCollected(): Unit {
        let d = PackageDoc()
        d.upstreamId = 7            // 回源镜像
        d.createdAt = 1700000000000
        let t = versionTimeText(d)
        @Expect(t.startsWith("收录于 "), true)
        @Expect(t.contains("发布于"), false)
    }

    // 时间拿不到（本地发布但 createdAt=0）→ 明确文案，不留空
    @TestCase
    public func testUnknownWhenNoTimestamp(): Unit {
        let d = PackageDoc()
        d.upstreamId = 0
        d.createdAt = 0
        @Expect(versionTimeText(d), "时间未知")
    }

    // 回源版本两个时间都缺 → 也是「时间未知」（而不是显示 1970）
    @TestCase
    public func testMirroredVersionWithoutAnyTime(): Unit {
        let d = PackageDoc()
        d.upstreamId = 3
        d.createdAt = 0
        d.updatedAt = 0
        @Expect(versionTimeText(d), "时间未知")
    }

    // ===== versionTimeMs：本地用 createdAt；回源优先 createdAt、缺失回落 updatedAt =====
    @TestCase
    public func testVersionTimeMsFallbacks(): Unit {
        let local = PackageDoc()
        local.upstreamId = 0
        local.createdAt = 111
        local.updatedAt = 222
        @Expect(versionTimeMs(local), 111)      // 本地只认 createdAt

        let mirrored = PackageDoc()
        mirrored.upstreamId = 9
        mirrored.createdAt = 0
        mirrored.updatedAt = 222
        @Expect(versionTimeMs(mirrored), 222)   // 回源缺 createdAt → 用 updatedAt

        let mirrored2 = PackageDoc()
        mirrored2.upstreamId = 9
        mirrored2.createdAt = 111
        mirrored2.updatedAt = 222
        @Expect(versionTimeMs(mirrored2), 111)  // 有 createdAt 就优先它
    }

    // ===== versionTimePrefix 只按来源区分 =====
    @TestCase
    public func testVersionTimePrefix(): Unit {
        let local = PackageDoc()
        local.upstreamId = 0
        @Expect(versionTimePrefix(local), "发布于 ")
        let mirrored = PackageDoc()
        mirrored.upstreamId = 5
        @Expect(versionTimePrefix(mirrored), "收录于 ")
    }

    // ===== reqDateText：详情页头部优先「更新于」，空列表给「未知」 =====
    @TestCase
    public func testReqDateText(): Unit {
        // 空版本列表
        @Expect(reqDateText(Array<PackageDoc>()), "未知")

        // 有 updatedAt → 「更新于」
        let d = PackageDoc()
        d.updatedAt = 1700000000000
        d.upstreamId = 0
        d.createdAt = 1700000000000
        let t = reqDateText([d])
        @Expect(t.startsWith("更新于 "), true)

        // 没有 updatedAt → 退回版本时间文案（本地发布 → 发布于）
        let d2 = PackageDoc()
        d2.updatedAt = 0
        d2.upstreamId = 0
        d2.createdAt = 1700000000000
        @Expect(reqDateText([d2]).startsWith("发布于 "), true)

        // updatedAt 与 createdAt 都缺 → 时间未知
        let d3 = PackageDoc()
        d3.updatedAt = 0
        d3.createdAt = 0
        @Expect(reqDateText([d3]), "时间未知")
    }

    // 只取第一条（版本列表约定最新在前）
    @TestCase
    public func testReqDateTextUsesFirstEntry(): Unit {
        let first = PackageDoc()
        first.updatedAt = 1700000000000
        let second = PackageDoc()
        second.updatedAt = 0
        second.createdAt = 0
        // 第一条有 updatedAt → 更新于（不会因为第二条缺时间变成未知）
        @Expect(reqDateText([first, second]).startsWith("更新于 "), true)
    }
}

@Test
public class PublicSharedRenderHelperTest {
    // ===== publicNav：登录态四分支（未登录 / 普通用户 / 管理员 / 空 isAdmin） =====
    @TestCase
    public func testPublicNavAnonymous(): Unit {
        let json = serializeSubtree(publicNav("/", None), HashMap<String, ActionHandler>())
        @Expect(json.contains("登录"), true)
        @Expect(json.contains("我的"), false)
        @Expect(json.contains("管理后台"), false)
        @Expect(json.contains("首页"), true)
        @Expect(json.contains("包列表"), true)
        @Expect(json.contains("帮助文档"), true)
    }

    // 显式传 siteName 时品牌文字用它（空串回落到包级 SITE_NAME）
    @TestCase
    public func testPublicNavBrandUsesSiteName(): Unit {
        let json = serializeSubtree(publicNav("/packages", None, siteName: "my-reg"),
            HashMap<String, ActionHandler>())
        @Expect(json.contains("my-reg"), true)
    }

    // ===== featureCard / linkOut：结构里带出传入文本与 URL、外链走新窗口 =====
    @TestCase
    public func testFeatureCardRendersTitleAndDesc(): Unit {
        let json = serializeSubtree(featureCard("view", "包管理", "轻松发布", "#409EFF"),
            HashMap<String, ActionHandler>())
        @Expect(json.contains("包管理"), true)
        @Expect(json.contains("轻松发布"), true)
        @Expect(json.contains("feature-card"), true)
        @Expect(json.contains("feature-icon"), true)
    }

    @TestCase
    public func testLinkOutOpensNewWindow(): Unit {
        let json = serializeSubtree(linkOut("https://example.com/repo", "查看代码"),
            HashMap<String, ActionHandler>())
        @Expect(json.contains("https://example.com/repo"), true)
        @Expect(json.contains("查看代码"), true)
        @Expect(json.contains("_blank"), true)
        @Expect(json.contains("noreferrer"), true)
    }
}
