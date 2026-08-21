// 版本区间匹配：基于中心仓 semver 包的 SemVer，实现 cjpm 版本要求语法
// 对齐 cjrepo internal/semverutil（Masterminds/semver 语义子集）：
//   精确 "1.2.3"、区间 "[1.0.0,2.0.0)" "(,2.0.0]" "[1.0.0,)"
//   比较符 ">=1.0.0" ">1.0.0" "<=" "<" "="
//   caret "^1.2.3"、tilde "~1.2.3"，多段或（逗号 / "||"）
package ystyle::cjreg.semver_range

import semver.*
import std.collection.*
import std.convert.*

// 单个版本区间（左/右可开可闭）
public class VersionBound {
    public var lower: ?SemVer
    public var lowerInc: Bool
    public var upper: ?SemVer
    public var upperInc: Bool

    public init(lower: ?SemVer, lowerInc: Bool, upper: ?SemVer, upperInc: Bool) {
        this.lower = lower
        this.lowerInc = lowerInc
        this.upper = upper
        this.upperInc = upperInc
    }

    public func rangeMatches(v: SemVer): Bool {
        match (this.lower) {
            case Some(lv) =>
                if (this.lowerInc) {
                    if (v < lv) {
                        return false
                    }
                } else {
                    if (v <= lv) {
                        return false
                    }
                }
            case None => ()
        }
        match (this.upper) {
            case Some(uv) =>
                if (this.upperInc) {
                    if (v > uv) {
                        return false
                    }
                } else {
                    if (v >= uv) {
                        return false
                    }
                }
            case None => ()
        }
        return true
    }

    // 是否有端点与 v 为相同三元组（major.minor.patch）且带预发布
    public func hasPrereleaseBoundOf(v: SemVer): Bool {
        if (v.preRelease.isEmpty()) {
            return false
        }
        return hasSameTuplePre(this.lower, v) || hasSameTuplePre(this.upper, v)
    }

    private func hasSameTuplePre(b: ?SemVer, v: SemVer): Bool {
        match (b) {
            case Some(sv) =>
                if (sv.major == v.major && sv.minor == v.minor && sv.patch == v.patch) {
                    return !sv.preRelease.isEmpty()
                }
                return false
            case None => return false
        }
    }
}

// 版本要求：多个区间任中其一即匹配
public class VersionReq {
    var bounds: ArrayList<VersionBound>

    public init(bounds: ArrayList<VersionBound>) {
        this.bounds = bounds
    }

    public func matches(v: SemVer): Bool {
        for (b in this.bounds) {
            if (b.rangeMatches(v)) {
                // 预发布规则（Masterminds 近似）：带预发布的版本仅当存在同三元组预发布端点时匹配
                if (v.preRelease.isEmpty() || b.hasPrereleaseBoundOf(v)) {
                    return true
                }
            }
        }
        return false
    }

    public static func parse(req: String): ?VersionReq {
        let trimmed = req.trimAscii()
        if (trimmed.isEmpty()) {
            return None
        }
        let bounds = ArrayList<VersionBound>()
        let parts = splitAlternatives(trimmed)
        for (part in parts) {
            let b = parseSingle(part)
            if (b.isSome()) {
                bounds.add(b.getOrThrow())
            }
        }
        if (bounds.size == 0) {
            return None
        }
        return Some(VersionReq(bounds))
    }
}

// 校验版本字符串是否满足要求
public func versionSatisfies(version: String, req: String): Bool {
    let v = SemVer.tryParse(version)
    if (v.isNone()) {
        return false
    }
    let r = VersionReq.parse(req)
    if (r.isNone()) {
        return false
    }
    return r.getOrThrow().matches(v.getOrThrow())
}

// 从可用版本（升序）中挑选满足要求的最佳（最高）版本；无匹配返回 None
public func bestMatch(versions: ArrayList<String>, req: String): ?String {
    let r = VersionReq.parse(req)
    if (r.isNone()) {
        return None
    }
    let rr = r.getOrThrow()
    // 从高到低找第一个满足的（versions 已升序）
    for (i in 0..versions.size) {
        let idx = versions.size - 1 - i
        let vs = versions[idx]
        let v = SemVer.tryParse(vs)
        if (v.isSome() && rr.matches(v.getOrThrow())) {
            return Some(vs)
        }
    }
    return None
}

// 按升序插入（去重）；versions 保持有序
public func insertSorted(versions: ArrayList<String>, version: String): Unit {
    let v = SemVer.tryParse(version)
    if (v.isNone()) {
        return
    }
    var idx = 0
    while (idx < versions.size) {
        let ev = SemVer.tryParse(versions[idx])
        if (ev.isSome() && ev.getOrThrow() < v.getOrThrow()) {
            idx++
        } else {
            break
        }
    }
    if (idx < versions.size && versions[idx] == version) {
        return  // 已存在
    }
    versions.add(version, at: idx)
}

// 比较两个版本：-1 / 0 / 1
public func compareVersions(a: String, b: String): Int64 {
    let va = SemVer.tryParse(a)
    let vb = SemVer.tryParse(b)
    if (va.isNone() || vb.isNone()) {
        let o = a.compare(b)
        match (o) {
            case LT => return -1
            case GT => return 1
            case EQ => return 0
        }
    }
    let o = va.getOrThrow().compare(vb.getOrThrow())
    match (o) {
        case LT => return -1
        case GT => return 1
        case EQ => return 0
    }
}

// 查找列表中最大的版本；空返回 None
public func maxVersion(versions: ArrayList<String>): ?String {
    if (versions.size == 0) {
        return None
    }
    var best = versions[0]
    for (i in 1..versions.size) {
        if (compareVersions(versions[i], best) > 0) {
            best = versions[i]
        }
    }
    return Some(best)
}

// ===== 解析辅助 =====

// 拆分多段（逗号 / "||" 顶层拆分，括号内深度不计）
func splitAlternatives(req: String): ArrayList<String> {
    let result = ArrayList<String>()
    var depth = 0
    let buf = StringBuilder()
    let rs = req.toRuneArray()
    var i = 0
    while (i < rs.size) {
        let c = rs[i]
        if (c == r'[' || c == r'(') {
            depth++
            buf.append(c)
        } else if (c == r']' || c == r')') {
            if (depth > 0) {
                depth--
            }
            buf.append(c)
        } else if (c == r',' && depth == 0) {
            let seg = buf.toString().trimAscii()
            if (!seg.isEmpty()) {
                result.add(seg)
            }
            buf.reset()
        } else if (c == r'|' && depth == 0 && i + 1 < rs.size && rs[i + 1] == r'|') {
            let seg = buf.toString().trimAscii()
            if (!seg.isEmpty()) {
                result.add(seg)
            }
            buf.reset()
            i++  // 跳过第二个 '|'
        } else {
            buf.append(c)
        }
        i++
    }
    let seg = buf.toString().trimAscii()
    if (!seg.isEmpty()) {
        result.add(seg)
    }
    return result
}

// 解析单个备选段
func parseSingle(seg: String): ?VersionBound {
    let s = seg.trimAscii()
    if (s.isEmpty()) {
        return None
    }
    let first = Rune(s[0])
    let last = Rune(s[s.size - 1])
    // 区间形式 [a,b] / (a,b) / (a,] 等
    if ((first == r'[' || first == r'(') && (last == r']' || last == r')')) {
        let lowerInc = first == r'['
        let upperInc = last == r']'
        let inner = s[1..s.size - 1]
        let parts = splitTopLevelComma(inner)
        var lower: ?SemVer = None
        var upper: ?SemVer = None
        if (parts.size >= 1 && !parts[0].trimAscii().isEmpty()) {
            lower = SemVer.tryParse(parts[0].trimAscii())
        }
        if (parts.size >= 2 && !parts[1].trimAscii().isEmpty()) {
            upper = SemVer.tryParse(parts[1].trimAscii())
        }
        if (parts.size > 2) {
            return None
        }
        if (lower.isNone() && upper.isNone()) {
            return None
        }
        return Some(VersionBound(lower, lowerInc, upper, upperInc))
    }

    if (s.startsWith("^")) {
        return parseCaret(s[1..s.size])
    }
    if (s.startsWith("~")) {
        return parseTilde(s[1..s.size])
    }
    // 比较符
    if (s.startsWith(">=")) {
        let v = SemVer.tryParse(s[2..s.size].trimAscii())
        if (v.isNone()) {
            return None
        }
        return Some(VersionBound(v, true, None, false))
    }
    if (s.startsWith(">")) {
        let v = SemVer.tryParse(s[1..s.size].trimAscii())
        if (v.isNone()) {
            return None
        }
        return Some(VersionBound(v, false, None, false))
    }
    if (s.startsWith("<=")) {
        let v = SemVer.tryParse(s[2..s.size].trimAscii())
        if (v.isNone()) {
            return None
        }
        return Some(VersionBound(None, false, v, true))
    }
    if (s.startsWith("<")) {
        let v = SemVer.tryParse(s[1..s.size].trimAscii())
        if (v.isNone()) {
            return None
        }
        return Some(VersionBound(None, false, v, false))
    }
    if (s.startsWith("==")) {
        let v = SemVer.tryParse(s[2..s.size].trimAscii())
        if (v.isNone()) {
            return None
        }
        return Some(VersionBound(v, true, v, true))
    }
    if (s.startsWith("=")) {
        let v = SemVer.tryParse(s[1..s.size].trimAscii())
        if (v.isNone()) {
            return None
        }
        return Some(VersionBound(v, true, v, true))
    }

    // 精确版本
    let v = SemVer.tryParse(s)
    if (v.isNone()) {
        return None
    }
    return Some(VersionBound(v, true, v, true))
}

// caret：^1.2.3 => [1.2.3, 2.0.0)；^0.2.3 => [0.2.3, 0.3.0)；^0.0.3 => [0.0.3, 0.0.4)
func parseCaret(s: String): ?VersionBound {
    let p = parseVersionTuple(s)
    if (p.isNone()) {
        return None
    }
    let (major, minor, patch) = p.getOrThrow()
    let lower = SemVer(major, minor, patch)
    var upper: SemVer
    if (major > 0) {
        upper = SemVer(UInt16(major + 1), 0, 0)
    } else if (minor > 0) {
        upper = SemVer(0, UInt16(minor + 1), 0)
    } else {
        upper = SemVer(0, 0, UInt16(patch + 1))
    }
    return Some(VersionBound(Some(lower), true, Some(upper), false))
}

// tilde：~1.2.3 => [1.2.3, 1.3.0)；~1.2 => [1.2.0, 1.3.0)；~1 => [1.0.0, 2.0.0)
func parseTilde(s: String): ?VersionBound {
    let parts = s.split(".")
    if (parts.size == 0 || parts.size > 3) {
        return None
    }
    let nums = parseVersionTuple(s)
    if (nums.isNone()) {
        return None
    }
    let (major, minor, patch) = nums.getOrThrow()
    let lower = SemVer(major, minor, patch)
    var upper: SemVer
    if (parts.size == 1) {
        upper = SemVer(UInt16(major + 1), 0, 0)
    } else {
        upper = SemVer(major, UInt16(minor + 1), 0)
    }
    return Some(VersionBound(Some(lower), true, Some(upper), false))
}

// 解析 1~3 段版本（允许 x / x.y / x.y.z），返回 (major, minor, patch)
func parseVersionTuple(s: String): ?(UInt16, UInt16, UInt16) {
    let parts = s.split(".")
    if (parts.size == 0 || parts.size > 3) {
        return None
    }
    let nums = ArrayList<UInt16>()
    for (p in parts) {
        var core = p
        let dash = core.indexOf("-")
        match (dash) {
            case Some(idx) => core = core[0..idx]
            case None => ()
        }
        let plus = core.indexOf("+")
        match (plus) {
            case Some(idx) => core = core[0..idx]
            case None => ()
        }
        let n = UInt16.tryParse(core, radix: 10)
        if (n.isNone()) {
            return None
        }
        nums.add(n.getOrThrow())
    }
    while (nums.size < 3) {
        nums.add(0)
    }
    return Some((nums[0], nums[1], nums[2]))
}

// 按顶层逗号拆分区间内部（只允许 2 段）
func splitTopLevelComma(inner: String): ArrayList<String> {
    let result = ArrayList<String>()
    var depth = 0
    var start = 0
    let rs = inner.toRuneArray()
    var i = 0
    while (i < rs.size) {
        let c = rs[i]
        if (c == r'[' || c == r'(') {
            depth++
        } else if (c == r']' || c == r')') {
            if (depth > 0) {
                depth--
            }
        } else if (c == r',' && depth == 0) {
            result.add(inner[start..i])
            start = i + 1
        }
        i++
    }
    result.add(inner[start..inner.size])
    return result
}
