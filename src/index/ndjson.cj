// 索引 NDJSON 生成/解析（对齐官方索引条目规格）
// 每行一个 JSON 条目：{organization,name,version,cjc-version,dependencies,test-dependencies,
//                       script-dependencies,sha256sum,yanked,index-version}
package ystyle::cjreg.index

import stdx.encoding.json.stream.*
import std.collection.*
import std.io.*
import std.convert.*

// 依赖条目（含平台隔离/编译模式/产物类型字段，需原样透传）
public class DependencyEntry {
    public var name: String
    public var require: String
    public var target: String    // 平台隔离标识，空 = 不区分平台
    public var mode: String      // 编译模式 debug/release，空 = 不区分
    public var outputType: String  // static/dynamic，空 = 跟随 package.output-type

    public init(name: String, require: String, target: String, mode: String, outputType: String) {
        this.name = name
        this.require = require
        this.target = target
        this.mode = mode
        this.outputType = outputType
    }

    public init() {
        this.name = ""
        this.require = ""
        this.target = ""
        this.mode = ""
        this.outputType = ""
    }
}

// 索引条目（官方 index 结构）
public class PackageIndex {
    public var organization: String
    public var name: String
    public var version: String
    public var cjcVersion: String
    public var dependencies: ArrayList<DependencyEntry>
    public var testDependencies: ArrayList<DependencyEntry>
    public var scriptDependencies: ArrayList<DependencyEntry>
    public var sha256sum: String
    public var yanked: Bool
    public var indexVersion: Int64

    public init() {
        this.organization = ""
        this.name = ""
        this.version = ""
        this.cjcVersion = ""
        this.dependencies = ArrayList<DependencyEntry>()
        this.testDependencies = ArrayList<DependencyEntry>()
        this.scriptDependencies = ArrayList<DependencyEntry>()
        this.sha256sum = ""
        this.yanked = false
        this.indexVersion = 1
    }
}

// ===== 序列化 =====
func writeDeps(w: JsonWriter, deps: ArrayList<DependencyEntry>): Unit {
    w.startArray()
    for (d in deps) {
        w.startObject()
        w.writeName("name").writeValue(d.name)
        w.writeName("require").writeValue(d.require)
        if (!d.target.isEmpty()) {
            w.writeName("target").writeValue(d.target)
        } else {
            w.writeName("target").writeValue(Option<String>.None)
        }
        if (!d.mode.isEmpty()) {
            w.writeName("type").writeValue(d.mode)
        } else {
            w.writeName("type").writeValue(Option<String>.None)
        }
        if (!d.outputType.isEmpty()) {
            w.writeName("output-type").writeValue(d.outputType)
        } else {
            w.writeName("output-type").writeValue(Option<String>.None)
        }
        w.endObject()
    }
    w.endArray()
}

func writeIndex(w: JsonWriter, idx: PackageIndex): Unit {
    w.startObject()
    w.writeName("organization").writeValue(idx.organization)
    w.writeName("name").writeValue(idx.name)
    w.writeName("version").writeValue(idx.version)
    w.writeName("cjc-version").writeValue(idx.cjcVersion)
    w.writeName("dependencies")
    writeDeps(w, idx.dependencies)
    w.writeName("test-dependencies")
    writeDeps(w, idx.testDependencies)
    w.writeName("script-dependencies")
    writeDeps(w, idx.scriptDependencies)
    w.writeName("sha256sum").writeValue(idx.sha256sum)
    w.writeName("yanked").writeValue(idx.yanked)
    w.writeName("index-version").writeValue(idx.indexVersion)
    w.endObject()
}

// 生成 NDJSON：每行一个索引条目
public func generateNDJSON(indexes: ArrayList<PackageIndex>): String {
    let sb = StringBuilder()
    for (idx in indexes) {
        let bb = ByteBuffer()
        let w = JsonWriter(bb)
        writeIndex(w, idx)
        w.flush()
        bb.seek(Begin(0))
        sb.append(String.fromUtf8(readToEnd(bb)))
        sb.append("\n")
    }
    return sb.toString()
}

// ===== 反序列化 =====
func readDeps(r: JsonReader): ArrayList<DependencyEntry> {
    let result = ArrayList<DependencyEntry>()
    r.startArray()
    while (r.peek() != EndArray) {
        let d = DependencyEntry()
        r.startObject()
        while (r.peek() != EndObject) {
            let n = r.readName()
            match (n) {
                case "name" => d.name = r.readValue<String>()
                case "require" => d.require = r.readValue<String>()
                case "target" => d.target = readNullableString(r)
                case "type" => d.mode = readNullableString(r)
                case "output-type" => d.outputType = readNullableString(r)
                case _ => r.skip()
            }
        }
        r.endObject()
        result.add(d)
    }
    r.endArray()
    return result
}

func readNullableString(r: JsonReader): String {
    // 官方规格 target/type/output-type 为 null 或字符串
    let v = r.readValue<Option<String>>()
    match (v) {
        case Some(s) => return s
        case None => return ""
    }
}

func readIndex(r: JsonReader): PackageIndex {
    let idx = PackageIndex()
    r.startObject()
    while (r.peek() != EndObject) {
        let n = r.readName()
        match (n) {
            case "organization" => idx.organization = r.readValue<String>()
            case "name" => idx.name = r.readValue<String>()
            case "version" => idx.version = r.readValue<String>()
            case "cjc-version" => idx.cjcVersion = r.readValue<String>()
            case "dependencies" => idx.dependencies = readDeps(r)
            case "test-dependencies" => idx.testDependencies = readDeps(r)
            case "script-dependencies" => idx.scriptDependencies = readDeps(r)
            case "sha256sum" => idx.sha256sum = r.readValue<String>()
            case "index" =>
                // cjpm meta 的 sha256sum/dependencies/index-version 在嵌套 index 对象
                r.startObject()
                while (r.peek() != EndObject) {
                    let in2 = r.readName()
                    match (in2) {
                        case "sha256sum" => idx.sha256sum = r.readValue<String>()
                        case "yanked" => idx.yanked = r.readValue<Bool>()
                        case "dependencies" => idx.dependencies = readDeps(r)
                        case "test-dependencies" => idx.testDependencies = readDeps(r)
                        case "script-dependencies" => idx.scriptDependencies = readDeps(r)
                        case "index-version" =>
                            let iv = r.peek()
                            match (iv) {
                                case Some(JsonToken.JsonString) => idx.indexVersion = Int64.parse(r.readValue<String>())
                                case Some(JsonToken.JsonNumber) => idx.indexVersion = r.readValue<Int64>()
                                case _ => r.skip()
                            }
                        case _ => r.skip()
                    }
                }
                r.endObject()
            case "yanked" => idx.yanked = r.readValue<Bool>()
            case "index-version" =>
                // 官方索引实际返回字符串 "1"，兼容数字
                let iv = r.peek()
                match (iv) {
                    case Some(JsonToken.JsonString) => idx.indexVersion = Int64.parse(r.readValue<String>())
                    case Some(JsonToken.JsonNumber) => idx.indexVersion = r.readValue<Int64>()
                    case _ => r.skip()
                }
            case _ => r.skip()
        }
    }
    r.endObject()
    return idx
}

// 解析 NDJSON / 多行 JSON：扫描所有顶层 JSON 对象（兼容单行/pretty-print 多行）
public func parseNDJSON(body: String): ArrayList<PackageIndex> {
    let result = ArrayList<PackageIndex>()
    let bb = ByteBuffer()
    bb.write(body.toArray())
    let r = JsonReader(bb)
    while (true) {
        // 找一个顶层 BeginObject；peek() 在文档末尾返回 None
        var found = false
        while (let Some(v) <- r.peek()) {
            match (v) {
                case BeginObject =>
                    try {
                        result.add(readIndex(r))
                        found = true
                        break
                    } catch (e: Exception) {
                        // 该对象非索引条目或解析失败 → 跳过整个对象继续
                        skipObject(r)
                        found = false
                        break
                    }
                case _ => r.skip()
            }
        }
        if (!found) {
            return result
        }
    }
    return result
}

// 跳过当前顶层对象（用 peek 循环到 EndObject）
func skipObject(r: JsonReader): Unit {
    try {
        r.startObject()
        while (r.peek() != EndObject) {
            r.skip()
        }
        r.endObject()
    } catch (e: Exception) {
        // 这是「坏对象跳过」的恢复路径：恢复本身再失败会让 reader 停在半途，
        // parseNDJSON 外层直接 return result，索引被静默截断后端给客户端。
        println("[cjreg] NDJSON 跳过坏对象失败（索引可能被截断）: " + e.toString())
    }
}

// 从索引列表中按 name+version 找条目
public func findIndexVersion(indexes: ArrayList<PackageIndex>, version: String): ?PackageIndex {
    for (idx in indexes) {
        if (idx.version == version && !idx.yanked) {
            return Some(idx)
        }
    }
    return None
}
