// cjxt 管理界面：发布计划 / 日志 页
package ystyle::cjreg.ui

import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import ystyle::cjreg.store.*
import ystyle::cjreg.server.*
import ystyle::cjreg.index.*
import std.collection.*
import std.convert.*

// ===== 发布计划 =====
@Page["/admin/publish-plans"]
class PublishPlansPage <: Component {
    var state: Option<CjregState> = None
    var rows = Signal<ArrayList<HashMap<String, String>>>(ArrayList<HashMap<String, String>>())
    var planName = Signal<String>("")
    var targetUrl = Signal<String>("")
    var msg = Signal<String>("")

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        refresh()
    }

    func refresh(): Unit {
        match (this.state) {
            case Some(st) =>
                let plans = st.adminData.listPlans()
                let data = ArrayList<HashMap<String, String>>()
                for (p in plans) {
                    let m = HashMap<String, String>()
                    m["id"] = p.id.toString()
                    m["name"] = p.name
                    m["status"] = p.status
                    m["target"] = p.targetUpstream
                    m["progress"] = "${p.completedCount}/${p.totalCount}"
                    data.add(m)
                }
                this.rows.set(data)
            case None => ()
        }
    }

    public func render(): IComponent {
        let toolbar = div([
            Input().bind(this.planName).placeholder("计划名"),
            Input().bind(this.targetUrl).placeholder("目标上游 URL"),
            Button([text("分析并创建")]).kind(ButtonKind.Primary).onClick(createPlan),
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
            .add(TableColumn().label("计划名").colProp("name"))
            .add(TableColumn().label("状态").colProp("status").width(100))
            .add(TableColumn().label("目标").colProp("target"))
            .add(TableColumn().label("进度").colProp("progress").width(100))
        adminLayout("/admin/publish-plans", [
            div([text("发布计划")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            adminCard("发布计划列表", [toolbar, table]),
        ])
    }

    func createPlan(ctx: ActionContext): PatchResult {
        let st = match (this.state) {
            case Some(x) => x
            case None => return PatchResult.ReRender
        }
        if (this.planName.get().isEmpty() || this.targetUrl.get().isEmpty()) {
            this.msg.set("计划名和目标 URL 必填")
            return PatchResult.ReRender
        }
        // 用 analyze 计算所有本地包拓扑（简化：以全部本地包为根）
        let allPkgs = st.pkgStore.storm.all<PackageDoc>()
        if (allPkgs.size == 0) {
            this.msg.set("无本地包可发布")
            return PatchResult.ReRender
        }
        let roots = ArrayList<(String, String, String)>()
        for (d in allPkgs) {
            roots.add((d.organization, d.name, d.version))
        }
        let planSvc = PublishPlanService(st.pkgStore)
        let (items, hasCycle) = planSvc.analyze(roots)
        if (hasCycle) {
            this.msg.set("依赖存在环")
            return PatchResult.ReRender
        }
        // 序列化计划项
        let sb = StringBuilder()
        sb.append("[")
        for (i in 0..items.size) {
            let it = items[i]
            if (i > 0) { sb.append(",") }
            sb.append("{\"name\":\"${it.name}\",\"org\":\"${it.org}\",\"version\":\"${it.version}\",\"order\":${it.order},\"status\":\"pending\"}")
        }
        sb.append("]")
        let planId = st.adminData.createPlan(this.planName.get(), this.targetUrl.get(), sb.toString(), nowMs())
        this.msg.set("已创建发布计划 #${planId}（${items.size} 个包）")
        // 执行推送
        let executor = PublishExecutor(st.pkgStore, DiskBlobStore("${getDataDir()}/blobs"))
        let (ok, total, errors) = executor.execute(items, this.targetUrl.get(), "")
        if (ok == total) {
            st.adminData.updatePlanStatus(planId, "completed", total)
            this.msg.set("计划 #${planId} 执行完成：${ok}/${total}")
        } else {
            st.adminData.updatePlanStatus(planId, "failed", ok)
            this.msg.set("计划 #${planId} 部分失败：${ok}/${total}")
        }
        this.planName.set("")
        this.targetUrl.set("")
        refresh()
        PatchResult.ReRender
    }
}

// 数据目录（从状态推断：blob 存储路径）
public func getDataDir(): String {
    "./data"
}

// ===== 日志页 =====
@Page["/admin/logs"]
class LogsPage <: Component {
    var state: Option<CjregState> = None
    var rows = Signal<ArrayList<HashMap<String, String>>>(ArrayList<HashMap<String, String>>())

    public func onMount(ctx: LifecycleContext): Unit {
        this.state = Some(ctx.getState<CjregState>())
        refresh()
    }

    func refresh(): Unit {
        match (this.state) {
            case Some(st) =>
                let logs = st.adminData.listLogs(Option<String>.None, 200)
                let data = ArrayList<HashMap<String, String>>()
                for (l in logs) {
                    let m = HashMap<String, String>()
                    m["id"] = l.id.toString()
                    m["kind"] = l.kind
                    m["actor"] = l.actorName
                    m["action"] = l.action
                    m["status"] = l.status
                    data.add(m)
                }
                this.rows.set(data)
            case None => ()
        }
    }

    public func render(): IComponent {
        let table = Table()
            .data(this.rows)
            .stripe()
            .add(TableColumn().label("ID").colProp("id").width(60))
            .add(TableColumn().label("类型").colProp("kind").width(100))
            .add(TableColumn().label("操作者").colProp("actor").width(100))
            .add(TableColumn().label("操作").colProp("action"))
            .add(TableColumn().label("结果").colProp("status").width(80))
        adminLayout("/admin/logs", [
            div([text("日志")], attrs: Some(HashMap<String, String>([("class", cls("page-title"))]))),
            adminCard("操作日志", [table]),
        ])
    }
}
