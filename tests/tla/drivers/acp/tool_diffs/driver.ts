// Runtime driver: runs the real `fx acp` binary through plans of file edits
// (a new file then an edit, two edits of one file in one step, an approved
// and a denied edit, and a write over the diff limit). It records what the
// client reads for each edit call, its permission request and its last
// update, checks each diff's text against the files on disk, and asks TLC
// whether each run is a behavior of tests/tla/acp/AcpToolDiffs.tla.
//
//   bun tests/tla/drivers/acp/tool_diffs/driver.ts                 # after zig build
//   bun tests/tla/drivers/acp/tool_diffs/driver.ts --model today   # fx acp before tool diffs
//
// --model rules (the default) checks the tool diffs rules. --model today
// checks the model of fx acp before them; a build of #2032, chosen with
// FX_WORKTREE or FX_BIN, fails --model rules. --only takes a pattern of plan
// names. No model calls: every reply comes from a fake Gateway.
import { existsSync } from "node:fs";
import { join } from "node:path";
import { binary, worktree } from "../../lib/context";
import { Fixture, type ToolCall } from "./harness";
import { outDir, sha256File, sha256Text, tlcToolchain, writeJson } from "./tlc";
import { type Observation, type Setup, validate } from "./trace";

type Plan = {
  name: string;
  mode: "full-access" | "ask";
  files: Record<string, string>;
  steps: ToolCall[][];
  /// How the client answers each permission request, in order.
  answers?: Array<"allow_once" | "reject_once">;
  /// The files whose calls are over the diff limit.
  big?: string[];
};

const BIG = "x".repeat((1 << 20) + 16);

const PLANS: Plan[] = [
  {
    name: "write-then-edit",
    mode: "full-access",
    files: {},
    steps: [
      [{ tool: "write_file", input: { path: "new.txt", content: "one\n" } }],
      [{ tool: "edit_file", input: { path: "new.txt", old_string: "one", new_string: "two" } }],
    ],
  },
  {
    name: "same-file-one-step",
    mode: "full-access",
    files: { "a.txt": "x1 y1\n" },
    steps: [[
      { tool: "edit_file", input: { path: "a.txt", old_string: "x1", new_string: "x2" } },
      { tool: "edit_file", input: { path: "a.txt", old_string: "y1", new_string: "y2" } },
    ]],
  },
  {
    name: "ask-approve-deny",
    mode: "ask",
    files: { "a.txt": "keep\n" },
    steps: [
      [{ tool: "edit_file", input: { path: "a.txt", old_string: "keep", new_string: "kept" } }],
      [{ tool: "write_file", input: { path: "b.txt", content: "denied\n" } }],
    ],
    answers: ["allow_once", "reject_once"],
  },
  {
    name: "big-write",
    mode: "full-access",
    files: {},
    steps: [[{ tool: "write_file", input: { path: "big.txt", content: BIG } }]],
    big: ["big.txt"],
  },
];

async function runPlan(plan: Plan) {
  const fixture = new Fixture(plan.files, plan.mode);
  const observations: Observation[] = [];
  const problems: string[] = [];
  let error: string | null = null;
  let process: { exit: number; stderr: string } | null = null;
  // Each file's texts as versions: its first text, or 0 if absent, then
  // each new text a diff showed.
  const versions = new Map<string, Map<string, number>>();
  let nextVersion = 1;
  const versionOf = (file: string, text: string | null) => {
    if (text === null) return 0;
    const known = versions.get(file) ?? new Map<string, number>();
    versions.set(file, known);
    if (!known.has(text)) known.set(text, nextVersion++);
    return known.get(text)!;
  };
  const initVer: Record<string, number> = {};
  for (const step of plan.steps) for (const call of step) {
    const file = call.input.path!;
    if (!(file in initVer)) initVer[file] = versionOf(file, plan.files[file] ?? null);
  }
  const callIds: string[] = [];
  const fileOf: string[] = [];
  const asked = new Set<number>();
  const lastNew = new Map<string, string>();
  try {
    let answerIndex = 0;
    const client = await fixture.start(plan.steps, () => plan.answers?.[answerIndex++] ?? "allow_once");
    const created = await client.request("session/new", { cwd: fixture.workspace, mcpServers: [] });
    if (created.error) throw new Error(`session/new failed: ${JSON.stringify(created.error)}`);
    const answer = await client.request("session/prompt", { sessionId: created.result.sessionId, prompt: [{ type: "text", text: "Make the edits." }] });
    if (answer.error || answer.result?.stopReason !== "end_turn") throw new Error(`prompt failed: ${JSON.stringify(answer)}`);
    const callNumber = (id: string, rawInput?: any) => {
      let index = callIds.indexOf(id);
      if (index === -1) {
        callIds.push(id);
        index = callIds.length - 1;
        const path = String(rawInput?.path ?? "");
        fileOf.push(path.includes("/") ? path.slice(path.lastIndexOf("/") + 1) : path);
      }
      return index + 1;
    };
    const diffOf = (content: any[] | undefined, c: number, committed: boolean): [number, number] | null => {
      const diff = content?.find((block) => block.type === "diff");
      if (!diff) return null;
      const file = fileOf[c - 1]!;
      if (!String(diff.path).endsWith(`/${file}`)) problems.push(`call ${c}: diff path ${diff.path} is not ${file}`);
      if (committed) lastNew.set(file, diff.newText);
      return [versionOf(file, diff.oldText), versionOf(file, diff.newText)];
    };
    for (const message of client.inbox) {
      const update = message.params?.update;
      if (message.method === "session/update" && update?.sessionUpdate === "tool_call") callNumber(update.toolCallId, update.rawInput);
      else if (message.method === "session/request_permission") {
        const toolCall = message.params.toolCall;
        const c = callNumber(toolCall.toolCallId, toolCall.rawInput);
        asked.add(c);
        observations.push({ c, status: "permission", content: Array.isArray(toolCall.content), diff: diffOf(toolCall.content, c, false) });
      } else if (message.method === "session/update" && update?.sessionUpdate === "tool_call_update" && (update.status === "completed" || update.status === "failed")) {
        const c = callNumber(update.toolCallId);
        observations.push({ c, status: update.status, content: Array.isArray(update.content), diff: update.status === "completed" ? diffOf(update.content, c, true) : null });
        if (update.status === "failed" && update.content?.some((block: any) => block.type === "diff")) problems.push(`call ${c}: a failed update shows a diff`);
      }
    }
    // Every diff a run showed ends where the file on disk ends.
    for (const [file, text] of lastNew) if (fixture.read(file) !== text) problems.push(`${file}: on disk it isn't the last diff's new text`);
    process = await client.close();
  } catch (err) {
    error = err instanceof Error ? err.message : String(err);
  } finally {
    fixture.dispose();
  }
  const used = new Set<number>([...versions.values()].flatMap((known) => [...known.values()]));
  const firsts = new Set(Object.values(initVer));
  const vs = [...used].filter((v) => !firsts.has(v));
  // Spare versions for the edits that showed no diff.
  for (let k = 0; k < callIds.length; k++) vs.push(nextVersion + k);
  const big = callIds.map((_, index) => index + 1).filter((c) => plan.big?.includes(fileOf[c - 1]!));
  const setup: Setup = { fileOf, ask: [...asked], big, initVer, vs };
  return { observations, setup, problems, error, process };
}

/// A run the model must not allow: the first diff's old text is the file
/// after the edit, as if fx read the file once the edit had landed.
function tamper(observations: Observation[]): Observation[] | null {
  const at = observations.findIndex((o) => o.status === "completed" && o.diff);
  if (at === -1) return null;
  const copy = observations.map((o) => ({ ...o, diff: o.diff ? [...o.diff] as [number, number] : null }));
  copy[at]!.diff = [copy[at]!.diff![1], copy[at]!.diff![1]];
  return copy;
}

function argValue(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  return index === -1 ? undefined : process.argv[index + 1];
}

function git(...args: string[]): string {
  const result = Bun.spawnSync(["git", "-C", worktree, ...args], { stdout: "pipe", stderr: "pipe" });
  return new TextDecoder().decode(result.stdout).trim();
}

async function main() {
  if (!existsSync(binary)) throw new Error(`missing ${binary}; run zig build first or set FX_BIN`);
  const model = argValue("--model") ?? "rules";
  if (model !== "rules" && model !== "today") throw new Error(`--model must be rules or today, not ${model}`);
  const rules = model === "rules";
  const only = argValue("--only");
  const reportDir = outDir(`acp-tool-diffs-${model}`);
  const status = git("status", "--porcelain");
  const manifest = {
    model, worktree, binary, head: git("rev-parse", "HEAD"), dirty: status.length > 0,
    diff_sha256: status ? sha256Text(git("diff", "HEAD")) : null, fx_binary_sha256: sha256File(binary),
    toolchain: tlcToolchain(), bun: Bun.version, argv: process.argv.slice(1),
  };
  writeJson(join(reportDir, "manifest.json"), manifest);

  const results = [];
  let tamperSource: { observations: Observation[]; setup: Setup } | null = null;
  for (const plan of PLANS.filter((p) => !only || new RegExp(only).test(p.name))) {
    const dir = join(reportDir, "traces", plan.name);
    const run = await runPlan(plan);
    writeJson(join(dir, "observations.json"), { observations: run.observations, setup: run.setup, problems: run.problems });
    const processFailed = run.process !== null && (run.process.exit !== 0 || run.process.stderr !== "");
    const checked = run.error ? null : await validate(run.observations, dir, rules, run.setup);
    const verdict = run.error ? "RUN_ERROR" : processFailed ? "PROCESS_ERROR" : run.problems.length > 0 && rules ? "DISK_MISMATCH" : checked!.verdict;
    if (verdict === "ACCEPTED" && !tamperSource && tamper(run.observations)) tamperSource = { observations: run.observations, setup: run.setup };
    results.push({ name: plan.name, verdict, observations: run.observations.length, problems: run.problems, error: run.error });
    console.log(`${plan.name}: ${verdict} (${run.observations.length} observations)${run.error ? ` ${run.error}` : ""}${run.problems.length ? ` ${run.problems.join("; ")}` : ""}`);
  }

  const controls = [];
  controls.push({ name: "empty-trace", expect: "TOOL_ERROR", got: (await validate([], join(reportDir, "controls", "empty-trace"), rules, { fileOf: [], ask: [], big: [], initVer: {}, vs: [] })).verdict });
  if (tamperSource) {
    controls.push({ name: "tampered-stale-old", expect: "REJECTED", got: (await validate(tamper(tamperSource.observations)!, join(reportDir, "controls", "tampered"), rules, tamperSource.setup)).verdict });
  }
  for (const control of controls) console.log(`control ${control.name}: ${control.got} (expected ${control.expect})`);
  const counts = results.reduce<Record<string, number>>((acc, result) => ({ ...acc, [result.verdict]: (acc[result.verdict] ?? 0) + 1 }), {});
  const controlsPassed = controls.length === 2 && controls.every((control) => control.got === control.expect);
  writeJson(join(reportDir, "summary.json"), { manifest, counts, controlsPassed, controls, results });
  console.log(`verdicts: ${JSON.stringify(counts)}; controls ${controlsPassed ? "pass" : "FAIL"}`);
  console.log(`report: ${reportDir}`);
  if (!controlsPassed || results.some((result) => result.verdict !== "ACCEPTED")) process.exit(1);
}

await main();
