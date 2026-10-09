// 发布计划 · 索引确认域：目标仓索引的一次性检查与阶梯轮询等待（单项 / 批量），
// 以及「版本已出现且 sha 一致」的判据与收口文案
package ystyle::cjreg.server

import ystyle::cjreg.index.*
import ystyle::cjreg.store.*
import graph.*
import ystyle::cjreg.config.*
import ystyle::cjreg.semver_range.*
import stdx.encoding.json.stream.*
import std.io.*
import std.collection.*

// 「检查索引」的结果
public class IndexCheckResult {
    public var checked: Int64 = 0          // 探测到了几个（含"目标仓确实没有"的 404）
    public var unreachable: Int64 = 0      // 探测本身失败的个数（401/403/429/5xx/网络）
    public var ready: ArrayList<Int64> = ArrayList<Int64>()   // 已在目标仓索引里的输入下标
    public var detail: String = ""         // 探测失败的最近一次原因（进文案）

    public init() {}
}

// 一次性检查若干 (org, name, version) 是否已出现在目标仓索引里。
//
// 用途：计划里那些「已推送成功、在等索引」的项，不该逼用户再点一次「继续执行」干等
// 一个轮询周期。这里只探一次：命中的就可以直接标成发布完成。
// 「目标仓到底有没有」永远是**现查**的（不在包记录上打标记），所以这个动作随时可重放。
//
// 探测失败与"目标仓没有这个版本"必须分开计数：404 是"确实没有"（继续等/等审核），
// 401/429/5xx 是"没问到"（得先解决认证/频率/服务问题），混在一起会让人以为在等一件不会发生的事。
public func checkVersionsInIndex(targets: ArrayList<(String, String, String)>,
                                 probe: (String, String) -> IndexProbe): IndexCheckResult {
    let r = IndexCheckResult()
    for (i in 0..targets.size) {
        let (org, name, version) = targets[i]
        let res = probe(org, name)
        if (res.ok()) {
            r.checked++
            if (indexHasVersion(res.body, name, version)) {
                r.ready.add(i)
            }
        } else if (res.status == 404) {
            r.checked++
        } else {
            r.unreachable++
            if (r.detail.isEmpty()) {
                r.detail = res.describe()
            }
        }
    }
    r
}

// 轮询目标仓索引直到出现「该包该版本」。
//
// 节奏：5s → 1m → 1m → 1m → 之后每 5 分钟一轮（见 IndexWaitLadder），**默认不设总超时**：
// 「索引里还没有」不是失败，中心仓索引/缓存同步慢是常态（几十分钟到几天，审核还可能更久），
// 让它一直等才是对的；人随时可以点「停止执行」，探测到 401/403/429/5xx/网络失败也会提前收工
// （那些再等也不会变好）。
//
// pollTimeoutSec > 0 时作为**总等待上限**（可选保险丝）；<= 0 表示不限。
// 返回 WAIT_READY / WAIT_TIMEOUT / WAIT_CANCELLED / WAIT_FATAL。
func waitIndexReady(probe: (String, String) -> IndexProbe, org: String, name: String, version: String,
                    pollTimeoutSec: Int64,
                    sha!: String = "",
                    shouldCancel!: () -> Bool = { => false },
                    onWaiting!: (Int64, Int64, IndexProbe) -> Unit = { _, _, _ => () },
                    ladder!: Array<Int64> = IndexWaitLadder,
                    steadySec!: Int64 = IndexWaitSteadySec): Int64 {
    let one = ArrayList<(String, String, String)>()
    one.add((org, name, version))
    let shas = ArrayList<String>()
    shas.add(sha)
    let (_, code) = waitIndexesReady(probe, one, pollTimeoutSec, shouldCancel: shouldCancel,
        onWaiting: onWaiting, ladder: ladder, steadySec: steadySec, shas: shas)
    return code
}

// 批量版等待：一轮探测覆盖多个待确认项，收口码与 waitIndexReady 同一套语义。
//
// 存在的原因：**没有下游的项**（叶子）不需要各自在原位等索引 —— 索引对它们只是"确认已进仓"。
// 逐项等是 N 项各等一轮（中心仓同步慢时就是 N 倍时长），攒到一起是一轮探 N 项。
// 返回 (每项是否就绪, 收口码)；WAIT_READY 表示**全部**就绪。
func waitIndexesReady(probe: (String, String) -> IndexProbe,
                      targets: ArrayList<(String, String, String)>,
                      pollTimeoutSec: Int64,
                      shouldCancel!: () -> Bool = { => false },
                      onWaiting!: (Int64, Int64, IndexProbe) -> Unit = { _, _, _ => () },
                      ladder!: Array<Int64> = IndexWaitLadder,
                      steadySec!: Int64 = IndexWaitSteadySec,
                      // 与 targets 下标对应的期望 sha256（空串 = 退化为「版本存在」）
                      shas!: ArrayList<String> = ArrayList<String>()): (ArrayList<Bool>, Int64) {
    let ready = ArrayList<Bool>()
    for (_ in targets) {
        ready.add(false)
    }
    var pending = targets.size
    var waited: Int64 = 0
    var round: Int64 = 0
    let t0 = nowMsUtc()  // 用**实际经过时间**计时：等待节奏里 step 可以为 0（紧凑/测试节奏），
    // 此时 `waited += step` 不增长，总超时（pollTimeoutSec）永远不会触发。
    while (pending > 0) {
        if (shouldCancel()) {
            return (ready, WAIT_CANCELLED)
        }
        let step = if (round < ladder.size) { ladder[round] } else { steadySec }
        round++
        if (step > 0) {
            sleep(Duration.second * step)
        } else {
            sleep(Duration.millisecond)  // step=0：至少让出一次，避免忙等打满 CPU
        }
        waited = (nowMsUtc() - t0) / 1000
        var last = IndexProbe(404, "")
        var fatal = false
        for (i in 0..targets.size) {
            if (ready[i]) {
                continue
            }
            let (org, name, version) = targets[i]
            let res = probe(org, name)
            last = res
            if (res.ok()) {
                let expectedSha = if (i < shas.size) { shas[i] } else { "" }
                if (indexHasVersionWithSha(res.body, name, version, expectedSha)) {
                    ready[i] = true
                    pending--
                }
            } else if (res.fatal()) {
                fatal = true
                break
            }
        }
        if (fatal) {
            // 失败的探测也要报给调用方（它要拿状态码决定"要不要把整个计划暂停"）
            onWaiting(waited, step, last)
            return (ready, WAIT_FATAL)
        }
        if (pending == 0) {
            // 就绪的那一轮不再报 onWaiting：回调是给"还在等"的进度用的（与单项版同一语义）
            return (ready, WAIT_READY)
        }
        onWaiting(waited, step, last)
        // 上限判定放在探测之后：等够时长就先探一次再收工（否则"上限 1 秒"会连一次都探不到）
        if (pollTimeoutSec > 0 && waited >= pollTimeoutSec) {
            return (ready, WAIT_TIMEOUT)
        }
    }
    (ready, WAIT_READY)
}

// 批量确认收口后，没等到索引的项该怎么说（收口码 → 文案，与单项等待保持一致）
func deferredPendingMsg(code: Int64, res: IndexProbe, pollTimeoutSec: Int64, it: PlanItem): String {
    if (code == WAIT_CANCELLED) {
        return "等待索引期间用户停止执行：已推送成功，续跑会继续等"
    }
    if (code == WAIT_FATAL) {
        return "索引确认失败（${res.describe()}）：已推送成功，稍后点「检查索引」再确认"
    }
    return "已等满索引等待上限（${pollTimeoutSec}s）：${it.name}@${it.version} 还没出现在目标仓索引里（已推送成功，续跑会继续等；可把上限设为 0 表示一直等）"
}

// 目标仓索引里是否已有该版本（索引是 NDJSON，逐行解析而不是做子串匹配——
// 子串会把 "1.0.1" 误命中成 "1.0.10"）
public func indexHasVersion(indexJson: String, name: String, version: String): Bool {
    for (e in parseNDJSON(indexJson)) {
        if (e.name == name && e.version == version) {
            return true
        }
    }
    false
}

// 「版本已就绪」的完整判据：索引里出现该版本 **且 sha256 与本地制品一致**。
// 只看版本号会误判 —— 目标仓可能先收录过同版本的别的产物（历史重发、上游换过内容），
// 那种情况下推送虽然成功，目标仓对外给的仍是旧内容。
// 兼容：期望 sha 为空、或索引条目没带 sha 时，退化为「版本存在」。
public func indexHasVersionWithSha(indexJson: String, name: String, version: String, sha: String): Bool {
    for (e in parseNDJSON(indexJson)) {
        if (e.name == name && e.version == version) {
            if (sha.isEmpty() || e.sha256sum.isEmpty() || e.sha256sum == sha) {
                return true
            }
        }
    }
    false
}
