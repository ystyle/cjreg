// 上游表单元测试
package ystyle::cjreg.config

import std.unittest.testmacro.*
import std.collection.*

func makeService(): UpstreamService {
    UpstreamService(MemoryUpstreamStore())
}

@Test
func testAddUpstream() {
    let svc = makeService()
    let up = svc.add("official", "https://pkg.cangjie-lang.cn/registry", 0, "", 0)
    match (up) {
        case Some(u) =>
            @Expect(u.name, "official")
            @Expect(u.isOfficial, true)   // URL 自动识别官方仓
            @Expect(u.enabled, true)
            @Expect(u.cacheTtl, 86400)    // 默认 TTL
        case None => @Fail("add should succeed")
    }
}

@Test
func testAddNonOfficialAndDup() {
    let svc = makeService()
    svc.add("mirror", "https://mirror.example.com/registry", 1, "", 0)
    match (svc.getByName("mirror")) {
        case Some(u) => @Expect(u.isOfficial, false)
        case None => @Fail("mirror should exist")
    }
    // 重名拒绝
    @Expect(svc.add("mirror", "https://other/registry", 2, "", 0).isNone(), true)
    // 空 name/url 拒绝
    @Expect(svc.add("", "https://x", 0, "", 0).isNone(), true)
    @Expect(svc.add("x", "", 0, "", 0).isNone(), true)
}

@Test
func testOfficialProtected() {
    let svc = makeService()
    let up = svc.add("official", "https://pkg.cangjie-lang.cn/registry", 0, "", 0).getOrThrow()
    // 官方仓不可删除
    @Expect(svc.remove(up.id), false)
    // 非官方仓可删
    let mir = svc.add("mirror", "https://m/registry", 1, "", 0).getOrThrow()
    @Expect(svc.remove(mir.id), true)
    @Expect(svc.getById(mir.id).isNone(), true)
}

@Test
func testPriorityOrder() {
    let svc = makeService()
    svc.add("home", "https://pkg.cangjie-lang.cn/registry", 0, "", 0)
    svc.add("b2", "https://m2/registry", 5, "", 0)
    svc.add("a1", "https://m1/registry", 1, "", 0)
    // 禁用 b2
    let b2 = svc.getByName("b2").getOrThrow()
    svc.update(b2.id, Some(false), None, None, None)

    let sorted = svc.proxySorted()
    @Expect(sorted.size, 2)
    @Expect(sorted[0].name, "home")  // priority 0
    @Expect(sorted[1].name, "a1")    // priority 1
    @Expect(sorted[0].priority <= sorted[1].priority, true)
}

@Test
func testUpdateUpstream() {
    let svc = makeService()
    let up = svc.add("official", "https://pkg.cangjie-lang.cn/registry", 0, "", 0).getOrThrow()
    // 官方仓可更新 enabled/priority/authToken（不可删除）
    @Expect(svc.update(up.id, Some(false), Some(9), Some(3600), Some("tok")), true)
    let upd = svc.getById(up.id).getOrThrow()
    @Expect(upd.enabled, false)
    @Expect(upd.priority, 9)
    @Expect(upd.cacheTtl, 3600)
    @Expect(upd.authToken, "tok")
    @Expect(upd.isOfficial, true)  // isOfficial 不变
    // 不存在 id → false
    @Expect(svc.update(999, None, None, None, None), false)
}

// 上游两个正交开关：新建默认「回源开、可推送关」
@Test
func testAddDefaultsProxyOnTargetOff() {
    let svc = makeService()
    let up = svc.add("mirror", "https://mirror.example.com/registry", 1, "", 0).getOrThrow()
    @Expect(up.proxyEnabled, true)   // 新上游默认参与回源（镜像同步）
    @Expect(up.asTarget, false)      // 推送不可逆：默认不允许作为发布计划目标
    // 显式指定时按指定值
    let t = svc.add("t", "https://t.example.com/registry", 2, "", 0,
        proxyEnabled: false, asTarget: true).getOrThrow()
    @Expect(t.proxyEnabled, false)
    @Expect(t.asTarget, true)
}

// 回源链只包含 enabled 且 proxyEnabled 的上游
@Test
func testProxySortedHonoursProxySwitch() {
    let svc = makeService()
    let a = svc.add("a", "https://a.example.com/registry", 0, "", 0).getOrThrow()
    let b = svc.add("b", "https://b.example.com/registry", 0, "", 0).getOrThrow()
    let c = svc.add("c", "https://c.example.com/registry", 0, "", 0).getOrThrow()
    @Expect(svc.update(b.id, None, None, None, None, proxyEnabled: Some(false)), true)  // 关回源
    @Expect(svc.update(c.id, Some(false), None, None, None), true)                       // 总闸关
    let names = ArrayList<String>()
    for (u in svc.proxySorted()) {
        names.add(u.name)
    }
    @Expect(names.size, 1)
    @Expect(names[0], "a")
    // 关回源不影响它作为目标仓的资格（两个开关正交）
    @Expect(svc.update(a.id, None, None, None, None, asTarget: Some(true)), true)
    @Expect(svc.planTargets().size, 1)
}

// 发布计划目标下拉只包含 enabled 且 asTarget 的上游
@Test
func testPlanTargetsHonoursAsTargetSwitch() {
    let svc = makeService()
    svc.add("a", "https://a.example.com/registry", 0, "", 0)
    let b = svc.add("b", "https://b.example.com/registry", 1, "", 0).getOrThrow()
    @Expect(svc.planTargets().size, 0)   // 新建的上游默认都不出现在目标下拉里
    @Expect(svc.update(b.id, None, None, None, None, asTarget: Some(true)), true)
    let list = svc.planTargets()
    @Expect(list.size, 1)
    @Expect(list[0].name, "b")
    // 总闸关掉后即使 asTarget=true 也不出现
    @Expect(svc.update(b.id, Some(false), None, None, None), true)
    @Expect(svc.planTargets().size, 0)
    // b 总闸关 = 不回源；回源链里只剩 a（默认参与回源）
    let proxies = svc.proxySorted()
    @Expect(proxies.size, 1)
    @Expect(proxies[0].name, "a")
}
