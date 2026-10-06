// 上游 bstorm 存储层单测：文档反序列化与「新增开关字段」的兼容性
package ystyle::cjreg.store

import std.unittest.testmacro.*
import stdx.encoding.json.stream.*
import std.io.ByteBuffer

// 升级前写入的文档没有 proxyEnabled / asTarget 两个键。bstorm 的 @Model fromJson 会先按
// **字段默认值**构造对象、再按键逐个赋值（缺失键走 skip）→ 缺失键保持字段默认值。
// 这条守住"升级不改存量行为"：若哪天把字段默认值写成 false，存量上游会立刻停止回源，
// 并从发布计划的目标下拉里消失。
@Test
func testLegacyUpstreamDocKeepsBothSwitchesTrue() {
    let legacy = "{\"id\":1,\"name\":\"official\"," +
        "\"url\":\"https://pkg.cangjie-lang.cn/registry\",\"enabled\":true," +
        "\"cacheTtl\":86400,\"authToken\":\"\",\"isOfficial\":true," +
        "\"priority\":0,\"lastSyncAt\":0}"
    let doc = UpstreamDoc.fromJson(JsonReader(ByteBuffer(legacy.toArray())))
    @Expect(doc.name, "official")
    @Expect(doc.proxyEnabled, true)   // 旧文档 → 继续参与回源
    @Expect(doc.asTarget, true)       // 旧文档 → 仍可作为目标仓（与升级前一致）
}

// 显式写出这两个键时按值生效（升级后新建/改写过的文档）
@Test
func testUpstreamDocReadsExplicitSwitches() {
    let json = "{\"id\":2,\"name\":\"mirror\",\"url\":\"https://m.example.com/registry\"," +
        "\"enabled\":true,\"cacheTtl\":86400,\"authToken\":\"\",\"isOfficial\":false," +
        "\"priority\":1,\"lastSyncAt\":0,\"proxyEnabled\":false,\"asTarget\":true}"
    let doc = UpstreamDoc.fromJson(JsonReader(ByteBuffer(json.toArray())))
    @Expect(doc.proxyEnabled, false)
    @Expect(doc.asTarget, true)
}
