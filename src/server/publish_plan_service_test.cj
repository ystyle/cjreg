// 发布计划服务单元测试（analyze 拓扑排序）
package ystyle::cjreg.server

import ystyle::cjreg.store.*
import ystyle::cjreg.index.*
import bstorm.*
import std.unittest.testmacro.*
import std.collection.*

func makePlanService(): (PublishPlanService, PackageStore) {
    beginTestStores()
    let store = PackageStore(testStorm())
    (PublishPlanService(store), store)
}

// 造一个带依赖的包文档（indexJson 含 dependencies）
func makePkgWithDeps(store: PackageStore, org: String, name: String, version: String, deps: ArrayList<String>): Int64 {
    let d = PackageDoc()
    d.organization = org
    d.name = name
    d.version = version
    // 构造 indexJson（含 dependencies）
    let sb = StringBuilder()
    sb.append("{\"name\":\"${name}\",\"version\":\"${version}\",\"dependencies\":[")
    for (i in 0..deps.size) {
        if (i > 0) {
            sb.append(",")
        }
        sb.append("{\"name\":\"${deps[i]}\",\"require\":\"1.0.0\"}")
    }
    sb.append("]}")
    d.indexJson = sb.toString()
    store.save(d)
    d.id
}

@Test
func testAnalyzeTopologicalOrder() {
    let (svc, store) = makePlanService()
    // base 无依赖；mid 依赖 base；app 依赖 mid+base
    let base = makePkgWithDeps(store, "test", "base", "1.0.0", ArrayList<String>())
    let mid = makePkgWithDeps(store, "test", "mid", "1.0.0", ArrayList<String>(["base"]))
    let app = makePkgWithDeps(store, "test", "app", "1.0.0", ArrayList<String>(["mid", "base"]))

    let roots = ArrayList<(String, String, String)>([("test", "app", "1.0.0")])
    let a = svc.analyze(roots)
    let items = a.items
    @Expect(a.hasCycle, false)
    @Expect(items.size, 3)
    // 拓扑：base 先于 mid 先于 app
    @Expect(items[0].name, "base")
    @Expect(items[1].name, "mid")
    @Expect(items[2].name, "app")
    // order 字段
    @Expect(items[0].order, 1)
    @Expect(items[2].order, 3)
}

@Test
func testAnalyzeNoRoot() {
    let (svc, store) = makePlanService()
    makePkgWithDeps(store, "test", "base", "1.0.0", ArrayList<String>())
    let roots = ArrayList<(String, String, String)>([("test", "missing", "1.0.0")])
    let a = svc.analyze(roots)
    @Expect(a.items.size, 0)
    @Expect(a.hasCycle, false)
}

@Test
func testParseDependencyNames() {
    beginTestStores()
    let svc = PublishPlanService(PackageStore(testStorm()))
    let json = "{\"dependencies\":[{\"name\":\"base\",\"require\":\"1.0.0\"},{\"name\":\"org::lib\",\"require\":\"1.0.0\"}]}"
    let deps = svc.parseDependencyNames(json)
    @Expect(deps.size, 2)
    @Expect(deps[0], "base")
    @Expect(deps[1], "lib")  // org::lib → lib
}
