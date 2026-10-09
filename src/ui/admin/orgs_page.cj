// 管理端组织管理（@Page /admin/organizations）
package ystyle::cjreg.ui.admin

import ystyle::cjreg.ui.*
import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.model.*
import std.collection.*
import std.convert.*

// ===== 组织管理 =====
@Page["/admin/organizations", "组织管理", requireAdmin]
class OrganizationsPage <: Component {
    var state: Option<CjregState> = None
    var msg = Signal<String>("")
    // 行数据 + 分页（泛型 Table<OrgDoc>）
    var rows = Signal<ArrayList<OrgDoc>>(ArrayList<OrgDoc>())
    var currentPage = Signal<Int64>(1)
    var pageSize = Signal<Int64>(20)
    var total = Signal<Int64>(0)
    // 新增/编辑 Dialog
    var dialogVisible = Signal<Bool>(false)
    var dialogMode = Signal<String>("create")
    var editingId: Int64 = 0
    var formName = Signal<String>("")
    var formDisplay = Signal<String>("")
    var formDesc = Signal<String>("")
    var formIsDefault = Signal<Bool>(false)
    var nameError = Signal<String>("")
    var orgForm = Form([])
    // 删除确认
    var confirmVisible = Signal<Bool>(false)
    var pendingDeleteId: Int64 = 0
    var pendingDeleteName: String = ""

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        refresh()
    }

    // 分页切片（行数据直接为强类型 OrgDoc）
    func refresh(): Unit {
        match (this.state) {
            case Some(st) =>
                let orgs = st.adminData.listOrgs()
                this.total.set(orgs.size)
                let (start, end) = pageWindow(orgs.size, this.currentPage.get(), this.pageSize.get())
                let data = ArrayList<OrgDoc>()
                var i = start
                while (i < end) {
                    data.add(orgs[i])
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

    // ===== 新增/编辑 =====
    func openCreate(ctx: ActionContext): PatchResult {
        this.dialogMode.set("create")
        this.formName.set("")
        this.formDisplay.set("")
        this.formDesc.set("")
        this.formIsDefault.set(false)
        this.nameError.set("")
        this.dialogVisible.set(true)
        PatchResult.ReRender
    }

    func openEdit(ctx: ActionContext, id: Int64): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        match (st.adminData.getOrg(id)) {
            case Some(o) =>
                this.dialogMode.set("edit")
                this.editingId = o.id
                this.formName.set(o.name)
                this.formDisplay.set(o.displayName)
                this.formDesc.set(o.description)
                this.formIsDefault.set(o.isDefault)
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
        if (!this.orgForm.validate()) {
            return PatchResult.ReRender
        }
        let name = this.formName.get()
        let display = this.formDisplay.get()
        let desc = this.formDesc.get()
        let isDefault = this.formIsDefault.get()
        let uid = sessionUid(ctx)
        let uname = sessionUsername(ctx)
        if (this.dialogMode.get() == "create") {
            let id = st.adminData.createOrg(name, display, uid, nowMs(), description: desc, isDefault: isDefault)
            this.msg.set("已创建组织 #${id}")
            uiAuditAs(st, uid, uname, "create_org", name, detail: "isDefault=${isDefault}")
        } else {
            if (st.adminData.updateOrg(this.editingId, display, desc, isDefault, nowMs())) {
                this.msg.set("已更新组织 ${name}")
                uiAuditAs(st, uid, uname, "update_org", name, detail: "isDefault=${isDefault}")
            } else {
                this.msg.set("更新失败")
            }
        }
        this.dialogVisible.set(false)
        this.refresh()
        PatchResult.ReRender
    }

    // ===== 删除 =====
    func askDelete(ctx: ActionContext, id: Int64): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        match (st.adminData.getOrg(id)) {
            case Some(o) =>
                this.pendingDeleteId = o.id
                this.pendingDeleteName = o.name
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
        if (st.adminData.deleteOrg(this.pendingDeleteId, nowMs())) {
            this.msg.set("已删除组织 ${this.pendingDeleteName}")
            uiAudit(st, ctx, "delete_org", this.pendingDeleteName)
        } else {
            this.msg.set("删除失败")
        }
        this.confirmVisible.set(false)
        this.pendingDeleteId = 0
        PatchResult.ReRender
    }

    // ===== 渲染 =====
    func listHint(): String {
        if (this.rows.get().size == 0) {
            return "暂无组织，点击「新增组织」创建"
        }
        ""
    }

    func renderList(): IComponent {
        Table<OrgDoc>()
            .data(this.rows)
            .emptyText("暂无数据")
            .stripe()
            .add(TableColumn<OrgDoc>().label("ID").accessor({ o => o.id.toString() }).width(60))
            .add(TableColumn<OrgDoc>().label("组织名").accessor({ o => o.name }).minWidth(140))
            .add(TableColumn<OrgDoc>().label("显示名").accessor({ o => o.displayName }).minWidth(140))
            .add(TableColumn<OrgDoc>().label("描述").accessor({ o => o.description }).minWidth(200))
            .add(TableColumn<OrgDoc>().label("默认").width(80).render({ o, i =>
                if (o.isDefault) {
                    Tag([text("默认")]).kind(ComponentKind.Primary)
                } else {
                    Tag([text("普通")]).kind(ComponentKind.Info)
                }
            }))
            .add(TableColumn<OrgDoc>().label("操作").minWidth(180).render({ o, i =>
                let editH: ActionHandler = { c => this.openEdit(c, o.id) }
                let deleteH: ActionHandler = { c => this.askDelete(c, o.id) }
                div([
                    Button([text("编辑")]).size(ButtonSize.Small).onClick(editH),
                    Button([text("删除")]).size(ButtonSize.Small).kind(ButtonKind.Danger).onClick(deleteH),
                ])
            }))
    }

    func renderFormDialog(): IComponent {
        let title = if (this.dialogMode.get() == "create") { "新增组织" } else { "编辑组织" }
        let isEdit = this.dialogMode.get() == "edit"
        let nameInput = if (isEdit) {
            Input().bind(this.formName).disabled()
        } else {
            Input().bind(this.formName)
        }
        let form = Form([
            FormItem([nameInput]).label("组织名")
                .bindValue({ => this.formName.get() })
                .rule(FormRule(required: true, message: "组织名必填"))
                .errorSignal(this.nameError),
            FormItem([Input().bind(this.formDisplay).placeholder("可选")]).label("显示名")
                .bindValue({ => this.formDisplay.get() }),
            FormItem([Input().bind(this.formDesc).placeholder("可选")]).label("描述")
                .bindValue({ => this.formDesc.get() }),
            FormItem([Switch().bind(this.formIsDefault).activeText("默认").inactiveText("普通")]).label("默认组织")
                .bindValue({ => if (this.formIsDefault.get()) { "1" } else { "0" } }),
        ]).labelTop()
        this.orgForm = form
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

    func renderConfirmDialog(): IComponent {
        let dlg = Dialog([
            div([text("确定要删除组织「${this.pendingDeleteName}」吗？")]),
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
            Button([text("新增组织")]).kind(ButtonKind.Primary).onClick(openCreate),
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
        adminLayout("/admin/organizations", [
            div([text("组织管理")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            adminCard("组织列表", [toolbar, listBody(this.listHint(), this.renderList()), pager,
                this.renderFormDialog(), this.renderConfirmDialog()]),
        ])
    }
}
