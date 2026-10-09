// 管理 API · 组织管理（列表 / 详情 / 创建 / 更新 / 删除）——AdminService 的组织域扩展
package ystyle::cjreg.server

import tang.*
import ystyle::cjreg.store.*
import std.collection.*
import std.convert.*

extend AdminService {
    // ===== 组织 CRUD（REST）=====
    // 组织端点需要的两个 store：缺失时写 500 并返回 None
    func orgStores(ctx: TangHttpContext): ?(AdminDataStore, PackageStore) {
        let ad = match (this.adminData) {
            case Some(x) => x
            case None =>
                writeDto(ctx, 500u16, ErrorResp("admin data store unavailable"))
                return None
        }
        let ps = match (this.pkgStore) {
            case Some(x) => x
            case None =>
                writeDto(ctx, 500u16, ErrorResp("package store unavailable"))
                return None
        }
        Some((ad, ps))
    }

    // GET /api/admin/organizations → 列表（含包/版本/团队计数）
    public func listOrganizations(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let (ad, ps) = match (this.orgStores(ctx)) {
            case Some(v) => v
            case None => return
        }
        let items = ArrayList<OrgDto>()
        for (o in ad.listOrgs()) {
            let (pkgs, versions) = orgPackageStats(ps, o.name)
            items.add(orgJson(o, pkgs, versions, orgReferencingTeams(ad, o.id).size))
        }
        writeDto(ctx, 200u16, orgListJson(items, items.size))
    }

    // GET /api/admin/organizations/:id → 详情
    public func getOrganization(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let (ad, ps) = match (this.orgStores(ctx)) {
            case Some(v) => v
            case None => return
        }
        let id = match (Int64.tryParse(ctx.param("id"))) {
            case Some(n) => n
            case None => 0
        }
        let org = match (ad.getOrg(id)) {
            case Some(o) => if (o.deletedAt == 0) { o } else {
                writeDto(ctx, 404u16, ErrorResp("organization not found"))
                return
            }
            case None =>
                writeDto(ctx, 404u16, ErrorResp("organization not found"))
                return
        }
        let (pkgs, versions) = orgPackageStats(ps, org.name)
        writeDto(ctx, 200u16, orgJson(org, pkgs, versions, orgReferencingTeams(ad, org.id).size))
    }

    // POST /api/admin/organizations  body {name, displayName?, description?, isDefault?}
    public func createOrganization(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let (ad, _) = match (this.orgStores(ctx)) {
            case Some(v) => v
            case None => return
        }
        let body = match (parseJsonBody<OrgUpsertRequest>(ctx.bodyRaw(), { r => OrgUpsertRequest.fromJson(r) })) {
            case Some(b) => b
            case None =>
                writeDto(ctx, 400u16, ErrorResp("invalid JSON body"))
                return
        }
        let (actorId, _) = this.actorOf(ctx)
        let r = createOrgChecked(ad, body.name.trimAscii(), body.displayName, body.description,
            body.isDefault, actorId, auditNowMs())
        this.auditOrg(ctx, "create_org", body.name.trimAscii(), r)
        writeDto(ctx, orgResultCode(r), orgResultJson(r))
    }

    // PUT /api/admin/organizations/:id  body {name?, displayName?, description?, isDefault?}
    // 未传的字段保持原值；name 非空且与原值不同时视为改名（有包则 409）
    public func updateOrganization(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let (ad, ps) = match (this.orgStores(ctx)) {
            case Some(v) => v
            case None => return
        }
        let id = match (Int64.tryParse(ctx.param("id"))) {
            case Some(n) => n
            case None => 0
        }
        let body = match (parseJsonBody<OrgUpsertRequest>(ctx.bodyRaw(), { r => OrgUpsertRequest.fromJson(r) })) {
            case Some(b) => b
            case None =>
                writeDto(ctx, 400u16, ErrorResp("invalid JSON body"))
                return
        }
        let cur = match (ad.getOrg(id)) {
            case Some(o) => o
            case None =>
                writeDto(ctx, 404u16, ErrorResp("organization not found"))
                return
        }
        let displayName = if (body.hasDisplayName) { body.displayName } else { cur.displayName }
        let description = if (body.hasDescription) { body.description } else { cur.description }
        let isDefault = if (body.hasIsDefault) { body.isDefault } else { cur.isDefault }
        let wantedName = body.name.trimAscii()
        let r = updateOrgChecked(ps, ad, id, wantedName, displayName, description, isDefault, auditNowMs())
        let target = if (wantedName.isEmpty() || wantedName == cur.name) { cur.name } else { "${cur.name}→${wantedName}" }
        this.auditOrg(ctx, "update_org", target, r)
        writeDto(ctx, orgResultCode(r), orgResultJson(r))
    }

    // DELETE /api/admin/organizations/:id → 软删（有包或仍被团队关联时 409）
    public func deleteOrganization(ctx: TangHttpContext): Unit {
        if (!requireAdmin(ctx)) {
            return
        }
        let (ad, ps) = match (this.orgStores(ctx)) {
            case Some(v) => v
            case None => return
        }
        let id = match (Int64.tryParse(ctx.param("id"))) {
            case Some(n) => n
            case None => 0
        }
        let name = match (ad.getOrg(id)) {
            case Some(o) => o.name
            case None => "#${id}"
        }
        let r = deleteOrgChecked(ps, ad, id, auditNowMs())
        this.auditOrg(ctx, "delete_org", name, r)
        writeDto(ctx, orgResultCode(r), orgResultJson(r))
    }

    // 组织操作审计（与 UI 侧 uiAudit 的动作名保持一致）
    func auditOrg(ctx: TangHttpContext, action: String, target: String, r: OrgResult): Unit {
        let (actorId, actorName) = this.actorOf(ctx)
        writeAudit(this.adminData, LogKind.Admin, actorId, actorName, action,
            if (r.outcome == OrgOutcome.Ok) { "ok" } else { "failed" }, target, ctx,
            error: if (r.outcome == OrgOutcome.Ok) { "" } else { r.message },
            detail: "id=${r.orgId} affected=${r.affected}")
    }
}
