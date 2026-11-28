//! The Codex and Grok client versions fx reports to ChatGPT and Grok. Each
//! release pins them, so fx never asks npm or x.ai for them and the update
//! check stays its only background connection (RULES.md R4.7).
//! `scripts/check-provider-versions.sh` stops a stable release whose pins are
//! behind the providers' current releases.
const update_target = @import("../upgrade/update_target.zig");

/// How often a subscription model list is fetched again while fx runs.
pub const refresh_interval_ms: i64 = 60_000;

pub const codex_client_version = "0.172.0";
pub const grok_client_version = "1.0.92";

comptime {
    for ([_][]const u8{ codex_client_version, grok_client_version }) |pinned| {
        if (!update_target.isValidVersion(pinned)) @compileError("a pinned provider client version must be MAJOR.MINOR.PATCH");
    }
}
