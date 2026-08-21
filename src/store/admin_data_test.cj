// AdminDataStore 单元测试
package ystyle::cjreg.store

import bstorm.*
import std.unittest.testmacro.*
import std.collection.*

func makeAdminStore(): AdminDataStore {
    AdminDataStore(Storm.inMemory())
}

@Test
func testOrgLifecycle() {
    let store = makeAdminStore()
    let id = store.createOrg("test-org", "测试组织", 1, 1000)
    @Expect(id > 0, true)
    @Expect(store.listOrgs().size, 1)
    // 软删
    @Expect(store.deleteOrg(id, 2000), true)
    @Expect(store.listOrgs().size, 0)
    // 不存在
    @Expect(store.deleteOrg(999, 2000), false)
}

@Test
func testTeamAndMembers() {
    let store = makeAdminStore()
    let orgId = store.createOrg("org1", "组织1", 1, 1000)
    let teamId = store.createTeam("dev", orgId, 1000)
    @Expect(store.listTeams().size, 1)
    store.addTeamMember(teamId, 1)
    store.addTeamMember(teamId, 2)
    @Expect(store.listTeamMembers(teamId).size, 2)
}

@Test
func testLogs() {
    let store = makeAdminStore()
    store.addLog(LogKind.Publish, 1, "admin", "publish demo@1.0.0", "ok", 1000)
    store.addLog(LogKind.Admin, 1, "admin", "create upstream", "ok", 1100)
    store.addLog(LogKind.Publish, 2, "user2", "publish lib@2.0.0", "failed", 1200)
    let publishLogs = store.listLogs(Some("publish"), 10)
    @Expect(publishLogs.size, 2)
    @Expect(publishLogs[0].action, "publish lib@2.0.0")  // 最新在前
    let all = store.listLogs(None, 10)
    @Expect(all.size, 3)
}

@Test
func testPlanLifecycle() {
    let store = makeAdminStore()
    let id = store.createPlan("plan1", "http://localhost:8070", "[{\"name\":\"app\"}]", 1000)
    @Expect(store.listPlans().size, 1)
    @Expect(store.getPlan(id).isSome(), true)
    match (store.getPlan(id)) {
        case Some(p) => @Expect(p.status, "pending")
        case None => ()
    }
    @Expect(store.updatePlanStatus(id, "running", 3), true)
    match (store.getPlan(id)) {
        case Some(p) =>
            @Expect(p.status, "running")
            @Expect(p.completedCount, 3)
        case None => ()
    }
    @Expect(store.deletePlan(id), true)
    @Expect(store.listPlans().size, 0)
}
