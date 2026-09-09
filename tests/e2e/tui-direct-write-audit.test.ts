import { execFileSync, spawnSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { describe, expect, test } from "bun:test";

const repoRoot = join(import.meta.dir, "..", "..");
const auditScript = join(import.meta.dir, "render-lab", "audit-direct-writes.ts");

type Fixture = {
  name: string;
  path: string;
  source: string;
  accepted: boolean;
};

function writeSource(root: string, path: string, source: string): void {
  const fullPath = join(root, path);
  mkdirSync(join(fullPath, ".."), { recursive: true });
  writeFileSync(fullPath, `${source.trim()}\n`);
}

function writeFrameCommit(root: string, writes = 1): void {
  writeSource(
    root,
    "src/ui/transcript/io.zig",
    `fn writeFrameBytes(shell: anytype, bytes: []const u8) void {
${"    _ = shell.stdout_file.writeStreaming(io, &.{}, &.{bytes}, 1);\n".repeat(writes)}}`,
  );
}

function runFixture(fixture: Fixture): ReturnType<typeof spawnSync> {
  const root = mkdtempSync(join(tmpdir(), "fx-direct-write-audit-"));
  try {
    writeFrameCommit(root);
    writeSource(root, fixture.path, fixture.source);
    return spawnSync("bun", [auditScript, "--repo-root", root], {
      cwd: repoRoot,
      encoding: "utf8",
    });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

function zigSources(root: string): Array<{ path: string; source: string }> {
  const files: Array<{ path: string; source: string }> = [];
  const visit = (dir: string): void => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) {
        visit(path);
      } else if (entry.isFile() && entry.name.endsWith(".zig")) {
        files.push({
          path: relative(repoRoot, path),
          source: readFileSync(path, "utf8"),
        });
      }
    }
  };
  visit(root);
  return files.sort((a, b) => a.path.localeCompare(b.path));
}

describe("tui: direct-write audit", () => {
  test("classifies the real repository with one frame commit", () => {
    const output = execFileSync(
      "bun",
      [auditScript, "--repo-root", repoRoot, "--inventory"],
      { cwd: repoRoot, encoding: "utf8" },
    );
    expect(output).toContain("frame_commit=1");
    expect(output).toContain("unclassified=0");
    expect(output).toContain("path=src/ui/transcript/io.zig");
    expect(output).toContain("category=acp_protocol_transport");
    expect(output).toContain("category=subprocess_protocol_transport");
    expect(output).toMatch(
      /path=src\/core\/terminal\/native_session\.zig .*function=acceptMarker .*category=subprocess_protocol_transport/,
    );
    expect(output).toMatch(
      /path=src\/core\/terminal\/tmux_session\.zig .*function=runLauncher .*category=subprocess_protocol_transport/,
    );
    expect(output).toContain("function=clearTmuxScreenAndHistory");
    expect(output).toContain("category=terminal_reset");
    expect(output).toContain("path=src/core/app/app_entry_runtime.zig");
    expect(output).toContain("function=writeRealStdout");
  });

  test("accepts owned forms and rejects unowned acquisition or writes", () => {
    const fixtures: Fixture[] = [
      {
        name: "captured helper stream closure",
        path: "src/core/execution/command_runner.zig",
        accepted: true,
        source: `fn superviseSessionHelpers() void {
          std.Io.File.stdout().close(io);
          std.Io.File.stderr().close(io);
        }`,
      },
      {
        name: "unowned helper stream write",
        path: "src/core/execution/command_runner.zig",
        accepted: false,
        source: `fn superviseSessionHelpers() void {
          std.Io.File.stderr().writeStreamingAll(io, "unframed");
        }`,
      },
      {
        name: "helper retirement failure diagnostic",
        path: "src/core/execution/managed_execution.zig",
        accepted: true,
        source: `fn deinitWithOutcome() void {
          std.Io.File.stderr().writeStreamingAll(io, "cleanup incomplete");
        }`,
      },
      {
        name: "unowned execution diagnostic",
        path: "src/core/execution/managed_execution.zig",
        accepted: false,
        source: `fn workerMain() void {
          std.Io.File.stderr().writeStreamingAll(io, "unframed");
        }`,
      },
      {
        name: "terminal probe",
        path: "src/ui/shell_runtime.zig",
        accepted: true,
        source: `const std = @import("std");
          fn queryCursorPosition() !void {
            const stdout = std.Io.File.stdout();
            try stdout.writeStreamingAll(io, "\\x1b[6n");
          }`,
      },
      {
        name: "top-level help TTY capability probe",
        path: "src/main.zig",
        accepted: true,
        source: `const std = @import("std");
          fn stdoutIsTerminal() bool {
            return std.c.isatty(std.posix.STDOUT_FILENO) != 0;
          }`,
      },
      {
        name: "tmux history reset",
        path: "src/ui/shell_runtime.zig",
        accepted: true,
        source: `const std = @import("std");
          fn clearTmuxScreenAndHistory() !void {
            const stdout_file = std.Io.File.stdout();
            try stdout_file.writeStreamingAll(io, "\\x1b[3J");
          }`,
      },
      {
        name: "ordinary file output",
        path: "src/core/files/write.zig",
        accepted: true,
        source: `fn writeFile(file: anytype, bytes: []const u8) !void {
          try file.writeStreamingAll(io, bytes);
        }`,
      },
      {
        name: "local stdout alias",
        path: "src/core/unexpected/local.zig",
        accepted: false,
        source: `const std = @import("std");
          fn leak(bytes: []const u8) !void {
            const output = std.Io.File.stdout();
            try output.writeStreamingAll(io, bytes);
          }`,
      },
      {
        name: "stdout function-value alias",
        path: "src/core/unexpected/stdout-function-alias.zig",
        accepted: false,
        source: `const std = @import("std");
          const acquireOutput = std.Io.File.stdout;
          fn leak(bytes: []const u8) !void {
            const output = acquireOutput();
            try output.writeStreamingAll(io, bytes);
          }`,
      },
      {
        name: "stderr function-value alias with renamed handle",
        path: "src/core/unexpected/stderr-function-alias.zig",
        accepted: false,
        source: `const std = @import("std");
          const acquireError = std.Io.File.stderr;
          fn leak(bytes: []const u8) !void {
            const diagnostic = acquireError();
            try diagnostic.writeStreamingAll(io, bytes);
          }`,
      },
      {
        name: "renamed stored stdout handle",
        path: "src/ui/transcript/runtime.zig",
        accepted: false,
        source: `const std = @import("std");
          const terminalOutput = std.Io.File.stdout();
          fn leak(bytes: []const u8) !void {
            const renamed = terminalOutput;
            try renamed.writeStreamingAll(io, bytes);
          }`,
      },
      {
        name: "direct stdout function-value alias call in allowlisted owner",
        path: "src/ui/transcript/runtime.zig",
        accepted: false,
        source: `const std = @import("std");
          const acquireOutput = std.Io.File.stdout;
          fn leak(bytes: []const u8) !void {
            try acquireOutput().writeStreamingAll(io, bytes);
          }`,
      },
      {
        name: "stored stdout handle",
        path: "src/core/unexpected/stored.zig",
        accepted: false,
        source: `const std = @import("std");
          const Runtime = struct { stdout_file: std.Io.File = std.Io.File.stdout() };`,
      },
      {
        name: "buffered stdout",
        path: "src/core/unexpected/buffered.zig",
        accepted: false,
        source: `const std = @import("std");
          fn leak() void {
            const output = std.Io.File.stdout();
            var buffer: [64]u8 = undefined;
            _ = std.Io.File.Writer.initStreaming(output, io, &buffer);
          }`,
      },
      {
        name: "fixed descriptor",
        path: "src/core/unexpected/fd.zig",
        accepted: false,
        source: `const std = @import("std");
          fn leak(bytes: []const u8) void {
            _ = std.c.write(std.posix.STDOUT_FILENO, bytes.ptr, bytes.len);
          }`,
      },
      {
        name: "interactive write",
        path: "src/ui/leak.zig",
        accepted: false,
        source: `fn leak(shell: anytype, bytes: []const u8) !void {
          try shell.stdout_file.writeStreamingAll(io, bytes);
        }`,
      },
      {
        name: "debug print",
        path: "src/core/unexpected/debug.zig",
        accepted: false,
        source: `const std = @import("std");
          fn leak() void { std.debug.print("leak", .{}); }`,
      },
    ];

    for (const fixture of fixtures) {
      const result = runFixture(fixture);
      if (fixture.accepted) {
        expect(result.status, fixture.name).toBe(0);
        expect(result.stdout).toContain("frame_commit=1");
      } else {
        expect(result.status, fixture.name).not.toBe(0);
        expect(result.stderr).toContain(`unclassified_direct_write ${fixture.path}`);
      }
    }
  });

  test("requires exactly one normal interactive frame commit", () => {
    for (const writes of [0, 2]) {
      const root = mkdtempSync(join(tmpdir(), "fx-direct-write-audit-"));
      try {
        if (writes > 0) writeFrameCommit(root, writes);
        const result = spawnSync("bun", [auditScript, "--repo-root", root], {
          cwd: repoRoot,
          encoding: "utf8",
        });
        expect(result.status).not.toBe(0);
        expect(result.stderr).toContain(`frame_commit expected=1 actual=${writes}`);
      } finally {
        rmSync(root, { recursive: true, force: true });
      }
    }
  });

  test("keeps one render-request authority and no obsolete scheduler", () => {
    const sources = zigSources(join(repoRoot, "src"));
    const obsoleteSymbols = [
      "force_footer_redraw",
      "pending_frame_invalidations",
      "ResizeCoordinator",
      "RenderHooks",
      "redrawNow",
      "checkResizeAndRedraw",
      "renderFrameIfAdmitted",
      "loopRenderFrame",
      "takePendingFrameInvalidations",
      "drainFrameInvalidation",
    ];

    for (const symbol of obsoleteSymbols) {
      const hits = sources
        .filter(({ source }) => source.includes(symbol))
        .map(({ path }) => path);
      expect(hits, symbol).toEqual([]);
    }

    expect(existsSync(join(repoRoot, "src", "ui", "input", "submission.zig"))).toBe(false);

    const flushFiles = sources
      .filter(({ source }) => source.includes("flushRequestedFrame("))
      .map(({ path }) => path);
    expect(flushFiles).toEqual([
      "src/core/app/app_render_runtime.zig",
      "src/main.zig",
    ]);

    const main = sources.find(({ path }) => path === "src/main.zig")!.source;
    expect(main.match(/RenderAppRuntime\.flushRequestedFrame\(self\)/g) ?? []).toHaveLength(1);

    const coordinator = sources.find(
      ({ path }) => path === "src/core/app/app_render_runtime.zig",
    )!.source;
    const productionCoordinator = coordinator.split('\ntest "')[0]!;
    expect(productionCoordinator.match(/flushRequestedFrame\(/g) ?? []).toHaveLength(1);
    expect(
      productionCoordinator.match(/attemptRequestedFrame\(app, snapshot\)/g) ?? [],
    ).toHaveLength(1);
  });
});
