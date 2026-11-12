// Plants each bug below in the quiet relay's code, one at a time, rebuilds
// fx, and runs the relay's focused tests: the unit tests of the changed
// files, the fx ask E2E tests, and the agent list's tmux test. A bug the
// tests miss fails the run. The clean code must pass every command first,
// and every file is restored after each bug, whatever happens.
//
// The unit tests run through a test step this script adds to build.zig for
// the run and removes after it: `zig build test` also runs the session
// manager's tests, whose file mode checks fail when the tests run as root,
// so it could not tell a caught bug from a sandbox.
//
//   bun tests/tla/drivers/subagent/quiet-relay-mutants.ts
//   bun tests/tla/drivers/subagent/quiet-relay-mutants.ts closed-not-checked   runs one bug
//   bun tests/tla/drivers/subagent/quiet-relay-mutants.ts --clean              runs the tests on the clean code only
//   bun tests/tla/drivers/subagent/quiet-relay-mutants.ts --plant <name>       runs the tests with one bug in place: exits 1 when they catch it
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { REPO_ROOT } from "../lib/tlc";

type Mutant = { name: string; file: string; from: string; to: string };

const mutants: Mutant[] = [
  {
    name: "shell-relays-every-notice",
    file: "src/tools/shell/shell.zig",
    from: "if (!snapshot.quiet_crossed or ctx.tool_result_memory_sink == null) return;",
    to: "if (!snapshot.quiet_notice or ctx.tool_result_memory_sink == null) return;",
  },
  {
    name: "wait-never-crosses",
    file: "src/core/execution/managed_execution.zig",
    from: "prepared.snapshot.quiet_crossed = prepared.snapshot.quiet_notice;",
    to: "prepared.snapshot.quiet_crossed = false;",
  },
  {
    name: "memory-drops-crossing",
    file: "src/core/agent/runtime/execution_memory.zig",
    from: "    prepared.quiet_crossing = source_memory.quiet_crossing;\n",
    to: "",
  },
  {
    name: "adapter-no-relay",
    file: "src/core/subagent/agent_adapter.zig",
    from: "context.config.host.noteChildQuiet(child_id, context.turn.child_name orelse child_id, crossing);",
    to: "if (false) context.config.host.noteChildQuiet(child_id, context.turn.child_name orelse child_id, crossing);",
  },
  {
    name: "hosted-no-relay",
    file: "src/core/app/app_agents_runtime.zig",
    from: "host.noteChildQuiet(child.id, child.displayName(), crossing);",
    to: "if (false) host.noteChildQuiet(child.id, child.displayName(), crossing);",
  },
  {
    name: "closed-not-checked",
    file: "src/core/subagent/tool_host.zig",
    from: "if (!self.childOpen(child_id)) return",
    to: "if (false and !self.childOpen(child_id)) return",
  },
  {
    name: "status-no-call",
    file: "src/core/subagent/tool_host.zig",
    from: "if (self.isBusyLocked(child.id)) for (calls) |entry| {",
    to: "if (false) for (calls) |entry| {",
  },
  {
    name: "call-never-ends",
    file: "src/core/subagent/live_metrics.zig",
    from: "if (self.call.active and std.mem.eql(u8, self.call.id(), id)) self.call = .{};",
    to: "if (false and self.call.active and std.mem.eql(u8, self.call.id(), id)) self.call = .{};",
  },
  {
    name: "label-past-its-bound",
    file: "src/core/subagent/live_metrics.zig",
    from: "head, max_label_bytes - ellipsis.len)",
    to: "head, max_label_bytes)",
  },
  {
    name: "label-shows-secrets",
    file: "src/core/subagent/live_metrics.zig",
    from: "const masked = text_utils.maskSecrets(alloc, searched) catch return storeFallback(out);",
    to: "const masked = searched;",
  },
  {
    name: "row-hides-call",
    file: "src/ui/footer/agents_menu_presentation.zig",
    from: "    if (row.activity.len > 0) return row.activity;\n",
    to: "",
  },
];

const unitFilters = [
  "call label",
  "masks secrets",
  "a call's label stays one line",
  "a call ends only itself",
  "durations read",
  "the quiet note names",
  "a quiet note for a child",
  "only a running result that ended",
  "working subagent's row",
  "dupeToolResultMemory",
  "command sidebands merge",
];

const commands: Array<{ name: string; argv: string[]; cwd: string }> = [
  { name: "unit", argv: ["zig", "build", "quiet-relay-unit", ...unitFilters.map((f) => `-Dquiet-relay-filter=${f}`)], cwd: REPO_ROOT },
  { name: "fx ask E2E", argv: ["bun", "test", "./gateway-stream-lifecycle.test.ts", "-t", "quiet subagent command wakes|relayed again"], cwd: join(REPO_ROOT, "tests", "e2e") },
  { name: "agent list tmux", argv: ["bun", "test", "./tui-host-switch.test.ts", "-t", "row names its current call"], cwd: join(REPO_ROOT, "tests", "e2e") },
];

const buildFile = join(REPO_ROOT, "build.zig");
const buildAnchor = "    const run_exe_tests = b.addRunArtifact(exe_tests);\n";
const unitStep = [
  "    const quiet_relay_tests = b.addTest(.{",
  "        .root_module = exe.root_module,",
  "        .filters = b.option([]const []const u8, \"quiet-relay-filter\", \"\") orelse &.{},",
  "    });",
  "    b.step(\"quiet-relay-unit\", \"\").dependOn(&b.addRunArtifact(quiet_relay_tests).step);",
  "",
].join("\n");

async function run(argv: string[], cwd: string): Promise<{ code: number; tail: string }> {
  const proc = Bun.spawn(argv, { cwd, env: { ...process.env, FX_SOUND: "0" }, stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, code] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
  return { code, tail: `${stdout}\n${stderr}`.split("\n").slice(-12).join("\n") };
}

/** Builds fx and runs every command, stopping at the first that fails. */
async function suite(): Promise<{ built: boolean; failed: string | null; tail: string }> {
  const build = await run(["zig", "build"], REPO_ROOT);
  if (build.code !== 0) return { built: false, failed: null, tail: build.tail };
  for (const command of commands) {
    const result = await run(command.argv, command.cwd);
    if (result.code !== 0) return { built: true, failed: command.name, tail: result.tail };
  }
  return { built: true, failed: null, tail: "" };
}

const plant = process.argv[2] === "--plant" ? process.argv[3] : undefined;
const only = plant ?? process.argv[2];
const cleanOnly = only === "--clean";
const selected = cleanOnly ? [] : only ? mutants.filter((m) => m.name === only) : mutants;
if (!cleanOnly && selected.length === 0) throw new Error(`no planted bug named ${only}`);

const originalBuild = readFileSync(buildFile, "utf8");
if (!originalBuild.includes(buildAnchor)) throw new Error("build.zig changed: its exe test run is not where this script adds its step");
writeFileSync(buildFile, originalBuild.replace(buildAnchor, buildAnchor + unitStep));
let survived = 0;
let cleanFails = false;
try {
  const clean = await suite();
  cleanFails = !clean.built || clean.failed !== null;
  if (cleanFails) console.error(`the clean code fails ${clean.failed ?? "to build"}:\n${clean.tail}`);
  else console.log("clean: every command passes");
  for (const mutant of cleanFails ? [] : selected) {
    const path = join(REPO_ROOT, mutant.file);
    const source = readFileSync(path, "utf8");
    if (source.split(mutant.from).length !== 2) throw new Error(`${mutant.name}: its text is not in ${mutant.file} exactly once`);
    writeFileSync(path, source.replace(mutant.from, mutant.to));
    try {
      const result = await suite();
      if (!result.built) console.log(`not viable  ${mutant.name}: does not build\n${result.tail}`);
      else if (result.failed) console.log(`caught      ${mutant.name}: by ${result.failed}`);
      else {
        survived += 1;
        console.log(`SURVIVED    ${mutant.name}`);
      }
    } finally {
      writeFileSync(path, source);
    }
  }
} finally {
  writeFileSync(buildFile, originalBuild);
}
// Exits only after the finally above has put build.zig back.
if (cleanFails) process.exit(2);
console.log(`${selected.length - survived} of ${selected.length} planted bugs caught`);
// With --plant, the tests failing on the planted bug is the expected result.
if (plant !== undefined) process.exit(survived === 0 ? 1 : 0);
process.exit(survived === 0 ? 0 : 1);
