// 管理端共用辅助（manage_shared.cj）的分支回归。
//
// 这个文件里的两个格式化函数被所有包相关页面复用，边界口径必须钉住：
//   * fmtSize：0/负数 → 「-」；<1KB → B；<1MB → KB；<1GB → MB；否则 GB；
//   * formatLogTime：<= 0 → 「-」；正数 → MM-dd HH:mm（本地时区）；
//   * versionSource：本地发布 / 回源有名 / 回源无名三档；
//   * timeCell：始终带 nowrap 样式（列宽不足时表格会折行变高，这条守住它）；
//   * SignalView：render 每次都调 build（所以它读到的信号会被登记为依赖）。
package ystyle::cjreg.ui.admin

import ystyle::cjreg.ui.*
import cjxt.*
import ystyle::cjreg.store.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class CovManageSharedTest {
    // fmtSize 五档边界：0 / 负数 / B / KB / MB / GB 与各档的分界值
    @TestCase
    public func covShared_fmtSizeAllBranches(): Unit {
        @Expect(fmtSize(0), "-")
        @Expect(fmtSize(-1), "-")
        @Expect(fmtSize(1), "1 B")
        @Expect(fmtSize(1023), "1023 B")
        @Expect(fmtSize(1024), "1 KB")                 // k 的分界
        @Expect(fmtSize(1024 * 1024 - 1), "1023 KB")
        @Expect(fmtSize(1024 * 1024), "1 MB")          // k*k 的分界
        @Expect(fmtSize(1024 * 1024 * 1024 - 1), "1023 MB")
        @Expect(fmtSize(1024 * 1024 * 1024), "1 GB")   // k*k*k 的分界
        @Expect(fmtSize(5 * 1024 * 1024 * 1024), "5 GB")
    }

    // formatLogTime：0 / 负数 → 「-」，正数是 MM-dd HH:mm 形状
    @TestCase
    public func covShared_formatLogTimeAllBranches(): Unit {
        @Expect(formatLogTime(0), "-")
        @Expect(formatLogTime(-100), "-")
        let s = formatLogTime(1700000000000)
        @Expect(s.size, "MM-dd HH:mm".size)
        @Expect(s.contains("-"), true)
        @Expect(s.contains(":"), true)
    }

    // versionSource 三档：本地发布 / 回源（有名）/ 回源（无名兜底 #id）
    @TestCase
    public func covShared_versionSourceAllBranches(): Unit {
        let local = PackageDoc()
        @Expect(versionSource(local), "本地发布")

        let named = PackageDoc()
        named.upstreamId = 3
        named.upstreamName = "mirror"
        @Expect(versionSource(named), "回源 · mirror")

        let unnamed = PackageDoc()
        unnamed.upstreamId = 7
        @Expect(versionSource(unnamed), "上游 #7")
    }

    // timeCell 渲染：文本原样 + 钉住 nowrap 样式
    @TestCase
    public func covShared_timeCellKeepsNowrap(): Unit {
        let json = serializeSubtree(timeCell("09-16 00:24"), HashMap<String, ActionHandler>())
        @Expect(json.contains("09-16 00:24"), true)
        @Expect(json.contains("white-space:nowrap;"), true)
    }

    // SignalView：render 每次都重跑 build（信号依赖因此被登记 → 信号变页面就脏）
    @TestCase
    public func covShared_signalViewRebuildsOnEachRender(): Unit {
        let count = Box<Int64>(0)
        let view = SignalView({ =>
            count.value++
            text("build-${count.value}")
        })
        let first = covRender(view)
        @Expect(first.contains("build-1"), true)
        let second = covRender(view)
        @Expect(second.contains("build-2"), true)   // 不是缓存的旧树
        @Expect(count.value, 2)
    }

    // SignalView 包住的信号确实是渲染依赖：走一次渲染遍历后改信号 → 组件变脏
    @TestCase
    public func covShared_signalViewTracksSignal(): Unit {
        let s = Signal<String>("a")
        let view = SignalView({ => text(s.get()) })
        let _ = RenderContext.expandTree(view, "")
        RenderContext.clearDirty()
        @Expect(RenderContext.collectDirty().size, 0)
        s.set("b")
        @Expect(RenderContext.collectDirty().size > 0, true)
        RenderContext.clearDirty()
    }
}
