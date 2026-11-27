package ystyle::cjreg.server

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class LoginLimiterTest {

    @TestCase
    public func testBlocksAfterThreshold(): Unit {
        let l = LoginLimiter(maxFailures: 3, windowMs: 1000)
        let k = "admin|1.2.3.4"
        @Expect(l.isBlocked(k, 0), false)
        l.recordFailure(k, 0)
        l.recordFailure(k, 10)
        @Expect(l.isBlocked(k, 20), false)
        l.recordFailure(k, 20)
        @Expect(l.isBlocked(k, 30), true)
    }

    @TestCase
    public func testWindowExpires(): Unit {
        let l = LoginLimiter(maxFailures: 2, windowMs: 1000)
        let k = "admin|1.2.3.4"
        l.recordFailure(k, 0)
        l.recordFailure(k, 10)
        @Expect(l.isBlocked(k, 20), true)
        // 超过窗口：计数清零，重新可用
        @Expect(l.isBlocked(k, 2000), false)
        l.recordFailure(k, 2100)
        @Expect(l.isBlocked(k, 2200), false)
    }

    @TestCase
    public func testResetOnSuccess(): Unit {
        let l = LoginLimiter(maxFailures: 1, windowMs: 10000)
        let k = "admin|1.2.3.4"
        l.recordFailure(k, 0)
        @Expect(l.isBlocked(k, 1), true)
        l.reset(k)
        @Expect(l.isBlocked(k, 2), false)
    }

    @TestCase
    public func testKeysAreIndependent(): Unit {
        let l = LoginLimiter(maxFailures: 1, windowMs: 10000)
        l.recordFailure("admin|1.1.1.1", 0)
        @Expect(l.isBlocked("admin|1.1.1.1", 1), true)
        @Expect(l.isBlocked("admin|2.2.2.2", 1), false)
        @Expect(l.isBlocked("bob|1.1.1.1", 1), false)
    }
}
