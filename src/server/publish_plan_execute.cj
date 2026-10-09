// 发布计划 · 执行域：PublishExecutor（逐个推送 / 退避重试 / 依赖门 / 索引等待编排 / 批次末尾统一确认）
// 与它用到的发布体组装、结果文案、发布 URL 拼接
package ystyle::cjreg.server

import ystyle::cjreg.index.*
import ystyle::cjreg.store.*
import graph.*
import ystyle::cjreg.config.*
import ystyle::cjreg.semver_range.*
import stdx.encoding.json.stream.*
import std.io.*
import std.collection.*

// 构造官方发布二进制段 [version(1B)][size(4B LE)][data]
func makePublishSection(version: UInt8, data: Array<Byte>): Array<Byte> {
    let buf = ArrayList<Byte>()
    buf.add(version)
    let size = data.size
    buf.add(UInt8(size & 0xFF))
    buf.add(UInt8((size >> 8) & 0xFF))
    buf.add(UInt8((size >> 16) & 0xFF))
    buf.add(UInt8((size >> 24) & 0xFF))
    for (b in data) {
        buf.add(b)
    }
    return buf.toArray()
}

// 发布计划执行引擎：按拓扑顺序把本地包推送到目标上游
public class PublishExecutor {
    public var pkgStore: PackageStore
    public var blobStore: BlobStore

    public init(pkgStore: PackageStore, blobStore: BlobStore) {
        this.pkgStore = pkgStore
        this.blobStore = blobStore
    }

    // 执行：对 items（拓扑序）逐个推送。
    //
    // 状态码语义（对齐官方仓返回码规格）：
    //   200        成功
    //   400 / 404  该项失败（元数据/制品/路径问题，重试无用）→ 继续下一项
    //   401 / 403  认证 / 权限 → **中止整个计划**（后面每一项都会同样失败）
    //   409        目标仓已有同版本不同制品 → 该项**跳过**（需升版或先处理目标仓）→ 继续
    //   429        每日请求频率超限 → **中止整个计划**（保存进度，明日再执行）
    //   >=500 / 网络异常  服务器/连接故障 → 退避重试至多 MaxRetries 次，仍失败判该项失败
    //
    // poster：出网 POST 的注入点（单测用桩，默认走真实 HTTP）。
    public func execute(items: ArrayList<PlanItem>, targetUrl: String, token: String,
                        onItem!: (PlanItem, Bool, String) -> Unit = { _, _, _ => () },
                        poster!: (String, Array<Byte>, String) -> (Bool, Int64, String) = { u, b, t =>
                            httpPostBinary(u, b, t)
                        },
                        indexProbe!: ?(String, String) -> IndexProbe = None,
                        pollTimeoutSec!: Int64 = 0,
                        // 等待节奏可注入：单测用秒级阶梯，生产用 IndexWaitLadder
                        indexWaitLadder!: Array<Int64> = IndexWaitLadder,
                        indexWaitSteadySec!: Int64 = IndexWaitSteadySec,
                        shouldCancel!: () -> Bool = { => false },
                        // 「该项是否已被手动跳过」：由调用方按 pkgId 查（存储里的 item 状态）。
                        // 之所以注入而不是在 execute 里查存储：执行器不持有管理存储，
                        // 且计划详情页在执行**过程中**标记跳过时，这一路径能即时生效。
                        shouldSkip!: (Int64) -> Bool = { _ => false }): ExecuteReport {
        let report = ExecuteReport()
        report.total = items.size
        let MaxRetries: Int64 = 3

        // 执行顺序**现算**：按 items 当前的依赖声明做拓扑排序（graph-cj），
        // 计划里的 `order` 只当同层先后的兜底 —— 建计划那一刻的快照会过期
        // （依赖边解析错过一次、或依赖后来改了，冻结的顺序就会一直错下去）。
        let sorted = planExecutionOrder(items, this.pkgStore)

        // 计划内依赖关系 + "目标仓里还没就绪"的项集合。
        // 只有（直接/间接）依赖这些项的项才该被卡住，与它们无关的项照发。
        let edges = planDependencyEdges(sorted, this.pkgStore)
        let unavailable = HashSet<Int64>()
        let labelOf = HashMap<Int64, String>()
        for (it in sorted) {
            labelOf[it.pkgId] = packageLabel(it.org, it.name, it.version)
        }

        // 哪些项的索引必须**原地等**：被别人依赖的那些。
        // 依赖方推上去时目标仓要能解析到它，索引没就绪就推 = 悬空依赖（实测会换来假失败），
        // 所以这一步省不掉。反过来说，**没人依赖的项（叶子）原地等索引只是"确认已进仓"**：
        // 推送返回 200 时内容就已经进去了，索引只是"我们看见没看见" —— 攒到本批末尾一起确认，
        // 别让整批为它停住（中心仓索引同步几十分钟到几天是常态，N 项各等一轮 = N 倍等待）。
        let inlineWait = HashSet<Int64>()
        for (it in sorted) {
            if (!it.selected || it.status == PlanItemStatus.Completed) {
                continue
            }
            collectDeployDependents(edges, it.pkgId, inlineWait)
        }
        // 已推送、只差索引确认的叶子项：批次末尾统一确认（见 confirmDeferred）
        let deferred = ArrayList<PlanItem>()

        var idx: Int64 = 0
        while (idx < sorted.size) {
            let it = sorted[idx]
            // 用户点了「停止执行」→ 收口成"中止"：剩下的项走已有的 aborted 分支统一记「未推送」
            if (!report.aborted && shouldCancel()) {
                report.aborted = true
                report.abortReason = "用户已停止执行"
            }
            // 依赖里有"发失败"或"索引一直没出现"的项 → 这项现在发上去也是缺依赖，直接说明原因
            var blockedBy: Int64 = 0
            for (d in transitivePlanDeps(it.pkgId, edges)) {
                if (unavailable.contains(d)) {
                    blockedBy = d
                    break
                }
            }
            if (blockedBy != 0) {
                it.status = PlanItemStatus.Skipped
                let bad = match (labelOf.get(blockedBy)) {
                    case Some(s) => s
                    case None => "#${blockedBy}"
                }
                it.error = "依赖 ${bad} 未在目标仓就绪，本次不推送（它发成功后重新执行本计划即可）"
                report.skipped++
                onItem(it, true, it.error)
                idx++
                continue
            }
            if (report.aborted) {
                // 中止后剩余项统一记成「未推送（计划已中止）」，避免看起来像各自失败了
                it.status = PlanItemStatus.Skipped
                it.error = "计划已中止：${report.abortReason}"
                report.skipped++
                onItem(it, true, it.error)
                idx++
                continue
            }
            if (it.status == PlanItemStatus.Skipped || shouldSkip(it.pkgId)) {
                // 手动跳过（执行前标记，或执行中由 shouldSkip 即时反映）：不推送、不计失败
                it.status = PlanItemStatus.Skipped
                it.error = "手动跳过"
                report.skipped++
                onItem(it, true, it.error)
                idx++
                continue
            }
            if (!it.selected) {
                it.status = PlanItemStatus.Skipped
                it.error = unselectedReason(it)
                report.skipped++
                onItem(it, true, it.error)
                idx++
                continue
            }
            if (it.status == PlanItemStatus.Completed) {
                // 续跑（计划被中止后再次执行）时跳掉已成功的项：重复推同一版本只会换回 409
                it.error = "已完成：跳过"
                report.skipped++
                onItem(it, true, it.error)
                idx++
                continue
            }
            // 取本地包文档（含 meta + sha）
            let doc = match (this.pkgStore.getById(it.pkgId)) {
                case Some(d) => d
                case None =>
                    it.status = PlanItemStatus.Failed
                    it.error = "包文档不存在"
                    report.failed++
                    report.errors.add("pkg#${it.pkgId} 不存在")
                    onItem(it, false, it.error)
                    idx++
                    continue
            }
            let sha = extractSha256(doc.indexJson)
            if (sha.isEmpty()) {
                it.status = PlanItemStatus.Failed
                it.error = "无 sha256sum"
                report.failed++
                report.errors.add("${doc.name}@${doc.version}: 无 sha256sum")
                onItem(it, false, it.error)
                idx++
                continue
            }
            let tar = match (this.blobStore.get(sha)) {
                case Some(b) => b
                case None =>
                    it.status = PlanItemStatus.Failed
                    it.error = "制品缺失（sha=${sha}）"
                    report.failed++
                    report.errors.add("${doc.name}@${doc.version}: 制品缺失（sha=${sha}）")
                    onItem(it, false, it.error)
                    idx++
                    continue
            }
            // 组装官方发布二进制 [meta][tar]
            let metaBytes = doc.indexJson.toArray()
            let body = ArrayList<Byte>()
            for (b in makePublishSection(UInt8(1), metaBytes)) {
                body.add(b)
            }
            for (b in makePublishSection(UInt8(1), tar)) {
                body.add(b)
            }
            let url = buildPackagePublishURL(targetUrl, doc.name, doc.organization)
            // 续跑语义：状态是「等待索引」的项上一次**已经推成功了**，只是索引还没同步。
            // 这种项不能重推——同版本重推只会换回 409，还会被误判成「目标仓已有同版本不同制品」，
            // 于是直接进入等待分支，继续等依赖就绪。
            let alreadyPushed = (it.status == PlanItemStatus.WaitingIndex)
            var ok = alreadyPushed
            var code: Int64 = 0
            var text = ""
            if (alreadyPushed) {
                it.status = PlanItemStatus.WaitingIndex
                onItem(it, true, "已推送过，继续等目标仓索引就绪")
            } else {
                it.status = PlanItemStatus.Publishing
                onItem(it, true, "推送中")
                var attempt: Int64 = 0
                while (attempt < MaxRetries) {
                    attempt++
                    let (o, c, t) = poster(url, body.toArray(), token)
                    ok = o
                    code = c
                    text = t
                    if (ok || !isRetryable(code)) {
                        break
                    }
                    if (attempt < MaxRetries) {
                        // 退避：500ms / 1s（服务器故障多为瞬时）
                        sleep(Duration.millisecond * 500 * attempt)
                    }
                }
            }
            if (ok && !inlineWait.contains(it.pkgId)) {
                // 叶子项：没有下游，索引确认不影响任何后续推送 → 推成功就往下走，
                // 攒到本批末尾一次性确认（confirmDeferred）。
                it.status = PlanItemStatus.WaitingIndex
                it.error = DEFER_INDEX_MSG
                report.waitingIndex++
                deferred.add(it)
                onItem(it, true, it.error)
            } else if (ok) {
                // 推送成功后还要**等目标仓索引就绪**才算完成：
                // 拓扑序里下一条依赖这一条，而中心仓的索引/缓存同步可能很慢
                // （几十分钟到几天，审核还可能更久）。不等就推下一条，会出现「依赖还没出现在
                // 索引里」的假失败，或者推到一半自己把自己卡住。
                //
                // 默认**不设总超时**（pollTimeoutSec <= 0）：没出现就是还没同步到，继续等；
                // 只有探测本身失败（401/403/429/5xx/网络）或用户点停止才收工。
                let lastProbe = Box<IndexProbe>(IndexProbe(404, ""))
                var waitCode = WAIT_READY
                match (indexProbe) {
                    case Some(probe) =>
                        it.status = PlanItemStatus.WaitingIndex
                        onItem(it, true, "等待目标仓索引就绪")
                        waitCode = waitIndexReady(probe, doc.organization, doc.name, doc.version, pollTimeoutSec,
                            sha: doc.sha256, shouldCancel: shouldCancel,
                            ladder: indexWaitLadder, steadySec: indexWaitSteadySec,
                            onWaiting: { waited, step, res =>
                                lastProbe.value = res
                                // 每轮把「已等多久 / 下一轮什么时候再探」写进条目说明：
                                // 否则界面只有一句「等待索引」，看不出是在正常等还是卡住了
                                let mins = waited / 60
                                onItem(it, true,
                                    "等待目标仓索引就绪（已等 ${mins} 分钟，${step} 秒后再探；最近一次：${res.describe()}）")
                            })
                    case None => ()
                }
                if (waitCode == WAIT_CANCELLED) {
                    // 用户在等索引期间点了停止：内容已经推上去了，记「等索引」并中止，
                    // 续跑时也是从这里接着等（不会重推）
                    it.status = PlanItemStatus.WaitingIndex
                    it.error = "等待索引期间用户停止执行：已推送成功，续跑会继续等"
                    report.waitingIndex++
                    unavailable.add(it.pkgId)
                    report.aborted = true
                    // 计划级原因只写「用户停止」：这句会被盖到**所有未处理项**的说明上，
                    // 而"谁在等索引"是该条目自己的事（it.error 已写清 1327 行）。
                    // 曾经把「holt@1.0.8 已推送成功，正在等目标仓索引」拼进计划级原因，
                    // 结果与 holt 毫无依赖关系的 bstorm/sunku/tsdb 也显示这句，
                    // 看起来像被 holt 的索引卡住了。
                    report.abortReason = "用户已停止执行"
                    onItem(it, false, it.error)
                } else if (waitCode == WAIT_READY) {
                    report.success++
                    it.status = PlanItemStatus.Completed
                    it.error = ""
                    onItem(it, true, "")
                } else if (waitCode == WAIT_FATAL) {
                    // 索引探测本身失败（401/403/429/5xx/网络）：内容已经推上去了，只是"索引里有"
                    // 这件事问不出来 → 记「等索引」而不是失败（重推只会换回 409）。
                    let res = lastProbe.value
                    it.status = PlanItemStatus.WaitingIndex
                    it.error = "索引确认失败（${res.describe()}）：已推送成功，稍后点「检查索引」再确认"
                    report.waitingIndex++
                    unavailable.add(it.pkgId)
                    report.errors.add("${doc.name}@${doc.version}: ${it.error}")
                    if (res.planFatal()) {
                        // 认证/权限/频率超限：与推送阶段同一判据 —— 继续跑整个计划也是白费。
                        // 已推送成功的项不受影响，暂停后可以「检查索引」或次日「继续执行」。
                        report.aborted = true
                        report.abortReason = "目标仓 ${res.describe()}：计划已暂停（已推送的项不受影响）"
                        onItem(it, false, it.error)
                    } else {
                        onItem(it, true, it.error)
                    }
                } else {
                    // 走到这里只有一种情况：配置了「索引等待上限」且等满了（可选保险丝）。
                    // 记「等索引」不是失败：内容其实已经推上去了，只是还没同步（中心仓同步慢、
                    // 或审核没过）。续跑时据此**不再重推**，只继续等。
                    //
                    // **不中止整个计划**：只有依赖它的项会被卡住（下面的 blockedBy 逻辑），
                    // 与它无关的项该发还是要发。以前这里 `aborted = true`，实测把不依赖
                    // 出问题那一项的包（bstorm 之于 tsdb）一起卡死了。
                    it.status = PlanItemStatus.WaitingIndex
                    it.error = "已等满索引等待上限（${pollTimeoutSec}s）：${doc.name}@${doc.version} 还没出现在目标仓索引里（已推送成功，续跑会继续等；可把上限设为 0 表示一直等）"
                    report.waitingIndex++
                    unavailable.add(it.pkgId)
                    report.errors.add("${doc.name}@${doc.version}: ${it.error}")
                    onItem(it, false, it.error)
                }
            } else {
                match (code) {
                    case 409 =>
                        // 目标仓已有同版本不同制品：不是「失败」，而是「这次发不上去」
                        it.status = PlanItemStatus.Skipped
                        it.error = "409 目标仓已有同版本不同制品（需升版后重发）${bodyTail(text)}"
                        report.skipped++
                        onItem(it, true, it.error)
                    case 401 | 403 =>
                        it.status = PlanItemStatus.Skipped
                        it.error = "${code} 目标仓认证/权限失败，计划已中止${bodyTail(text)}"
                        report.skipped++
                        report.aborted = true
                        report.abortReason = "${code} 认证/权限失败：请检查发布 Token 与组织权限"
                        report.errors.add("${doc.name}@${doc.version}: ${it.error}")
                        onItem(it, false, it.error)
                    case 429 =>
                        it.status = PlanItemStatus.Skipped
                        it.error = "429 每日请求频率超限，计划已中止${bodyTail(text)}"
                        report.skipped++
                        report.aborted = true
                        report.abortReason = "429 每日请求频率超限：进度已保存，请次日再执行剩余项"
                        report.errors.add("${doc.name}@${doc.version}: ${it.error}")
                        onItem(it, false, it.error)
                    case _ =>
                        it.status = PlanItemStatus.Failed
                        it.error = "HTTP ${code}${bodyTail(text)}"
                        if (code == 0) {
                            it.error = "推送失败（网络/连接）：${text}"
                        }
                        report.failed++
                        // 它没进目标仓：依赖它的项这次也不该发（发了就是缺依赖的包）
                        unavailable.add(it.pkgId)
                        report.errors.add("${doc.name}@${doc.version}: ${it.error}")
                        onItem(it, false, it.error)
                }
            }
            idx++
        }
        // 批次末尾：把所有"已推送、只差索引"的叶子项一起确认。
        // 一轮探测覆盖全部待确认项（而不是每项各等一轮）——这就是"没有下游的项不原地等，
        // 到最后一起等"的落点。计划已中止或没接索引探测时按 confirmDeferred 的说明处理。
        if (deferred.size > 0) {
            this.confirmDeferred(deferred, report, indexProbe, pollTimeoutSec, shouldCancel,
                indexWaitLadder, indexWaitSteadySec, onItem)
        }
        return report
    }

    // 批次末尾统一确认「已推送、只差索引」的叶子项。
    //
    // 攒到最后的依据：这些项没有任何下游 —— 它们的索引只决定"我们看见没看见"，
    // 不影响任何后续推送；而中心仓索引同步可能几十分钟到几天，逐项原地等会把整批拖成 N 倍。
    // 探测是批量做的（waitIndexesReady），N 项共享 N 轮。
    //
    // 没接索引探测（indexProbe = None）时直接判完成：与旧行为一致，没有探测能力就没有"确认"一说。
    // 计划已在推送阶段中止（429/401/用户停止）时不在这里空等：内容都已推出去，
    // 保持「等索引」即可（= 已推送成功、续跑接着确认）。
    func confirmDeferred(deferred: ArrayList<PlanItem>, report: ExecuteReport,
                         indexProbe: ?(String, String) -> IndexProbe, pollTimeoutSec: Int64,
                         shouldCancel: () -> Bool, ladder: Array<Int64>, steadySec: Int64,
                         onItem: (PlanItem, Bool, String) -> Unit): Unit {
        if (indexProbe.isNone()) {
            for (it in deferred) {
                this.markIndexConfirmed(it, report, onItem, "")
            }
            return
        }
        if (report.aborted) {
            for (it in deferred) {
                it.status = PlanItemStatus.WaitingIndex
                it.error = "计划已中止，索引确认留到续跑（内容已推送成功）"
                onItem(it, true, it.error)
            }
            return
        }
        let probe = indexProbe.getOrThrow()
        let targets = ArrayList<(String, String, String)>()
        let targetShas = ArrayList<String>()
        for (it in deferred) {
            targets.add((it.org, it.name, it.version))
            targetShas.add(it.localSha256)
        }
        let lastProbe = Box<IndexProbe>(IndexProbe(404, ""))
        let (ready, code) = waitIndexesReady(probe, targets, pollTimeoutSec,
            shouldCancel: shouldCancel,
            onWaiting: { waited, step, res =>
                lastProbe.value = res
                let mins = waited / 60
                let text = "等待目标仓索引就绪（已等 ${mins} 分钟，${step} 秒后再探；最近一次：${res.describe()}）"
                for (it in deferred) {
                    onItem(it, true, text)
                }
            },
            ladder: ladder, steadySec: steadySec, shas: targetShas)
        if (code == WAIT_CANCELLED) {
            // 与"等单项索引时被停止"同一语义：内容已推出去，记「等索引」，续跑接着确认
            report.aborted = true
            report.abortReason = "用户已停止执行"
        } else if (code == WAIT_FATAL && lastProbe.value.planFatal()) {
            report.aborted = true
            report.abortReason = "目标仓 ${lastProbe.value.describe()}：计划已暂停（已推送的项不受影响）"
        }
        for (i in 0..deferred.size) {
            let it = deferred[i]
            if (ready[i]) {
                this.markIndexConfirmed(it, report, onItem, "")
            } else {
                it.status = PlanItemStatus.WaitingIndex
                it.error = deferredPendingMsg(code, lastProbe.value, pollTimeoutSec, it)
                report.errors.add("${it.name}@${it.version}: ${it.error}")
                onItem(it, false, it.error)
            }
        }
    }

    // 索引确认通过 → 该项才算完成。defer 时按「等索引」记过一次，这里换算成成功。
    func markIndexConfirmed(it: PlanItem, report: ExecuteReport,
                            onItem: (PlanItem, Bool, String) -> Unit, msg: String): Unit {
        it.status = PlanItemStatus.Completed
        it.error = msg
        if (report.waitingIndex > 0) {
            report.waitingIndex--
        }
        report.success++
        onItem(it, true, msg)
    }
}

// 服务器故障/网络异常可重试；4xx 一律不重试（重试也还是同一个结果，还会白烧配额）
func isRetryable(code: Int64): Bool {
    code == 0 || code >= 500
}

// 把目标仓返回的正文尾部拼进错误文案（正文里是官方仓的原因说明）
func bodyTail(text: String): String {
    if (text.isEmpty()) {
        return ""
    }
    ": ${text}"
}

// 目标上游发布 URL：POST /pkg/{name}?organization={org}
public func buildPackagePublishURL(targetUrl: String, name: String, org: String): String {
    var base = targetUrl
    // 去掉末尾斜杠
    while (base.endsWith("/")) {
        base = base[0..base.size - 1]
    }
    if (org.isEmpty()) {
        return "${base}/pkg/${name}"
    }
    return "${base}/pkg/${name}?organization=${org}"
}
