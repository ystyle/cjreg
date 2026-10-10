// 测试用内存态 Storm 的生命周期管理（server 包测试共用）
package ystyle::cjreg.server

import bstorm.*
import std.collection.*

// 内存态 Storm 很重：Badger 打开即预分配一个 skiplist Segment（8192 个 AtomicUInt64 +
// 8192 × MAX_HEIGHT(20) 个 AtomicUInt32，约 17 万个对象，含 1.3 MB 连续数组），
// 且写入 / flush 后台线程会一直持有实例引用 —— 不 close 既回收不了内存，也持续占着大对象空间。
//
// server 包有 13 处夹具，累计后在 CI 的覆盖率插桩构建里触发
// OutOfMemoryError（badgercj.skiplist.Segment::init，见 docs/verification.md §4.7）。
//
// 约定：一个用例内只保留「当前一代」库。
//   - 夹具工厂开头调用 beginTestStores() 关掉上一代；
//   - 需要同时存活多个库的用例（用户表 + 包表）只在开头调用一次 beginTestStores()，
//     随后任意次 testStorm()。
//
// ⚠️ 列表必须是**线程局部**的：unittest 用多个 worker 线程并发跑用例，
// 若共用一个进程级列表，A 用例建夹具时会把 B 用例正在用的库一起 close，
// B 随后在随机时刻踩到已关闭的库 —— 症状是「全量跑间歇失败、单独跑全绿」
// （实测：resolve_integration_test.testResolveWithMultilineCache、
//  publish_plan_order_test.planDependencyEdges_*）。ThreadLocal 让每个 worker
// 只管自己那一代，这个干扰从结构上消失。
let liveTestStorms = ThreadLocal<ArrayList<Storm>>()

func covStormList(): ArrayList<Storm> {
    match (liveTestStorms.get()) {
        case Some(l) => l
        case None =>
            let l = ArrayList<Storm>()
            liveTestStorms.set(Some(l))
            l
    }
}

func beginTestStores(): Unit {
    let list = covStormList()
    for (s in list) {
        s.close()
    }
    list.clear()
}

func testStorm(): Storm {
    let s = Storm.inMemory()
    covStormList().add(s)
    return s
}
