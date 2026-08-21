// 中心仓协议：索引/制品 URL 构造（对齐官方 /index、/pkg 格式）
package ystyle::cjreg.protocol

// 去除末尾斜杠
public func trimTrailing(base: String): String {
    var b = base
    while (b.endsWith("/")) {
        b = b[0..b.size - 1]
    }
    return b
}

// 索引 URL：/index/{mo}/{du}/{name}[?organization={org}]
// 短名规则：name >= 4 字符 → mo=name[0:2], du=name[2:4]
//           name == 3 字符 → mo=name[0:2], du=name[2]（第 3 字符）
//           name <  3 字符 → 官方模块名规格为 [3,64]，此分支为防御性处理，返回空串
public func buildIndexURL(base: String, name: String, org: String): String {
    let b = trimTrailing(base)
    if (name.size < 3) {
        return ""
    }
    let mo = name[0..2]
    var du: String
    if (name.size >= 4) {
        du = name[2..4]
    } else {
        du = name[2..3]
    }
    var url = b + "/index/" + mo + "/" + du + "/" + name
    if (!org.isEmpty()) {
        url += "?organization=" + org
    }
    return url
}

// 制品 URL：/pkg/{name}/{version}[?organization={org}]
public func buildPackageURL(base: String, name: String, version: String, org: String): String {
    let b = trimTrailing(base)
    var url = b + "/pkg/" + name + "/" + version
    if (!org.isEmpty()) {
        url += "?organization=" + org
    }
    return url
}

// 官方仓 base URL 识别（isOfficial 判定前缀）
public func isOfficialRegistry(base: String): Bool {
    trimTrailing(base) == "https://pkg.cangjie-lang.cn/registry"
}
