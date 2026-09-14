// 「等目标仓索引就绪」的节奏与收工条件。
//
// 出过的毛病：等待是「每 pollInterval 秒探一次、到 pollTimeout 就放弃」，默认 60s/600s。
// 但中心仓索引/缓存同步几十分钟到几天是常态（审核没过甚至更久），600 秒到点就把一项
// 判成「等超时」既不准确也没意义 —— 人会以为这项失败了，其实只是还没同步到。
//
// 现在的口径：
//   节奏 = 5s → 1m → 3m → 5m → 之后每 5m（对齐 cangjie-publish 的 1/3/5 分钟重试）
//   默认**不设总超时**：只有用户点停止、或探测本身失败（400/401/403/429/5xx/网络）才收工
//   pollTimeoutSec > 0 时作为可选的总等待上限（保险丝）
//
// 用例把阶梯注入成秒级，别真等一分钟。
package ystyle::cjreg.server

import std.collection.*

// 记下每轮「等了多久、下一轮多久后再探」，用来验证阶梯确实按 1m/3m/5m 走
func waitRecorder(): (ArrayList<Int64>, (Int64, Int64, IndexProbe) -> Unit) {
    let steps = ArrayList<Int64>()
    let cb: (Int64, Int64, IndexProbe) -> Unit = { _, step, _ =>
        steps.add(step)
    }
    (steps, cb)
}

// 第一轮就查到 → 直接返回就绪，不做多余的等待与探测
@Test
func waitIndexReady_readyOnFirstProbe() {
    let probes = Box<Int64>(0)
    let (steps, cb) = waitRecorder()
    let code = waitIndexReady({ _, _ =>
        probes.value++
        IndexProbe(200, "{\"name\":\"a\",\"version\":\"1.0.0\"}\n")
    }, "", "a", "1.0.0", 0, onWaiting: cb, ladder: [0], steadySec: 0)
    @Expect(code, WAIT_READY)
    @Expect(probes.value, 1)
    @Expect(steps.size, 0)          // 就绪那一轮不回调「还要等」
}

// 阶梯走完后按 steady 秒继续：4 次探测分别等 1、1、1、1（ladder [1,1] + steady 1）
@Test
func waitIndexReady_ladderThenSteady() {
    let probes = Box<Int64>(0)
    let (steps, cb) = waitRecorder()
    let code = waitIndexReady({ _, _ =>
        probes.value++
        if (probes.value < 4) {
            IndexProbe(200, "{\"name\":\"a\",\"version\":\"0.9.0\"}\n")
        } else {
            IndexProbe(200, "{\"name\":\"a\",\"version\":\"1.0.0\"}\n")
        }
    }, "", "a", "1.0.0", 0, onWaiting: cb, ladder: [1, 1], steadySec: 1)
    @Expect(code, WAIT_READY)
    @Expect(probes.value, 4)
    @Expect(steps.size, 3)          // 前三次没查到，各回调一次
    @Expect(steps[0], 1)
    @Expect(steps[1], 1)
    @Expect(steps[2], 1)            // 阶梯用完后按 steadySec
}

// 401（认证失败）→ 立刻收工，不做无谓重试
@Test
func waitIndexReady_authFailureStopsImmediately() {
    let probes = Box<Int64>(0)
    let code = waitIndexReady({ _, _ =>
        probes.value++
        IndexProbe(401, "unauthorized")
    }, "", "a", "1.0.0", 0, ladder: [0], steadySec: 0)
    @Expect(code, WAIT_FATAL)
    @Expect(probes.value, 1)
}

// 429（每日频率超限）与 5xx（服务器故障）同样是"再等也不会变好"
@Test
func waitIndexReady_rateLimitAndServerErrorStop() {
    let c429 = waitIndexReady({ _, _ => IndexProbe(429, "too many") }, "", "a", "1.0.0", 0,
        ladder: [0], steadySec: 0)
    @Expect(c429, WAIT_FATAL)
    let c500 = waitIndexReady({ _, _ => IndexProbe(503, "bad gateway") }, "", "a", "1.0.0", 0,
        ladder: [0], steadySec: 0)
    @Expect(c500, WAIT_FATAL)
    let net = waitIndexReady({ _, _ => IndexProbe(0, "", detail: "connection refused") }, "", "a", "1.0.0", 0,
        ladder: [0], steadySec: 0)
    @Expect(net, WAIT_FATAL)
}

// 404（还没同步到）**不算失败**：默认没有总超时，会一直探下去，直到用户点停止。
// 这里用"探 4 次后请求取消"来证明它确实在继续探（如果还按老的超时语义，第一次就该收工了）。
@Test
func waitIndexReady_keepsPollingWithoutTimeout() {
    let probes = Box<Int64>(0)
    let code = waitIndexReady({ _, _ =>
        probes.value++
        IndexProbe(404, "")
    }, "", "a", "1.0.0", 0,
        shouldCancel: { => probes.value >= 4 },
        ladder: [0], steadySec: 0)
    @Expect(code, WAIT_CANCELLED)
    @Expect(probes.value, 4)        // 没有超时，一直探到用户取消
}

// 显式设了「索引等待上限」时它才生效（可选保险丝）：ladder [1,1,...] + 上限 2 秒
@Test
func waitIndexReady_honorsOptionalCap() {
    let probes = Box<Int64>(0)
    let code = waitIndexReady({ _, _ =>
        probes.value++
        IndexProbe(404, "")
    }, "", "a", "1.0.0", 2, ladder: [1, 1, 1], steadySec: 1)
    @Expect(code, WAIT_TIMEOUT)
    // 等够时长先探一次再收工：两轮各探一次（第一轮 1s 后、第二轮凑满 2s 上限）
    @Expect(probes.value, 2)
}

// 旧计划（老语义的出厂默认 60s/600s）按新语义迁成"一直等"；用户改过的不动
@Test
func legacyPollDefaults_onlyMatchesUntouchedDefaults() {
    @Expect(legacyPollDefaults(60, 600), true)
    @Expect(legacyPollDefaults(60, 0), false)
    @Expect(legacyPollDefaults(30, 600), false)
    @Expect(legacyPollDefaults(60, 1800), false)
}

// 生产节奏就是 5 秒 → 1 分钟 → 3 分钟 → 5 分钟，之后每 5 分钟（配置本身就是契约）
@Test
func indexWaitLadder_matchesPublishSkillRhythm() {
    @Expect(IndexWaitLadder.size, 4)
    @Expect(IndexWaitLadder[0], 5)
    @Expect(IndexWaitLadder[1], 60)
    @Expect(IndexWaitLadder[2], 180)
    @Expect(IndexWaitLadder[3], 300)
    @Expect(IndexWaitSteadySec, 300)
}

// 探测结果的收工判据（对齐官方返回码表）
@Test
func indexProbe_fatalJudgement() {
    @Expect(IndexProbe(200, "").fatal(), false)
    @Expect(IndexProbe(200, "").ok(), true)
    @Expect(IndexProbe(404, "").fatal(), false)      // 还没同步到：继续等
    @Expect(IndexProbe(409, "").fatal(), false)
    @Expect(IndexProbe(400, "").fatal(), true)
    @Expect(IndexProbe(401, "").fatal(), true)
    @Expect(IndexProbe(403, "").fatal(), true)
    @Expect(IndexProbe(429, "").fatal(), true)
    @Expect(IndexProbe(500, "").fatal(), true)
    @Expect(IndexProbe(503, "").fatal(), true)
    @Expect(IndexProbe(0, "", detail: "boom").fatal(), true)
    // 401/403/429 会把整个计划暂停；5xx/网络只让这一项等索引（目标仓抖动，别人还能发）
    @Expect(IndexProbe(401, "").planFatal(), true)
    @Expect(IndexProbe(429, "").planFatal(), true)
    @Expect(IndexProbe(500, "").planFatal(), false)
    @Expect(IndexProbe(0, "", detail: "boom").planFatal(), false)
    @Expect(IndexProbe(0, "", detail: "boom").describe(), "网络不可达：boom")
    @Expect(IndexProbe(503, "").describe(), "HTTP 503")
}
