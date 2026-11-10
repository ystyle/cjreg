// 组织/用户/团队页面的行模型
package ystyle::cjreg.ui.admin

import ystyle::cjreg.ui.*
import cjxt.*
import cjxt.macros.*
import cjxt.components.*
import ystyle::cjreg.store.*
import ystyle::cjreg.auth.model.*
import std.collection.*
import std.convert.*

public struct TeamRow {
    public let doc: TeamDoc
    public let members: Int64
    public let orgs: Int64
    public let pkgs: Int64

    public init(doc: TeamDoc, members: Int64, orgs: Int64, pkgs: Int64) {
        this.doc = doc
        this.members = members
        this.orgs = orgs
        this.pkgs = pkgs
    }
}

/// 团队-包关联行：包实体 + 是否已关联
public struct PkgRow {
    public let doc: PackageDoc
    public let linked: Bool

    public init(doc: PackageDoc, linked: Bool) {
        this.doc = doc
        this.linked = linked
    }
}

/// 团队「成员」弹窗表格行：只带展示与移除所需的键
public struct TeamMemberLink {
    public let userId: Int64
    public let username: String

    public init(userId: Int64, username: String) {
        this.userId = userId
        this.username = username
    }
}

/// 团队「包」弹窗表格行：只带 org/name（团队按包授权，不区分版本）
public struct TeamPkgLink {
    public let organization: String
    public let name: String

    public init(organization: String, name: String) {
        this.organization = organization
        this.name = name
    }
}

/// 团队-成员关联行：用户实体 + 是否已关联
public struct MemberRow {
    public let user: User
    public let linked: Bool

    public init(user: User, linked: Bool) {
        this.user = user
        this.linked = linked
    }
}
