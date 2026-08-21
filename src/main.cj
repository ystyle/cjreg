// cjreg 入口：serve / init / admin
package ystyle::cjreg

import std.argopt.*
import std.convert.*
import std.env.*
import std.io.*
import bstorm.*
import ystyle::cjreg.server.*
import ystyle::cjreg.store.*

func printUsage(): Unit {
    println("cjreg - 仓颉私有中心仓与多仓工具")
    println()
    println("用法: cjreg <command> [options]")
    println()
    println("命令:")
    println("  serve   启动私有中心仓 HTTP 服务（发布/下载/索引 + 管理 API）")
    println("  init    初始化数据目录（空数据目录创建首个管理员 + 默认官方上游）")
    println("  admin   应急管理（reset-password）")
    println()
    println("选项:")
    println("  -d, --data <dir>   数据目录（默认 ./data）")
    println("  -p, --port <n>     serve 端口（默认 8060）")
    println("  -h, --help         帮助")
}

main(args: Array<String>): Int64 {
    let specs = [
        Full("data", r'd', RequiredValue),
        Full("port", r'p', RequiredValue),
        Full("help", r'h', NoValue)
    ]
    var result: ParsedArguments
    try {
        result = parseArguments(args, specs)
    } catch (e: ArgumentParseException) {
        printUsage()
        return 2
    }

    if (result.options.contains("help")) {
        printUsage()
        return 0
    }

    var command = "serve"
    if (result.nonOptions.size >= 1) {
        command = result.nonOptions[0]
    }

    var dataDir = "./data"
    match (result.options.get("data")) {
        case Some(v) => if (!v.isEmpty()) {
            dataDir = v
        }
        case None => ()
    }
    var port: UInt16 = 8060
    match (result.options.get("port")) {
        case Some(v) =>
            let n = UInt16.tryParse(v)
            match (n) {
                case Some(p) => port = p
                case None => ()
            }
        case None => ()
    }

    match (command) {
        case "serve" =>
            return cmdServe(dataDir, port)
        case "init" =>
            println("cjreg: init 尚未实现（M3 部署引导）")
            return 1
        case "admin" =>
            println("cjreg: admin 尚未实现（M3 应急管理）")
            return 1
        case _ =>
            println("cjreg: 未知命令 ${command}")
            printUsage()
            return 2
    }
}

// serve：启动 HTTP 服务
func cmdServe(dataDir: String, port: UInt16): Int64 {
    // 打开 bstorm 存储（数据目录）
    var store: PackageStore
    try {
        let storm = Storm.open(dataDir + "/cjreg.db")
        store = PackageStore(storm)
    } catch (e: Exception) {
        println("cjreg: 无法打开数据目录 ${dataDir}: ${e.message}")
        return 1
    }

    let app = buildServer(store, port)
    println("cjreg: serving on port ${port} (data=${dataDir})")
    app.listen(port)
    return 0
}
