//! The core both faces share, the `publr` command and Desktop: the command's folder and
//! config, the sites in every listed folder, which Publr each runs, their servers, signed-in
//! links and the helper, and this computer's sign-ins to sites and to Cloud.

pub const config = @import("core/config.zig");
pub const sites = @import("core/sites.zig");
pub const server = @import("core/server.zig");
pub const sign_on = @import("core/sign_on.zig");
pub const helper = @import("core/helper.zig");
pub const versions = @import("core/versions.zig");
pub const project = @import("core/project.zig");
pub const credentials = @import("core/credentials.zig");
pub const remote = @import("core/remote.zig");
pub const login = @import("core/login.zig");
pub const cloud_login = @import("core/cloud_login.zig");
pub const archive = @import("core/archive.zig");
pub const site_data = @import("core/site_data.zig");
pub const transfer = @import("core/transfer.zig");
pub const links = @import("core/links.zig");
pub const changes = @import("core/changes.zig");
pub const skill = @import("core/skill.zig");
pub const compat = @import("core/compat.zig");
pub const upgrade = @import("core/upgrade.zig");
pub const rename = @import("core/rename.zig");

pub const Config = config.Config;
pub const Site = sites.Site;
pub const Sites = sites.Sites;

test {
    @import("std").testing.refAllDecls(@This());
}
