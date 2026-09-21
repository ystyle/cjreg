// bindRows / bindPaged 的派生行为：过滤信号或分页信号一变，行与总数立刻重算。
//
// 这条正是「搜索输入即生效」的机制保证：Table 绑的是派生出来的 rows 信号，
// 而不是被动作缓存下来的快照。
package ystyle::cjreg.ui

import cjxt.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

// 造一个可被关键字过滤的整数源：关键字为空 = 全要，否则按十进制包含匹配
func intSource(all: ArrayList<Int64>, keyword: Signal<String>): () -> ArrayList<Int64> {
    { =>
        let q = keyword.get()
        let out = ArrayList<Int64>()
        for (v in all) {
            if (q == "" || v.toString().contains(q)) { out.add(v) }
        }
        out
    }
}

@Test
func bindRows_tracksFilterSignal() {
    let all = ArrayList<Int64>()
    for (i in 1..=9) { all.add(i) }
    let keyword = Signal<String>("")
    let rows = Signal<ArrayList<Int64>>(ArrayList<Int64>())
    let total = Signal<Int64>(0)
    let eff = bindRows(rows, total, intSource(all, keyword))
    @Expect(total.get(), 9)
    @Expect(rows.get().size, 9)

    // 输入即生效：不需要任何动作，信号一变派生值就跟着变
    keyword.set("1")
    @Expect(total.get(), 1)          // 只有 1 命中（1 与 10 不存在）
    @Expect(rows.get().size, 1)
    @Expect(rows.get()[0], 1)

    keyword.set("")
    @Expect(total.get(), 9)
    eff.dispose()
}

@Test
func bindPaged_slicesAndClampsPageLocally() {
    let all = ArrayList<Int64>()
    for (i in 1..=5) { all.add(i) }
    let keyword = Signal<String>("")
    let page = Signal<Int64>(1)
    let size = Signal<Int64>(2)
    let rows = Signal<ArrayList<Int64>>(ArrayList<Int64>())
    let total = Signal<Int64>(0)
    let eff = bindPaged(rows, total, intSource(all, keyword), page, size)

    @Expect(total.get(), 5)
    @Expect(rows.get().size, 2)
    @Expect(rows.get()[0], 1)

    page.set(3)
    @Expect(rows.get().size, 1)      // 第 3 页只剩 1 条
    @Expect(rows.get()[0], 5)

    // 越界页：本地钳到最后一页（不回写 page 信号，避免自订阅成环）
    page.set(99)
    @Expect(rows.get().size, 1)
    @Expect(rows.get()[0], 5)
    @Expect(page.get(), 99)          // 信号本身没被改写

    // 过滤后总数变小，同样按过滤后的集合切片
    page.set(1)
    keyword.set("5")
    @Expect(total.get(), 1)
    @Expect(rows.get().size, 1)
    @Expect(rows.get()[0], 5)
    eff.dispose()
}

@Test
func bindPaged_emptySourceKeepsOnePage() {
    let keyword = Signal<String>("")
    let page = Signal<Int64>(1)
    let size = Signal<Int64>(20)
    let rows = Signal<ArrayList<Int64>>(ArrayList<Int64>())
    let total = Signal<Int64>(0)
    let eff = bindPaged(rows, total, intSource(ArrayList<Int64>(), keyword), page, size)
    @Expect(total.get(), 0)
    @Expect(rows.get().size, 0)
    // 空集不该把页码算成 0 页
    page.set(2)
    @Expect(rows.get().size, 0)
    eff.dispose()
}
