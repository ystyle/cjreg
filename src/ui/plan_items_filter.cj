// 发布计划详情「发布项」列表的显示过滤：只决定**看得到哪些行**，不参与计数与执行。
//
// 为什么过滤结果要单独一份、而不是直接过滤掉不显示的项：
// 明细（共几项 / 需发布几项）与"还有没有在等索引的项"必须按**全量**算 —— 隐藏几条不推送的项，
// 不能让「共 N 项」跟着变小（用户会以为项丢了），也不能让「检查索引」按钮对隐藏项失明。
// 所以详情页显式分成两份数据：items（全量：计数、执行、按钮判据都用它）+ itemRows（显示用）。
package ystyle::cjreg.ui

import ystyle::cjreg.store.*
import std.collection.*

/// 这一项「会真的推送」吗？
///
/// 两个否的来源：**没勾选**（用户不想发，执行器据此跳过）与**已被执行器记为未推送**
/// （409 目标仓已有同版本不同制品 / 依赖未就绪 / 计划中止 / 认证失败…）。
/// 两者都是"这次不会上传内容"，也就是用户说的"不发的项"。
public func willPublish(d: PlanItemDoc): Bool {
    d.selected && d.status != "skipped"
}

/// 按「隐藏不推送的项」开关过滤显示行。
///
/// 关闭时**原样返回**同一份列表（不复制）：行数多时无谓拷贝没有意义，
/// 调用方也不会改它（Table 只读）。
public func visibleItems(all: ArrayList<PlanItemDoc>, hideUnpublished: Bool): ArrayList<PlanItemDoc> {
    if (!hideUnpublished) {
        return all
    }
    let out = ArrayList<PlanItemDoc>()
    for (d in all) {
        if (willPublish(d)) {
            out.add(d)
        }
    }
    out
}

/// 显示行数的文案：隐藏时给出「显示 N / 共 M」，否则只说总数。
public func itemCountTextOf(shown: Int64, all: Int64, hideUnpublished: Bool): String {
    if (!hideUnpublished) {
        return "共 ${all} 项"
    }
    "显示 ${shown} / 共 ${all} 项（隐藏 ${all - shown} 项不推送的）"
}
