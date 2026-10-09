// ui 包测试共用桩（跨子包共享）
//
// 注意：cjpm 里 `*_test.cj` 只对它自己所属的包可见，ui 已按站点面拆成子包，
// 所以这份测试桩必须放在**非测试文件**里，子包测试才能 import 到。
// 内容：内存态 Storm 的生命周期管理 + 页面挂载所需的 state/上下文装配。
//
// 内存态 Storm 很重（每个实例一个 skiplist Segment ≈ 17 万个原子对象）且被后台线程持有，
// 不 close 不会回收 —— 详见 src/server/test_stores_test.cj 的说明与 docs/verification.md §4.7。
package ystyle::cjreg.ui

import bstorm.*
import std.collection.*
import cjxt.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.util.*
import ystyle::cjreg.auth.model.*
import ystyle::cjreg.config.*
import std.reflect.*

let liveTestStorms = ArrayList<Storm>()

public func beginTestStores(): Unit {
    for (s in liveTestStorms) {
        s.close()
    }
    liveTestStorms.clear()
}

public func testStorm(): Storm {
    let s = Storm.inMemory()
    liveTestStorms.add(s)
    return s
}

// ===== 页面挂载桩 =====

// 组装一个门户态 CjregState（内存态 Storm；mode 决定 permissionMode）
public func makePortalState(mode: String, publicUrl!: String = "http://localhost:8060", port!: UInt16 = 8060): CjregState {
    let cfg = CjregConfig()
    cfg.publicUrl = publicUrl
    cfg.port = port
    cfg.permissionMode = mode
    PasswordHash.ITERATIONS = 1000  // 测试提速
    beginTestStores()
    let storm = testStorm()
    let pkgStore = PackageStore(storm)
    let userStore = BstormUserStore(storm)
    let upStore = BstormUpstreamStore(storm)
    let authSvc = AuthService(userStore, 3600)
    let adminData = AdminDataStore(storm)
    CjregState(pkgStore, userStore, upStore, adminData, authSvc, config: cfg)
}

// 组装页面挂载所需的 LifecycleContext（states + 会话上下文）
public func mountCtx(state: CjregState, ctxMap: HashMap<String, String>): LifecycleContext {
    let states = HashMap<String, AppState>()
    states.add(TypeInfo.of<CjregState>().qualifiedName, state)
    let sctx: SessionContext = SessionContextState(ctxMap)
    LifecycleContext("sid-test", HashMap<String, String>(), Option<String>.None, Option<String>.None,
        states: states, sessionContext: Some(sctx))
}

public func userCtxMap(uid: Int64, username: String, isAdmin: Bool): HashMap<String, String> {
    let m = HashMap<String, String>()
    m["uid"] = uid.toString()
    m["username"] = username
    m["isAdmin"] = if (isAdmin) { "1" } else { "0" }
    m["token"] = "sess-test"
    m
}
