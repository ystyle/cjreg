// 管理数据 store（bstorm）：组织/团队/日志/发布计划持久化
package ystyle::cjreg.store

import bstorm.*
import bstorm.macros.*
import stdx.encoding.json.stream.*
import std.collection.*

// ===== 组织 =====
@Model
public class OrgDoc {
    @Id public var id: Int64 = 0
    public var name: String = ""
    public var displayName: String = ""
    public var description: String = ""
    public var ownerId: Int64 = 0
    public var createdAt: Int64 = 0
    public var deletedAt: Int64 = 0
}

@Model
public class TeamDoc {
    @Id public var id: Int64 = 0
    public var name: String = ""
    public var orgId: Int64 = 0        // 0 = 全局团队
    public var description: String = ""
    public var createdAt: Int64 = 0
    public var deletedAt: Int64 = 0
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
    public var createdAt: Int64 = 0
}

// ===== 发布计划 =====
@Model
public class PlanDoc {
    @Id public var id: Int64 = 0
    public var name: String = ""
    public var status: String = ""        // pending/running/paused/completed/failed
    public var targetUpstream: String = "" // 目标上游 URL
    public var totalCount: Int64 = 0
    public var completedCount: Int64 = 0
    public var createdAt: Int64 = 0
    public var itemsJson: String = ""     // 计划项 JSON（name/org/version/order/status）
}

// 管理 store 聚合服务
public class AdminDataStore {
    public var storm: Storm
    public var nextOrg: Int64
    public var nextTeam: Int64
    public var nextMember: Int64
    public var nextLog: Int64
    public var nextPlan: Int64

    public init(storm: Storm) {
        this.storm = storm
        this.nextOrg = 1
        this.nextTeam = 1
        this.nextMember = 1
        this.nextLog = 1
        this.nextPlan = 1
        this.storm.reindex<OrgDoc>()
        this.storm.reindex<TeamDoc>()
        this.storm.reindex<TeamMemberDoc>()
        this.storm.reindex<LogDoc>()
        this.storm.reindex<PlanDoc>()
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
        for (d in this.storm.all<TeamMemberDoc>()) { if (d.id >= m) { m = d.id } }
        if (m >= this.nextMember) { this.nextMember = m + 1 }
        m = 0
        for (d in this.storm.all<LogDoc>()) { if (d.id >= m) { m = d.id } }
        if (m >= this.nextLog) { this.nextLog = m + 1 }
        m = 0
        for (d in this.storm.all<PlanDoc>()) { if (d.id >= m) { m = d.id } }
        if (m >= this.nextPlan) { this.nextPlan = m + 1 }
    }

    // ===== 组织 =====
    public func createOrg(name: String, displayName: String, ownerId: Int64, now: Int64): Int64 {
        let d = OrgDoc()
        d.id = this.nextOrg
        this.nextOrg++
        d.name = name
        d.displayName = displayName
        d.ownerId = ownerId
        d.createdAt = now
        this.storm.save(d)
        return d.id
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
    public func createTeam(name: String, orgId: Int64, now: Int64): Int64 {
        let d = TeamDoc()
        d.id = this.nextTeam
        this.nextTeam++
        d.name = name
        d.orgId = orgId
        d.createdAt = now
        this.storm.save(d)
        return d.id
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

    // ===== 日志 =====
    public func addLog(kind: LogKind, actorId: Int64, actorName: String, action: String, status: String, now: Int64): Int64 {
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
        d.createdAt = now
        this.storm.save(d)
        return d.id
    }

    public func listLogs(kind: ?String, limit: Int64): ArrayList<LogDoc> {
        let r = ArrayList<LogDoc>()
        let all = this.storm.all<LogDoc>()
        var i = all.size - 1
        while (i >= 0 && r.size < limit) {
            let d = all[i]
            if (kind.isNone() || d.kind == kind.getOrThrow()) {
                r.add(d)
            }
            i--
        }
        return r
    }

    // ===== 发布计划 =====
    public func createPlan(name: String, targetUpstream: String, itemsJson: String, now: Int64): Int64 {
        let d = PlanDoc()
        d.id = this.nextPlan
        this.nextPlan++
        d.name = name
        d.status = "pending"
        d.targetUpstream = targetUpstream
        d.itemsJson = itemsJson
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

    public func updatePlanStatus(id: Int64, status: String, completed: Int64): Bool {
        match (this.storm.get<PlanDoc>(id)) {
            case Some(d) =>
                d.status = status
                d.completedCount = completed
                this.storm.save(d)
                return true
            case None => return false
        }
    }

    public func deletePlan(id: Int64): Bool {
        match (this.storm.get<PlanDoc>(id)) {
            case Some(d) =>
                this.storm.delete(d)
                return true
            case None => return false
        }
    }
}
