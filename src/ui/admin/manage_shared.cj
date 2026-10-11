// 管理端各页面共用：日志时间/体积格式化、SignalView 等
package ystyle::cjreg.ui.admin

import ystyle::cjreg.ui.public.*
import ystyle::cjreg.ui.*
import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import ystyle::cjreg.store.*
import ystyle::cjreg.config.*
import ystyle::cjreg.server.{BlobStore, LifecycleOutcome, LifecycleResult, MemoryBlobStore, RefetchOutcome, hardDeleteVersion, refetchVersion, restoreVersion, shortSha, softDeleteVersion}
import ystyle::cjreg.semver_range.*
import std.collection.*
import std.convert.*
import std.sort.*
import std.time.*

// 秒级时间戳 → 可读时间（本地时区）
func formatLogTime(ms: Int64): String {
    if (ms <= 0) { return "-" }
    DateTime.fromUnixTimeStamp(Duration.millisecond * ms).inLocal().format("MM-dd HH:mm")
}

// 制品字节数 → 可读体积（版本列表/详情用）
func fmtSize(bytes: Int64): String {
    if (bytes <= 0) { return "-" }
    let k = 1024
    if (bytes < k) { return "${bytes} B" }
    if (bytes < k * k) { return "${bytes / k} KB" }
    if (bytes < k * k * k) { return "${bytes / (k * k)} MB" }
    return "${bytes / (k * k * k)} GB"
}

// 时间单元格：不换行。时间戳里有空格（"09-16 00:24"），单元格宽度不足时会折成两行、
// 整张表跟着变高；列宽已按格式给足，这里再钉一次 white-space。
func timeCell(t: String): IComponent {
    div([text(t)], attrs: Some(HashMap<String, String>([("style", "white-space:nowrap;")])))
}

// 版本来源：回源镜像显示上游名，本地发布标出来
func versionSource(d: PackageDoc): String {
    if (d.upstreamId == 0) {
        return "本地发布"
    }
    if (d.upstreamName.isEmpty()) {
        return "上游 #${d.upstreamId}"
    }
    return "回源 · ${d.upstreamName}"
}
