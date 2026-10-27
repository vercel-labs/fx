//! The built-in rules, ported from proto's `discovery/builtin-rules`. The two
//! Python kernel rules are left out: they teach proto's kernel prelude, which
//! proto-fx does not have. Scopes name proto-fx's `shell` tool where proto's
//! named `bash`.

pub const Source = struct { name: []const u8, content: []const u8 };

pub const sources = [_]Source{
    .{ .name = "go-add-cleanup", .content = @embedFile("builtin/go-add-cleanup.md") },
    .{ .name = "go-bench-loop", .content = @embedFile("builtin/go-bench-loop.md") },
    .{ .name = "go-exp-promoted", .content = @embedFile("builtin/go-exp-promoted.md") },
    .{ .name = "go-ioutil", .content = @embedFile("builtin/go-ioutil.md") },
    .{ .name = "go-join-hostport", .content = @embedFile("builtin/go-join-hostport.md") },
    .{ .name = "go-new-expr", .content = @embedFile("builtin/go-new-expr.md") },
    .{ .name = "go-rand-v2", .content = @embedFile("builtin/go-rand-v2.md") },
    .{ .name = "go-range-int", .content = @embedFile("builtin/go-range-int.md") },
    .{ .name = "rs-box-leak", .content = @embedFile("builtin/rs-box-leak.md") },
    .{ .name = "rs-future-prelude", .content = @embedFile("builtin/rs-future-prelude.md") },
    .{ .name = "rs-lazylock", .content = @embedFile("builtin/rs-lazylock.md") },
    .{ .name = "rs-match-ergonomics", .content = @embedFile("builtin/rs-match-ergonomics.md") },
    .{ .name = "rs-parking-lot", .content = @embedFile("builtin/rs-parking-lot.md") },
    .{ .name = "rs-result-type", .content = @embedFile("builtin/rs-result-type.md") },
    .{ .name = "ts-bare-catch", .content = @embedFile("builtin/ts-bare-catch.md") },
    .{ .name = "ts-import-type", .content = @embedFile("builtin/ts-import-type.md") },
    .{ .name = "ts-no-any", .content = @embedFile("builtin/ts-no-any.md") },
    .{ .name = "ts-no-deprecated-leftovers", .content = @embedFile("builtin/ts-no-deprecated-leftovers.md") },
    .{ .name = "ts-no-dynamic-import", .content = @embedFile("builtin/ts-no-dynamic-import.md") },
    .{ .name = "ts-no-inline-cast-access", .content = @embedFile("builtin/ts-no-inline-cast-access.md") },
    .{ .name = "ts-no-local-is-record", .content = @embedFile("builtin/ts-no-local-is-record.md") },
    .{ .name = "ts-no-return-type", .content = @embedFile("builtin/ts-no-return-type.md") },
    .{ .name = "ts-no-test-timers", .content = @embedFile("builtin/ts-no-test-timers.md") },
    .{ .name = "ts-no-tiny-functions", .content = @embedFile("builtin/ts-no-tiny-functions.md") },
    .{ .name = "ts-promise-with-resolvers", .content = @embedFile("builtin/ts-promise-with-resolvers.md") },
    .{ .name = "ts-redundant-clear-guard", .content = @embedFile("builtin/ts-redundant-clear-guard.md") },
    .{ .name = "ts-set-map", .content = @embedFile("builtin/ts-set-map.md") },
};
