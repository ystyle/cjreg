// 管理端列表的「行/总数」派生：把过滤+分页的结果写进 Table / Pagination 要的信号。
//
// 为什么必须走 Effect，而不是在 `Component.on("input", …)` 里 refresh：
//
// 1. cjxt 的 `Table.data()` **只接受 `Signal<ArrayList<T>>`**（components/Table.cj:103），
//    所以"过滤结果"只能由一个信号承载；
// 2. 前端对同一元素的监听是**先 action 后 bind**（public/js/cangjie-ui.js:333 收到 input
//    立刻发 action，而 bind 有 300ms 防抖，见 :490）——action 里读信号拿到的是**上一次**
//    的关键字；
// 3. 更致命的是：过滤结果被缓存进 rows 信号、而 render 只读 rows 不读 search，
//    于是 bind 写完信号后**没有任何作用域重算表格** → 表现为"搜索完全无效"，
//    只有再点一次「刷新」才生效。
//
// 正确做法是让「过滤后的行」成为**信号变化时自动重算的派生值**：`source()` 内部读哪些
// 信号，Effect 就订阅哪些信号（读取即订阅）。仓库里同样的教训见 pages_plan.cj:290-296。
package ystyle::cjreg.ui

import cjxt.*
import std.collection.*

/// 无分页：source() 的全量结果直接进 rows，总数进 total。
public func bindRows<T>(rows: Signal<ArrayList<T>>, total: Signal<Int64>,
                        source: () -> ArrayList<T>): Effect {
    Effect({ =>
        let all = source()
        total.set(all.size)
        rows.set(all)
    })
}

/// 带分页：按 page/size 切片后进 rows，过滤后的总数进 total。
///
/// 页越界时**只在本地钳制**，不回写 page 信号——回写会让本 Effect 自订阅成环。
public func bindPaged<T>(rows: Signal<ArrayList<T>>, total: Signal<Int64>,
                         source: () -> ArrayList<T>,
                         page: Signal<Int64>, size: Signal<Int64>): Effect {
    Effect({ =>
        let all = source()
        total.set(all.size)
        let pageSize = size.get()
        let safeSize = if (pageSize < 1) { 1 } else { pageSize }
        let pageCount = if (all.size == 0) { 1 } else { (all.size + safeSize - 1) / safeSize }
        var p = page.get()
        if (p > pageCount) { p = pageCount }
        if (p < 1) { p = 1 }
        let (start, end) = pageWindow(all.size, p, safeSize)
        let slice = ArrayList<T>()
        var i = start
        while (i < end) {
            slice.add(all[i])
            i++
        }
        rows.set(slice)
    })
}
