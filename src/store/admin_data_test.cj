// AdminDataStore 单元测试（模型对齐 cjrepo 后：团队多对多关联/计划 items 独立表）
package ystyle::cjreg.store

import bstorm.*
import std.unittest.testmacro.*
import std.collection.*

func makeAdminStore(): AdminDataStore {
    beginTestStores()
    AdminDataStore(testStorm())
}

@Test
func testOrgLifecycle() {
    let store = makeAdminStore()
    let id = store.createOrg("test-org", "测试组织", 1, 1000)
    @Expect(id > 0, true)
    @Expect(store.listOrgs().size, 1)
    // 编辑（displayName/description/isDefault）
    @Expect(store.updateOrg(id, "新显示名", "描述", true, 1500), true)
    match (store.getOrg(id)) {
        case Some(o) =>
            @Expect(o.displayName, "新显示名")
            @Expect(o.description, "描述")
            @Expect(o.isDefault, true)
        case None => @Fail("expected org")
    }
    // 软删
    @Expect(store.deleteOrg(id, 2000), true)
    @Expect(store.listOrgs().size, 0)
    // 不存在
    @Expect(store.deleteOrg(999, 2000), false)
}

@Test
func testTeamLifecycleAndAssociations() {
    let store = makeAdminStore()
    let orgA = store.createOrg("org-a", "组织A", 1, 1000)
    let orgB = store.createOrg("org-b", "组织B", 1, 1000)
    let teamId = store.createTeam("dev", 1000, displayName: "开发团队", description: "核心开发", permission: "write")
    @Expect(store.listTeams().size, 1)
    match (store.getTeam(teamId)) {
        case Some(t) =>
            @Expect(t.displayName, "开发团队")
            @Expect(t.description, "核心开发")
            @Expect(t.permission, "write")
        case None => @Fail("expected team")
    }
    // 编辑
    @Expect(store.updateTeam(teamId, "改名", "", "overwrite", 1500), true)
    match (store.getTeam(teamId)) {
        case Some(t) => @Expect(t.permission, "overwrite")
        case None => ()
    }
    // 团队-组织多对多（0 = 无组织包）
    store.setTeamOrganizations(teamId, [0, orgA, orgB], 1600)
    @Expect(store.listTeamOrganizationIds(teamId).size, 3)
    store.setTeamOrganizations(teamId, [orgA], 1700)
    @Expect(store.listTeamOrganizationIds(teamId).size, 1)
    @Expect(store.listTeamOrganizationIds(teamId)[0], orgA)
    // 团队-包关联
    store.setTeamPackages(teamId, [("", "core-lib"), ("org-b", "web-app")], 1800)
    @Expect(store.listTeamPackages(teamId).size, 2)
    store.setTeamPackages(teamId, [("", "core-lib")], 1900)
    @Expect(store.listTeamPackages(teamId).size, 1)
    // 成员
    store.addTeamMember(teamId, 1)
    store.addTeamMember(teamId, 2)
    @Expect(store.listTeamMembers(teamId).size, 2)
    store.removeTeamMember(teamId, 1)
    @Expect(store.listTeamMembers(teamId).size, 1)
    store.setTeamMembers(teamId, [3, 4])
    @Expect(store.listTeamMemberIds(teamId).size, 2)
    // 软删团队
    @Expect(store.deleteTeam(teamId, 2000), true)
    @Expect(store.listTeams().size, 0)
}

@Test
func testLogsStructured() {
    let store = makeAdminStore()
    store.addLog(LogKind.Publish, 1, "admin", "publish demo@1.0.0", "ok", 1000, target: "demo", ipAddr: "127.0.0.1", userAgent: "cjpm/1.1")
    store.addLog(LogKind.Admin, 1, "admin", "create upstream", "ok", 1100)
    store.addLog(LogKind.Publish, 2, "user2", "publish lib@2.0.0", "failed", 1200, error: "sha256 mismatch")
    let publishLogs = store.listLogs(Some("publish"), 10)
    @Expect(publishLogs.size, 2)
    @Expect(publishLogs[0].action, "publish lib@2.0.0")  // 最新在前
    @Expect(publishLogs[0].error, "sha256 mismatch")
    @Expect(publishLogs[1].ipAddr, "127.0.0.1")
    let all = store.listLogs(None, 10)
    @Expect(all.size, 3)
}

@Test
func testQueryLogsFilterPagingAndOrder() {
    let store = makeAdminStore()
    // 时间乱序写入：验证按时间倒序而非写入顺序
    store.addLog(LogKind.Publish, 1, "admin", "publish demo@1.0.0", "ok", 1000, target: "test/demo@1.0.0")
    store.addLog(LogKind.Auth, 1, "admin", "login", "ok", 1500, target: "admin", ipAddr: "10.0.0.1")
    store.addLog(LogKind.Publish, 2, "user2", "publish lib@2.0.0", "failed", 1200,
        target: "test/lib@2.0.0", error: "sha256 mismatch", ipAddr: "10.0.0.2", userAgent: "cjpm/1.1")
    store.addLog(LogKind.Publish, 2, "user2", "publish lib@2.0.1", "ok", 1300, target: "test/lib@2.0.1")

    // 全量：时间倒序
    let (all, totalAll) = store.queryLogs(None, "", "", 0, 0, 0, 10)
    @Expect(totalAll, 4)
    @Expect(all[0].action, "login")
    @Expect(all[1].action, "publish lib@2.0.1")
    @Expect(all[3].action, "publish demo@1.0.0")

    // kind 过滤
    let (pub, totalPub) = store.queryLogs(Some("publish"), "", "", 0, 0, 0, 10)
    @Expect(totalPub, 3)
    @Expect(pub.size, 3)

    // status 过滤
    let (failed, totalFailed) = store.queryLogs(None, "", "failed", 0, 0, 0, 10)
    @Expect(totalFailed, 1)
    @Expect(failed[0].error, "sha256 mismatch")

    // 关键字（命中目标字段）
    let (kw, totalKw) = store.queryLogs(None, "lib@2.0.1", "", 0, 0, 0, 10)
    @Expect(totalKw, 1)
    @Expect(kw[0].actorName, "user2")

    // 关键字（命中 error 字段）
    let (kw2, _) = store.queryLogs(None, "mismatch", "", 0, 0, 0, 10)
    @Expect(kw2.size, 1)

    // 时间范围（含边界）
    let (ranged, totalRanged) = store.queryLogs(None, "", "", 1200, 1300, 0, 10)
    @Expect(totalRanged, 2)
    @Expect(ranged[0].createdAt, 1300)
    @Expect(ranged[1].createdAt, 1200)

    // 分页：total 为命中总数而非本页条数
    let (page2, totalPage) = store.queryLogs(None, "", "", 0, 0, 2, 2)
    @Expect(totalPage, 4)
    @Expect(page2.size, 2)
    // 全序：login(1500) > lib@2.0.1(1300) > lib@2.0.0(1200) > demo@1.0.0(1000)
    @Expect(page2[0].action, "publish lib@2.0.0")
    @Expect(page2[1].action, "publish demo@1.0.0")
    // 越界页返回空、总数不变
    let (page9, _) = store.queryLogs(None, "", "", 0, 0, 9, 2)
    @Expect(page9.size, 0)

    // 清理：按 kind 删除
    @Expect(store.removeLogs(Some("publish"), 0), 3)
    @Expect(store.queryLogs(Some("publish"), "", "", 0, 0, 0, 10)[1], 0)
    @Expect(store.queryLogs(None, "", "", 0, 0, 0, 10)[1], 1)
    // 清理：按时间（before）——只剩 login(1500)，阈值 1400 不命中、1600 命中
    @Expect(store.removeLogs(None, 1400), 0)
    @Expect(store.queryLogs(None, "", "", 0, 0, 0, 10)[1], 1)
    @Expect(store.removeLogs(None, 1600), 1)
    @Expect(store.queryLogs(None, "", "", 0, 0, 0, 10)[1], 0)
}

@Test
func testPlanLifecycleWithItems() {
    let store = makeAdminStore()
    let id = store.createPlan("plan1", 3, 60, 600, 1000)
    @Expect(store.listPlans().size, 1)
    match (store.getPlan(id)) {
        case Some(p) =>
            @Expect(p.status, "pending")
            @Expect(p.targetUpstream, 3)
            @Expect(p.pollInterval, 60)
            @Expect(p.pollTimeout, 600)
        case None => @Fail("expected plan")
    }
    // 计划项独立表
    let item1 = store.addPlanItem(id, 10, "demo", "app", "1.0.0", 1, "app", true)
    let item2 = store.addPlanItem(id, 11, "demo", "lib", "2.0.0", 0, "deps", true)
    let items = store.listPlanItems(id)
    @Expect(items.size, 2)
    @Expect(items[0].order, 0)   // 按 order 排序
    @Expect(items[1].packageName, "app")
    @Expect(store.updatePlanItem(item2, "running", "", 1100), true)
    @Expect(store.updatePlanItem(item2, "completed", "", 1200), true)
    match (store.getPlanItem(item2)) {
        case Some(it) =>
            @Expect(it.status, "completed")
            @Expect(it.completedAt > 0, true)
        case None => @Fail("expected item")
    }
    @Expect(store.setPlanItemSelected(item1, false), true)
    match (store.getPlanItem(item1)) {
        case Some(it) => @Expect(it.selected, false)
        case None => ()
    }
    @Expect(store.updatePlanStatus(id, "running", 1, 1300), true)
    match (store.getPlan(id)) {
        case Some(p) =>
            @Expect(p.status, "running")
            @Expect(p.completedCount, 1)
        case None => ()
    }
    // 删除计划连带删除 items
    @Expect(store.deletePlan(id), true)
    @Expect(store.listPlans().size, 0)
    @Expect(store.listPlanItems(id).size, 0)
}

// 时间线时间戳：进入「等索引」= 内容推送成功时刻；「完成」= 目标仓索引确认到该版本的时刻。
// 重复写同一状态（续跑/重新检查）不能把已有时间覆盖掉——那是发生过的事实。
@Test
func planItem_timelineStamps() {
    let store = makeAdminStore()
    let id = store.createPlan("plan3", 3, 60, 0, 1000)
    let item = store.addPlanItem(id, 10, "", "bstorm", "1.4.9", 1, "need_publish", true)
    @Expect(store.updatePlanItem(item, "running", "", 1100), true)
    match (store.getPlanItem(item)) {
        case Some(it) =>
            @Expect(it.startedAt, 1100)
            @Expect(it.pushedAt, 0)          // 还只是"在推"
        case None => @Fail("expected item")
    }
    // 推成功、进入等索引 → 记发布时间
    @Expect(store.updatePlanItem(item, "waiting_index", "等待目标仓索引就绪", 1200), true)
    match (store.getPlanItem(item)) {
        case Some(it) => @Expect(it.pushedAt, 1200)
        case None => @Fail("expected item")
    }
    // 续跑再次写 waiting_index：发布时间保持第一次的
    @Expect(store.updatePlanItem(item, "waiting_index", "已推送过，继续等", 1300), true)
    // 索引确认到 → 记索引生效时间；完成时间也落这一笔
    @Expect(store.updatePlanItem(item, "completed", "", 1400), true)
    match (store.getPlanItem(item)) {
        case Some(it) =>
            @Expect(it.pushedAt, 1200)
            @Expect(it.indexAt, 1400)
            @Expect(it.completedAt, 1400)
        case None => @Fail("expected item")
    }
    // 再次标完成（例如执行器重复回调）：索引时间不覆盖
    @Expect(store.updatePlanItem(item, "completed", "", 1500), true)
    match (store.getPlanItem(item)) {
        case Some(it) => @Expect(it.indexAt, 1400)
        case None => @Fail("expected item")
    }
}

// 计划项的「目标仓对照」要落库：详情页刷新后还得看得到对照值（否则只能重新分析才显示）
@Test
func planItem_targetComparePersists() {
    let store = makeAdminStore()
    let id = store.createPlan("plan2", 3, 60, 600, 1000)
    let item = store.addPlanItem(id, 10, "", "bstorm", "1.4.9", 1, "need_publish", true,
        targetVersion: "1.4.8", targetCompared: true)
    match (store.getPlanItem(item)) {
        case Some(it) =>
            @Expect(it.targetVersion, "1.4.8")
            @Expect(it.targetCompared, true)
        case None => @Fail("expected item")
    }
    // 重新分析：分类与对照一起更新（对照是必填参数，不给就等于清空，这里显式给新值）
    @Expect(store.setPlanItemCategory(item, "already_exists", false,
        targetVersion: "1.4.9", targetCompared: true), true)
    match (store.getPlanItem(item)) {
        case Some(it) =>
            @Expect(it.category, "already_exists")
            @Expect(it.selected, false)
            @Expect(it.targetVersion, "1.4.9")
        case None => @Fail("expected item")
    }
    // 没做成对照（索引取不到）→ compared=false，版本清空：界面据此显示「未对照」
    @Expect(store.setPlanItemCategory(item, "need_publish", true,
        targetVersion: "", targetCompared: false), true)
    match (store.getPlanItem(item)) {
        case Some(it) =>
            @Expect(it.targetVersion, "")
            @Expect(it.targetCompared, false)
        case None => @Fail("expected item")
    }
}
