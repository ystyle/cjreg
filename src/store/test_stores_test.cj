// 测试用内存态 Storm 的生命周期管理（store 包测试共用）
//
// 内存态 Storm 很重（每个实例一个 skiplist Segment ≈ 17 万个原子对象）且被后台线程持有，
// 不 close 不会回收 —— 详见 src/server/test_stores_test.cj 的说明与 docs/verification.md §4.7。
package ystyle::cjreg.store

import bstorm.*
import std.collection.*

// ⚠️ 列表必须是**线程局部**的：unittest 用多个 worker 线程并发跑同一个包内的用例，
// 若共用一个进程级列表，A 用例建夹具时会把 B 用例正在用的库一起 close，
// B 随后在随机时刻踩到已关闭的库 —— 症状是「全量跑间歇失败、单独跑全绿」。
// ThreadLocal 让每个 worker 只管自己那一代，这个干扰从结构上消失。
// （server 包的同类夹具 src/server/test_stores_test.cj 已按同一口径处理。）
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
