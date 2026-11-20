//! The hooks engine. It matches user hooks to fx events, runs them through
//! its host, and merges their answers into one outcome. Files under
//! `src/hooks/` import only `std` and each other. Outside code imports only
//! this file.

pub const event = @import("event.zig");
pub const answer = @import("answer.zig");
pub const limits = @import("limits.zig");
const merge = @import("merge.zig");
pub const match = @import("match.zig");
pub const config = @import("config.zig");
pub const protocol = @import("protocol.zig");
pub const host = @import("host.zig");
const engine = @import("engine.zig");

pub const EventName = event.EventName;
pub const Event = event.Event;
pub const Scope = event.Scope;
pub const Surface = event.Surface;
pub const Field = event.Field;
pub const Value = event.Value;
pub const Decision = answer.Decision;
pub const Answer = answer.Answer;
pub const Outcome = answer.Outcome;
pub const Host = host.Host;
pub const Engine = engine.Engine;
pub const Builtin = engine.Builtin;

test {
    // Reference every file so `zig test src/hooks/hooks.zig` runs all their tests.
    _ = event;
    _ = answer;
    _ = limits;
    _ = merge;
    _ = match;
    _ = config;
    _ = protocol;
    _ = host;
    _ = engine;
}
