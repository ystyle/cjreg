// cjxt 管理界面：用户 / 组织 / 团队 管理页
package ystyle::cjreg.ui

import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import ystyle::cjreg.store.*
import std.collection.*
import std.convert.*

// ===== 用户管理 =====
@Page["/admin/users"]
class UsersPage <: Component {
    var state: Option<CjregState> = None
    var rows = Signal<ArrayList<HashMap<String, String>>>(ArrayList<HashMap<String, String>>())
    var newUser = Signal<String>("")
    var newPass = Signal<String>("")
    var msg = Signal<String>("")

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        refresh()
    }

    func refresh(): Unit {
        match (this.state) {
            case Some(st) =>
                let users = st.userStore.listAllUsers()
                let data = ArrayList<HashMap<String, String>>()
                for (u in users) {
                    let m = HashMap<String, String>()
                    m["id"] = u.id.toString()
                    m["username"] = u.username
                    m["admin"] = if (u.isAdmin) { "是" } else { "否" }
                    m["active"] = if (u.isActive) { "正常" } else { "禁用" }
                    data.add(m)
                }
                this.rows.set(data)
            case None => ()
        }
    }

    public func render(): IComponent {
        let toolbar = div([
            Input().bind(this.newUser).placeholder("用户名"),
            Input().bind(this.newPass).placeholder("密码"),
            Button([text("创建用户")]).kind(ButtonKind.Primary).onClick(createUser),
            if (this.msg.get() != "") {
                Tag([text(this.msg.get())]).kind(ComponentKind.Success)
            } else {
                div()
            },
        ], attrs: Some(HashMap<String, String>([("class", cls("toolbar"))])))
        let table = Table()
            .data(this.rows)
            .stripe()
            .add(TableColumn().label("ID").colProp("id").width(60))
            .add(TableColumn().label("用户名").colProp("username"))
            .add(TableColumn().label("管理员").colProp("admin").width(80))
            .add(TableColumn().label("状态").colProp("active").width(80))
        adminLayout("/admin/users", [
            div([text("用户管理")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            adminCard("用户列表", [toolbar, table]),
        ])
    }

    func createUser(ctx: ActionContext): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (this.newUser.get().isEmpty() || this.newPass.get().isEmpty()) {
            this.msg.set("用户名和密码必填")
            return PatchResult.ReRender
        }
        match (st.auth.createUser(this.newUser.get(), this.newPass.get(), false)) {
            case Some(u) =>
                this.msg.set("已创建 ${u.username}")
                this.newUser.set("")
                this.newPass.set("")
                st.adminData.addLog(LogKind.Admin, 0, "admin", "create user ${u.username}", "ok", nowMs())
            case None =>
                this.msg.set("创建失败（用户已存在）")
        }
        refresh()
        PatchResult.ReRender
    }
}

// ===== 组织管理 =====
@Page["/admin/organizations"]
class OrganizationsPage <: Component {
    var state: Option<CjregState> = None
    var rows = Signal<ArrayList<HashMap<String, String>>>(ArrayList<HashMap<String, String>>())
    var newName = Signal<String>("")
    var newDisplay = Signal<String>("")
    var msg = Signal<String>("")

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        refresh()
    }

    func refresh(): Unit {
        match (this.state) {
            case Some(st) =>
                let orgs = st.adminData.listOrgs()
                let data = ArrayList<HashMap<String, String>>()
                for (o in orgs) {
                    let m = HashMap<String, String>()
                    m["id"] = o.id.toString()
                    m["name"] = o.name
                    m["display"] = o.displayName
                    data.add(m)
                }
                this.rows.set(data)
            case None => ()
        }
    }

    public func render(): IComponent {
        let toolbar = div([
            Input().bind(this.newName).placeholder("组织名"),
            Input().bind(this.newDisplay).placeholder("显示名"),
            Button([text("创建组织")]).kind(ButtonKind.Primary).onClick(createOrg),
            if (this.msg.get() != "") {
                Tag([text(this.msg.get())]).kind(ComponentKind.Success)
            } else {
                div()
            },
        ], attrs: Some(HashMap<String, String>([("class", cls("toolbar"))])))
        let table = Table()
            .data(this.rows)
            .stripe()
            .add(TableColumn().label("ID").colProp("id").width(60))
            .add(TableColumn().label("组织名").colProp("name"))
            .add(TableColumn().label("显示名").colProp("display"))
        adminLayout("/admin/organizations", [
            div([text("组织管理")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            adminCard("组织列表", [toolbar, table]),
        ])
    }

    func createOrg(ctx: ActionContext): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (this.newName.get().isEmpty()) {
            this.msg.set("组织名必填")
            return PatchResult.ReRender
        }
        let id = st.adminData.createOrg(this.newName.get(), this.newDisplay.get(), 0, nowMs())
        this.msg.set("已创建组织 #${id}")
        this.newName.set("")
        this.newDisplay.set("")
        st.adminData.addLog(LogKind.Admin, 0, "admin", "create org ${this.newName.get()}", "ok", nowMs())
        refresh()
        PatchResult.ReRender
    }
}

// ===== 团队管理 =====
@Page["/admin/teams"]
class TeamsPage <: Component {
    var state: Option<CjregState> = None
    var rows = Signal<ArrayList<HashMap<String, String>>>(ArrayList<HashMap<String, String>>())
    var newName = Signal<String>("")
    var newOrgId = Signal<String>("0")
    var msg = Signal<String>("")

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        refresh()
    }

    func refresh(): Unit {
        match (this.state) {
            case Some(st) =>
                let teams = st.adminData.listTeams()
                let data = ArrayList<HashMap<String, String>>()
                for (t in teams) {
                    let m = HashMap<String, String>()
                    m["id"] = t.id.toString()
                    m["name"] = t.name
                    m["org"] = t.orgId.toString()
                    data.add(m)
                }
                this.rows.set(data)
            case None => ()
        }
    }

    public func render(): IComponent {
        let toolbar = div([
            Input().bind(this.newName).placeholder("团队名"),
            Input().bind(this.newOrgId).placeholder("组织ID(0=全局)"),
            Button([text("创建团队")]).kind(ButtonKind.Primary).onClick(createTeam),
            if (this.msg.get() != "") {
                Tag([text(this.msg.get())]).kind(ComponentKind.Success)
            } else {
                div()
            },
        ], attrs: Some(HashMap<String, String>([("class", cls("toolbar"))])))
        let table = Table()
            .data(this.rows)
            .stripe()
            .add(TableColumn().label("ID").colProp("id").width(60))
            .add(TableColumn().label("团队名").colProp("name"))
            .add(TableColumn().label("组织ID").colProp("org").width(100))
        adminLayout("/admin/teams", [
            div([text("团队管理")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            adminCard("团队列表", [toolbar, table]),
        ])
    }

    func createTeam(ctx: ActionContext): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (this.newName.get().isEmpty()) {
            this.msg.set("团队名必填")
            return PatchResult.ReRender
        }
        let orgId = Int64.parse(this.newOrgId.get())
        let id = st.adminData.createTeam(this.newName.get(), orgId, nowMs())
        this.msg.set("已创建团队 #${id}")
        this.newName.set("")
        st.adminData.addLog(LogKind.Admin, 0, "admin", "create team ${this.newName.get()}", "ok", nowMs())
        refresh()
        PatchResult.ReRender
    }
}
