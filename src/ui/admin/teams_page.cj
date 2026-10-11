// 管理端团队管理（@Page /admin/teams）
package ystyle::cjreg.ui.admin

import ystyle::cjreg.ui.*
import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.model.*
import ystyle::cjreg.server.{transferTeamOwnerChecked, isTeamMember}
import std.collection.*
import std.convert.*

// ===== 团队管理 =====
@Page["/admin/teams", "团队管理", requireAdmin]
class TeamsPage <: Component {
    var state: Option<CjregState> = None
    var msg = Signal<String>("")
    // 行数据 + 分页（泛型 Table<TeamRow>：实体 + 关联计数视图）
    var rows = Signal<ArrayList<TeamRow>>(ArrayList<TeamRow>())
    var currentPage = Signal<Int64>(1)
    var pageSize = Signal<Int64>(20)
    var total = Signal<Int64>(0)
    // 基础表单 Dialog
    var dialogVisible = Signal<Bool>(false)
    var dialogMode = Signal<String>("create")
    var editingId: Int64 = 0
    var formName = Signal<String>("")
    var formDisplay = Signal<String>("")
    var formDesc = Signal<String>("")
    var formPermission = Signal<String>("read")
    // owner 自助：指定 owner（用户名）+ 是否开启自助（默认关，只有管理员能开）
    var formOwnerName = Signal<String>("")
    var formSelfService = Signal<Bool>(false)
    var teamNameError = Signal<String>("")
    var teamForm = Form([])
    // 组织关联 Dialog
    var orgDialogVisible = Signal<Bool>(false)
    var orgSelect = Signal<ArrayList<String>>(ArrayList<String>())
    // 包关联 Dialog
    var pkgDialogVisible = Signal<Bool>(false)
    var pkgSearch = Signal<String>("")
    var pkgRows = Signal<ArrayList<PkgRow>>(ArrayList<PkgRow>())
    // 成员关联 Dialog
    var memberDialogVisible = Signal<Bool>(false)
    var memberSearch = Signal<String>("")
    var memberRows = Signal<ArrayList<MemberRow>>(ArrayList<MemberRow>())
    // 删除确认
    var confirmVisible = Signal<Bool>(false)
    var pendingDeleteId: Int64 = 0
    var pendingDeleteName: String = ""
    // 两个弹窗列表的"数据版本"：store 与 editingId 都不是信号，改动后 bump 一次让派生重算
    var pkgVersion = Signal<Int64>(0)
    var memberVersion = Signal<Int64>(0)
    // 派生绑定：弹窗里的搜索必须"输入即过滤"（见 list_binding.cj 的根因说明）
    private var pkgBinding: Option<Effect> = None
    private var memberBinding: Option<Effect> = None

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        refresh()
        this.rebind()
    }

    public func onUnmount(ctx: LifecycleContext): Unit {
        match (this.pkgBinding) {
            case Some(e) => e.dispose()
            case None => ()
        }
        match (this.memberBinding) {
            case Some(e) => e.dispose()
            case None => ()
        }
        this.pkgBinding = None
        this.memberBinding = None
    }

    private func rebind(): Unit {
        match (this.pkgBinding) {
            case Some(e) => e.dispose()
            case None => ()
        }
        match (this.memberBinding) {
            case Some(e) => e.dispose()
            case None => ()
        }
        this.pkgBinding = Some(bindVisible(this.pkgRows, { => this.filteredPkgs() }))
        this.memberBinding = Some(bindVisible(this.memberRows, { => this.filteredMembers() }))
    }

    // 分页切片（行数据为 TeamRow 视图）
    func refresh(): Unit {
        match (this.state) {
            case Some(st) =>
                let teams = st.adminData.listTeams()
                this.total.set(teams.size)
                let (start, end) = pageWindow(teams.size, this.currentPage.get(), this.pageSize.get())
                let data = ArrayList<TeamRow>()
                var i = start
                while (i < end) {
                    let t = teams[i]
                    data.add(TeamRow(t,
                        st.adminData.listTeamMembers(t.id).size,
                        st.adminData.listTeamOrganizations(t.id).size,
                        st.adminData.listTeamPackages(t.id).size))
                    i++
                }
                this.rows.set(data)
            case None => ()
        }
    }

    func onPageChange(ctx: ActionContext): PatchResult {
        this.refresh()
        PatchResult.ReRender
    }

    // ===== 基础表单 =====
    func openCreate(ctx: ActionContext): PatchResult {
        this.dialogMode.set("create")
        this.formName.set("")
        this.formDisplay.set("")
        this.formDesc.set("")
        this.formPermission.set("read")
        this.formOwnerName.set("")
        this.formSelfService.set(false)
        this.teamNameError.set("")
        this.dialogVisible.set(true)
        PatchResult.ReRender
    }

    func openEdit(ctx: ActionContext, id: Int64): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        match (st.adminData.getTeam(id)) {
            case Some(t) =>
                this.dialogMode.set("edit")
                this.editingId = t.id
                this.formName.set(t.name)
                this.formDisplay.set(t.displayName)
                this.formDesc.set(t.description)
                this.formPermission.set(t.permission)
                // owner 用用户名回填（表单面向人，不要求记 id）
                this.formOwnerName.set(match (st.userStore.getUser(t.ownerId)) {
                    case Some(u) => u.username
                    case None => ""
                })
                this.formSelfService.set(t.selfService)
                this.teamNameError.set("")
                this.dialogVisible.set(true)
            case None => ()
        }
        PatchResult.ReRender
    }

    func closeDialog(ctx: ActionContext): PatchResult {
        this.dialogVisible.set(false)
        PatchResult.ReRender
    }

    func submitForm(ctx: ActionContext): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            this.msg.set("无权限：需要管理员登录")
            return PatchResult.ReRender
        }
        if (!this.teamForm.validate()) {
            return PatchResult.ReRender
        }
        let name = this.formName.get()
        let display = this.formDisplay.get()
        let desc = this.formDesc.get()
        let perm = this.formPermission.get()
        let ownerName = this.formOwnerName.get().trimAscii()
        let selfService = this.formSelfService.get()
        let uid = sessionUid(ctx)
        let uname = sessionUsername(ctx)
        // owner 按用户名解析（表单不暴露 id）；填了但查不到 → 直接拒绝，避免静默丢字段
        var ownerId: Int64 = 0
        if (!ownerName.isEmpty()) {
            var found = false
            for (u in st.userStore.listAllUsers()) {
                if (u.username == ownerName) {
                    ownerId = u.id
                    found = true
                }
            }
            if (!found) {
                this.teamNameError.set("所有者用户名不存在：${ownerName}")
                return PatchResult.ReRender
            }
        }
        if (selfService && ownerId <= 0) {
            this.teamNameError.set("开启 owner 自助前必须先指定所有者")
            return PatchResult.ReRender
        }
        if (this.dialogMode.get() == "create") {
            let id = st.adminData.createTeam(name, nowMs(), displayName: display, description: desc,
                permission: perm, ownerId: ownerId, selfService: selfService)
            if (ownerId > 0 && !isTeamMember(st.adminData, id, ownerId)) {
                st.adminData.addTeamMember(id, ownerId)
            }
            this.msg.set("已创建团队 #${id}")
            uiAuditAs(st, uid, uname, "create_team", name,
                detail: "permission=${perm} ownerId=${ownerId} selfService=${selfService}")
        } else {
            // owner 变更走转让语义（自动补成员），其余字段走局部更新
            let cur = st.adminData.getTeam(this.editingId)
            var ownerNote = ""
            match (cur) {
                case Some(t) =>
                    if (ownerId != t.ownerId) {
                        if (ownerId > 0) {
                            let r = transferTeamOwnerChecked(st.adminData, st.userStore, this.editingId, ownerId, nowMs())
                            if (!r.ok) {
                                this.teamNameError.set(r.message)
                                return PatchResult.ReRender
                            }
                        } else {
                            let _ = st.adminData.setTeamOwner(this.editingId, 0, nowMs())
                        }
                        ownerNote = " ownerId=${ownerId}"
                    }
                case None => ()
            }
            if (st.adminData.updateTeam(this.editingId, display, desc, perm, nowMs(), selfService: Some(selfService))) {
                this.msg.set("已更新团队 ${name}")
                uiAuditAs(st, uid, uname, "update_team", name,
                    detail: "permission=${perm} selfService=${selfService}${ownerNote}")
            } else {
                this.msg.set("更新失败")
            }
        }
        this.dialogVisible.set(false)
        this.refresh()
        PatchResult.ReRender
    }

    // ===== 组织关联 =====
    func openOrgs(ctx: ActionContext, id: Int64): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        this.editingId = id
        let ids = ArrayList<String>()
        for (oid in st.adminData.listTeamOrganizationIds(id)) {
            ids.add(oid.toString())
        }
        this.orgSelect.set(ids)
        this.orgDialogVisible.set(true)
        PatchResult.ReRender
    }

    func closeOrgs(ctx: ActionContext): PatchResult {
        this.orgDialogVisible.set(false)
        PatchResult.ReRender
    }

    func saveOrgs(ctx: ActionContext): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            this.msg.set("无权限：需要管理员登录")
            return PatchResult.ReRender
        }
        let ids = ArrayList<Int64>()
        for (v in this.orgSelect.get()) {
            let n = match (Int64.tryParse(v)) {
                case Some(x) => x
                case None => 0
            }
            ids.add(n)
        }
        st.adminData.setTeamOrganizations(this.editingId, ids.toArray(), nowMs())
        this.msg.set("已更新团队组织关联")
        uiAudit(st, ctx, "set_team_orgs", "team#${this.editingId}", detail: "count=${ids.size}")
        this.orgDialogVisible.set(false)
        PatchResult.ReRender
    }

    // ===== 包关联 =====
    func openPackages(ctx: ActionContext, id: Int64): PatchResult {
        this.editingId = id
        this.pkgSearch.set("")
        this.refreshPkgs()
        this.pkgDialogVisible.set(true)
        PatchResult.ReRender
    }

    func closePackages(ctx: ActionContext): PatchResult {
        this.pkgDialogVisible.set(false)
        PatchResult.ReRender
    }

    // 包关联列表：全量包 + 搜索过滤 + 关联标记。
    // 读到的每个信号都被 pkgBinding 的 Effect 订阅 → 关键字一变就自动重算。
    func filteredPkgs(): ArrayList<PkgRow> {
        let _ = this.pkgVersion.get()
        let data = ArrayList<PkgRow>()
        let st = match (this.state) {
            case Some(x) => x
            case None => return data
        }
        let kw = this.pkgSearch.get().trimAscii()
        let linked = st.adminData.listTeamPackages(this.editingId)
        for (d in st.pkgStore.storm.all<PackageDoc>()) {
            if (d.deletedAt != 0) { continue }
            if (kw != "" && !d.name.contains(kw)) { continue }
            var isLinked = false
            for (p in linked) {
                if (p.organization == d.organization && p.packageName == d.name) {
                    isLinked = true
                    break
                }
            }
            data.add(PkgRow(d, isLinked))
        }
        data
    }

    // 数据变了（换团队、关联/移除）就 bump：效果会重算并写回 pkgRows
    func refreshPkgs(): Unit {
        this.pkgVersion.update({ v => v + 1 })
    }

    func togglePkg(ctx: ActionContext, org: String, name: String): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            this.msg.set("无权限：需要管理员登录")
            return PatchResult.ReRender
        }
        let cur = st.adminData.listTeamPackages(this.editingId)
        var found = false
        let next = ArrayList<(String, String)>()
        for (p in cur) {
            if (p.organization == org && p.packageName == name) {
                found = true
            } else {
                next.add((p.organization, p.packageName))
            }
        }
        if (!found) {
            next.add((org, name))
        }
        st.adminData.setTeamPackages(this.editingId, next.toArray(), nowMs())
        this.msg.set(if (!found) { "已关联 ${name}" } else { "已移除 ${name}" })
        this.refreshPkgs()
        PatchResult.ReRender
    }

    // ===== 成员关联 =====
    func openMembers(ctx: ActionContext, id: Int64): PatchResult {
        this.editingId = id
        this.memberSearch.set("")
        this.refreshMembers()
        this.memberDialogVisible.set(true)
        PatchResult.ReRender
    }

    func closeMembers(ctx: ActionContext): PatchResult {
        this.memberDialogVisible.set(false)
        PatchResult.ReRender
    }

    // 成员列表：全量用户 + 搜索过滤 + 关联标记（派生逻辑同 filteredPkgs）
    func filteredMembers(): ArrayList<MemberRow> {
        let _ = this.memberVersion.get()
        let data = ArrayList<MemberRow>()
        let st = match (this.state) {
            case Some(x) => x
            case None => return data
        }
        let kw = this.memberSearch.get().trimAscii()
        let linked = st.adminData.listTeamMemberIds(this.editingId)
        for (u in st.userStore.listAllUsers()) {
            if (kw != "" && !u.username.contains(kw)) { continue }
            var isLinked = false
            for (uid in linked) {
                if (uid == u.id) {
                    isLinked = true
                    break
                }
            }
            data.add(MemberRow(u, isLinked))
        }
        data
    }

    func refreshMembers(): Unit {
        this.memberVersion.update({ v => v + 1 })
    }

    func toggleMember(ctx: ActionContext, userId: Int64): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            this.msg.set("无权限：需要管理员登录")
            return PatchResult.ReRender
        }
        let cur = st.adminData.listTeamMemberIds(this.editingId)
        var found = false
        let next = ArrayList<Int64>()
        for (uid in cur) {
            if (uid == userId) {
                found = true
            } else {
                next.add(uid)
            }
        }
        if (!found) {
            next.add(userId)
        }
        st.adminData.setTeamMembers(this.editingId, next.toArray())
        let memberName = match (st.userStore.getUser(userId)) {
            case Some(u) => u.username
            case None => "#${userId}"
        }
        uiAudit(st, ctx, if (!found) { "add_team_member" } else { "remove_team_member" }, memberName,
            detail: "team#${this.editingId} members=${next.size}")
        this.msg.set(if (!found) { "已添加成员" } else { "已移除成员" })
        this.refreshMembers()
        PatchResult.ReRender
    }

    // ===== 删除 =====
    func askDelete(ctx: ActionContext, id: Int64): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        match (st.adminData.getTeam(id)) {
            case Some(t) =>
                this.pendingDeleteId = t.id
                this.pendingDeleteName = t.name
                this.confirmVisible.set(true)
            case None => ()
        }
        PatchResult.ReRender
    }

    func cancelDelete(ctx: ActionContext): PatchResult {
        this.confirmVisible.set(false)
        PatchResult.ReRender
    }

    func confirmDelete(ctx: ActionContext): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (!st.isAdminSession(ctx)) {
            this.msg.set("无权限：需要管理员登录")
            return PatchResult.ReRender
        }
        if (st.adminData.deleteTeam(this.pendingDeleteId, nowMs())) {
            this.msg.set("已删除团队 ${this.pendingDeleteName}")
            uiAudit(st, ctx, "delete_team", this.pendingDeleteName)
        } else {
            this.msg.set("删除失败")
        }
        this.confirmVisible.set(false)
        this.pendingDeleteId = 0
        PatchResult.ReRender
    }

    // ===== 渲染 =====
    func permTag(p: String): IComponent {
        match (p) {
            case "write" => Tag([text("写入")]).kind(ComponentKind.Warning)
            case "overwrite" => Tag([text("覆盖")]).kind(ComponentKind.Danger)
            case _ => Tag([text("读取")]).kind(ComponentKind.Info)
        }
    }

    func listHint(): String {
        if (this.rows.get().size == 0) {
            return "暂无团队，点击「新增团队」创建"
        }
        ""
    }

    func renderList(): IComponent {
        Table<TeamRow>()
            .data(this.rows)
            .emptyText("暂无数据")
            .stripe()
            .add(TableColumn<TeamRow>().label("ID").accessor({ r => r.doc.id.toString() }).width(50))
            // 「团队名」与「显示名」合并成一列：有显示名时显示显示名、副行给出标识名，
            // 避免两列内容高度重复还挤掉右侧的操作列
            .add(TableColumn<TeamRow>().label("团队").minWidth(140).render({ r, i =>
                if (r.doc.displayName.isEmpty()) {
                    text(r.doc.name)
                } else {
                    div([
                        text(r.doc.displayName),
                        div([text(r.doc.name)], attrs: Some(HashMap<String, String>([("class", cls("portal-dim"))]))),
                    ])
                }
            }))
            .add(TableColumn<TeamRow>().label("权限").width(90).render({ r, i =>
                this.permTag(r.doc.permission)
            }))
            .add(TableColumn<TeamRow>().label("所有者").width(110).render({ r, i =>
                if (r.doc.ownerId > 0) {
                    text(this.ownerNameOf(r.doc.ownerId))
                } else {
                    text("-")
                }
            }))
            .add(TableColumn<TeamRow>().label("owner 自助").width(100).render({ r, i =>
                if (r.doc.selfService) {
                    Tag([text("已开启")]).kind(ComponentKind.Warning)
                } else {
                    text("关闭")
                }
            }))
                        // 三列计数合成一列，避免把操作列挤到视口外
            .add(TableColumn<TeamRow>().label("关联").width(132).render({ r, i =>
                div([text("成员 ${r.members}｜组织 ${r.orgs}｜包 ${r.pkgs}")],
                    attrs: Some(HashMap<String, String>([("class", cls("nowrap-dim"))])))
            }))
            .add(TableColumn<TeamRow>().label("操作").width(400).render({ r, i =>
                let id = r.doc.id
                let editH: ActionHandler = { c => this.openEdit(c, id) }
                let orgH: ActionHandler = { c => this.openOrgs(c, id) }
                let pkgH: ActionHandler = { c => this.openPackages(c, id) }
                let memberH: ActionHandler = { c => this.openMembers(c, id) }
                let deleteH: ActionHandler = { c => this.askDelete(c, id) }
                // 按钮组必须走 flex + gap：裸 div 里按钮会随列宽任意折行（实测折成 3 行）
                div([
                    Button([text("编辑")]).size(ButtonSize.Small).onClick(editH),
                    Button([text("组织")]).size(ButtonSize.Small).onClick(orgH),
                    Button([text("包")]).size(ButtonSize.Small).onClick(pkgH),
                    Button([text("成员")]).size(ButtonSize.Small).onClick(memberH),
                    Button([text("删除")]).size(ButtonSize.Small).kind(ButtonKind.Danger).onClick(deleteH),
                ], attrs: Some(HashMap<String, String>([("class", cls("btn-row"))])))
            }))
    }

    // ownerId → 用户名（表格展示用）
    func ownerNameOf(userId: Int64): String {
        match (this.state) {
            case Some(st) => match (st.userStore.getUser(userId)) {
                case Some(u) => u.username
                case None => "#${userId}"
            }
            case None => "#${userId}"
        }
    }

    func renderFormDialog(): IComponent {
        let title = if (this.dialogMode.get() == "create") { "新增团队" } else { "编辑团队" }
        let isEdit = this.dialogMode.get() == "edit"
        let nameInput = if (isEdit) {
            Input().bind(this.formName).disabled()
        } else {
            Input().bind(this.formName)
        }
        let permSelect = Select([
            SelectOption([text("读取（可下载）")], "read"),
            SelectOption([text("写入（可发布）")], "write"),
            SelectOption([text("覆盖（可覆盖版本）")], "overwrite"),
        ]).bind(this.formPermission).placeholder("默认权限")
        let form = Form([
            FormItem([nameInput]).label("团队名")
                .bindValue({ => this.formName.get() })
                .rule(FormRule(required: true, message: "团队名必填"))
                .errorSignal(this.teamNameError),
            FormItem([Input().bind(this.formDisplay).placeholder("可选")]).label("显示名")
                .bindValue({ => this.formDisplay.get() }),
            FormItem([Input().bind(this.formDesc).placeholder("可选")]).label("描述")
                .bindValue({ => this.formDesc.get() }),
            FormItem([permSelect]).label("默认权限")
                .bindValue({ => this.formPermission.get() }),
            FormItem([Input().bind(this.formOwnerName).placeholder("留空 = 不指定")]).label("所有者（用户名）")
                .bindValue({ => this.formOwnerName.get() }),
            FormItem([Switch().bind(this.formSelfService).activeText("开启").inactiveText("关闭")])
                .label("owner 自助"),
        ]).labelTop()
        this.teamForm = form
        let dlg = Dialog([form])
            .visible(this.dialogVisible)
            .title(title)
            .width("440px")
            .closeOnClickModal(false)
            .footer([
                Button([text("取消")]).onClick(closeDialog),
                Button([text("确定")]).kind(ButtonKind.Primary).onClick(submitForm),
            ])
        dlg
    }

    func renderOrgDialog(): IComponent {
        let orgOptions = ArrayList<IComponent>()
        let st = match (this.state) {
            case Some(x) => x
            case None => return div()
        }
        // 无组织包选项（value=0，对齐 cjrepo NULL 语义）
        orgOptions.add(SelectOption([text("（无组织包）")], "0"))
        for (o in st.adminData.listOrgs()) {
            let label = if (o.displayName.isEmpty()) { o.name } else { "${o.displayName}（${o.name}）" }
            orgOptions.add(SelectOption([text(label)], o.id.toString()))
        }
        let dlg = Dialog([
            div([
                div([text("选择团队可操作的组织（含「无组织包」；可多选）")], attrs: Some(HashMap<String, String>([("class", cls("dialog-form-label"))]))),
                Select(orgOptions.toArray()).bindMulti(this.orgSelect).multiple().placeholder("选择组织"),
            ], attrs: Some(HashMap<String, String>([("class", cls("dialog-form"))]))),
        ])
            .visible(this.orgDialogVisible)
            .title("团队组织关联")
            .width("480px")
            .closeOnClickModal(false)
            .footer([
                Button([text("取消")]).onClick(closeOrgs),
                Button([text("保存")]).kind(ButtonKind.Primary).onClick(saveOrgs),
            ])
        dlg
    }

    func renderPkgDialog(): IComponent {
        let dlg = Dialog([
            div([
                div([text("搜索包并关联/移除（权限走团队默认权限）")], attrs: Some(HashMap<String, String>([("class", cls("dialog-form-label"))]))),
                // 只 bind：过滤由 pkgBinding 的 Effect 跟着关键字重算。
                // 旧写法在 input 的 action 里 refreshPkgs()，而前端先 action 后 bind
                // （cjxt public/js/cangjie-ui.js:333 立即发 action，:490 的 bind 有 300ms 防抖），
                // action 里读到的关键字还是上一次的 → 搜索框里打字等于没反应。
                Input().bind(this.pkgSearch).placeholder("搜索包名"),
                Table<PkgRow>()
                    .data(this.pkgRows)
                    .emptyText("暂无数据")
                    .stripe()
                    .add(TableColumn<PkgRow>().label("包").minWidth(280).render({ r, i =>
                        text("${if (r.doc.organization.isEmpty()) { "-" } else { r.doc.organization }}/${r.doc.name}@${r.doc.version}")
                    }))
                    .add(TableColumn<PkgRow>().label("操作").width(100).render({ r, i =>
                        let org = r.doc.organization
                        let name = r.doc.name
                        let toggleH: ActionHandler = { c => this.togglePkg(c, org, name) }
                        Button([text(if (r.linked) { "移除" } else { "关联" })]).size(ButtonSize.Small).kind(if (r.linked) { ButtonKind.Danger } else { ButtonKind.Primary }).onClick(toggleH)
                    })),
            ], attrs: Some(HashMap<String, String>([("class", cls("dialog-form"))]))),
        ])
            .visible(this.pkgDialogVisible)
            .title("团队包关联")
            .width("560px")
            .closeOnClickModal(false)
            .footer([
                Button([text("关闭")]).onClick(closePackages),
            ])
        dlg
    }

    func renderMemberDialog(): IComponent {
        let dlg = Dialog([
            div([
                div([text("搜索用户并添加/移除成员")], attrs: Some(HashMap<String, String>([("class", cls("dialog-form-label"))]))),
                Input().bind(this.memberSearch).placeholder("搜索用户名"),   // 同 pkgSearch：只 bind
                Table<MemberRow>()
                    .data(this.memberRows)
                    .emptyText("暂无数据")
                    .stripe()
                    .add(TableColumn<MemberRow>().label("用户名").accessor({ r => r.user.username }).minWidth(200))
                    .add(TableColumn<MemberRow>().label("操作").width(100).render({ r, i =>
                        let uid = r.user.id
                        let toggleH: ActionHandler = { c => this.toggleMember(c, uid) }
                        Button([text(if (r.linked) { "移除" } else { "添加" })]).size(ButtonSize.Small).kind(if (r.linked) { ButtonKind.Danger } else { ButtonKind.Primary }).onClick(toggleH)
                    })),
            ], attrs: Some(HashMap<String, String>([("class", cls("dialog-form"))]))),
        ])
            .visible(this.memberDialogVisible)
            .title("团队成员管理")
            .width("480px")
            .closeOnClickModal(false)
            .footer([
                Button([text("关闭")]).onClick(closeMembers),
            ])
        dlg
    }

    func renderConfirmDialog(): IComponent {
        let dlg = Dialog([
            div([text("确定要删除团队「${this.pendingDeleteName}」吗？其组织/包/成员关联将一并移除。")]),
        ])
            .visible(this.confirmVisible)
            .title("删除确认")
            .width("400px")
            .closeOnClickModal(false)
            .footer([
                Button([text("取消")]).onClick(cancelDelete),
                Button([text("删除")]).kind(ButtonKind.Danger).onClick(confirmDelete),
            ])
        dlg
    }

    public func render(): IComponent {
        let toolbar = div([
            Button([text("新增团队")]).kind(ButtonKind.Primary).onClick(openCreate),
            if (this.msg.get() != "") {
                Tag([text(this.msg.get())]).kind(ComponentKind.Success)
            } else {
                div()
            },
        ], attrs: Some(HashMap<String, String>([("class", cls("toolbar"))])))
        let pager = Pagination()
            .currentPage(this.currentPage)
            .pageSize(this.pageSize)
            .total(this.total.get())
            .layout("total, prev, pager, next, sizes")
            .onChange(onPageChange)
        adminLayout("/admin/teams", [
            div([text("团队管理")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            adminCard("团队列表", [toolbar, listBody(this.listHint(), this.renderList()), pager,
                this.renderFormDialog(), this.renderOrgDialog(), this.renderPkgDialog(),
                this.renderMemberDialog(), this.renderConfirmDialog()]),
        ])
    }
}
