// Token 生成与时间工具（对齐 cjcc：前缀 + 32 位随机串）
package ystyle::cjreg.auth.util

import std.random.Random
import std.time.DateTime

public class TokenGenerator {
    public static let TOKEN_LENGTH: Int64 = 32

    public static func generateSessionToken(): String {
        "sess-${generateRandomString(TOKEN_LENGTH)}"
    }

    public static func generatePublishToken(): String {
        "publish-${generateRandomString(TOKEN_LENGTH)}"
    }

    private static func generateRandomString(length: Int64): String {
        let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".toRuneArray()
        let random = Random()
        let sb = StringBuilder()
        var i: Int64 = 0
        while (i < length) {
            let idx = random.nextInt64(chars.size)
            sb.append(chars[idx])
            i++
        }
        return sb.toString()
    }
}

// 当前 Unix 时间戳（秒）
public func currentTimestamp(): Int64 {
    DateTime.now().toUnixTimeStamp().toSeconds()
}

// 从现在起 n 秒后的时间戳
public func expiresAt(secondsFromNow: Int64): Int64 {
    currentTimestamp() + secondsFromNow
}
