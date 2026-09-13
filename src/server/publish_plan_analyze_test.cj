// 发布计划 analyze 的版本解析回归。
//
// 出过的故障：analyze 把调用方给的 version 丢掉（`let (org, name, _) = r`），
// 然后取「第一个匹配 org+name 的 doc」——doc 顺序近似按 id 升序，于是**永远拿到最老版本**。
// 界面是按 doc id 选包的，计划随后又按该 id 取制品推送 → 在界面上发版会**发出旧版本**。
// 实测证据（修复前，对生产私有仓）：请求 badgercj 1.6.18 / snappy 1.0.1 / bstorm 1.4.8 /
// tsdb 0.3.2，返回的是 badgercj 1.0.0 / snappy 1.0.0 / bstorm 1.0.0 / tsdb 0.1.0。
//
// 本文件独立造夹具（不用其它测试的 beginTestStores/testStorm），避免和并发 WIP 纠缠。

package ystyle::cjreg.server

import ystyle::cjreg.store.*
import ystyle::cjreg.index.*
import bstorm.*
import std.collection.*

func planDoc(org: String, name: String, version: String, deps: ArrayList<String>): PackageDoc {
    let d = PackageDoc()
    d.organization = org
    d.name = name
    d.version = version
    d.sha256 = "sha-" + name + "-" + version
    d.createdAt = 1000
    d.updatedAt = 1000
    let entry = PackageIndex()
    entry.organization = org
    entry.name = name
    entry.version = version
    entry.sha256sum = d.sha256
    for (dep in deps) {
        entry.dependencies.add(DependencyEntry(dep, "1.0.0", "", "", ""))
    }
    d.indexJson = generateNDJSON(ArrayList<PackageIndex>([entry]))
    d
}

// 同一个包存多个版本（先存老版本，复现「取第一个匹配 doc」）
func multiVersionStore(): PackageStore {
    let store = PackageStore(Storm.inMemory())
    store.save(planDoc("", "demo", "1.0.0", ArrayList<String>()))
    store.save(planDoc("", "demo", "1.1.0", ArrayList<String>()))
    store.save(planDoc("", "demo", "1.2.0", ArrayList<String>()))
    store
}

@Test
func analyzePlan_honorsRequestedVersion() {
    let store = multiVersionStore()
    let svc = PublishPlanService(store)
    let roots = ArrayList<(String, String, String)>()
    roots.add(("", "demo", "1.1.0"))
    let (items, cycle) = svc.analyze(roots)
    @Expect(cycle, false)
    @Expect(items.size, 1)
    @Expect(items[0].version, "1.1.0")     // 修复前会得到 1.0.0
    store.storm.close()
}

@Test
func analyzePlan_emptyVersionPicksNewest() {
    let store = multiVersionStore()
    let svc = PublishPlanService(store)
    let roots = ArrayList<(String, String, String)>()
    roots.add(("", "demo", ""))
    let (items, _) = svc.analyze(roots)
    @Expect(items.size, 1)
    @Expect(items[0].version, "1.2.0")
    store.storm.close()
}

@Test
func analyzePlan_unknownVersionFallsBackToNewest() {
    let store = multiVersionStore()
    let svc = PublishPlanService(store)
    let roots = ArrayList<(String, String, String)>()
    roots.add(("", "demo", "9.9.9"))
    let (items, _) = svc.analyze(roots)
    @Expect(items.size, 1)
    @Expect(items[0].version, "1.2.0")
    store.storm.close()
}

// 依赖展开时也必须带对版本：被依赖的包同样有多版本。
// 显式选了 base 2.0.0 时，top 的依赖展开必须复用同一个版本（同包一个计划只出一个版本）。
@Test
func analyzePlan_dependencyExpansionKeepsVersions() {
    let store = PackageStore(Storm.inMemory())
    store.save(planDoc("", "base", "1.0.0", ArrayList<String>()))
    store.save(planDoc("", "base", "2.0.0", ArrayList<String>()))
    let deps = ArrayList<String>()
    deps.add("base")
    store.save(planDoc("", "top", "0.5.0", deps))
    let svc = PublishPlanService(store)
    let roots = ArrayList<(String, String, String)>()
    roots.add(("", "top", "0.5.0"))
    roots.add(("", "base", "2.0.0"))
    let (items, cycle) = svc.analyze(roots)
    @Expect(cycle, false)
    @Expect(items.size, 2)
    @Expect(items[0].name, "base")          // 被依赖的先发
    @Expect(items[0].version, "2.0.0")
    @Expect(items[1].name, "top")
    @Expect(items[1].version, "0.5.0")
    store.storm.close()
}

// 依赖声明的版本要求要生效：base 有 1.0.0 / 1.5.0 / 2.0.0，top 要求 [1.0.0,2.0.0)
// → 应选**满足要求里最新的** 1.5.0（此前按名字取第一个 doc，等于取最老版本）
@Test
func analyzePlan_dependencySatisfiesDeclaredRange() {
    let store = PackageStore(Storm.inMemory())
    store.save(planDoc("", "base", "1.0.0", ArrayList<String>()))
    store.save(planDoc("", "base", "1.5.0", ArrayList<String>()))
    store.save(planDoc("", "base", "2.0.0", ArrayList<String>()))
    let entry = PackageIndex()
    entry.name = "top"
    entry.version = "0.5.0"
    entry.sha256sum = "sha-top-0.5.0"
    entry.dependencies.add(DependencyEntry("base", "[1.0.0,2.0.0)", "", "", ""))
    let top = PackageDoc()
    top.name = "top"
    top.version = "0.5.0"
    top.indexJson = generateNDJSON(ArrayList<PackageIndex>([entry]))
    store.save(top)
    let svc = PublishPlanService(store)
    let roots = ArrayList<(String, String, String)>()
    roots.add(("", "top", "0.5.0"))
    let (items, _) = svc.analyze(roots)
    @Expect(items.size, 2)
    @Expect(items[0].name, "base")
    @Expect(items[0].version, "1.5.0")
    @Expect(items[1].name, "top")
    store.storm.close()
}
