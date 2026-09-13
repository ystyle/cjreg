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
import ystyle::cjreg.config.*
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
    let a = svc.analyze(roots)
    @Expect(a.hasCycle, false)
    @Expect(a.items.size, 1)
    @Expect(a.items[0].version, "1.1.0")     // 修复前会得到 1.0.0
    store.storm.close()
}

@Test
func analyzePlan_emptyVersionPicksNewest() {
    let store = multiVersionStore()
    let svc = PublishPlanService(store)
    let roots = ArrayList<(String, String, String)>()
    roots.add(("", "demo", ""))
    let a = svc.analyze(roots)
    @Expect(a.items.size, 1)
    @Expect(a.items[0].version, "1.2.0")
    store.storm.close()
}

@Test
func analyzePlan_unknownVersionFallsBackToNewest() {
    let store = multiVersionStore()
    let svc = PublishPlanService(store)
    let roots = ArrayList<(String, String, String)>()
    roots.add(("", "demo", "9.9.9"))
    let a = svc.analyze(roots)
    @Expect(a.items.size, 1)
    @Expect(a.items[0].version, "1.2.0")
    store.storm.close()
}

// 跨组织依赖：依赖名带 `org::` 前缀时必须按前缀里的 org 找。
// 丢掉前缀 → 去 snappy 自己的 org（""）里找 crc → 找不到 → 依赖边消失 → 拓扑序错
// （实测 crc 被排到 snappy 后面，等于先发依赖方）。
@Test
func analyzePlan_crossOrgDependencyOrderedFirst() {
    let store = PackageStore(Storm.inMemory())
    store.save(planDoc("ystyle", "crc", "1.0.1", ArrayList<String>()))
    let deps = ArrayList<String>()
    deps.add("ystyle::crc")
    store.save(planDoc("", "snappy", "1.0.2", deps))
    let svc = PublishPlanService(store)
    let roots = ArrayList<(String, String, String)>()
    roots.add(("", "snappy", "1.0.2"))     // 只选 snappy：crc 必须由依赖展开带进来且排在它前面
    let a = svc.analyze(roots)
    @Expect(a.hasCycle, false)
    @Expect(a.items.size, 2)
    @Expect(a.items[0].name, "crc")
    @Expect(a.items[0].version, "1.0.1")
    @Expect(a.items[1].name, "snappy")
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
    let a = svc.analyze(roots)
    @Expect(a.hasCycle, false)
    @Expect(a.items.size, 2)
    @Expect(a.items[0].name, "base")          // 被依赖的先发
    @Expect(a.items[0].version, "2.0.0")
    @Expect(a.items[1].name, "top")
    @Expect(a.items[1].version, "0.5.0")
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
    let a = svc.analyze(roots)
    @Expect(a.items.size, 2)
    @Expect(a.items[0].name, "base")
    @Expect(a.items[0].version, "1.5.0")
    @Expect(a.items[1].name, "top")
    store.storm.close()
}

// ===== 按目标仓索引分类（对齐 cjrepo 的 Analyze）=====
//
// 出过的故障：分类是写死的 `need_publish`，于是**目标仓早就有同版本的包也显示成「待发布」**
// （实测：中心仓已有 ystyle::crc@1.0.0 / snappy@1.0.1，界面照样让它们"待发布"）。
// 用户只能靠执行时换回 409 才知道「其实不用发」。

func classFixture(): (PackageStore, PublishPlanService) {
    let store = PackageStore(Storm.inMemory())
    let svc = PublishPlanService(store)
    (store, svc)
}

// 目标仓同版本 sha 一致 → already_exists，且默认不勾选
@Test
func classifyPlan_alreadyExistsWhenShaMatches() {
    let (store, svc) = classFixture()
    store.save(planDoc("ystyle", "crc", "1.0.0", ArrayList<String>()))
    let up = Upstream(1, "official", "http://up.example", true, 0, "", true, 0, 0)
    let roots = ArrayList<(String, String, String)>()
    roots.add(("ystyle", "crc", "1.0.0"))
    let a = svc.analyze(roots, targetUpstream: up, fetchIndex: { _, org, name =>
        // 目标仓同版本、同 sha
        Some("{\"organization\":\"${org}\",\"name\":\"${name}\",\"version\":\"1.0.0\",\"sha256sum\":\"sha-crc-1.0.0\"}\n")
    })
    @Expect(a.targetChecked, true)
    @Expect(a.targetError, "")
    @Expect(a.items.size, 1)
    @Expect(a.items[0].category == PlanCategory.AlreadyExists, true)
    @Expect(a.items[0].selected, false)      // 默认不推：推上去也只会 409
    @Expect(a.items[0].remoteSha256, "sha-crc-1.0.0")
    store.storm.close()
}

// 目标仓同版本但 sha 不同 → conflict（默认不勾选：覆盖与否得人来定）
@Test
func classifyPlan_conflictWhenShaDiffers() {
    let (store, svc) = classFixture()
    store.save(planDoc("ystyle", "crc", "1.0.0", ArrayList<String>()))
    let up = Upstream(1, "official", "http://up.example", true, 0, "", true, 0, 0)
    let roots = ArrayList<(String, String, String)>()
    roots.add(("ystyle", "crc", "1.0.0"))
    let a = svc.analyze(roots, targetUpstream: up, fetchIndex: { _, _, _ =>
        Some("{\"name\":\"crc\",\"version\":\"1.0.0\",\"sha256sum\":\"different-sha\"}\n")
    })
    @Expect(a.items[0].category == PlanCategory.Conflict, true)
    @Expect(a.items[0].selected, false)
    @Expect(a.items[0].remoteSha256, "different-sha")
    store.storm.close()
}

// 目标仓没有该版本 → 仍是 need_publish（真需要发，且默认勾选）
@Test
func classifyPlan_needPublishWhenAbsentUpstream() {
    let (store, svc) = classFixture()
    store.save(planDoc("ystyle", "crc", "1.0.1", ArrayList<String>()))
    let up = Upstream(1, "official", "http://up.example", true, 0, "", true, 0, 0)
    let roots = ArrayList<(String, String, String)>()
    roots.add(("ystyle", "crc", "1.0.1"))
    let a = svc.analyze(roots, targetUpstream: up, fetchIndex: { _, _, _ =>
        // 目标仓只有更老的版本
        Some("{\"name\":\"crc\",\"version\":\"1.0.0\",\"sha256sum\":\"old\"}\n")
    })
    @Expect(a.items[0].category == PlanCategory.NeedPublish, true)
    @Expect(a.items[0].selected, true)
    @Expect(a.items[0].remoteSha256, "")
    store.storm.close()
}

// 目标仓有**更高**版本 → version_optional（提示"可以不发"）
@Test
func classifyPlan_versionOptionalWhenUpstreamNewer() {
    let (store, svc) = classFixture()
    store.save(planDoc("", "demo", "1.0.0", ArrayList<String>()))
    let up = Upstream(1, "official", "http://up.example", true, 0, "", true, 0, 0)
    let roots = ArrayList<(String, String, String)>()
    roots.add(("", "demo", "1.0.0"))
    let a = svc.analyze(roots, targetUpstream: up, fetchIndex: { _, _, _ =>
        Some("{\"name\":\"demo\",\"version\":\"2.0.0\",\"sha256sum\":\"new\"}\n")
    })
    @Expect(a.items[0].category == PlanCategory.VersionOptional, true)
    store.storm.close()
}

// 目标仓索引取不到 → 退回 need_publish，但**必须留下可见的说明**：
// 静默退回会让人以为"对比过了、目标仓什么都没有"，然后去重复推已存在的版本
@Test
func classifyPlan_unreachableTargetIsVisible() {
    let (store, svc) = classFixture()
    store.save(planDoc("", "demo", "1.0.0", ArrayList<String>()))
    let up = Upstream(1, "official", "http://up.example", true, 0, "", true, 0, 0)
    let roots = ArrayList<(String, String, String)>()
    roots.add(("", "demo", "1.0.0"))
    let a = svc.analyze(roots, targetUpstream: up, fetchIndex: { _, _, _ => None })
    @Expect(a.targetChecked, false)
    @Expect(a.targetError.isEmpty(), false)   // 必须说出来
    @Expect(a.targetError.contains("索引"), true)
    @Expect(a.items[0].category == PlanCategory.NeedPublish, true)
    store.storm.close()
}

// 没给目标上游（老接口）→ 不做对比，也不报"对比失败"
@Test
func classifyPlan_noTargetKeepsLocalView() {
    let (store, svc) = classFixture()
    store.save(planDoc("", "demo", "1.0.0", ArrayList<String>()))
    let roots = ArrayList<(String, String, String)>()
    roots.add(("", "demo", "1.0.0"))
    let a = svc.analyze(roots)
    @Expect(a.targetChecked, false)
    @Expect(a.targetError, "")
    @Expect(a.items[0].category == PlanCategory.NeedPublish, true)
    @Expect(a.items[0].selected, true)
    store.storm.close()
}

// 包名显示：org::name@version（无组织就不带前缀）
@Test
func packageLabel_format() {
    @Expect(packageLabel("ystyle", "crc", "1.0.0"), "ystyle::crc@1.0.0")
    @Expect(packageLabel("", "snappy", "1.0.1"), "snappy@1.0.1")
    @Expect(packageLabel("", "snappy", ""), "snappy")
}

// 分类 → 字符串（存储/接口取值必须与 cjrepo 一致）
@Test
func planCategoryName_values() {
    @Expect(planCategoryName(PlanCategory.NeedPublish), "need_publish")
    @Expect(planCategoryName(PlanCategory.AlreadyExists), "already_exists")
    @Expect(planCategoryName(PlanCategory.Conflict), "conflict")
    @Expect(planCategoryName(PlanCategory.VersionOptional), "version_optional")
}
