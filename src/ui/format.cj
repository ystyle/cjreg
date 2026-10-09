// UI 文本格式化助手（公开端与管理端共用）
package ystyle::cjreg.ui

import std.collection.*
import std.time.*

// 列表拼接（团队关联组织/包展示）
public func joinList(items: ArrayList<String>): String {
    let sb = StringBuilder()
    for (i in 0..items.size) {
        if (i > 0) {
            sb.append("、")
        }
        sb.append(items[i])
    }
    sb.toString()
}

// 时间戳 → "MM-dd HH:mm"（与日志页展示口径一致）
public func formatTimeMs(ms: Int64): String {
    if (ms <= 0) {
        return "-"
    }
    DateTime.fromUnixTimeStamp(Duration.millisecond * ms).inLocal().format("MM-dd HH:mm")
}
