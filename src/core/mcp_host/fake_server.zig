//! A fake MCP server for the host's tests, in sh, so they need no network
//! or package. Imported only from tests.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const Options = @import("runtime.zig").Options;
const testing = std.testing;

/// A 2025 MCP server in sh: discovery gets an error, so the engine falls back
/// to `initialize`; it lists one `echo` tool and answers calls, except a call
/// that mentions "slow", which never answers. A call that mentions
/// "withdraw" asks form question Q1, withdraws it, asks Q2, and once Q2 is
/// answered, returns what reached each: "e1 " if Q1 got an answer, then
/// "e2=" and Q2's `name`.
pub const script =
    \\#!/bin/sh
    \\while IFS= read -r line; do
    \\  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
    \\  case "$line" in
    \\    *'"method":"server/discover"'*) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found"}}\n' "$id" ;;
    \\    *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"1"}}}\n' "$id" ;;
    \\    *'"method":"tools/list"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo","description":"Echoes","inputSchema":{"type":"object"}}]}}\n' "$id" ;;
    \\    *'"method":"tools/call"'*slow*) ;;
    \\    *'"method":"tools/call"'*withdraw*)
    \\      call=$id
    \\      printf '{"jsonrpc":"2.0","id":"e1","method":"elicitation/create","params":{"mode":"form","message":"Q1","requestedSchema":{"type":"object","properties":{"name":{"type":"string"}}}}}\n'
    \\      printf '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"e1"}}\n'
    \\      printf '{"jsonrpc":"2.0","id":"e2","method":"elicitation/create","params":{"mode":"form","message":"Q2","requestedSchema":{"type":"object","properties":{"name":{"type":"string"}}}}}\n' ;;
    \\    *'"id":"e1"'*) got="${got}e1 " ;;
    \\    *'"id":"e2"'*)
    \\      name=$(printf '%s' "$line" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p')
    \\      printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"%se2=%s"}]}}\n' "$call" "$got" "$name" ;;
    \\    *'"method":"tools/call"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"content":[{"type":"text","text":"hi"}]}}\n' "$id" ;;
    \\  esac
    \\done
    \\
;

pub const Fixture = struct {
    tmp: testing.TmpDir,
    home: []u8,
    server: []u8,
    inherited: std.process.Environ.Map,

    pub fn init(f: *Fixture) !void {
        f.tmp = testing.tmpDir(.{});
        errdefer f.tmp.cleanup();
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "server", .data = script, .flags = .{ .permissions = .executable_file } });
        f.home = try io_mod.dirRealpathAlloc(testing.allocator, f.tmp.dir, ".");
        errdefer testing.allocator.free(f.home);
        f.server = try std.Io.Dir.path.join(testing.allocator, &.{ f.home, "server" });
        f.inherited = .init(testing.allocator);
    }

    pub fn deinit(f: *Fixture) void {
        f.inherited.deinit();
        testing.allocator.free(f.server);
        testing.allocator.free(f.home);
        f.tmp.cleanup();
    }

    pub fn options(f: *const Fixture) Options {
        return .{ .client_version = "test", .credentials = .{ .home = f.home, .backend = .file } };
    }
};
