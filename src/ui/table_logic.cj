// 管理界面列表通用纯逻辑：分页窗口切片
// 独立于组件/状态，供各列表页 refresh() 与单元测试复用
package ystyle::cjreg.ui

import std.core.*
import std.collection.*
import std.convert.*

/// 分页窗口 [start, end)：page/size 小于 1 时钳制为 1；start 越界（空页）时返回 (total, total)
public func pageWindow(total: Int64, page: Int64, size: Int64): (Int64, Int64) {
    let safePage = if (page < 1) { 1 } else { page }
    let safeSize = if (size < 1) { 1 } else { size }
    let start = (safePage - 1) * safeSize
    let end = if (start + safeSize > total) { total } else { start + safeSize }
    (start, end)
}
