// 多仓解析：按优先级在各上游索引中查找满足 require 的最佳版本
// 冲突检测（同版本不同 sha）+ 候选链路（trace，供 /api/admin/resolve 诊断）
package ystyle::cjreg.server

import ystyle::cjreg.index.*
import ystyle::cjreg.config.*
import ystyle::cjreg.semver_range.*
import std.collection.*

// 单个候选
public class ResolveCandidate {
    public var repo: String        // 上游名
    public var version: String
    public var sha256sum: String
    public var conflict: Bool

    public init(repo: String, version: String, sha256sum: String, conflict: Bool) {
        this.repo = repo
        this.version = version
        this.sha256sum = sha256sum
        this.conflict = conflict
    }
}

// 解析结果
public class ResolveResult {
    public var found: Bool
    public var name: String
    public var org: String
    public var require: String
    public var selected: ?ResolveCandidate
    public var candidates: ArrayList<ResolveCandidate>
    public var trace: ArrayList<String>
    public var replacedBy: String   // [replace] 命中的版本，空 = 未替换
    public var replaced: Bool

    public init(name: String, org: String, require: String) {
        this.found = false
        this.name = name
        this.org = org
        this.require = require
        this.selected = None
        this.candidates = ArrayList<ResolveCandidate>()
        this.trace = ArrayList<String>()
        this.replacedBy = ""
        this.replaced = false
    }
}

// 解析服务：给定 (name, org, require)，按优先级遍历上游索引找满足 require 的最佳版本
public class ResolveService {
    public var upstreamSvc: UpstreamService

    public init(upstreamSvc: UpstreamService) {
        this.upstreamSvc = upstreamSvc
    }

    // 核心：遍历上游找最佳版本
    // fetchIndex: (org, name) -> ?NDJSON（由外部注入，便于测试/接 ProxyService）
    public func resolve(name: String, org: String, require: String,
                        fetchIndex: (String, String) -> ?String): ResolveResult {
        let result = ResolveResult(name, org, require)

        // [replace] 检查（简化：replace 命中则直接用指定版本，标记 replaced）
        // 实际 replace 由工作空间 cjpm.toml 提供，此处保留钩子
        let replaced = this.replacedVersion(name)
        if (replaced.isSome()) {
            result.replacedBy = replaced.getOrThrow()
            result.replaced = true
            result.found = true
            result.trace.add("replace: 使用 ${result.replacedBy}")
            return result
        }

        // 按优先级遍历上游
        let ups = this.upstreamSvc.enabledSorted()
        for (up in ups) {
            let ndjson = fetchIndex(org, name)
            if (ndjson.isNone()) {
                result.trace.add("${up.name}: 索引获取失败")
                continue
            }
            let entries = parseNDJSON(ndjson.getOrThrow())
            result.trace.add("${up.name}: 索引 ${entries.size} 个版本")
            // 找到满足 require 的最佳版本
            var best: ?String = None
            for (e in entries) {
                if (e.yanked) {
                    continue
                }
                if (!require.isEmpty() && !versionSatisfies(e.version, require)) {
                    continue
                }
                if (best.isNone() || compareVersions(e.version, best.getOrThrow()) > 0) {
                    best = Some(e.version)
                }
            }
            if (best.isSome()) {
                // 冲突检测：与已有候选同版本但不同 sha
                var conflict = false
                for (c in result.candidates) {
                    if (c.version == best.getOrThrow() && c.sha256sum != this.shaOf(entries, best.getOrThrow())) {
                        conflict = true
                        c.conflict = true
                    }
                }
                result.candidates.add(ResolveCandidate(
                    up.name, best.getOrThrow(), this.shaOf(entries, best.getOrThrow()), conflict))
                result.trace.add("${up.name}: 命中 ${best.getOrThrow()}")
                result.found = true
                break  // 优先级最高的上游命中即止
            }
            result.trace.add("${up.name}: 无满足 ${require} 的版本")
        }

        // 选择优先级最高的候选
        if (result.candidates.size > 0) {
            result.selected = Some(result.candidates[0])
        }
        return result
    }

    // [replace] 钩子（工作空间统一版本；默认无）
    func replacedVersion(name: String): ?String {
        None
    }

    func shaOf(entries: ArrayList<PackageIndex>, version: String): String {
        for (e in entries) {
            if (e.version == version) {
                return e.sha256sum
            }
        }
        return ""
    }
}
