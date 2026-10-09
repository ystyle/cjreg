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

/// 团队-成员关联行：用户实体 + 是否已关联
public struct MemberRow {
    public let user: User
    public let linked: Bool

    public init(user: User, linked: Bool) {
        this.user = user
        this.linked = linked
    }
}
