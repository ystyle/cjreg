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
// 索引路径的两段分片是否与模块名匹配：
//   第 1 段 = 名字前 2 字符；第 2 段 = 第 3-4 字符（名字只有 3 字符时就是第 3 字符）。
// 官方中心仓对不匹配的分片返回 400；我们服务端也必须一样严格 —— 否则私有仓预演
// 会把"索引路径写错"这种错悄悄放过去（实测踩过：bs/ap/bstorm 在官方仓 400、在本仓 200）。
public func indexShardMatches(mo: String, du: String, name: String): Bool {
    if (name.size < 3) {
        return false
    }
    let wantMo = name[0..2]
    let wantDu = if (name.size >= 4) { name[2..4] } else { name[2..3] }
    mo == wantMo && du == wantDu
}

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
