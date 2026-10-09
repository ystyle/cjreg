// 发布计划：PublishPlanService 的字段与构造（顶层模型见 publish_plan_model.cj）
// 各域在同包文件里以 extend 展开：publish_plan_analyze.cj（分析与目标仓对照）/
// publish_plan_order.cj（拓扑顺序与重分析写回）/ publish_plan_index.cj（索引等待与确认）/
// publish_plan_execute.cj（PublishExecutor 推送执行）
package ystyle::cjreg.server

import ystyle::cjreg.index.*
import ystyle::cjreg.store.*
import graph.*
import ystyle::cjreg.config.*
import ystyle::cjreg.semver_range.*
import stdx.encoding.json.stream.*
import std.io.*
import std.collection.*

// 依赖解析（简化拓扑）：从本地 pkg 集合找包的依赖名集合
public class PublishPlanService {
    public var pkgStore: PackageStore

    public init(pkgStore: PackageStore) {
        this.pkgStore = pkgStore
    }
}
