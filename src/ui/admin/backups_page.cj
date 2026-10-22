// 管理端备份与恢复页（@Page /admin/backups）
//
// 能力边界（页面上也写清楚）：
// - **备份在线做**：服务端复用已持有的 Storm（只读快照），不需要停服；
// - **恢复不在线做**：Badger 独占数据目录、store 被全进程持有。所以本页只做
//   「上传归档 → 在线校验 → 标记下次重启应用」，重启后由启动流程替换并自动回滚。
package ystyle::cjreg.ui.admin

import ystyle::cjreg.ui.*
import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import ystyle::cjreg.store.*
import ystyle::cjreg.server.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.time.*

/** 备份归档行（页面展示用）。 */
class BackupRow {
    let fileName: String
    let sizeText: String
    let timeText: String
    let downloadUrl: String

    init(fileName: String, sizeText: String, timeText: String, downloadUrl: String) {
        this.fileName = fileName
        this.sizeText = sizeText
        this.timeText = timeText
        this.downloadUrl = downloadUrl
    }
}

@Page["/admin/backups", "备份与恢复", requireAdmin]
class BackupsPage <: Component {
    var state: Option<CjregState> = None
    var rows = Signal<ArrayList<BackupRow>>(ArrayList<BackupRow>())
    var msg = Signal<String>("")
    var busy = Signal<Bool>(false)
    var includeBlobs = Signal<Bool>(true)
    var pendingRestore = Signal<String>("")
    var dataVersion = Signal<Int64>(0)
    // 恢复上传：粘贴归档路径 or 上传（服务端同机）→ 校验 → 标记重启应用
    var restoreFile = Signal<String>("")
    var restoreResult = Signal<String>("")
    private var binding: Option<Effect> = None

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        this.rebind()
    }

    public func onUnmount(ctx: LifecycleContext): Unit {
        match (this.binding) {
            case Some(e) => e.dispose()
            case None => ()
        }
        this.binding = None
    }

    private func rebind(): Unit {
        match (this.binding) {
            case Some(e) => e.dispose()
            case None => ()
        }
        this.binding = Some(Effect({ => this.reload() }))
    }

    func bump(): Unit {
        this.dataVersion.update({ v => v + 1 })
    }

    private func svc(): ?OnlineBackupService {
        match (this.state) {
            case Some(st) => st.backupSvc
            case None => None
        }
    }

    /** 派生：数据版本变化时重建行（备份是异步的，完成后需要手动/轮询刷新）。 */
    func reload(): Unit {
        let _ = this.dataVersion.get()
        let s = match (this.svc()) {
            case Some(x) => x
            case None =>
                this.msg.set("备份服务未启用")
                return
        }
        this.busy.set(s.busy())
        let list = ArrayList<BackupRow>()
        for ((name, size, _) in s.listArchives()) {
            list.add(BackupRow(name, formatBytes(size), timeTextOf(name), "/api/admin/backups/${name}/download"))
        }
        this.rows.set(list)
        this.pendingRestore.set(pendingRestoreInfo(this.dataDir())[0])
    }

    // ===== 动作 =====
    func onRefresh(ctx: ActionContext): PatchResult {
        this.reload()
        PatchResult.ReRender
    }

    func onStartBackup(ctx: ActionContext): PatchResult {
        let s = match (this.svc()) {
            case Some(x) => x
            case None =>
                this.msg.set("备份服务未启用")
                return PatchResult.ReRender
        }
        match (s.startBackup(this.includeBlobs.get())) {
            case Some(job) =>
                this.msg.set("已开始备份 ${job.fileName}（后台执行，完成后刷新列表）")
            case None =>
                this.msg.set("已有备份任务在运行，请稍候")
        }
        this.bump()
        PatchResult.ReRender
    }

    func onDelete(ctx: ActionContext, fileName: String): PatchResult {
        let s = match (this.svc()) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (s.deleteArchive(fileName)) {
            this.msg.set("已删除 ${fileName}")
        } else {
            this.msg.set("删除失败：文件不存在")
        }
        this.bump()
        PatchResult.ReRender
    }

    /** 校验同机上的一个归档（等价 CLI 的 --check-only），不写库。 */
    func onVerify(ctx: ActionContext, fileName: String): PatchResult {
        let s = match (this.svc()) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        match (s.archivePath(fileName)) {
            case Some(path) =>
                try {
                    let r = restoreBackup("", path, checkOnly: true)
                    this.restoreResult.set("校验通过：${r.totalRows} 行、制品 ${r.blobFiles} 个（${fileName}）")
                } catch (e: Exception) {
                    this.restoreResult.set("校验失败：${e.message}")
                }
            case None =>
                this.restoreResult.set("文件不存在：${fileName}")
        }
        PatchResult.ReRender
    }

    /** 标记「下次重启应用这个归档」。恢复本身在重启时执行（含自动回滚）。 */
    func onApplyOnRestart(ctx: ActionContext, fileName: String): PatchResult {
        let s = match (this.svc()) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (s.archivePath(fileName).isNone()) {
            this.msg.set("文件不存在：${fileName}")
            return PatchResult.ReRender
        }
        this.writePending(fileName)
        this.msg.set("已标记：下次重启服务时应用 ${fileName}（失败会自动回滚）")
        this.bump()
        PatchResult.ReRender
    }

    func onCancelPending(ctx: ActionContext): PatchResult {
        this.clearPending()
        this.msg.set("已取消待应用的恢复")
        this.bump()
        PatchResult.ReRender
    }

    // 标记文件读写（UI 与 CLI 共用同一份格式：{"file":"..","at":ms}）
    private func dataDir(): String {
        match (this.state) {
            case Some(st) => st.dataDir
            case None => ""
        }
    }

    private func writePending(fileName: String): Unit {
        let dir = this.dataDir()
        if (dir.isEmpty()) {
            return
        }
        let f = File("${dir}/.restore-pending", Write)
        f.write("{\"file\":\"${fileName}\",\"at\":${DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()}}".toArray())
        f.close()
    }

    private func clearPending(): Unit {
        let dir = this.dataDir()
        if (dir.isEmpty()) {
            return
        }
        let path = "${dir}/.restore-pending"
        if (exists(Path(path))) {
            removeIfExists(Path(path), recursive: false)
        }
    }

    // ===== 渲染 =====
    func renderList(): IComponent {
        Table<BackupRow>()
            .data(this.rows)
            .emptyText("暂无备份，点「立即备份」创建")
            .stripe()
            .add(TableColumn<BackupRow>().label("归档").accessor({ r => r.fileName }).minWidth(240))
            .add(TableColumn<BackupRow>().label("大小").accessor({ r => r.sizeText }).width(100))
            .add(TableColumn<BackupRow>().label("时间").accessor({ r => r.timeText }).width(130))
            .add(TableColumn<BackupRow>().label("操作").width(300).render({ r, i =>
                let name = r.fileName
                let verifyH: ActionHandler = { c => this.onVerify(c, name) }
                let applyH: ActionHandler = { c => this.onApplyOnRestart(c, name) }
                let deleteH: ActionHandler = { c => this.onDelete(c, name) }
                div([
                    Link([text("下载")]).href(r.downloadUrl),
                    Button([text("校验")]).size(ButtonSize.Small).onClick(verifyH),
                    Button([text("重启时应用")]).size(ButtonSize.Small).kind(ButtonKind.Warning).onClick(applyH),
                    Button([text("删除")]).size(ButtonSize.Small).kind(ButtonKind.Danger).onClick(deleteH),
                ], attrs: Some(HashMap<String, String>([("style", "display:flex;gap:8px;align-items:center;flex-wrap:nowrap;")])))
            }))
    }

    func renderPending(): IComponent {
        let name = this.pendingRestore.get()
        if (name.isEmpty()) {
            return div()
        }
        let cancelH: ActionHandler = { c => this.onCancelPending(c) }
        return Alert()
            .children([text("已标记：下次重启服务将应用 ${name}（成功则替换数据，失败自动回滚并保留旧数据）")])
            .kind(AlertKind2.Warning)
            .showIcon()
    }

    public func render(): IComponent {
        let startH: ActionHandler = { c => this.onStartBackup(c) }
        let refreshH: ActionHandler = { c => this.onRefresh(c) }
        let toolbar = div([
            Button([text("立即备份")]).kind(ButtonKind.Primary).onClick(startH),
            Button([text("刷新")]).onClick(refreshH),
            if (this.busy.get()) {
                Tag([text("备份进行中…")]).kind(ComponentKind.Warning)
            } else {
                div()
            },
            if (this.msg.get() != "") {
                Tag([text(this.msg.get())]).kind(ComponentKind.Success)
            } else {
                div()
            },
        ], attrs: Some(HashMap<String, String>([("class", cls("toolbar"))])))

        let note = Alert()
            .children([text("备份在服务端进程内执行（复用当前数据库的只读快照），不需要停服。" +
                "恢复不在线做：归档替换需要独占数据目录，所以流程是「校验 → 标记 → 重启服务时应用」，" +
                "重启失败会自动回滚到恢复前的数据。")])
            .kind(AlertKind2.Info)
            .showIcon()

        let verifyBox = if (this.restoreResult.get() != "") {
            Alert().children([text(this.restoreResult.get())]).kind(AlertKind2.Success).showIcon()
        } else {
            div()
        }

        adminLayout("/admin/backups", [
            div([text("备份与恢复")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            this.renderPending(),
            adminCard("在线备份", [note, toolbar,
                FormItem([Switch().bind(this.includeBlobs).activeText("含制品").inactiveText("仅数据库")])
                    .label("备份内容"),
                listBody(this.listHint(), this.renderList())]),
            adminCard("恢复", [verifyBox,
                Alert()
                    .children([text("恢复步骤：① 上传或选择归档 → ② 校验（只读，不写库）→ ③ 标记「重启时应用」→ " +
                        "④ 重启服务，启动时替换数据；失败自动回滚。归档含口令哈希与 Token，请按敏感文件保管。")])
                    .kind(AlertKind2.Warning)
                    .showIcon(),
                p([text("上传接口：POST /api/admin/backups/restore-check（请求体为 tar.gz 字节）；" +
                    "命令行等价：cjreg admin restore -d <空目录> --from <归档> --check-only")]),
            ]),
        ])
    }

    func listHint(): String {
        if (this.rows.get().size == 0) {
            return "暂无备份"
        }
        ""
    }
}

// ===== 工具 =====

func formatBytes(n: Int64): String {
    if (n >= 1024 * 1024 * 1024) {
        return "${n / (1024 * 1024 * 1024)} GB"
    }
    if (n >= 1024 * 1024) {
        return "${n / (1024 * 1024)} MB"
    }
    if (n >= 1024) {
        return "${n / 1024} KB"
    }
    "${n} B"
}

/** 从 cjreg-20261022-153000.tar.gz 里还原可读时间；解析失败就原样显示文件名。 */
func timeTextOf(fileName: String): String {
    if (!fileName.startsWith("cjreg-") || fileName.size < 22) {
        return fileName
    }
    let stamp = fileName[6..21]  // 20261022-153000
    if (stamp.size != 15) {
        return fileName
    }
    let date = stamp[0..8]
    let time = stamp[9..15]
    "${date[4..6]}-${date[6..8]} ${time[0..2]}:${time[2..4]}"
}
