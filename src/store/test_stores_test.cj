// 测试用内存态 Storm 的生命周期管理（store 包测试共用）
//
// 内存态 Storm 很重（每个实例一个 skiplist Segment ≈ 17 万个原子对象）且被后台线程持有，
// 不 close 不会回收 —— 详见 src/server/test_stores_test.cj 的说明与 docs/verification.md §4.7。
package ystyle::cjreg.store

import bstorm.*
import std.collection.*

let liveTestStorms = ArrayList<Storm>()

func beginTestStores(): Unit {
    for (s in liveTestStorms) {
        s.close()
    }
    liveTestStorms.clear()
}

func testStorm(): Storm {
    let s = Storm.inMemory()
    liveTestStorms.add(s)
    return s
}
