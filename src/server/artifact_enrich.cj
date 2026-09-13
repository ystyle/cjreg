// 回源/存量包的展示字段补齐
//
// 索引协议（NDJSON）只带 name/version/deps/sha256sum/yanked —— **展示字段一律不在里面**，
// 所以「回源聚合落库」的包描述、协议、作者、README 全是空的（列表页一片空白）。
// 这些信息只存在于制品（.cjp）内部：README.md + cjpm.toml。
// 于是：制品流经本地（下载/回源）时顺手补齐；存量包用 `cjreg admin sync-metadata` 回捞。
//
// 两条硬约束：
//   1. 默认只填空字段，**绝不覆盖**已有值（本地发布的包已由 meta-data.json 填好）；
//      显式重拉（overwrite=true）时按上游新制品整体刷新 —— 那是「以上游为准」的语义；
//   2. 不改 updatedAt —— 元数据补齐不是发版，不能把「最近更新」排序搅乱。
package ystyle::cjreg.server

import ystyle::cjreg.protocol.*
import ystyle::cjreg.store.*
import ystyle::cjreg.semver_range.*
import std.collection.*

// 文档是否还缺展示字段/README（缺了才值得解压制品）
public func needsArtifactEnrich(d: PackageDoc): Bool {
    return d.readme.isEmpty() || d.description.isEmpty() || d.license.isEmpty()
        || d.authors.isEmpty() || d.repository.isEmpty() || d.tag.isEmpty()
        || d.category.isEmpty() || d.tarballSize == 0
}

// 用制品内容补齐文档；返回是否发生了变更（调用方负责 save）
// overwrite=false：只填空字段（下载/回源补齐）；true：按制品内容整体刷新（重拉覆盖）
public func enrichDocFromArtifact(doc: PackageDoc, tarball: Array<Byte>, overwrite!: Bool = false): Bool {
    let files = extractArtifactFiles(tarball)
    if (!files.ok()) {
        // 制品读不动 → 不采信任何派生字段（连大小也不写），只把失败打出来
        println("[cjreg] 制品内容提取失败 ${doc.organization}::${doc.name}@${doc.version}: ${files.error}")
        return false
    }
    var changed = false
    // 制品字节数：回源落库时拿不到（索引协议不带 size），下载后顺手补上
    if (overwrite || doc.tarballSize == 0) {
        if (doc.tarballSize != tarball.size) {
            doc.tarballSize = tarball.size
            changed = true
        }
    }
    if (!files.readme.isEmpty() && (overwrite || doc.readme.isEmpty())) {
        if (doc.readme != files.readme) {
            doc.readme = files.readme
            changed = true
            println("[cjreg] 补齐 README ${doc.organization}::${doc.name}@${doc.version}（${files.readme.size} 字节）")
        }
    }
    if (doc.readme.isEmpty()) {
        println("[cjreg] 制品内无 README ${doc.organization}::${doc.name}@${doc.version}（${files.note}）")
    }
    if (files.cjpmToml.isEmpty()) {
        return changed
    }
    let m = parseCjpmDisplayMeta(files.cjpmToml)
    if (!m.ok()) {
        println("[cjreg] cjpm.toml 解析失败 ${doc.organization}::${doc.name}@${doc.version}: ${m.error}")
        return changed
    }
    if (!m.description.isEmpty() && (overwrite || doc.description.isEmpty())) {
        if (doc.description != m.description) {
            doc.description = m.description
            changed = true
        }
    }
    if (overwrite || doc.repository.isEmpty()) {
        doc.repository = m.repository
    }
    if (overwrite || doc.homepage.isEmpty()) {
        doc.homepage = m.homepage
    }
    if (overwrite || doc.documentation.isEmpty()) {
        doc.documentation = m.documentation
    }
    if (overwrite || doc.authors.isEmpty()) {
        doc.authors = m.authors
    }
    if (overwrite || doc.tag.isEmpty()) {
        doc.tag = m.tag
    }
    if (overwrite || doc.category.isEmpty()) {
        doc.category = m.category
    }
    if (overwrite || doc.license.isEmpty()) {
        doc.license = m.license
    }
    if (m.outputType == "executable") {
        doc.executable = true
    }
    return changed
}

// 制品流经本地（下载/回源成功）时补齐该版本文档
//
// 只在真缺字段时才解压：补齐过的文档后续下载不再重复解压。
// 返回是否发生了变更并落库。
public func enrichDocByVersion(pkgStore: PackageStore, org: String, name: String, version: String,
                               bytes: Array<Byte>): Bool {
    for (d in pkgStore.listVersions(org, name)) {
        if (d.version != version || d.deletedAt != 0) {
            continue
        }
        if (!needsArtifactEnrich(d)) {
            return false
        }
        if (enrichDocFromArtifact(d, bytes)) {
            pkgStore.save(d)
            return true
        }
        return false
    }
    return false
}

// 补齐上报
public class SyncReport {
    public var packages: Int64 = 0
    // 补了「本仓收录时间」的版本文档数（存量回源文档 createdAt 为 0 → 公开页显示「未知」）
    public var stamped: Int64 = 0
    public var candidates: Int64 = 0   // 需要补齐的版本数
    public var enriched: Int64 = 0     // 实际补齐到东西的版本数
    public var unchanged: Int64 = 0    // 制品里也没有可补内容（如既无 README 也无 cjpm.toml 字段）
    public var unresolved: Int64 = 0   // 制品取不到（本地无 blob 且回源失败）
    // 补完后的余额（按列表页真用得上的字段分列）
    public var missingReadme: Int64 = 0
    public var missingDesc: Int64 = 0
    public var missingLicense: Int64 = 0
    public var stillIncomplete: Int64 = 0  // 仍有任一展示字段为空

    public init() {}
}

// 存量回捞：遍历包文档，把缺展示字段/README 的版本从制品里补齐
//
// all=false（默认）只处理每个包的最新版本 —— 列表页展示用它，网络开销最小；
// all=true 处理所有版本（详情页的版本行会一起变全）。
// 制品优先取本地 blob；没有则回源下载（会落 blob，供发布计划复用）。
public func syncPackageMetadata(pkgStore: PackageStore, blobStore: BlobStore, proxy: ProxyService,
                                all: Bool): SyncReport {
    let report = SyncReport()
    // 分组：org::name → 各版本文档
    let keys = ArrayList<String>()
    let groups = ArrayList<ArrayList<PackageDoc>>()
    for (d in pkgStore.storm.all<PackageDoc>()) {
        if (d.deletedAt != 0) {
            continue
        }
        let key = d.organization + "::" + d.name
        var idx: Int64 = -1
        for (i in 0..keys.size) {
            if (keys[i] == key) {
                idx = i
                break
            }
        }
        if (idx < 0) {
            keys.add(key)
            groups.add(ArrayList<PackageDoc>())
            idx = keys.size - 1
        }
        groups[idx].add(d)
    }
    // 0. 先补「本仓收录时间」：与制品无关，纯存量数据（回源落库早于本字段）
    //    只补 createdAt，不动 updatedAt —— 否则「最近更新」排序会被回捞时刻全部顶乱
    let stampNow = nowMsUtc()
    for (d in pkgStore.storm.all<PackageDoc>()) {
        if (d.deletedAt != 0 || d.createdAt > 0) {
            continue
        }
        d.createdAt = stampNow
        pkgStore.save(d)
        report.stamped++
    }
    for (i in 0..keys.size) {
        report.packages++
        let docs = groups[i]
        var targets = docs
        if (!all) {
            // 只留最新版本（与公开列表口径一致：compareVersions 取最大）
            var newest = docs[0]
            for (d in docs) {
                if (compareVersions(d.version, newest.version) > 0) {
                    newest = d
                }
            }
            targets = ArrayList<PackageDoc>([newest])
        }
        for (d in targets) {
            if (!needsArtifactEnrich(d)) {
                continue
            }
            report.candidates++
            // 本地 blob 优先；没有则回源（fetchArtifact 内部会把制品落 blob，并顺手补齐）
            var bytes: ?Array<Byte> = None
            if (!d.sha256.isEmpty()) {
                bytes = blobStore.get(d.sha256)
            }
            if (bytes.isNone()) {
                let (_, fetched, _) = proxy.fetchArtifact(d.organization, d.name, d.version)
                bytes = fetched
            }
            // fetchArtifact 命中时会就地补齐并落库（那是另一份对象）→ 重读当前文档再判断，
            // 否则会对同一版本重复解压、重复打补齐日志
            let cur = match (pkgStore.getById(d.id)) {
                case Some(x) => x
                case None => d
            }
            match (bytes) {
                case Some(b) =>
                    if (!needsArtifactEnrich(cur)) {
                        report.enriched++  // 已由 fetchArtifact 补齐
                    } else if (enrichDocFromArtifact(cur, b)) {
                        pkgStore.save(cur)
                        report.enriched++
                    } else {
                        report.unchanged++
                    }
                case None =>
                    println("[cjreg] 制品取不到 ${cur.organization}::${cur.name}@${cur.version}（本地无 blob 且回源失败）")
                    report.unresolved++
            }
            // 余额：按「列表页真用得上的字段」分别统计（tag/category 等制作者没写就是没有）
            if (cur.readme.isEmpty()) { report.missingReadme++ }
            if (cur.description.isEmpty()) { report.missingDesc++ }
            if (cur.license.isEmpty()) { report.missingLicense++ }
            if (needsArtifactEnrich(cur)) { report.stillIncomplete++ }
        }
    }
    return report
}
