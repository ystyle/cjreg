// 密码哈希（对齐 cjcc：pbkdf2 SHA512，900000 迭代，64 字节）
// 存储格式：{salt}:{hex(hash)}
package ystyle::cjreg.auth.util

import pbkdf2.*
import stdx.crypto.digest.HashType
import stdx.encoding.hex.toHexString
import stdx.crypto.crypto.SecureRandom
import std.unicode.*

public class PasswordHash {
    public static let SALT_LENGTH: Int32 = 16
    // 迭代次数可配置（生产默认 900000；测试可调低以提速）
    public static var ITERATIONS: Int64 = 900000
    public static let KEY_LENGTH: Int64 = 64

    public static func hash(password: String): String {
        let salt = generateSalt()
        let pwd = password.toUpper()
        let hashValue = pbkdf2(pwd, salt, ITERATIONS, KEY_LENGTH, HashType.SHA512)
        "${salt}:${toHexString(hashValue)}"
    }

    public static func verify(password: String, hashed: String): Bool {
        let parts = hashed.split(":")
        if (parts.size != 2) {
            return false
        }
        let salt = parts[0]
        let expected = parts[1]
        let pwd = password.toUpper()
        let actual = pbkdf2(pwd, salt, ITERATIONS, KEY_LENGTH, HashType.SHA512)
        toHexString(actual) == expected
    }

    private static func generateSalt(): String {
        let random = SecureRandom()
        let bytes = random.nextBytes(SALT_LENGTH)
        toHexString(bytes)
    }
}
