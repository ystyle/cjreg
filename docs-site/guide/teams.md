# 团队与组织

**团队 = 权限单元**：把「组织 / 包 + 成员」关联起来，对关联资源整体授予一个权限级别。

## 数据模型

```
Team              { id, name, displayName, description, permission: read|write|overwrite }
TeamOrganization  { teamId, organizationId }      // organizationId = 0 表示「无组织包」
TeamPackage       { teamId, organization, packageName }
TeamMember        { teamId, userId }
```

## 在管理后台操作

管理后台 → **团队管理**：

1. 「新增团队」：填写团队名（唯一）、显示名、描述，选择默认权限（read / write / overwrite）；
2. 行内「组织」：多选组织（含「无组织包」）；
3. 行内「包」：搜索已有包并关联；
4. 行内「成员」：搜索用户并添加/移除（添加即生效）。

**组织管理**：创建/编辑/删除组织；组织是团队关联与「组织级权限」的锚点，
也是用户在 URL 中填的 `organization` 参数在服务端登记的实体。

## 典型用法

| 诉求 | 配置 |
|---|---|
| 团队可发布某组织下所有包 | 团队权限 `write` + 关联该组织 |
| 团队只能发布指定几个包 | 团队权限 `write` + 只关联这几个包 |
| 允许覆盖已发布版本 | 团队权限 `overwrite` |
| 只读（可下载，不可发布） | 团队权限 `read`（配合 `require_auth` 生效） |

## 与个人路径的关系

- 团队协作发版不会产生新的 owner（见[权限模型](/guide/permission)）；
- 成员退出团队后即失去该包的权限（owner 除外）；
- 平台管理员始终是超集，可直接管理所有团队与包。
