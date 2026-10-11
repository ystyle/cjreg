// 用户门户「我的」（@Page /me）
package ystyle::cjreg.ui.public

import ystyle::cjreg.ui.*
import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.model.*
import ystyle::cjreg.server.{MyPackageRow, MyTeamRow, myPackageRows, myTeamRows, permissionHint,
    TeamMemberResp, TeamSelfServiceResult, teamMemberRows, addTeamMemberChecked, removeTeamMemberChecked,
    transferTeamOwnerChecked, canManageTeam, teamManageDeniedMessage,
    setTeamOrgsChecked, setTeamPkgsChecked}
import std.collection.*
import std.time.*
import std.convert.*

// ===== 个人中心（/me）=====
@Page["/me", "我的", requireUser]
class UserPortalPage <: Component {
    var state: Option<CjregState> = None
    // 会话上下文：onMount 取引用，render 期读（令牌恢复后的就地重渲不重跑 onMount）
    var sctx: Option<SessionContext> = None
    // 已加载数据的用户 id（会话换人时就地重渲也能纠正列表）
    var loadedUid: Int64 = 0

    var msg = Signal<String>("")
    var msgOk = Signal<Bool>(true)

    // 发布 Token
    var tokenValue = Signal<String>("")
    var resetVisible = Signal<Bool>(false)

    // 我的包
    var pkgSearch = Signal<String>("")
    var pkgRows = Signal<ArrayList<MyPackageRow>>(ArrayList<MyPackageRow>())
    var pkgTotal = Signal<Int64>(0)
    var pkgPage = Signal<Int64>(1)
    var pkgPageSize = Signal<Int64>(10)

    // 我的团队与权限
    var teamRows = Signal<ArrayList<MyTeamRow>>(ArrayList<MyTeamRow>())

    // ===== owner 自助（团队所有者管理本队成员）=====
    // 当前正在管理的团队（0 = 面板未打开）
    var manageTeamId = Signal<Int64>(0)
    var manageTeamName = Signal<String>("")
    // 该团队成员（打开面板时载入）
    var memberRows = Signal<ArrayList<TeamMemberResp>>(ArrayList<TeamMemberResp>())
    // 加人：按**用户名**输入（门户不该要求 owner 去记用户 id）
    var addMemberName = Signal<String>("")
    // 转让 / 移除确认
    var transferVisible = Signal<Bool>(false)
    var transferTargetId = Signal<Int64>(0)
    var removeVisible = Signal<Bool>(false)
    var pendingRemoveId = Signal<Int64>(0)
    var pendingRemoveName = Signal<String>("")
    // 关联管理（组织 / 包）：owner 能改关联才真正落地"加人=授予发布权"
    var linkOrgs = Signal<ArrayList<String>>(ArrayList<String>())
    var linkPkgs = Signal<ArrayList<String>>(ArrayList<String>())   // "org::name" 形式
    var linkPkgInput = Signal<String>("")

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        this.sctx = ctx.getSessionContext()
        this.refresh()
    }

    // 当前登录用户 id（会话上下文为空 → 0）
    func currentUid(): Int64 {
        match (this.sctx) {
            case Some(s) => s.uid
            case None => 0
        }
    }

    // 用户名（未登录为空串）
    func currentUsername(): String {
        match (this.sctx) {
            case Some(s) => s.username
            case None => ""
        }
    }

    // 会话用户与已加载数据不一致时重新加载（就地重渲路径不会重跑 onMount）
    func refreshIfUserChanged(): Unit {
        if (this.currentUid() != this.loadedUid) {
            this.refresh()
        }
    }

    // 加载/刷新三个区块的数据
    func refresh(): Unit {
        let uid = this.currentUid()
        this.loadedUid = uid
        if (uid <= 0) {
            return
        }
        let st = match (this.state) {
            case Some(x) => x
            case None => return
        }
        match (st.userStore.getUser(uid)) {
            case Some(u) => this.tokenValue.set(u.publishToken)
            case None => ()
        }
        // 我的包：我发布过版本的包（owner 标记由读模型给出）+ 名称/组织过滤 + 分页
        let all = myPackageRows(st.pkgStore, st.adminData, uid)
        let kw = this.pkgSearch.get()
        let hits = ArrayList<MyPackageRow>()
        for (r in all) {
            if (kw.isEmpty() || r.name.contains(kw) || r.org.contains(kw)) {
                hits.add(r)
            }
        }
        this.pkgTotal.set(hits.size)
        let (start, end) = pageWindow(hits.size, this.pkgPage.get(), this.pkgPageSize.get())
        let rows = ArrayList<MyPackageRow>()
        var i = start
        while (i < end) {
            rows.add(hits[i])
            i++
        }
        this.pkgRows.set(rows)
        // 我的团队与权限
        this.teamRows.set(myTeamRows(st.adminData, uid))
    }

    // 统一提示（成功/失败决定 Tag 颜色）
    func notify(text: String, ok: Bool): Unit {
        this.msg.set(text)
        this.msgOk.set(ok)
    }

    // ===== 交互 =====
    func onSearch(ctx: ActionContext): PatchResult {
        this.pkgPage.set(1)
        this.refresh()
        PatchResult.ReRender
    }

    func onPageChange(ctx: ActionContext): PatchResult {
        this.refresh()
        PatchResult.ReRender
    }

    func askResetToken(ctx: ActionContext): PatchResult {
        this.resetVisible.set(true)
        PatchResult.ReRender
    }

    func cancelResetToken(ctx: ActionContext): PatchResult {
        this.resetVisible.set(false)
        PatchResult.ReRender
    }

    // 重置发布 Token：只能重置自己的（用户 id 取自会话，不接受客户端传入）
    func confirmResetToken(ctx: ActionContext): PatchResult {
        this.resetVisible.set(false)
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        let user = match (st.userSession(ctx)) {
            case Some(u) => u
            case None =>
                this.notify("会话已失效，请重新登录", false)
                return PatchResult.ReRender
        }
        match (st.auth.resetPublishToken(user.id)) {
            case Some(t) =>
                this.tokenValue.set(t)
                st.adminData.addLog(LogKind.Auth, user.id, user.username, "reset publish token (portal)", "ok", nowMs())
                this.notify("已重置发布 Token（旧 Token 已失效）", true)
            case None =>
                this.notify("重置失败：用户不存在", false)
        }
        PatchResult.ReRender
    }

    // ===== owner 自助：打开/关闭成员管理面板 =====
    //
    // 注意：这里的「可见性」只是体验层 —— 真正的门在服务端（门户 API 的 canManageTeam
    // 与页面 action 里各自的守卫）。UI 隐藏不算安全。
    func openManageMembers(ctx: ActionContext, teamId: Int64, teamName: String): PatchResult {
        this.manageTeamId.set(teamId)
        this.manageTeamName.set(teamName)
        this.addMemberName.set("")
        this.reloadMembers()
        PatchResult.ReRender
    }

    func closeManageMembers(ctx: ActionContext): PatchResult {
        this.manageTeamId.set(0)
        this.memberRows.set(ArrayList<TeamMemberResp>())
        PatchResult.ReRender
    }

    // 重新载入当前管理团队的成员（仅在服务端拒绝时给出提示，不改数据）
    func reloadMembers(): Unit {
        let st = match (this.state) {
            case Some(x) => x
            case None => return
        }
        let teamId = this.manageTeamId.get()
        if (teamId <= 0) {
            this.memberRows.set(ArrayList<TeamMemberResp>())
            return
        }
        this.memberRows.set(teamMemberRows(st.adminData, teamId, this.teamOwnerId(teamId), st.userStore))
        // 关联：组织 id 列表 + 包 "org::name" 列表
        let orgs = ArrayList<String>()
        for (oid in st.adminData.listTeamOrganizationIds(teamId)) {
            orgs.add(oid.toString())
        }
        this.linkOrgs.set(orgs)
        let pkgs = ArrayList<String>()
        for (p in st.adminData.listTeamPackages(teamId)) {
            if (p.organization.isEmpty()) {
                pkgs.add(p.packageName)
            } else {
                pkgs.add("${p.organization}::${p.packageName}")
            }
        }
        this.linkPkgs.set(pkgs)
    }

    // 团队当前 owner 的 id（本地读，仅用于列表标注）
    func teamOwnerId(teamId: Int64): Int64 {
        match (this.state) {
            case Some(st) => match (st.adminData.getTeam(teamId)) {
                case Some(t) => t.ownerId
                case None => 0
            }
            case None => 0
        }
    }

    // 服务端守卫（与门户 API 同一份口径）：不是 owner / 自助未开 / 未登录 → 拒绝并提示
    func guardManage(ctx: ActionContext, teamId: Int64): ?(CjregState, User) {
        let st = match (this.state) {
            case Some(x) => x
            case None => return None
        }
        let user = match (st.userSession(ctx)) {
            case Some(u) => u
            case None =>
                this.notify("会话已失效，请重新登录", false)
                return None
        }
        let v = canManageTeam(st.adminData, Some(user), teamId)
        if (!v.allowed) {
            this.notify(teamManageDeniedMessage(v.reason), false)
            return None
        }
        Some((st, user))
    }

    // 加成员：按用户名解析（服务端解析，owner 不需要知道用户 id）
    func addMember(ctx: ActionContext): PatchResult {
        let teamId = this.manageTeamId.get()
        let name = this.addMemberName.get().trimAscii()
        if (teamId <= 0) {
            return PatchResult.ReRender
        }
        if (name.isEmpty()) {
            this.notify("请输入要加入的用户名", false)
            return PatchResult.ReRender
        }
        let (st, actor) = match (this.guardManage(ctx, teamId)) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        // 用户名 → 用户 id（门户只暴露「我自己的」数据，这里只做一次存在性解析）
        var targetId: Int64 = 0
        for (u in st.userStore.listAllUsers()) {
            if (u.username == name) {
                targetId = u.id
            }
        }
        if (targetId <= 0) {
            this.notify("用户不存在：${name}", false)
            return PatchResult.ReRender
        }
        let r = addTeamMemberChecked(st.adminData, st.userStore, teamId, targetId)
        this.auditManage(st, actor, "add_team_member", teamId, r)
        this.notify(r.message, r.ok)
        if (r.ok) {
            this.addMemberName.set("")
        }
        this.reloadMembers()
        PatchResult.ReRender
    }

    // 移除成员：走确认框
    func askRemoveMember(ctx: ActionContext, userId: Int64, username: String): PatchResult {
        this.pendingRemoveId.set(userId)
        this.pendingRemoveName.set(username)
        this.removeVisible.set(true)
        PatchResult.ReRender
    }

    func cancelRemoveMember(ctx: ActionContext): PatchResult {
        this.removeVisible.set(false)
        this.pendingRemoveId.set(0)
        PatchResult.ReRender
    }

    func confirmRemoveMember(ctx: ActionContext): PatchResult {
        this.removeVisible.set(false)
        let teamId = this.manageTeamId.get()
        let uid = this.pendingRemoveId.get()
        if (teamId <= 0 || uid <= 0) {
            return PatchResult.ReRender
        }
        let (st, actor) = match (this.guardManage(ctx, teamId)) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        let r = removeTeamMemberChecked(st.adminData, teamId, uid)
        this.auditManage(st, actor, "remove_team_member", teamId, r)
        this.notify(r.message, r.ok)
        this.pendingRemoveId.set(0)
        this.reloadMembers()
        PatchResult.ReRender
    }

    // 切换某个组织的关联（勾选/取消）—— 关闭组织关联等于收回该范围权限，必然影响成员有效权限
    func toggleTeamOrg(ctx: ActionContext, orgId: Int64): PatchResult {
        let teamId = this.manageTeamId.get()
        if (teamId <= 0) {
            return PatchResult.ReRender
        }
        let (st, actor) = match (this.guardManage(ctx, teamId)) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        let cur = ArrayList<Int64>()
        var removed = false
        for (v in this.linkOrgs.get()) {
            let n = match (Int64.tryParse(v)) {
                case Some(x) => x
                case None => 0
            }
            if (n == orgId) {
                removed = true      // 已关联 → 这次取消
            } else {
                cur.add(n)
            }
        }
        if (!removed) {
            cur.add(orgId)
        }
        let r = setTeamOrgsChecked(st.adminData, teamId, cur.toArray(), nowMs())
        this.auditManage(st, actor, "set_team_links", teamId, r)
        this.notify(r.message, r.ok)
        if (r.ok) {
            this.reloadMembers()
        }
        PatchResult.ReRender
    }

    // 增加包关联（输入 "org::name" 或裸包名）
    func addTeamPkg(ctx: ActionContext): PatchResult {
        let teamId = this.manageTeamId.get()
        let raw = this.linkPkgInput.get().trimAscii()
        if (teamId <= 0) {
            return PatchResult.ReRender
        }
        if (raw.isEmpty()) {
            this.notify("请输入包名（org::name 或 name）", false)
            return PatchResult.ReRender
        }
        let (st, actor) = match (this.guardManage(ctx, teamId)) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        var org = ""
        var name = raw
        let sep = raw.indexOf("::")
        match (sep) {
            case Some(i) =>
                org = raw[0..i]
                name = raw[(i + 2)..raw.size]
            case None => ()
        }
        let next = ArrayList<(String, String)>()
        for (p in st.adminData.listTeamPackages(teamId)) {
            next.add((p.organization, p.packageName))
        }
        next.add((org, name))
        let r = setTeamPkgsChecked(st.adminData, st.pkgStore, teamId, next.toArray(), nowMs())
        this.auditManage(st, actor, "set_team_links", teamId, r)
        this.notify(r.message, r.ok)
        if (r.ok) {
            this.linkPkgInput.set("")
            this.reloadMembers()
        }
        PatchResult.ReRender
    }

    // 移除包关联
    func removeTeamPkg(ctx: ActionContext, org: String, name: String): PatchResult {
        let teamId = this.manageTeamId.get()
        if (teamId <= 0) {
            return PatchResult.ReRender
        }
        let (st, actor) = match (this.guardManage(ctx, teamId)) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        let next = ArrayList<(String, String)>()
        for (p in st.adminData.listTeamPackages(teamId)) {
            if (!(p.organization == org && p.packageName == name)) {
                next.add((p.organization, p.packageName))
            }
        }
        let r = setTeamPkgsChecked(st.adminData, st.pkgStore, teamId, next.toArray(), nowMs())
        this.auditManage(st, actor, "set_team_links", teamId, r)
        this.notify(r.message, r.ok)
        if (r.ok) {
            this.reloadMembers()
        }
        PatchResult.ReRender
    }

    // 转让所有权
    func askTransferOwner(ctx: ActionContext, userId: Int64): PatchResult {
        this.transferTargetId.set(userId)
        this.transferVisible.set(true)
        PatchResult.ReRender
    }

    func cancelTransferOwner(ctx: ActionContext): PatchResult {
        this.transferVisible.set(false)
        this.transferTargetId.set(0)
        PatchResult.ReRender
    }

    func confirmTransferOwner(ctx: ActionContext): PatchResult {
        this.transferVisible.set(false)
        let teamId = this.manageTeamId.get()
        let target = this.transferTargetId.get()
        if (teamId <= 0 || target <= 0) {
            return PatchResult.ReRender
        }
        let (st, actor) = match (this.guardManage(ctx, teamId)) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        let r = transferTeamOwnerChecked(st.adminData, st.userStore, teamId, target, nowMs())
        this.auditManage(st, actor, "transfer_team_owner", teamId, r)
        this.notify(r.message, r.ok)
        this.transferTargetId.set(0)
        // 转让后 owner 变了：刷新团队列表（谁还能看到面板）与成员标注
        this.refresh()
        this.reloadMembers()
        PatchResult.ReRender
    }

    // owner 自助审计：actor = 实际操作者，detail 标注团队与结果
    func auditManage(st: CjregState, actor: User, action: String, teamId: Int64,
                     r: TeamSelfServiceResult): Unit {
        let _ = st.adminData.addLog(LogKind.Admin, actor.id, actor.username, action,
            if (r.ok) { "ok" } else { "failed" }, nowMs(),
            target: "team=${teamId}", error: if (r.ok) { "" } else { r.message },
            ipAddr: "portal-ui", userAgent: "cjxt-portal-ui",
            detail: "teamId=${teamId} outcome=${r.outcome}")
    }

    func doLogout(ctx: ActionContext): PatchResult {
        clearSessionContext(ctx)
        try {
            ctx.getState<CjregState>().currentUser.set(Option<User>.None)
        } catch (e: Exception) {
            // 同 layout.cj 的退出登录：用户回调里吞异常，登录态没清干净也查不到原因。
            println("[cjreg] 用户门户退出登录清空 currentUser 失败: " + e.toString())
        }
        ctx.route.push("/user/login")
        PatchResult.ReRender
    }

    // ===== 渲染 =====

    // 区块一：我的发布 Token（完整值 + 重置；重置后旧 Token 立即失效）
    func renderTokenSection(): IComponent {
        let resetH: ActionHandler = { c => this.askResetToken(c) }
        // registry 示例用配置的对外地址（cjreg.toml 的 server.public_url）
        let base = match (this.state) {
            case Some(st) => if (st.config.publicUrl.isEmpty()) { "http://<cjreg 地址>" } else { st.config.publicUrl }
            case None => "http://<cjreg 地址>"
        }
        let example = "[repository.home]\n" +
            "registry = \"${base}\"\n" +
            "token = \"${this.tokenValue.get()}\""
        div([
            div([text("我的发布 Token")], attrs: Some(HashMap<String, String>([("class", cls("portal-section-title"))]))),
            div([text("用于 cjpm 发布鉴权：写入项目根目录 cangjie-repo.toml 的 token 字段。请勿泄漏——持有它即可发布。")],
                attrs: Some(HashMap<String, String>([("class", cls("portal-hint"))]))),
            div([
                Input().readonly().bind(this.tokenValue),
                Button([text("重置 Token")]).kind(ButtonKind.Warning).onClick(resetH),
            ], attrs: Some(HashMap<String, String>([("class", cls("portal-token-row"))]))),
            div([text("cangjie-repo.toml 示例（registry 取自服务配置，可直接复制）")],
                attrs: Some(HashMap<String, String>([("class", cls("portal-hint"))]))),
            div([text(example)], attrs: Some(HashMap<String, String>([("class", cls("code-block"))]))),
        ], attrs: Some(HashMap<String, String>([("class", cls("portal-section"))])))
    }

    // 区块二：我的包（我发布过版本的包 + owner 标记 + 搜索/分页）
    func renderPackagesSection(): IComponent {
        let pager = Pagination()
            .currentPage(this.pkgPage)
            .pageSize(this.pkgPageSize)
            .total(this.pkgTotal.get())
            .layout("total, prev, pager, next")
            .onChange(onPageChange)
        let table = Table<MyPackageRow>()
            .data(this.pkgRows)
            .stripe()
            .add(TableColumn<MyPackageRow>().label("包名").minWidth(240).render({ r, i =>
                div([
                    text(r.displayName()),
                ])
            }))
            .add(TableColumn<MyPackageRow>().label("版本数").width(90).accessor({ r => r.versionCount.toString() }))
            .add(TableColumn<MyPackageRow>().label("最新版本").width(120).accessor({ r => if (r.latestVersion.isEmpty()) { "-" } else { r.latestVersion } }))
            .add(TableColumn<MyPackageRow>().label("角色").width(110).render({ r, i =>
                if (r.isOwner) {
                    Tag([text("所有者")]).kind(ComponentKind.Primary)
                } else {
                    Tag([text("协作者")]).kind(ComponentKind.Info)
                }
            }))
            .add(TableColumn<MyPackageRow>().label("最近发布").width(140).render({ r, i =>
                text(formatTimeMs(r.updatedAt))
            }))
            .add(TableColumn<MyPackageRow>().label("操作").width(100).render({ r, i =>
                let go: ActionHandler = { c =>
                    c.route.push("/packages/${pkgDisplayName(r.org, r.name)}")
                    PatchResult.ReRender
                }
                Button([text("详情")]).size(ButtonSize.Small).onClick(go)
            }))
        div([
            div([text("我的包")], attrs: Some(HashMap<String, String>([("class", cls("portal-section-title"))]))),
            div([text("我发布过版本的包（含参与协作的包）；「所有者」= 该包最早一条版本记录的发布者，只有所有者能凭个人身份发新版本。")],
                attrs: Some(HashMap<String, String>([("class", cls("portal-hint"))]))),
            div([Input().bind(this.pkgSearch).placeholder("按包名/组织搜索").on("keydown", onEnterSearch)],
                attrs: Some(HashMap<String, String>([("class", cls("portal-search"))]))),
            if (this.pkgTotal.get() == 0) {
                emptyState("还没有发布过包——用上面的 Token 发布第一个包吧")
            } else {
                div([table])
            },
            if (this.pkgTotal.get() > 0) {
                div([pager], attrs: Some(HashMap<String, String>([("class", cls("pager-wrap"))])))
            } else {
                div()
            },
        ], attrs: Some(HashMap<String, String>([("class", cls("portal-section"))])))
    }

    func onEnterSearch(ctx: ActionContext): PatchResult {
        match (ctx.keyEvent) {
            case Some(ke) =>
                if (ke.isEnter()) {
                    return this.onSearch(ctx)
                }
            case None => ()
        }
        PatchResult.ReRender
    }

    // 区块三：我的团队与权限（只读）+ 发布权限模式提示
    func renderTeamsSection(): IComponent {
        let mode = match (this.state) {
            case Some(st) => st.config.permissionMode
            case None => "open"
        }
        let table = Table<MyTeamRow>()
            .data(this.teamRows)
            .stripe()
            .add(TableColumn<MyTeamRow>().label("团队").minWidth(160).render({ r, i => text(r.label()) }))
            .add(TableColumn<MyTeamRow>().label("权限").width(110).render({ r, i =>
                let kind = match (r.permission) {
                    case "overwrite" => ComponentKind.Danger
                    case "write" => ComponentKind.Warning
                    case _ => ComponentKind.Info
                }
                Tag([text(r.permission)]).kind(kind)
            }))
            .add(TableColumn<MyTeamRow>().label("关联组织").minWidth(160).render({ r, i =>
                text(if (r.orgNames.size == 0) { "-" } else { joinList(r.orgNames) })
            }))
            .add(TableColumn<MyTeamRow>().label("关联包").minWidth(200).render({ r, i =>
                text(if (r.packages.size == 0) { "-" } else { joinList(r.packages) })
            }))
            // owner 自助入口：只有「我是本队 owner 且自助已开启」才显示按钮。
            // 可见性只是体验层，真正的门在服务端 canManageTeam。
            .add(TableColumn<MyTeamRow>().label("管理").width(120).render({ r, i =>
                if (r.canSelfManage) {
                    // onClick 有重载：先用 ActionHandler 标注再传（项目既有写法）
                    let manageH: ActionHandler = { ctx => this.openManageMembers(ctx, r.teamId, r.label()) }
                    Button("管理成员").size(ButtonSize.Small).onClick(manageH)
                } else if (r.isOwner) {
                    Tag([text("owner·自助未开")]).kind(ComponentKind.Info)
                } else {
                    text("-")
                }
            }))
        div([
            div([text("我的团队与权限")], attrs: Some(HashMap<String, String>([("class", cls("portal-section-title"))]))),
            div([
                Tag([text(permissionHint(mode))]).kind(if (mode == "team") { ComponentKind.Warning } else { ComponentKind.Info }),
            ], attrs: Some(HashMap<String, String>([("class", cls("portal-hint"))]))),
            if (this.teamRows.get().size == 0) {
                emptyState("暂未加入任何团队（发布权限由管理员配置）")
            } else {
                div([table])
            },
            if (this.manageTeamId.get() > 0) {
                this.renderManagePanel()
            } else {
                div()
            },
        ], attrs: Some(HashMap<String, String>([("class", cls("portal-section"))])))
    }

    // owner 自助面板：成员列表 + 加人 + 移出 + 转让
    func renderManagePanel(): IComponent {
        let addMemberH: ActionHandler = { ctx => this.addMember(ctx) }
        let closeManageH: ActionHandler = { ctx => this.closeManageMembers(ctx) }
        let memberTable = Table<TeamMemberResp>()
            .data(this.memberRows)
            .stripe()
            .add(TableColumn<TeamMemberResp>().label("成员").minWidth(160).render({ r, i =>
                if (r.isOwner) {
                    div([text(r.username), Tag([text("owner")]).kind(ComponentKind.Warning)])
                } else {
                    text(r.username)
                }
            }))
            .add(TableColumn<TeamMemberResp>().label("操作").width(200).render({ r, i =>
                if (r.isOwner) {
                    text("（所有者，需先转让）")
                } else {
                    let removeH: ActionHandler = { ctx => this.askRemoveMember(ctx, r.userId, r.username) }
                    let transferH: ActionHandler = { ctx => this.askTransferOwner(ctx, r.userId) }
                    div([
                        Button("移出").size(ButtonSize.Small).onClick(removeH),
                        Button("转让所有权").size(ButtonSize.Small).onClick(transferH),
                    ])
                }
            }))
        div([
            div([text("管理团队成员 · ${this.manageTeamName.get()}")],
                attrs: Some(HashMap<String, String>([("class", cls("portal-section-title"))]))),
            div([
                Input().bind(this.addMemberName).placeholder("要加入的用户名"),
                Button("加入团队").size(ButtonSize.Small).onClick(addMemberH),
                Button("收起").size(ButtonSize.Small).onClick(closeManageH),
            ], attrs: Some(HashMap<String, String>([("class", cls("portal-hint"))]))),
            if (this.memberRows.get().size == 0) {
                emptyState("该团队暂无成员")
            } else {
                div([memberTable])
            },
            this.renderLinkPanel(),
        ], attrs: Some(HashMap<String, String>([("class", cls("portal-section"))])))
    }

    // 关联管理：组织（勾选/取消）+ 包（增删）。
    // 这一步决定成员的有效权限范围 —— 只改成员不改关联，等于没真正下放发布权。
    func renderLinkPanel(): IComponent {
        let st = match (this.state) {
            case Some(x) => x
            case None => return div()
        }
        let teamId = this.manageTeamId.get()
        let orgRows = ArrayList<IComponent>()
        for (o in st.adminData.listOrgs()) {
            let linked = this.linkOrgs.get().contains(o.id.toString())
            let label = if (o.displayName.isEmpty()) { o.name } else { "${o.name}（${o.displayName}）" }
            let toggleH: ActionHandler = { ctx => this.toggleTeamOrg(ctx, o.id) }
            orgRows.add(div([
                Button(if (linked) { "已关联 ✓" } else { "关联" })
                    .size(ButtonSize.Small)
                    .kind(if (linked) { ButtonKind.Primary } else { ButtonKind.Default })
                    .onClick(toggleH),
                text(" " + label),
            ]))
        }
        let pkgRows = ArrayList<IComponent>()
        for (p in st.adminData.listTeamPackages(teamId)) {
            let orgName = p.organization
            let pkgName = p.packageName
            let rmH: ActionHandler = { ctx => this.removeTeamPkg(ctx, orgName, pkgName) }
            pkgRows.add(div([
                text(if (orgName.isEmpty()) { pkgName } else { "${orgName}::${pkgName}" }),
                Button("移除").size(ButtonSize.Small).kind(ButtonKind.Danger).onClick(rmH),
            ]))
        }
        let addPkgH: ActionHandler = { ctx => this.addTeamPkg(ctx) }
        div([
            div([text("关联范围（决定成员的有效发布权限）")],
                attrs: Some(HashMap<String, String>([("class", cls("portal-section-title"))]))),
            if (orgRows.size == 0) {
                div([text("（当前没有组织）")])
            } else {
                div(orgRows.toArray())
            },
            div([
                Input().bind(this.linkPkgInput).placeholder("包名，如 acme::demo"),
                Button("关联该包").size(ButtonSize.Small).onClick(addPkgH),
            ]),
            if (pkgRows.size == 0) {
                div([text("（尚未关联任何包）")])
            } else {
                div(pkgRows.toArray())
            },
        ], attrs: Some(HashMap<String, String>([("class", cls("portal-section"))])))
    }

    // 移出确认
    func renderRemoveDialog(): IComponent {
        MessageBox(this.removeVisible)
            .kind(MessageBoxKind2.Confirm)
            .icon(MessageBoxIcon2.Warning)
            .title("移出团队成员")
            .message("确定把 ${this.pendingRemoveName.get()} 移出该团队？移出后其发布权限可能随之失效。")
            .confirmText("移出")
            .cancelText("取消")
            .onConfirm(confirmRemoveMember)
            .onCancel(cancelRemoveMember)
    }

    // 转让确认
    func renderTransferDialog(): IComponent {
        MessageBox(this.transferVisible)
            .kind(MessageBoxKind2.Confirm)
            .icon(MessageBoxIcon2.Warning)
            .title("转让团队所有权")
            .message("转让后你将不再是该团队所有者，无法再自助管理成员。确定继续？")
            .confirmText("转让")
            .cancelText("取消")
            .onConfirm(confirmTransferOwner)
            .onCancel(cancelTransferOwner)
    }

    func renderResetDialog(): IComponent {
        MessageBox(this.resetVisible)
            .kind(MessageBoxKind2.Confirm)
            .icon(MessageBoxIcon2.Warning)
            .title("重置发布 Token")
            .message("重置后旧 Token 立即失效，正在使用它的本地配置与 CI 需要同步更新。确定继续？")
            .confirmText("重置")
            .cancelText("取消")
            .onConfirm(confirmResetToken)
            .onCancel(cancelResetToken)
    }

    public func render(): IComponent {
        this.refreshIfUserChanged()
        let msgKind = if (this.msgOk.get()) { ComponentKind.Success } else { ComponentKind.Danger }
        div([
            publicNav("/me", this.sctx),
            div([
                div([text("个人门户")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
                div([text("当前登录：${this.currentUsername()}")], attrs: Some(HashMap<String, String>([("class", cls("page-subtitle"))]))),
                if (this.msg.get() != "") {
                    div([Tag([text(this.msg.get())]).kind(msgKind)], attrs: Some(HashMap<String, String>([("class", cls("empty-line"))])))
                } else {
                    div()
                },
                this.renderTokenSection(),
                this.renderPackagesSection(),
                this.renderTeamsSection(),
                div([
                    Button([text("退出登录")]).size(ButtonSize.Small).onClick(doLogout),
                ], attrs: Some(HashMap<String, String>([("class", cls("toolbar"))]))),
                this.renderResetDialog(),
                this.renderRemoveDialog(),
                this.renderTransferDialog(),
            ], attrs: Some(HashMap<String, String>([("class", cls("public-main"))]))),
        ])
    }
}
