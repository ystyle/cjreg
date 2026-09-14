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

// ===== 目标仓「版本对照」：`bstorm@1.4.9` 对 `bstorm@1.4.8` =====
//
// 出过的缺口：分类只给出「待发布/已存在/冲突」，看不出**目标仓那边现在是哪个版本**——
// 人要判断"这是不是真新版本"（1.4.9 vs 1.4.8）还是"自己落后了"（1.4.9 vs 1.5.0），
// 只能挨个去查目标仓索引。所以每条都要带出目标仓该包的最新版本。

// 目标仓有多个版本 → 取最新的那个；本地更新 → need_publish，且对照值就是 1.4.8
@Test
func classifyPlan_reportsTargetLatestVersion() {
    let (store, svc) = classFixture()
    store.save(planDoc("", "bstorm", "1.4.9", ArrayList<String>()))
    let up = Upstream(1, "official", "http://up.example", true, 0, "", true, 0, 0)
    let roots = ArrayList<(String, String, String)>()
    roots.add(("", "bstorm", "1.4.9"))
    let a = svc.analyze(roots, targetUpstream: up, fetchIndex: { _, _, _ =>
        Some("{\"name\":\"bstorm\",\"version\":\"1.4.7\",\"sha256sum\":\"s7\"}\n" +
            "{\"name\":\"bstorm\",\"version\":\"1.4.8\",\"sha256sum\":\"s8\"}\n")
    })
    @Expect(a.items[0].targetCompared, true)
    @Expect(a.items[0].targetVersion, "1.4.8")
    @Expect(a.items[0].category == PlanCategory.NeedPublish, true)
    @Expect(targetCompareText(a.items[0].name, a.items[0].targetVersion, a.items[0].targetCompared), "bstorm@1.4.8")
    store.storm.close()
}

// 目标仓最新版本要按 semver 数值比，不是字典序（1.4.10 > 1.4.9，按字符串比会取错）
@Test
func classifyPlan_targetLatestUsesSemverOrder() {
    let (store, svc) = classFixture()
    store.save(planDoc("", "demo", "1.4.11", ArrayList<String>()))
    let up = Upstream(1, "official", "http://up.example", true, 0, "", true, 0, 0)
    let roots = ArrayList<(String, String, String)>()
    roots.add(("", "demo", "1.4.11"))
    let a = svc.analyze(roots, targetUpstream: up, fetchIndex: { _, _, _ =>
        Some("{\"name\":\"demo\",\"version\":\"1.4.9\",\"sha256sum\":\"s9\"}\n" +
            "{\"name\":\"demo\",\"version\":\"1.4.10\",\"sha256sum\":\"s10\"}\n" +
            "{\"name\":\"demo\",\"version\":\"1.4.2\",\"sha256sum\":\"s2\"}\n")
    })
    @Expect(a.items[0].targetVersion, "1.4.10")
    store.storm.close()
}

// 目标仓同版本已存在 → 对照值还是那个版本（分类已经在说"已存在"）
@Test
func classifyPlan_targetLatestEqualsLocalForExisting() {
    let (store, svc) = classFixture()
    store.save(planDoc("ystyle", "crc", "1.0.0", ArrayList<String>()))
    let up = Upstream(1, "official", "http://up.example", true, 0, "", true, 0, 0)
    let roots = ArrayList<(String, String, String)>()
    roots.add(("ystyle", "crc", "1.0.0"))
    let a = svc.analyze(roots, targetUpstream: up, fetchIndex: { _, org, name =>
        Some("{\"organization\":\"${org}\",\"name\":\"${name}\",\"version\":\"1.0.0\",\"sha256sum\":\"sha-crc-1.0.0\"}\n")
    })
    @Expect(a.items[0].category == PlanCategory.AlreadyExists, true)
    @Expect(a.items[0].targetCompared, true)
    @Expect(a.items[0].targetVersion, "1.0.0")
    store.storm.close()
}

// 目标仓**查到了但没有这个包** → compared=true 且 version 为空，文案是「无此包」。
// 这与「没查到」（未对照）是两件事，混起来会让人把"不知道"当成"放心发"。
@Test
func classifyPlan_targetWithoutPackageIsComparedButEmpty() {
    let (store, svc) = classFixture()
    store.save(planDoc("", "fresh", "1.0.0", ArrayList<String>()))
    let up = Upstream(1, "official", "http://up.example", true, 0, "", true, 0, 0)
    let roots = ArrayList<(String, String, String)>()
    roots.add(("", "fresh", "1.0.0"))
    let a = svc.analyze(roots, targetUpstream: up, fetchIndex: { _, _, _ => Some("") })
    @Expect(a.targetChecked, true)                 // 索引取到了，只是这个包不在里面
    @Expect(a.items[0].targetCompared, true)
    @Expect(a.items[0].targetVersion, "")
    @Expect(a.items[0].category == PlanCategory.NeedPublish, true)
    @Expect(targetCompareText(a.items[0].name, a.items[0].targetVersion, a.items[0].targetCompared), "无此包")
    store.storm.close()
}

// 索引取不到 / 没选目标上游 → 对照没做成：必须报「未对照」，不能假装目标仓是空的
@Test
func classifyPlan_unreachableTargetLeavesUncompared() {
    let (store, svc) = classFixture()
    store.save(planDoc("", "demo", "1.0.0", ArrayList<String>()))
    let up = Upstream(1, "official", "http://up.example", true, 0, "", true, 0, 0)
    let roots = ArrayList<(String, String, String)>()
    roots.add(("", "demo", "1.0.0"))
    let a = svc.analyze(roots, targetUpstream: up, fetchIndex: { _, _, _ => None })
    @Expect(a.items[0].targetCompared, false)
    @Expect(a.items[0].targetVersion, "")
    @Expect(targetCompareText(a.items[0].name, a.items[0].targetVersion, a.items[0].targetCompared), "未对照")
    // 没给目标上游时同样只有「未对照」
    let b = svc.analyze(roots)
    @Expect(b.items[0].targetCompared, false)
    @Expect(b.items[0].targetVersion, "")
    store.storm.close()
}

// 对照文案：三种取值 × 带组织的包名
@Test
func targetCompareText_values() {
    @Expect(targetCompareText("bstorm", "1.4.8", true), "bstorm@1.4.8")
    @Expect(targetCompareText("crc", "1.0.0", true), "crc@1.0.0")
    @Expect(targetCompareText("crc", "", true), "无此包")
    @Expect(targetCompareText("crc", "1.0.0", false), "未对照")
    // 目标仓没有版本号时，即使 compared=true 也不该拼出半截名字
    @Expect(targetCompareText("crc", "", false), "未对照")
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

// ===== 目标仓「能不能覆盖」决定冲突条目还有没有救 =====
//
// 官方中心仓不可逆、同版本一律 409 → 冲突只能升版重发；自建仓（team 模式）可覆盖。
// 不区分这一点的话，界面把「冲突」写成"由人来定"，等于给了一个注定失败的按钮。

@Test
func classifyPlan_officialTargetCannotOverwrite() {
    let (store, svc) = classFixture()
    store.save(planDoc("ystyle", "crc", "1.0.0", ArrayList<String>()))
    let official = Upstream(1, "official", "https://pkg.cangjie-lang.cn/registry", true, 0, "", true, 0, 0)
    let roots = ArrayList<(String, String, String)>()
    roots.add(("ystyle", "crc", "1.0.0"))
    let a = svc.analyze(roots, targetUpstream: official, fetchIndex: { _, _, _ =>
        Some("{\"name\":\"crc\",\"version\":\"1.0.0\",\"sha256sum\":\"different-sha\"}\n")
    })
    @Expect(a.items[0].category == PlanCategory.Conflict, true)
    @Expect(a.items[0].overwriteAllowed, false)
    store.storm.close()
}

@Test
func classifyPlan_privateTargetAllowsOverwrite() {
    let (store, svc) = classFixture()
    store.save(planDoc("ystyle", "crc", "1.0.0", ArrayList<String>()))
    let privateRepo = Upstream(2, "cjrepo", "http://192.168.3.6:8066", true, 0, "", false, 0, 0)
    let roots = ArrayList<(String, String, String)>()
    roots.add(("ystyle", "crc", "1.0.0"))
    let a = svc.analyze(roots, targetUpstream: privateRepo, fetchIndex: { _, _, _ =>
        Some("{\"name\":\"crc\",\"version\":\"1.0.0\",\"sha256sum\":\"different-sha\"}\n")
    })
    @Expect(a.items[0].category == PlanCategory.Conflict, true)
    @Expect(a.items[0].overwriteAllowed, true)
    store.storm.close()
}

@Test
func targetOverwritable_onlyOfficialIsForbidden() {
    @Expect(targetOverwritable(Some(Upstream(1, "official", "u", true, 0, "", true, 0, 0))), false)
    @Expect(targetOverwritable(Some(Upstream(2, "cjrepo", "u", true, 0, "", false, 0, 0))), true)
    @Expect(targetOverwritable(None), false)
}

// 冲突文案：官方仓只能升版，自建仓可以勾选覆盖
@Test
func categoryHint_conflictDependsOnOverwrite() {
    let official = categoryHint(PlanCategory.Conflict, false)
    @Expect(official.contains("不允许覆盖"), true)
    @Expect(official.contains("升版"), true)
    let own = categoryHint(PlanCategory.Conflict, true)
    @Expect(own.contains("勾选"), true)
    @Expect(categoryHint(PlanCategory.NeedPublish, false).contains("需要发布"), true)
}

// ===== 进度口径：分母是"需要发布的项数"，不含目标仓已有的 =====
//
// 出过的故障：进度显示 0/6，而 6 项里有 4 项目标仓早就有了（默认不勾选、也不会发），
// 用户看到"6 个要发"就以为计划要大发一批。
@Test
func progressCount_excludesAlreadyExists() {
    let items = ArrayList<PlanItem>()
    let a = PlanItem(1, "crc", "ystyle", "1.0.0", PlanCategory.AlreadyExists, 1)
    let b = PlanItem(2, "snappy", "", "1.0.1", PlanCategory.AlreadyExists, 2)
    let c = PlanItem(3, "tsdb", "", "0.3.3", PlanCategory.NeedPublish, 3)
    let d = PlanItem(4, "bstorm", "", "1.4.9", PlanCategory.NeedPublish, 4)
    items.add(a)
    items.add(b)
    items.add(c)
    items.add(d)
    @Expect(countRequired(items), 2)
    @Expect(progressTextOf(0, 2), "0/2")
}

// 冲突项仍需处理（升版），算进分母；确实一项都不用发时直说
@Test
func progressCount_keepsConflictAndEmptyCase() {
    let items = ArrayList<PlanItem>()
    items.add(PlanItem(1, "x", "", "1.0.0", PlanCategory.Conflict, 1))
    items.add(PlanItem(2, "y", "", "1.0.0", PlanCategory.VersionOptional, 2))
    @Expect(countRequired(items), 2)
    @Expect(progressTextOf(0, 0), "无需发布")
}

// 「检查索引」：只探一次目标仓索引，命中的项交给调用方标成已发布。
// 这样"已推送成功、在等索引"的项不用逼用户再点一次执行、干等一个轮询周期（默认 60s）。
@Test
func checkVersionsInIndex_reportsReadyOnes() {
    let targets = ArrayList<(String, String, String)>()
    targets.add(("ystyle", "crc", "1.0.1"))     // 索引里有
    targets.add(("", "snappy", "1.0.2"))        // 索引里没有
    targets.add(("", "tsdb", "0.3.3"))          // 索引取不到
    let r = checkVersionsInIndex(targets, { org, name =>
        if (name == "tsdb") {
            None
        } else if (name == "crc") {
            Some("{\"name\":\"crc\",\"version\":\"1.0.1\"}\n")
        } else {
            Some("{\"name\":\"snappy\",\"version\":\"1.0.1\"}\n")
        }
    })
    @Expect(r.checked, 2)
    @Expect(r.unreachable, 1)
    @Expect(r.ready.size, 1)
    @Expect(r.ready[0], 0)               // 只有 crc 那个下标
}
