// 管理数据 store（bstorm）：组织/团队/团队关联/日志/发布计划持久化
// 数据模型对齐 cjrepo（参见 docs/ui-gap-report.md）：
// - Team 去单组织外键，改为 团队↔组织/包/成员 三类关联表
// - Plan.targetUpstream 存上游 ID（Int64），items 独立成 PlanItemDoc 表
package ystyle::cjreg.store

import bstorm.*
import bstorm.macros.*
import stdx.encoding.json.stream.*
import std.collection.*
import std.sort.*

// ===== 组织 =====
@Model
public class OrgDoc {
    @Id public var id: Int64 = 0
    public var name: String = ""
    public var displayName: String = ""
    public var description: String = ""
    public var isDefault: Bool = false
    public var ownerId: Int64 = 0
    public var createdAt: Int64 = 0
    public var updatedAt: Int64 = 0
    public var deletedAt: Int64 = 0
}

// ===== 团队 =====
@Model
public class TeamDoc {
    @Id public var id: Int64 = 0
    public var name: String = ""
    public var displayName: String = ""
    public var description: String = ""
    public var permission: String = "read"  // read/write/overwrite
    public var createdAt: Int64 = 0
    public var updatedAt: Int64 = 0
    public var deletedAt: Int64 = 0
}

// 团队-组织关联（organizationId = 0 表示「无组织包」，对齐 cjrepo 的 NULL）
@Model
public class TeamOrganizationDoc {
    @Id public var id: Int64 = 0
    public var teamId: Int64 = 0
    public var organizationId: Int64 = 0
    public var createdAt: Int64 = 0
}

// 团队-包关联（organization 空串表示「无组织包」）
@Model
public class TeamPackageDoc {
    @Id public var id: Int64 = 0
    public var teamId: Int64 = 0
    public var organization: String = ""
    public var packageName: String = ""
    public var createdAt: Int64 = 0
}

// 团队-用户绑定
@Model
public class TeamMemberDoc {
    @Id public var id: Int64 = 0
    public var teamId: Int64 = 0
    public var userId: Int64 = 0
}

// ===== 日志 =====
public enum LogKind {
    | Publish      // 发布
    | Admin        // 管理操作
    | Auth         // 登录/登出

    public operator func ==(other: LogKind): Bool {
        match (this) {
            case LogKind.Publish => match (other) {
                case LogKind.Publish => true
                case _ => false
            }
            case LogKind.Admin => match (other) {
                case LogKind.Admin => true
                case _ => false
            }
            case LogKind.Auth => match (other) {
                case LogKind.Auth => true
                case _ => false
            }
        }
    }
}

@Model
public class LogDoc {
    @Id public var id: Int64 = 0
    public var kind: String = ""     // publish/admin/auth
    public var actorId: Int64 = 0
    public var actorName: String = ""
    public var action: String = ""   // 描述（如 "publish demo@1.0.0"）
    public var detail: String = ""
    public var status: String = ""   // ok/failed
    public var target: String = ""   // 操作对象（包名/团队名等）
    public var error: String = ""    // 失败详情
    public var ipAddr: String = ""
    public var userAgent: String = ""
    public var createdAt: Int64 = 0
}

// ===== 发布计划 =====
@Model
public class PlanDoc {
    @Id public var id: Int64 = 0
    public var name: String = ""
    public var status: String = ""        // pending/running/paused/completed/failed
    public var targetUpstream: Int64 = 0  // 目标上游 ID（对齐 cjrepo）
    public var totalCount: Int64 = 0
    public var completedCount: Int64 = 0
    public var pollInterval: Int64 = 60
    public var pollTimeout: Int64 = 600
    public var createdAt: Int64 = 0
    public var updatedAt: Int64 = 0
}

// 计划项（独立表，对齐 cjrepo PublishPlanItem）
@Model
public class PlanItemDoc {
    @Id public var id: Int64 = 0
    public var planId: Int64 = 0
    public var packageId: Int64 = 0
    public var packageOrg: String = ""
    public var packageName: String = ""
    public var packageVersion: String = ""
    public var order: Int64 = 0
    public var category: String = ""       // app/deps/...
    public var status: String = "pending"  // pending/running/completed/failed
    public var selected: Bool = true
    public var error: String = ""
    public var startedAt: Int64 = 0
    public var completedAt: Int64 = 0
}

// 管理 store 聚合服务
public class AdminDataStore {
    public var storm: Storm
    public var nextOrg: Int64
    public var nextTeam: Int64
    public var nextTeamOrg: Int64
    public var nextTeamPkg: Int64
    public var nextMember: Int64
    public var nextLog: Int64
    public var nextPlan: Int64
    public var nextPlanItem: Int64

    public init(storm: Storm) {
        this.storm = storm
        this.nextOrg = 1
        this.nextTeam = 1
        this.nextTeamOrg = 1
        this.nextTeamPkg = 1
        this.nextMember = 1
        this.nextLog = 1
        this.nextPlan = 1
        this.nextPlanItem = 1
        this.storm.reindex<OrgDoc>()
        this.storm.reindex<TeamDoc>()
        this.storm.reindex<TeamOrganizationDoc>()
        this.storm.reindex<TeamPackageDoc>()
        this.storm.reindex<TeamMemberDoc>()
        this.storm.reindex<LogDoc>()
        this.storm.reindex<PlanDoc>()
        this.storm.reindex<PlanItemDoc>()
        recoverNextIds()
    }

    func recoverNextIds(): Unit {
        var m: Int64 = 0
        for (d in this.storm.all<OrgDoc>()) { if (d.id >= m) { m = d.id } }
        if (m >= this.nextOrg) { this.nextOrg = m + 1 }
        m = 0
        for (d in this.storm.all<TeamDoc>()) { if (d.id >= m) { m = d.id } }
        if (m >= this.nextTeam) { this.nextTeam = m + 1 }
        m = 0
        for (d in this.storm.all<TeamOrganizationDoc>()) { if (d.id >= m) { m = d.id } }
        if (m >= this.nextTeamOrg) { this.nextTeamOrg = m + 1 }
        m = 0
        for (d in this.storm.all<TeamPackageDoc>()) { if (d.id >= m) { m = d.id } }
        if (m >= this.nextTeamPkg) { this.nextTeamPkg = m + 1 }
        m = 0
        for (d in this.storm.all<TeamMemberDoc>()) { if (d.id >= m) { m = d.id } }
        if (m >= this.nextMember) { this.nextMember = m + 1 }
        m = 0
        for (d in this.storm.all<LogDoc>()) { if (d.id >= m) { m = d.id } }
        if (m >= this.nextLog) { this.nextLog = m + 1 }
        m = 0
        for (d in this.storm.all<PlanDoc>()) { if (d.id >= m) { m = d.id } }
        if (m >= this.nextPlan) { this.nextPlan = m + 1 }
        m = 0
        for (d in this.storm.all<PlanItemDoc>()) { if (d.id >= m) { m = d.id } }
        if (m >= this.nextPlanItem) { this.nextPlanItem = m + 1 }
    }

    // ===== 组织 =====
    public func createOrg(name: String, displayName: String, ownerId: Int64, now: Int64, description!: String = "", isDefault!: Bool = false): Int64 {
        let d = OrgDoc()
        d.id = this.nextOrg
        this.nextOrg++
        d.name = name
        d.displayName = displayName
        d.description = description
        d.isDefault = isDefault
        d.ownerId = ownerId
        d.createdAt = now
        this.storm.save(d)
        return d.id
    }

    public func updateOrg(id: Int64, displayName: String, description: String, isDefault: Bool, now: Int64): Bool {
        match (this.storm.get<OrgDoc>(id)) {
            case Some(d) =>
                d.displayName = displayName
                d.description = description
                d.isDefault = isDefault
                d.updatedAt = now
                this.storm.save(d)
                return true
            case None => return false
        }
    }

    public func listOrgs(): ArrayList<OrgDoc> {
        let r = ArrayList<OrgDoc>()
        for (d in this.storm.all<OrgDoc>()) {
            if (d.deletedAt == 0) {
                r.add(d)
            }
        }
        return r
    }

    public func getOrg(id: Int64): ?OrgDoc {
        this.storm.get<OrgDoc>(id)
    }

    public func deleteOrg(id: Int64, now: Int64): Bool {
        match (this.storm.get<OrgDoc>(id)) {
            case Some(d) =>
                d.deletedAt = now
                this.storm.save(d)
                return true
            case None => return false
        }
    }

    // ===== 团队 =====
    public func createTeam(name: String, now: Int64, displayName!: String = "", description!: String = "", permission!: String = "read"): Int64 {
        let d = TeamDoc()
        d.id = this.nextTeam
        this.nextTeam++
        d.name = name
        d.displayName = displayName
        d.description = description
        d.permission = permission
        d.createdAt = now
        this.storm.save(d)
        return d.id
    }

    public func updateTeam(id: Int64, displayName: String, description: String, permission: String, now: Int64): Bool {
        match (this.storm.get<TeamDoc>(id)) {
            case Some(d) =>
                d.displayName = displayName
                d.description = description
                d.permission = permission
                d.updatedAt = now
                this.storm.save(d)
                return true
            case None => return false
        }
    }

    public func listTeams(): ArrayList<TeamDoc> {
        let r = ArrayList<TeamDoc>()
        for (d in this.storm.all<TeamDoc>()) {
            if (d.deletedAt == 0) {
                r.add(d)
            }
        }
        return r
    }

    public func getTeam(id: Int64): ?TeamDoc {
        this.storm.get<TeamDoc>(id)
    }

    public func deleteTeam(id: Int64, now: Int64): Bool {
        match (this.storm.get<TeamDoc>(id)) {
            case Some(d) =>
                d.deletedAt = now
                this.storm.save(d)
                return true
            case None => return false
        }
    }

    // ---- 团队-组织关联（多对多；organizationId 0 = 无组织包）----
    public func setTeamOrganizations(teamId: Int64, orgIds: Array<Int64>, now: Int64): Unit {
        for (d in this.storm.all<TeamOrganizationDoc>()) {
            if (d.teamId == teamId) {
                this.storm.delete(d)
            }
        }
        for (oid in orgIds) {
            let d = TeamOrganizationDoc()
            d.id = this.nextTeamOrg
            this.nextTeamOrg++
            d.teamId = teamId
            d.organizationId = oid
            d.createdAt = now
            this.storm.save(d)
        }
    }

    public func listTeamOrganizations(teamId: Int64): ArrayList<TeamOrganizationDoc> {
        let r = ArrayList<TeamOrganizationDoc>()
        for (d in this.storm.all<TeamOrganizationDoc>()) {
            if (d.teamId == teamId) {
                r.add(d)
            }
        }
        return r
    }

    public func listTeamOrganizationIds(teamId: Int64): ArrayList<Int64> {
        let r = ArrayList<Int64>()
        for (d in this.listTeamOrganizations(teamId)) {
            r.add(d.organizationId)
        }
        return r
    }

    // ---- 团队-包关联（organization 空串 = 无组织包）----
    public func setTeamPackages(teamId: Int64, pkgs: Array<(String, String)>, now: Int64): Unit {
        for (d in this.storm.all<TeamPackageDoc>()) {
            if (d.teamId == teamId) {
                this.storm.delete(d)
            }
        }
        for ((org, name) in pkgs) {
            let d = TeamPackageDoc()
            d.id = this.nextTeamPkg
            this.nextTeamPkg++
            d.teamId = teamId
            d.organization = org
            d.packageName = name
            d.createdAt = now
            this.storm.save(d)
        }
    }

    public func listTeamPackages(teamId: Int64): ArrayList<TeamPackageDoc> {
        let r = ArrayList<TeamPackageDoc>()
        for (d in this.storm.all<TeamPackageDoc>()) {
            if (d.teamId == teamId) {
                r.add(d)
            }
        }
        return r
    }

    // ---- 团队成员 ----
    public func setTeamMembers(teamId: Int64, userIds: Array<Int64>): Unit {
        for (d in this.storm.all<TeamMemberDoc>()) {
            if (d.teamId == teamId) {
                this.storm.delete(d)
            }
        }
        for (uid in userIds) {
            let d = TeamMemberDoc()
            d.id = this.nextMember
            this.nextMember++
            d.teamId = teamId
            d.userId = uid
            this.storm.save(d)
        }
    }

    public func addTeamMember(teamId: Int64, userId: Int64): Unit {
        let d = TeamMemberDoc()
        d.id = this.nextMember
        this.nextMember++
        d.teamId = teamId
        d.userId = userId
        this.storm.save(d)
    }

    public func listTeamMembers(teamId: Int64): ArrayList<TeamMemberDoc> {
        let r = ArrayList<TeamMemberDoc>()
        for (d in this.storm.all<TeamMemberDoc>()) {
            if (d.teamId == teamId) {
                r.add(d)
            }
        }
        return r
    }

    public func removeTeamMember(teamId: Int64, userId: Int64): Unit {
        for (d in this.storm.all<TeamMemberDoc>()) {
            if (d.teamId == teamId && d.userId == userId) {
                this.storm.delete(d)
            }
        }
    }

    public func listTeamMemberIds(teamId: Int64): ArrayList<Int64> {
        let r = ArrayList<Int64>()
        for (d in this.listTeamMembers(teamId)) {
            r.add(d.userId)
        }
        return r
    }

    // ===== 日志 =====
    public func addLog(kind: LogKind, actorId: Int64, actorName: String, action: String, status: String, now: Int64, target!: String = "", error!: String = "", ipAddr!: String = "", userAgent!: String = "", detail!: String = ""): Int64 {
        let d = LogDoc()
        d.id = this.nextLog
        this.nextLog++
        match (kind) {
            case LogKind.Publish => d.kind = "publish"
            case LogKind.Admin => d.kind = "admin"
            case LogKind.Auth => d.kind = "auth"
        }
        d.actorId = actorId
        d.actorName = actorName
        d.action = action
        d.status = status
        d.target = target
        d.detail = detail
        d.error = error
        d.ipAddr = ipAddr
        d.userAgent = userAgent
        d.createdAt = now
        this.storm.save(d)
        return d.id
    }

    public func listLogs(kind: ?String, limit: Int64): ArrayList<LogDoc> {
        let (rows, _) = this.queryLogs(kind, "", "", 0, 0, 0, limit)
        rows
    }

    /// 审计日志查询（管理 API 用）：按 kind/关键字/状态/时间范围过滤 + 分页
    /// - keyword 命中 操作/目标/操作者/错误/详情 任一字段
    /// - status/kind 为空串/None 表示不过滤；from/to 为 0 表示不限
    /// - 返回 (rows, 命中总数)，rows 按时间倒序（最新在前）
    public func queryLogs(kind: ?String, keyword: String, status: String,
                          from: Int64, to: Int64, offset: Int64, limit: Int64): (ArrayList<LogDoc>, Int64) {
        let matched = ArrayList<LogDoc>()
        for (d in this.storm.all<LogDoc>()) {
            if (kind.isSome() && d.kind != kind.getOrThrow()) { continue }
            if (!status.isEmpty() && d.status != status) { continue }
            if (from > 0 && d.createdAt < from) { continue }
            if (to > 0 && d.createdAt > to) { continue }
            if (!keyword.isEmpty() && !logMatches(d, keyword)) { continue }
            matched.add(d)
        }
        // 时间倒序（同一毫秒按 id 倒序），不依赖底层扫描顺序
        sort(matched, by: logAscCmp, descending: true)
        let total = matched.size
        let rows = ArrayList<LogDoc>()
        var idx = if (offset < 0) { 0 } else { offset }
        let safeLimit = if (limit < 0) { 0 } else { limit }
        let end = if (idx + safeLimit > total) { total } else { idx + safeLimit }
        while (idx < end) {
            rows.add(matched[idx])
            idx++
        }
        (rows, total)
    }

    /// 删除日志：kind 为空则全清；before > 0 时只删该时间戳之前的
    /// 返回删除条数
    public func removeLogs(kind: ?String, before: Int64): Int64 {
        var n: Int64 = 0
        for (d in this.storm.all<LogDoc>()) {
            if (kind.isSome() && d.kind != kind.getOrThrow()) { continue }
            if (before > 0 && d.createdAt >= before) { continue }
            this.storm.delete(d)
            n++
        }
        n
    }

    /// 关键字匹配（操作/目标/操作者/错误/详情 任一字段包含即命中）
    func logMatches(d: LogDoc, kw: String): Bool {
        d.action.contains(kw) || d.target.contains(kw) || d.actorName.contains(kw) ||
        d.error.contains(kw) || d.detail.contains(kw)
    }

    /// 清理日志（全部删除）
    public func clearLogs(): Unit {
        for (d in this.storm.all<LogDoc>()) {
            this.storm.delete(d)
        }
    }

    // ===== 发布计划 =====
    public func createPlan(name: String, targetUpstream: Int64, pollInterval: Int64, pollTimeout: Int64, now: Int64): Int64 {
        let d = PlanDoc()
        d.id = this.nextPlan
        this.nextPlan++
        d.name = name
        d.status = "pending"
        d.targetUpstream = targetUpstream
        d.pollInterval = pollInterval
        d.pollTimeout = pollTimeout
        d.createdAt = now
        this.storm.save(d)
        return d.id
    }

    public func listPlans(): ArrayList<PlanDoc> {
        let r = ArrayList<PlanDoc>()
        let all = this.storm.all<PlanDoc>()
        for (d in all) {
            r.add(d)
        }
        return r
    }

    public func getPlan(id: Int64): ?PlanDoc {
        this.storm.get<PlanDoc>(id)
    }

    public func updatePlanStatus(id: Int64, status: String, completed: Int64, now: Int64): Bool {
        match (this.storm.get<PlanDoc>(id)) {
            case Some(d) =>
                d.status = status
                d.completedCount = completed
                d.updatedAt = now
                this.storm.save(d)
                return true
            case None => return false
        }
    }

    public func setPlanTotal(id: Int64, total: Int64): Bool {
        match (this.storm.get<PlanDoc>(id)) {
            case Some(d) =>
                d.totalCount = total
                this.storm.save(d)
                return true
            case None => return false
        }
    }

    public func deletePlan(id: Int64): Bool {
        match (this.storm.get<PlanDoc>(id)) {
            case Some(d) =>
                this.storm.delete(d)
                for (it in this.listPlanItems(id)) {
                    this.storm.delete(it)
                }
                return true
            case None => return false
        }
    }

    // ---- 计划项 ----
    public func addPlanItem(planId: Int64, packageId: Int64, org: String, name: String, version: String, order: Int64, category: String, selected: Bool): Int64 {
        let d = PlanItemDoc()
        d.id = this.nextPlanItem
        this.nextPlanItem++
        d.planId = planId
        d.packageId = packageId
        d.packageOrg = org
        d.packageName = name
        d.packageVersion = version
        d.order = order
        d.category = category
        d.selected = selected
        d.startedAt = 0
        d.completedAt = 0
        this.storm.save(d)
        return d.id
    }

    /// 全量列举计划项（跨计划扫描用：如包版本删除后的联动标记）
    public func listPlanItems(): ArrayList<PlanItemDoc> {
        let r = ArrayList<PlanItemDoc>()
        for (d in this.storm.all<PlanItemDoc>()) {
            r.add(d)
        }
        sort(r, by: planItemByOrderAsc)
        r
    }

    public func listPlanItems(planId: Int64): ArrayList<PlanItemDoc> {
        let r = ArrayList<PlanItemDoc>()
        for (d in this.storm.all<PlanItemDoc>()) {
            if (d.planId == planId) {
                r.add(d)
            }
        }
        sort(r, lessThan: { a, b => a.order < b.order })
        return r
    }

    public func getPlanItem(id: Int64): ?PlanItemDoc {
        this.storm.get<PlanItemDoc>(id)
    }

    public func updatePlanItem(id: Int64, status: String, error: String, now: Int64): Bool {
        match (this.storm.get<PlanItemDoc>(id)) {
            case Some(d) =>
                d.status = status
                d.error = error
                if (status == "running" && d.startedAt == 0) { d.startedAt = now }
                if (status == "completed" || status == "failed") { d.completedAt = now }
                this.storm.save(d)
                return true
            case None => return false
        }
    }

    public func setPlanItemSelected(id: Int64, selected: Bool): Bool {
        match (this.storm.get<PlanItemDoc>(id)) {
            case Some(d) =>
                d.selected = selected
                this.storm.save(d)
                return true
            case None => return false
        }
    }
}

// 日志升序比较（时间 → id），配合 sort(..., descending!: true) 得到「最新在前」
func logAscCmp(a: LogDoc, b: LogDoc): Ordering {
    if (a.createdAt != b.createdAt) {
        return if (a.createdAt < b.createdAt) { Ordering.LT } else { Ordering.GT }
    }
    if (a.id != b.id) {
        return if (a.id < b.id) { Ordering.LT } else { Ordering.GT }
    }
    return Ordering.EQ
}

// 计划项排序（order 升序，同序按 id）
func planItemByOrderAsc(a: PlanItemDoc, b: PlanItemDoc): Ordering {
    if (a.order != b.order) {
        return if (a.order < b.order) { Ordering.LT } else { Ordering.GT }
    }
    if (a.id == b.id) {
        return Ordering.EQ
    }
    return if (a.id < b.id) { Ordering.LT } else { Ordering.GT }
}
