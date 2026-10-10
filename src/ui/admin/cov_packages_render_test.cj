// 包管理页（/admin/packages）渲染 + 交互回归（第二势力范围）。
//
// 既有用例覆盖了"搜索输入即生效"与抽屉/分页（pages_manage_render_test.cj）。
// 这里补的是三条**写路径**及其全部失败出口 + 详情/重拉/确认三个弹窗的正文分支：
//   * 恢复（restore）：制品仍在 → 成功；制品丢失且非回源 → 失败（两条出口都要）；
//   * 三级删除：软删 / 硬删 / 未注入制品库时硬删被拒 / 记录不存在；
//   * 重拉：Ok（内容已更新 / 内容一致两种文案）、ShaChanged（弹二次确认）、
//     其它失败、未注入回源代理、记录不存在、非管理员；
//   * 版本行「操作」下拉的命令分发（detail/refetch/soft/restore/hard/未知命令）；
//   * 单版本详情弹窗的每个 kv 分支（空值 → 「-」、本地发布 vs 回源镜像的时间口径、
//     空 README 的提示语 vs Markdown 正文、软删状态）；
//   * 确认框的软删/硬删两套正文与标题。
package ystyle::cjreg.ui.admin

import ystyle::cjreg.ui.*
import cjxt.*
import ystyle::cjreg.store.*
import ystyle::cjreg.config.*
import ystyle::cjreg.index.*
import ystyle::cjreg.server.{DiskBlobStore, MemoryBlobStore, ProxyService, RefetchOutcome,
    LifecycleOutcome, sha256Hex, shortSha}
import ystyle::cjreg.auth.*
import ystyle::cjreg.auth.model.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

func mountPackagesCov(state: CjregState): PackagesPage {
    let page = PackagesPage()
    page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
    page
}

// 造一个「制品在 blob 里」的包版本：doc.sha256 与 blob 内容对得上
func seedCovPkgWithArtifact(state: CjregState, blob: MemoryBlobStore, org: String, name: String,
                            version: String, payload!: Array<Byte> = [UInt8(1), UInt8(2), UInt8(3)],
                            upstreamId!: Int64 = 0, upstreamName!: String = ""): PackageDoc {
    let sha = sha256Hex(payload)
    blob.put(sha, payload)
    let d = PackageDoc()
    d.organization = org
    d.name = name
    d.version = version
    d.sha256 = sha
    d.tarballSize = payload.size
    d.upstreamId = upstreamId
    d.upstreamName = upstreamName
    d.createdAt = 1000
    d.updatedAt = 2000
    state.pkgStore.save(d)
    d
}

// 上游 stub：索引与制品都从内存给（全程离线）
class CovPkgUpstreamStub {
    var artifact: Array<Byte> = [UInt8(9), UInt8(9)]
    var indexShaOverride: String = ""
    var indexHasVersion: Bool = true
    var indexBroken: Bool = false
    var artifactBroken: Bool = false

    func fetch(url: String, token: String): ?Array<Byte> {
        if (url.contains("/index/")) {
            if (this.indexBroken) { return None }
            let e = PackageIndex()
            e.name = "alpha"
            e.version = "1.0.0"
            e.sha256sum = if (this.indexShaOverride.isEmpty()) { sha256Hex(this.artifact) } else { this.indexShaOverride }
            if (!this.indexHasVersion) {
                e.version = "2.0.0"
            }
            return Some(generateNDJSON(ArrayList<PackageIndex>([e])).toArray())
        }
        if (this.artifactBroken) { return None }
        Some(this.artifact)
    }
}

// 装一个「包 store + 制品库 + 回源代理（stub 出网）」的状态
func covPkgState(blob: MemoryBlobStore, stub: CovPkgUpstreamStub): CjregState {
    let state = makePortalState("team")
    state.blobStore = Some(blob)
    let ups = UpstreamService(state.upStore)
    let _ = ups.add("mirror", "https://mirror.test/registry", 0, "", 0)
    let proxy = ProxyService(state.pkgStore, blob, ups)
    proxy.httpFetch = { u, t => stub.fetch(u, t) }
    state.proxySvc = Some(proxy)
    state
}

@Test
public class CovPackagesActionsTest {
    // ===== 恢复（restore）=====

    // 制品仍在 → 恢复成功 + 审计 detail 带 artifactPresent；列表里那行状态跟着回到「正常」
    @TestCase
    public func covPkg_restoreSucceeds(): Unit {
        let blob = MemoryBlobStore()
        let stub = CovPkgUpstreamStub()
        let state = covPkgState(blob, stub)
        let doc = seedCovPkgWithArtifact(state, blob, "ystyle", "alpha", "1.0.0")
        state.pkgStore.softDelete(doc, 5000)
        let page = mountPackagesCov(state)
        let (actx, _) = covActx(state)
        page.select("ystyle", "alpha")
        @Expect(page.verAll.get()[0].deletedAt != 0, true)

        let _ = page.doRestore(actx, doc.id, "alpha", "1.0.0")
        @Expect(page.msg.get(), "已恢复 alpha@1.0.0")
        @Expect(state.pkgStore.getById(doc.id).getOrThrow().deletedAt, 0)
        @Expect(page.verAll.get()[0].deletedAt, 0)
        let (logs, total) = state.adminData.queryLogs(Some("admin"), "restore_package", "", 0, 0, 0, 10)
        @Expect(total, 1)
        @Expect(logs[0].target, "alpha@1.0.0")
        @Expect(logs[0].detail, "artifactPresent=true")
        @Expect(covRender(page.render()).contains("已恢复 alpha@1.0.0"), true)
    }

    // 制品丢失且不是回源版本 → 恢复被拒，提示带原因，写失败审计
    @TestCase
    public func covPkg_restoreFailsWithoutArtifact(): Unit {
        let blob = MemoryBlobStore()
        let stub = CovPkgUpstreamStub()
        let state = covPkgState(blob, stub)
        let doc = seedCovPkgWithArtifact(state, blob, "ystyle", "alpha", "1.0.0")
        blob.remove(doc.sha256)              // 制品没了
        state.pkgStore.softDelete(doc, 5000)
        let page = mountPackagesCov(state)
        let (actx, _) = covActx(state)

        let _ = page.doRestore(actx, doc.id, "alpha", "1.0.0")
        @Expect(page.msg.get().startsWith("恢复失败："), true)
        @Expect(page.msg.get().contains("制品已丢失"), true)
        @Expect(state.pkgStore.getById(doc.id).getOrThrow().deletedAt != 0, true)
        let (logs, total) = state.adminData.queryLogs(Some("admin"), "restore_package", "", 0, 0, 0, 10)
        @Expect(total, 1)
        @Expect(logs[0].status, "failed")
    }

    // 回源镜像版本：即使本地没有制品也能恢复（可以重新回源）
    @TestCase
    public func covPkg_restoreMirroredWithoutLocalBlob(): Unit {
        let blob = MemoryBlobStore()
        let stub = CovPkgUpstreamStub()
        let state = covPkgState(blob, stub)
        let doc = seedCovPkgWithArtifact(state, blob, "ystyle", "alpha", "1.0.0",
            upstreamId: 1, upstreamName: "mirror")
        blob.remove(doc.sha256)
        state.pkgStore.softDelete(doc, 5000)
        let page = mountPackagesCov(state)
        let (actx, _) = covActx(state)
        let _ = page.doRestore(actx, doc.id, "alpha", "1.0.0")
        @Expect(page.msg.get(), "已恢复 alpha@1.0.0")
        @Expect(state.pkgStore.getById(doc.id).getOrThrow().deletedAt, 0)
    }

    // 记录不存在 → 「版本不存在」，不写审计
    @TestCase
    public func covPkg_restoreMissingRecord(): Unit {
        let blob = MemoryBlobStore()
        let stub = CovPkgUpstreamStub()
        let state = covPkgState(blob, stub)
        let page = mountPackagesCov(state)
        let (actx, _) = covActx(state)
        let _ = page.doRestore(actx, 999999, "ghost", "1.0.0")
        @Expect(page.msg.get(), "版本不存在")
        @Expect(state.adminData.queryLogs(Option<String>.None, "", "", 0, 0, 0, 10)[1], 0)
    }

    // 未注入制品库：doRestore 退回 MemoryBlobStore（恢复动作本身仍要走通）
    @TestCase
    public func covPkg_restoreWithoutInjectedBlobStore(): Unit {
        let state = makePortalState("team")
        // 无 blobStore、无 sha（artifactAvailable 按「非回源 → 不可用」判）
        let doc = covSeedPkg(state, "ystyle", "alpha", "1.0.0")
        state.pkgStore.softDelete(doc, 5000)
        let page = mountPackagesCov(state)
        let (actx, _) = covActx(state)
        let _ = page.doRestore(actx, doc.id, "alpha", "1.0.0")
        @Expect(page.msg.get().startsWith("恢复失败："), true)
    }

    // ===== 软删 / 硬删 =====

    // 软删确认：正文含包名@版本、走 soft 分支的标题与按钮文案
    @TestCase
    public func covPkg_softDeleteConfirmBody(): Unit {
        let blob = MemoryBlobStore()
        let stub = CovPkgUpstreamStub()
        let state = covPkgState(blob, stub)
        let doc = seedCovPkgWithArtifact(state, blob, "ystyle", "alpha", "1.0.0")
        let page = mountPackagesCov(state)
        let (actx, _) = covActx(state)
        page.select("ystyle", "alpha")

        let _ = page.askDelete(actx, doc.id, "alpha", "1.0.0")
        @Expect(page.confirmVisible.get(), true)
        @Expect(page.pendingMode.get(), "soft")
        @Expect(page.pendingDeleteName.get(), "alpha@1.0.0")
        let json = covRender(page.render())
        @Expect(json.contains("软删除确认"), true)
        @Expect(json.contains("确定要软删除「alpha@1.0.0」吗？"), true)
        @Expect(json.contains("索引/下载/公开 API 立即不可见，可在包列表随时恢复。"), true)
        @Expect(json.contains("软删除"), true)
    }

    // 软删执行：状态置位、提示、审计 detail 里带 blobRemoved/skippedPlanItems
    @TestCase
    public func covPkg_softDeleteExecutes(): Unit {
        let blob = MemoryBlobStore()
        let stub = CovPkgUpstreamStub()
        let state = covPkgState(blob, stub)
        let doc = seedCovPkgWithArtifact(state, blob, "ystyle", "alpha", "1.0.0")
        let page = mountPackagesCov(state)
        let (actx, _) = covActx(state)
        page.select("ystyle", "alpha")
        let _ = page.askDelete(actx, doc.id, "alpha", "1.0.0")
        let _ = page.confirmDelete(actx)

        @Expect(page.msg.get(), "已软删除（可恢复） alpha@1.0.0")
        @Expect(page.confirmVisible.get(), false)
        @Expect(page.pendingDeleteId, 0)
        @Expect(state.pkgStore.getById(doc.id).getOrThrow().deletedAt != 0, true)
        // 制品还在（软删不删 blob）
        @Expect(blob.has(doc.sha256), true)
        let (logs, total) = state.adminData.queryLogs(Some("admin"), "delete_package", "", 0, 0, 0, 10)
        @Expect(total, 1)
        @Expect(logs[0].detail.contains("skippedPlanItems="), true)
        @Expect(logs[0].detail.contains("blobRemoved=false"), true)
        // 右栏版本表跟着刷新（软删后状态列变「已删」——注意不是提示语里的「已软删除」）
        @Expect(page.verAll.get()[0].deletedAt != 0, true)
        @Expect(covRender(page.render()).contains("\"text\":\"已删\""), true)
    }

    // 幂等：已软删的版本再软删一次 → AlreadyDeleted 也走成功文案
    @TestCase
    public func covPkg_softDeleteIsIdempotent(): Unit {
        let blob = MemoryBlobStore()
        let stub = CovPkgUpstreamStub()
        let state = covPkgState(blob, stub)
        let doc = seedCovPkgWithArtifact(state, blob, "ystyle", "alpha", "1.0.0")
        state.pkgStore.softDelete(doc, 5000)
        let page = mountPackagesCov(state)
        let (actx, _) = covActx(state)
        page.select("ystyle", "alpha")
        let _ = page.askDelete(actx, doc.id, "alpha", "1.0.0")
        let _ = page.confirmDelete(actx)
        @Expect(page.msg.get(), "已软删除（可恢复） alpha@1.0.0")
    }

    // 硬删确认：正文与标题走 hard 分支
    @TestCase
    public func covPkg_hardDeleteConfirmBody(): Unit {
        let blob = MemoryBlobStore()
        let stub = CovPkgUpstreamStub()
        let state = covPkgState(blob, stub)
        let doc = seedCovPkgWithArtifact(state, blob, "ystyle", "alpha", "1.0.0")
        state.pkgStore.softDelete(doc, 5000)
        let page = mountPackagesCov(state)
        let (actx, _) = covActx(state)
        page.select("ystyle", "alpha")

        let _ = page.askHardDelete(actx, doc.id, "alpha", "1.0.0")
        @Expect(page.pendingMode.get(), "hard")
        let json = covRender(page.render())
        @Expect(json.contains("硬删除确认"), true)
        @Expect(json.contains("确定要硬删除「alpha@1.0.0」吗？"), true)
        @Expect(json.contains("将同时删除制品文件（若仍被其它版本引用则保留），且不可恢复"), true)
        @Expect(json.contains("硬删除"), true)
    }

    // 硬删执行（已软删）：记录与制品都消失，审计 action 为 hard_delete_package
    @TestCase
    public func covPkg_hardDeleteExecutes(): Unit {
        let blob = MemoryBlobStore()
        let stub = CovPkgUpstreamStub()
        let state = covPkgState(blob, stub)
        let doc = seedCovPkgWithArtifact(state, blob, "ystyle", "alpha", "1.0.0")
        let sha = doc.sha256
        state.pkgStore.softDelete(doc, 5000)
        let page = mountPackagesCov(state)
        let (actx, _) = covActx(state)
        page.select("ystyle", "alpha")
        let _ = page.askHardDelete(actx, doc.id, "alpha", "1.0.0")
        let _ = page.confirmDelete(actx)

        @Expect(page.msg.get(), "已硬删除 alpha@1.0.0")
        @Expect(state.pkgStore.getById(doc.id).isNone(), true)
        @Expect(blob.has(sha), false)
        @Expect(page.verAll.get().size, 0)
        @Expect(page.versionHint(), "该包还没有版本记录")
        let (logs, total) = state.adminData.queryLogs(Some("admin"), "hard_delete_package", "", 0, 0, 0, 10)
        @Expect(total, 1)
        @Expect(logs[0].detail.contains("blobRemoved=true"), true)
    }

    // 硬删前没软删 → 服务端返回 NotDeleted → 「删除失败：…」+ 失败审计
    @TestCase
    public func covPkg_hardDeleteRequiresSoftDeleteFirst(): Unit {
        let blob = MemoryBlobStore()
        let stub = CovPkgUpstreamStub()
        let state = covPkgState(blob, stub)
        let doc = seedCovPkgWithArtifact(state, blob, "ystyle", "alpha", "1.0.0")
        let page = mountPackagesCov(state)
        let (actx, _) = covActx(state)
        page.select("ystyle", "alpha")
        let _ = page.askHardDelete(actx, doc.id, "alpha", "1.0.0")
        let _ = page.confirmDelete(actx)

        @Expect(page.msg.get().startsWith("删除失败："), true)
        @Expect(page.msg.get().contains("硬删除前需先软删除"), true)
        @Expect(state.pkgStore.getById(doc.id).isSome(), true)
        let (logs, total) = state.adminData.queryLogs(Some("admin"), "hard_delete_package", "", 0, 0, 0, 10)
        @Expect(total, 1)
        @Expect(logs[0].status, "failed")
    }

    // 未注入制品库时硬删被拒（避免删了记录留孤儿制品）
    @TestCase
    public func covPkg_hardDeleteWithoutBlobStoreRejected(): Unit {
        let state = makePortalState("team")
        let doc = covSeedPkg(state, "ystyle", "alpha", "1.0.0")
        state.pkgStore.softDelete(doc, 5000)
        let page = mountPackagesCov(state)
        let (actx, _) = covActx(state)
        page.select("ystyle", "alpha")
        let _ = page.askHardDelete(actx, doc.id, "alpha", "1.0.0")
        let _ = page.confirmDelete(actx)

        @Expect(page.msg.get(), "硬删除不可用：该进程未注入制品库")
        @Expect(page.confirmVisible.get(), false)
        @Expect(page.pendingDeleteId, 0)
        @Expect(state.pkgStore.getById(doc.id).isSome(), true)
        @Expect(state.adminData.queryLogs(Option<String>.None, "", "", 0, 0, 0, 10)[1], 0)
    }

    // 确认删除时记录已不存在 → 「版本不存在」+ 关闭弹窗 + 复位 pendingDeleteId
    @TestCase
    public func covPkg_confirmDeleteMissingRecord(): Unit {
        let blob = MemoryBlobStore()
        let stub = CovPkgUpstreamStub()
        let state = covPkgState(blob, stub)
        let doc = seedCovPkgWithArtifact(state, blob, "ystyle", "alpha", "1.0.0")
        let page = mountPackagesCov(state)
        let (actx, _) = covActx(state)
        let _ = page.askDelete(actx, doc.id, "alpha", "1.0.0")
        state.pkgStore.delete(doc)
        let _ = page.confirmDelete(actx)
        @Expect(page.msg.get(), "版本不存在")
        @Expect(page.confirmVisible.get(), false)
        @Expect(page.pendingDeleteId, 0)
    }

    // 取消删除：关框、数据不动
    @TestCase
    public func covPkg_cancelDelete(): Unit {
        let blob = MemoryBlobStore()
        let stub = CovPkgUpstreamStub()
        let state = covPkgState(blob, stub)
        let doc = seedCovPkgWithArtifact(state, blob, "ystyle", "alpha", "1.0.0")
        let page = mountPackagesCov(state)
        let (actx, _) = covActx(state)
        page.select("ystyle", "alpha")
        let _ = page.askDelete(actx, doc.id, "alpha", "1.0.0")
        let _ = page.cancelDelete(actx)
        @Expect(page.confirmVisible.get(), false)
        @Expect(state.pkgStore.getById(doc.id).getOrThrow().deletedAt, 0)
    }

    // ===== 单版本详情弹窗 =====

    // 全字段（本地发布）：发布者/时间口径「发布于」/空字段显示「-」/没有 README 的提示语
    @TestCase
    public func covPkg_detailDialogLocalPublish(): Unit {
        let blob = MemoryBlobStore()
        let stub = CovPkgUpstreamStub()
        let state = covPkgState(blob, stub)
        let doc = seedCovPkgWithArtifact(state, blob, "ystyle", "alpha", "1.0.0")
        doc.description = "描述文本"
        doc.cjcVersion = "1.1.3"
        doc.repository = "https://repo.test/x"
        // homepage / documentation 都留空：这一行 kv 的值 trim 后为空 → 应显示 "-"
        doc.homepage = ""
        doc.documentation = ""
        doc.publisherId = 42
        doc.downloadCount = 7
        doc.license = ArrayList<String>(["MIT"])
        doc.authors = ArrayList<String>(["ystyle", "someone"])
        doc.tag = ArrayList<String>(["cli"])
        doc.category = ArrayList<String>(["tools"])
        state.pkgStore.save(doc)
        let page = mountPackagesCov(state)
        let (actx, _) = covActx(state)
        page.select("ystyle", "alpha")

        let _ = page.showDetail(actx, doc.id)
        @Expect(page.detailVisible.get(), true)
        @Expect(page.detailDoc.get().id, doc.id)
        let json = covRenderExpanded(page.render())
        @Expect(json.contains("版本详情"), true)
        @Expect(json.contains("ystyle::alpha@1.0.0"), true)
        @Expect(json.contains("完整包名"), true)
        @Expect(json.contains("本地发布"), true)
        @Expect(json.contains("#42"), true)          // 发布者有值
        @Expect(json.contains("发布于"), true)        // upstreamId == 0
        @Expect(json.contains("描述文本"), true)
        @Expect(json.contains("MIT"), true)
        @Expect(json.contains("ystyle、someone"), true)   // joinList 的分隔符
        @Expect(json.contains("cli"), true)
        @Expect(json.contains("tools"), true)
        @Expect(json.contains("https://repo.test/x"), true)
        // 空 README → 提示语而不是 Markdown
        @Expect(json.contains("该版本没有提取到 README"), true)
        @Expect(json.contains("README（0 字节）"), true)
        // homepage/documentation 都为空 → 这一格的值落 "-" 分支
        @Expect(json.contains("主页 / 文档"), true)
        @Expect(json.contains("\"text\":\"-\""), true)
    }

    // 详情（回源镜像 + 有 README + 已软删 + 无发布者）：另一套分支
    @TestCase
    public func covPkg_detailDialogMirroredWithReadme(): Unit {
        let blob = MemoryBlobStore()
        let stub = CovPkgUpstreamStub()
        let state = covPkgState(blob, stub)
        let doc = seedCovPkgWithArtifact(state, blob, "ystyle", "alpha", "1.0.0",
            upstreamId: 3, upstreamName: "mirror")
        doc.readme = "# 标题\n\n正文内容"
        doc.publisherId = 0
        doc.deletedAt = 1234
        state.pkgStore.save(doc)
        let page = mountPackagesCov(state)
        let (actx, _) = covActx(state)
        page.select("ystyle", "alpha")

        let _ = page.showDetail(actx, doc.id)
        let json = covRenderExpanded(page.render())
        @Expect(json.contains("回源 · mirror"), true)
        @Expect(json.contains("收录于"), true)      // upstreamId != 0
        @Expect(json.contains("已软删除"), true)
        // README 非空 → 走 Markdown 正文，不再是那句提示
        @Expect(json.contains("正文内容"), true)
        @Expect(json.contains("该版本没有提取到 README"), false)
        @Expect(json.contains("README（${doc.readme.size} 字节）"), true)

        let _ = page.closeDetail(actx)
        @Expect(page.detailVisible.get(), false)
    }

    // 详情：不存在的 id → 「版本不存在」，弹窗不开
    @TestCase
    public func covPkg_showDetailMissingRecord(): Unit {
        let blob = MemoryBlobStore()
        let stub = CovPkgUpstreamStub()
        let state = covPkgState(blob, stub)
        let page = mountPackagesCov(state)
        let (actx, _) = covActx(state)
        let _ = page.showDetail(actx, 999999)
        @Expect(page.detailVisible.get(), false)
        @Expect(page.msg.get(), "版本不存在")
    }

    // 无组织包：详情标题只给包名（不出现 "::"）
    @TestCase
    public func covPkg_detailDialogNoOrg(): Unit {
        let blob = MemoryBlobStore()
        let stub = CovPkgUpstreamStub()
        let state = covPkgState(blob, stub)
        let doc = seedCovPkgWithArtifact(state, blob, "", "snappy", "1.0.1")
        let page = mountPackagesCov(state)
        let (actx, _) = covActx(state)
        page.select("", "snappy")
        let _ = page.showDetail(actx, doc.id)
        let json = covRenderExpanded(page.render())
        @Expect(json.contains("snappy@1.0.1"), true)
        @Expect(json.contains("::snappy"), false)
    }

    // ===== 重拉 =====

    // 重拉成功（内容变了）：提示带「内容已更新」与体积；写审计；弹窗关闭
    @TestCase
    public func covPkg_refetchOkChanged(): Unit {
        let blob = MemoryBlobStore()
        let stub = CovPkgUpstreamStub()
        let state = covPkgState(blob, stub)
        let doc = seedCovPkgWithArtifact(state, blob, "ystyle", "alpha", "1.0.0",
            upstreamId: 1, upstreamName: "mirror", payload: [UInt8(1)])
        let oldSha = doc.sha256
        stub.artifact = [UInt8(2), UInt8(3), UInt8(4), UInt8(5)]
        let page = mountPackagesCov(state)
        let (actx, _) = covActx(state)
        page.select("ystyle", "alpha")

        // 上游同版本 sha 与本地不同 → 默认会被 ShaChanged 拦下，需 force；
        // 这条用例直接走 force=true 的覆盖路径（非 force 的路径由 shaChanged 用例守）。
        let _ = page.askRefetch(actx, doc.id, "alpha", "1.0.0", true, "上游已变")
        @Expect(page.refetchVisible.get(), true)
        @Expect(page.refetchDocId, doc.id)
        @Expect(page.refetchForce.get(), true)
        @Expect(covRender(page.render()).contains("⚠ 上游同版本的内容已经变了。"), true)
        // force=true 时正文换成"覆盖"那套，不再出现非 force 的"重新拉取"文案
        @Expect(covRender(page.render()).contains("将按上游内容重新拉取该版本"), false)

        let _ = page.doRefetch(actx)
        @Expect(page.msg.get().startsWith("已重拉 alpha@1.0.0（内容已更新，"), true)
        @Expect(page.refetchVisible.get(), false)
        @Expect(page.refetchDocId, 0)
        let after = state.pkgStore.getById(doc.id).getOrThrow()
        @Expect(after.sha256 != oldSha, true)
        @Expect(after.sha256, sha256Hex(stub.artifact))
        let (logs, total) = state.adminData.queryLogs(Some("admin"), "refetch_package", "", 0, 0, 0, 10)
        @Expect(total, 1)
        @Expect(logs[0].detail.contains("force=true"), true)
    }

    // 重拉成功（内容一致）：提示「内容一致」
    @TestCase
    public func covPkg_refetchOkUnchanged(): Unit {
        let blob = MemoryBlobStore()
        let stub = CovPkgUpstreamStub()
        let state = covPkgState(blob, stub)
        stub.artifact = [UInt8(7), UInt8(7), UInt8(7)]
        let doc = seedCovPkgWithArtifact(state, blob, "ystyle", "alpha", "1.0.0",
            upstreamId: 1, upstreamName: "mirror", payload: stub.artifact)
        let page = mountPackagesCov(state)
        let (actx, _) = covActx(state)
        page.select("ystyle", "alpha")
        let _ = page.askRefetch(actx, doc.id, "alpha", "1.0.0", false, "")
        let _ = page.doRefetch(actx)
        @Expect(page.msg.get().contains("内容一致"), true)
        @Expect(state.pkgStore.getById(doc.id).getOrThrow().sha256, sha256Hex(stub.artifact))
    }

    // 上游同版本 sha 变了：第一次不 force → ShaChanged，弹二次确认（正文走 force 分支）
    @TestCase
    public func covPkg_refetchShaChangedNeedsForce(): Unit {
        let blob = MemoryBlobStore()
        let stub = CovPkgUpstreamStub()
        let state = covPkgState(blob, stub)
        stub.artifact = [UInt8(5), UInt8(5)]
        let doc = seedCovPkgWithArtifact(state, blob, "ystyle", "alpha", "1.0.0",
            upstreamId: 1, upstreamName: "mirror", payload: [UInt8(1)])
        let page = mountPackagesCov(state)
        let (actx, _) = covActx(state)
        page.select("ystyle", "alpha")
        let _ = page.askRefetch(actx, doc.id, "alpha", "1.0.0", false, "")
        let _ = page.doRefetch(actx)

        @Expect(page.msg.get(), "上游同版本内容已变，请确认后覆盖")
        @Expect(page.refetchForce.get(), true)
        @Expect(page.refetchInfo.get().contains("上游同版本内容已变"), true)
        // 弹窗仍开着，正文换成 force 那套
        @Expect(page.refetchVisible.get(), true)
        let json = covRenderExpanded(page.render())
        @Expect(json.contains("⚠ 上游同版本的内容已经变了。"), true)
        @Expect(json.contains("继续将用上游内容覆盖本地该版本"), true)
        @Expect(json.contains("上游同版本内容已变"), true)
        // 本地没被改
        @Expect(state.pkgStore.getById(doc.id).getOrThrow().sha256, sha256Hex([UInt8(1)]))

        // 带 force 再拉一次 → 成功覆盖
        let _ = page.doRefetch(actx)
        @Expect(page.msg.get().contains("内容已更新"), true)
        @Expect(state.pkgStore.getById(doc.id).getOrThrow().sha256, sha256Hex(stub.artifact))
    }

    // 重拉失败（上游不可达）：提示「重拉失败：…」+ 失败审计
    @TestCase
    public func covPkg_refetchFails(): Unit {
        let blob = MemoryBlobStore()
        let stub = CovPkgUpstreamStub()
        let state = covPkgState(blob, stub)
        let doc = seedCovPkgWithArtifact(state, blob, "ystyle", "alpha", "1.0.0",
            upstreamId: 1, upstreamName: "mirror", payload: [UInt8(1)])
        stub.indexBroken = true
        let page = mountPackagesCov(state)
        let (actx, _) = covActx(state)
        page.select("ystyle", "alpha")
        let _ = page.askRefetch(actx, doc.id, "alpha", "1.0.0", false, "")
        let _ = page.doRefetch(actx)
        @Expect(page.msg.get().startsWith("重拉失败："), true)
        @Expect(page.refetchVisible.get(), false)
        @Expect(page.refetchDocId, 0)
        let (logs, total) = state.adminData.queryLogs(Some("admin"), "refetch_package", "", 0, 0, 0, 10)
        @Expect(total, 1)
        @Expect(logs[0].status, "failed")
        @Expect(state.pkgStore.getById(doc.id).getOrThrow().sha256, sha256Hex([UInt8(1)]))
    }

    // 重拉取消：关框 + 复位 refetchDocId
    @TestCase
    public func covPkg_cancelRefetch(): Unit {
        let blob = MemoryBlobStore()
        let stub = CovPkgUpstreamStub()
        let state = covPkgState(blob, stub)
        let doc = seedCovPkgWithArtifact(state, blob, "ystyle", "alpha", "1.0.0",
            upstreamId: 1, upstreamName: "mirror")
        let page = mountPackagesCov(state)
        let (actx, _) = covActx(state)
        let _ = page.askRefetch(actx, doc.id, "alpha", "1.0.0", false, "info")
        @Expect(page.refetchInfo.get(), "info")
        let _ = page.cancelRefetch(actx)
        @Expect(page.refetchVisible.get(), false)
        @Expect(page.refetchDocId, 0)
    }

    // 未注入回源代理：重拉不可用（明确提示，而不是静默）
    @TestCase
    public func covPkg_refetchWithoutProxyRejected(): Unit {
        let state = makePortalState("team")
        let doc = covSeedPkg(state, "ystyle", "alpha", "1.0.0", upstreamId: 1)
        let page = mountPackagesCov(state)
        let (actx, _) = covActx(state)
        page.select("ystyle", "alpha")
        let _ = page.askRefetch(actx, doc.id, "alpha", "1.0.0", false, "")
        let _ = page.doRefetch(actx)
        @Expect(page.msg.get(), "重拉不可用：该进程未注入回源代理")
        @Expect(page.refetchVisible.get(), false)
    }

    // 重拉时记录已不存在 → 「版本不存在」，并复位 refetchDocId
    //
    // 这条守着一个真实缺陷：该出口原先只关弹窗、**不复位** refetchDocId，
    // 与 Ok / 其它失败两条出口不一致 —— 下次打开重拉弹窗会带着已被删除的那条记录。
    @TestCase
    public func covPkg_refetchMissingRecord(): Unit {
        let blob = MemoryBlobStore()
        let stub = CovPkgUpstreamStub()
        let state = covPkgState(blob, stub)
        let page = mountPackagesCov(state)
        let (actx, _) = covActx(state)
        let _ = page.askRefetch(actx, 999999, "ghost", "1.0.0", false, "")
        let _ = page.doRefetch(actx)
        @Expect(page.msg.get(), "版本不存在")
        @Expect(page.refetchVisible.get(), false)
        // 三条出口口径统一：弹窗收起就复位目标 id
        @Expect(page.refetchDocId, 0)
    }

    // ===== 版本行下拉菜单的命令分发 =====

    @TestCase
    public func covPkg_versionCommandDispatch(): Unit {
        let blob = MemoryBlobStore()
        let stub = CovPkgUpstreamStub()
        let state = covPkgState(blob, stub)
        let doc = seedCovPkgWithArtifact(state, blob, "ystyle", "alpha", "1.0.0",
            upstreamId: 1, upstreamName: "mirror")
        let page = mountPackagesCov(state)
        let (actx, _) = covActx(state)
        page.select("ystyle", "alpha")

        // detail
        let _ = page.onVersionCommand(actx, doc.id, "detail")
        @Expect(page.detailVisible.get(), true)

        // refetch
        let _ = page.onVersionCommand(actx, doc.id, "refetch")
        @Expect(page.refetchVisible.get(), true)
        @Expect(page.refetchForce.get(), false)

        // soft
        let _ = page.onVersionCommand(actx, doc.id, "soft")
        @Expect(page.confirmVisible.get(), true)
        @Expect(page.pendingMode.get(), "soft")
        @Expect(page.pendingDeleteName.get(), "alpha@1.0.0")

        // restore（先把它软删掉，restore 才有意义）
        state.pkgStore.softDelete(doc, 5000)
        page.select("ystyle", "alpha")
        let _ = page.onVersionCommand(actx, doc.id, "restore")
        @Expect(page.msg.get(), "已恢复 alpha@1.0.0")

        // hard（先软删）
        state.pkgStore.softDelete(state.pkgStore.getById(doc.id).getOrThrow(), 6000)
        page.select("ystyle", "alpha")
        let _ = page.onVersionCommand(actx, doc.id, "hard")
        @Expect(page.confirmVisible.get(), true)
        @Expect(page.pendingMode.get(), "hard")

        // 未知命令：什么都不做
        let before = page.msg.get()
        let _ = page.onVersionCommand(actx, doc.id, "no-such-command")
        @Expect(page.msg.get(), before)

        // 命令里的 id 不在当前全量列表里：name/version 取不到（空串），仍然按命令分发
        let _ = page.onVersionCommand(actx, 424242, "soft")
        @Expect(page.pendingDeleteName.get(), "@")
    }

    // ===== 鉴权 =====

    // 库里降级 + 未登录：五条写动作全被拒且不落库、不留审计
    @TestCase
    public func covPkg_writeActionsRequireAdmin(): Unit {
        let blob = MemoryBlobStore()
        let stub = CovPkgUpstreamStub()
        let state = covPkgState(blob, stub)
        let doc = seedCovPkgWithArtifact(state, blob, "ystyle", "alpha", "1.0.0")
        let page = mountPackagesCov(state)
        page.select("ystyle", "alpha")

        let (plain, _) = covActx(state, dbIsAdmin: false, ctxIsAdmin: true, username: "covplain")
        let _ = page.doRestore(plain, doc.id, "alpha", "1.0.0")
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        let _ = page.confirmDelete(plain)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(state.pkgStore.getById(doc.id).getOrThrow().deletedAt, 0)
        let _ = page.doRefetch(plain)
        @Expect(page.msg.get(), "无权限：需要管理员登录")

        let anon = covAnonActx(state)
        let _ = page.confirmDelete(anon)
        @Expect(page.msg.get(), "无权限：需要管理员登录")
        @Expect(state.adminData.queryLogs(Option<String>.None, "", "", 0, 0, 0, 10)[1], 0)
    }

    // 未挂载 state：全部写动作走 None 分支
    @TestCase
    public func covPkg_withoutState(): Unit {
        let state = makePortalState("team")
        let page = PackagesPage()
        // state 为 None 时 render 直接返回 div()（连 adminLayout 都不渲染）
        let empty = covRender(page.render())
        @Expect(empty.contains("包管理"), false)
        @Expect(empty.contains("admin-layout"), false)
        let (actx, _) = covActx(state)
        let _ = page.doRestore(actx, 1, "a", "1.0.0")
        let _ = page.confirmDelete(actx)
        let _ = page.showDetail(actx, 1)
        let _ = page.doRefetch(actx)
        @Expect(page.msg.get(), "")
        @Expect(page.detailVisible.get(), false)
        // select 在 state 为 None 时也能开抽屉（只写信号）
        page.select("o", "n")
        @Expect(page.verDrawerVisible.get(), true)
        @Expect(page.verAll.get().size, 0)
    }

    // closeVersionDrawer：关抽屉 + 重画
    @TestCase
    public func covPkg_closeVersionDrawer(): Unit {
        let state = makePortalState("team")
        let _ = covSeedPkg(state, "ystyle", "alpha", "1.0.0")
        let page = mountPackagesCov(state)
        let (actx, _) = covActx(state)
        page.select("ystyle", "alpha")
        @Expect(page.verDrawerVisible.get(), true)
        @Expect(covRender(page.render()).contains("el-drawer"), true)
        let _ = page.closeVersionDrawer(actx)
        @Expect(page.verDrawerVisible.get(), false)
        @Expect(covRender(page.render()).contains("el-drawer"), false)
    }

    // refreshVersions 的 name == "" 提前返回分支
    @TestCase
    public func covPkg_refreshVersionsIgnoresEmptyName(): Unit {
        let blob = MemoryBlobStore()
        let stub = CovPkgUpstreamStub()
        let state = covPkgState(blob, stub)
        let _ = seedCovPkgWithArtifact(state, blob, "ystyle", "alpha", "1.0.0")
        let page = mountPackagesCov(state)
        page.select("ystyle", "alpha")
        @Expect(page.verAll.get().size, 1)
        page.refreshVersions(state, "ystyle", "")
        @Expect(page.verAll.get().size, 1)   // 没被清空
    }

    // 主表「已删」Tag：全部版本都软删时主行标红
    @TestCase
    public func covPkg_masterRowShowsDeletedTag(): Unit {
        let blob = MemoryBlobStore()
        let stub = CovPkgUpstreamStub()
        let state = covPkgState(blob, stub)
        let doc = seedCovPkgWithArtifact(state, blob, "ystyle", "alpha", "1.0.0")
        let page = mountPackagesCov(state)
        @Expect(page.rows.get()[0].allDeleted, false)
        @Expect(covRender(page.render()).contains("已删"), false)

        state.pkgStore.softDelete(doc, 5000)
        page.bump()
        @Expect(page.rows.get()[0].allDeleted, true)
        @Expect(covRender(page.render()).contains("已删"), true)
    }

    // 选中行高亮：主表里选中的包带 ● 前缀（Tag 而不是纯文本）
    @TestCase
    public func covPkg_selectedRowHighlighted(): Unit {
        let state = makePortalState("team")
        let _ = covSeedPkg(state, "ystyle", "alpha", "1.0.0")
        let _ = covSeedPkg(state, "ystyle", "beta", "1.0.0")
        let page = mountPackagesCov(state)
        @Expect(covRender(page.render()).contains("● "), false)
        page.select("ystyle", "alpha")
        let json = covRender(page.render())
        @Expect(json.contains("● ystyle::alpha"), true)
        @Expect(json.contains("● ystyle::beta"), false)

        // 切到 beta：高亮跟着走
        page.select("ystyle", "beta")
        let json2 = covRender(page.render())
        @Expect(json2.contains("● ystyle::beta"), true)
        @Expect(json2.contains("● ystyle::alpha"), false)
    }

    // 组织下拉：只有非空组织进选项（"" 与"全部组织"分开）
    @TestCase
    public func covPkg_orgOptionsSkipEmptyOrg(): Unit {
        let state = makePortalState("team")
        let _ = covSeedPkg(state, "", "noorg", "1.0.0")
        let _ = covSeedPkg(state, "acme", "withorg", "1.0.0")
        let page = mountPackagesCov(state)
        let json = covRender(page.render())
        @Expect(json.contains("全部组织"), true)
        @Expect(json.contains("acme"), true)
        // 空组织不产生 SelectOption（但包名本身还会出现在表格里）
        @Expect(page.rows.get().size, 2)
    }

    // 刷新按钮 = bump：store 里改了数据后点刷新才更新
    @TestCase
    public func covPkg_refreshButtonBumps(): Unit {
        let state = makePortalState("team")
        let page = mountPackagesCov(state)
        @Expect(page.rows.get().size, 0)
        let _ = covSeedPkg(state, "ystyle", "alpha", "1.0.0")
        @Expect(page.rows.get().size, 0)
        let (actx, _) = covActx(state)
        let _ = page.doRefresh(actx)
        @Expect(page.rows.get().size, 1)
        // onPageChange 只重画（页码信号变了派生会自己重算）
        let _ = page.onPageChange(actx)
        @Expect(page.rows.get().size, 1)
    }

    // 抽屉页越界：bindPaged 本地钳制，切片仍给最后一页
    @TestCase
    public func covPkg_versionPageClamping(): Unit {
        let state = makePortalState("team")
        for (i in 0..12) {
            let _ = covSeedPkg(state, "ystyle", "many", "1.0.${i}")
        }
        let page = mountPackagesCov(state)
        page.select("ystyle", "many")
        @Expect(page.verTotal.get(), 12)
        page.verPage.set(99)
        @Expect(page.verRows.get().size, 2)
        @Expect(page.verRows.get()[0].version, "1.0.1")
        page.verPageSize.set(0)
        @Expect(page.verRows.get().size, 1)
    }

    // 版本表「来源」列：本地发布 vs 回源镜像；「重拉」只对回源版本出现
    @TestCase
    public func covPkg_versionTableSourceColumn(): Unit {
        let state = makePortalState("team")
        let _ = covSeedPkg(state, "ystyle", "alpha", "1.0.0")
        let _ = covSeedPkg(state, "ystyle", "alpha", "1.0.1", upstreamId: 2, upstreamName: "mirror")
        let _ = covSeedPkg(state, "ystyle", "alpha", "1.0.2", upstreamId: 2)
        let page = mountPackagesCov(state)
        page.select("ystyle", "alpha")
        let json = covRender(page.render())
        @Expect(json.contains("本地发布"), true)
        @Expect(json.contains("回源 · mirror"), true)
        @Expect(json.contains("上游 #2"), true)   // upstreamName 为空时的兜底文案
    }

    // 主表「查看版本」按钮的分发：selectPackage 会打开抽屉并刷新版本
    @TestCase
    public func covPkg_selectPackageOpensDrawer(): Unit {
        let state = makePortalState("team")
        let _ = covSeedPkg(state, "ystyle", "alpha", "1.0.0")
        let page = mountPackagesCov(state)
        let (actx, _) = covActx(state)
        let _ = page.selectPackage(actx, "ystyle", "alpha")
        @Expect(page.verDrawerVisible.get(), true)
        @Expect(page.selOrg.get(), "ystyle")
        @Expect(page.selName.get(), "alpha")
        @Expect(page.verAll.get().size, 1)
        @Expect(page.verTitle.get(), "ystyle::alpha 的版本（1）")
    }

    // 空包名（"" / ""）时详情标题只给 name；版本来源文案也覆盖未命名上游
    @TestCase
    public func covPkg_versionSourceFallbacks(): Unit {
        @Expect(versionSource(covDocFor(0, "")), "本地发布")
        @Expect(versionSource(covDocFor(5, "")), "上游 #5")
        @Expect(versionSource(covDocFor(5, "up-x")), "回源 · up-x")
    }

    // 未挂载 state 的 onUnmount：两个 binding 都是 None 分支
    @TestCase
    public func covPkg_unmountWithoutMount(): Unit {
        let state = makePortalState("team")
        let page = PackagesPage()
        page.onUnmount(mountCtx(state, userCtxMap(1, "admin", true)))
        @Expect(page.verAll.get().size, 0)
    }

    // 重新挂载：rebind 走 Some 分支（旧绑定先 dispose），订阅不叠加
    @TestCase
    public func covPkg_remountRebuildsBindings(): Unit {
        let state = makePortalState("team")
        let _ = covSeedPkg(state, "ystyle", "alpha", "1.0.0")
        let page = mountPackagesCov(state)
        page.onMount(mountCtx(state, userCtxMap(1, "admin", true)))
        page.search.set("alpha")
        @Expect(page.rows.get().size, 1)
        page.search.set("nope")
        @Expect(page.rows.get().size, 0)
        @Expect(page.listHint(), "没有匹配的包")
    }

    // 长文本与特殊字符：搜索关键字里的 % 与引号不炸渲染
    @TestCase
    public func covPkg_specialCharsInSearch(): Unit {
        let state = makePortalState("team")
        let _ = covSeedPkg(state, "ystyle", "alpha", "1.0.0", desc: "含 \"引号\" 与 \\ 反斜杠")
        let page = mountPackagesCov(state)
        page.search.set("\"引号\"")
        @Expect(page.rows.get().size, 1)
        page.search.set("\\")
        @Expect(page.rows.get().size, 1)
        page.search.set("%")
        @Expect(page.rows.get().size, 0)
        @Expect(page.listHint(), "没有匹配的包")
        @Expect(covRender(page.render()).contains("没有匹配的包"), true)
    }

    // 版本表为空时的提示（选了包但没有版本记录）
    @TestCase
    public func covPkg_versionHintWhenNoVersions(): Unit {
        let state = makePortalState("team")
        let page = mountPackagesCov(state)
        @Expect(page.versionHint(), "该包还没有版本记录")
        @Expect(covRenderExpanded(page.render()).contains("没有匹配的包"), true)
    }
}

// versionSource 的入参构造（只为纯函数断言用）
func covDocFor(upstreamId: Int64, upstreamName: String): PackageDoc {
    let d = PackageDoc()
    d.upstreamId = upstreamId
    d.upstreamName = upstreamName
    d
}
