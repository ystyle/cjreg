package ystyle::cjreg.server

import std.collection.HashMap
import std.sync.Mutex

// ============ 登录失败限速 ============
//
// 安全测试报告 5.6：/api/admin/login 连续 30 次错误口令全部 401，无 429/无锁定，
// 可在线撞库。这里按 (用户名|来源 IP) 做窗口内计数，超阈值直接拒绝。
//
// 内存态：进程重启即清空。撞库的时间尺度远小于重启频率，够用；
// 多实例部署时应换成共享存储（当前部署是单实例）。

class FailWindow {
    var count: Int64
    var firstAtMs: Int64

    init(count: Int64, firstAtMs: Int64) {
        this.count = count
        this.firstAtMs = firstAtMs
    }
}

public class LoginLimiter {
    let maxFailures: Int64
    let windowMs: Int64
    let lock = Mutex()
    let fails = HashMap<String, FailWindow>()

    public init(maxFailures!: Int64 = 5, windowMs!: Int64 = 300000) {
        this.maxFailures = maxFailures
        this.windowMs = windowMs
    }

    /// 当前是否已被限速（不改变计数）
    public func isBlocked(key: String, nowMs: Int64): Bool {
        this.lock.lock()
        try {
            match (this.fails.get(key)) {
                case Some(w) =>
                    if (nowMs - w.firstAtMs > this.windowMs) {
                        this.fails.remove(key)
                        return false
                    }
                    return w.count >= this.maxFailures
                case None => return false
            }
        } finally {
            this.lock.unlock()
        }
    }

    /// 记一次失败；窗口过期则重新开窗
    public func recordFailure(key: String, nowMs: Int64): Unit {
        this.lock.lock()
        try {
            match (this.fails.get(key)) {
                case Some(w) =>
                    if (nowMs - w.firstAtMs > this.windowMs) {
                        w.count = 1
                        w.firstAtMs = nowMs
                    } else {
                        w.count += 1
                    }
                case None =>
                    this.fails.add(key, FailWindow(1, nowMs))
            }
        } finally {
            this.lock.unlock()
        }
    }

    /// 登录成功后清零
    public func reset(key: String): Unit {
        this.lock.lock()
        try {
            this.fails.remove(key)
        } finally {
            this.lock.unlock()
        }
    }
}
