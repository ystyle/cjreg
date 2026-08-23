// 列表分页/行数据纯逻辑单元测试
package ystyle::cjreg.ui

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
public class PageWindowTest {
    @TestCase
    public func testFirstPageFullWindow(): Unit {
        let (start, end) = pageWindow(10, 1, 20)
        @Expect(start, 0)
        @Expect(end, 10)
    }

    @TestCase
    public func testSecondPage(): Unit {
        let (start, end) = pageWindow(10, 2, 4)
        @Expect(start, 4)
        @Expect(end, 8)
    }

    @TestCase
    public func testLastPagePartial(): Unit {
        let (start, end) = pageWindow(7, 3, 3)
        @Expect(start, 6)
        @Expect(end, 7)
    }

    @TestCase
    public func testEmptyTotal(): Unit {
        let (start, end) = pageWindow(0, 1, 20)
        @Expect(start, 0)
        @Expect(end, 0)
    }

    @TestCase
    public func testPageBeyondRangeReturnsEmpty(): Unit {
        let (start, end) = pageWindow(10, 6, 2)
        @Expect(start, 10)
        @Expect(end, 10)
    }

    @TestCase
    public func testPageClampedTo1(): Unit {
        let (start, end) = pageWindow(5, 0, 10)
        @Expect(start, 0)
        @Expect(end, 5)
    }

    @TestCase
    public func testSizeClampedTo1(): Unit {
        let (start, end) = pageWindow(3, 2, 0)
        @Expect(start, 1)
        @Expect(end, 2)
    }
}
