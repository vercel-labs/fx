// Capture real shell output and its RTK request view without calling a model.
// FX_E2E_DISABLE_DOTENV=1 bun test benchmarks/rtk.test.ts > /tmp/rtk-corpus.jsonl
import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdirSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { cleanupIsolatedTestHome, createIsolatedTestHome, REPO_ROOT, runFx } from "../tests/evals/eval-helpers";
import { savedSession, savedToolResults } from "../tests/e2e/saved-sessions";
import { FAKE_GATEWAY_MODEL, fakeGatewayFinalText, fakeShellRun, startFakeGateway } from "../tests/e2e/tmux-helpers";

function toolPart(request: any) {
  return request.prompt.flatMap((message: any) => Array.isArray(message.content) ? message.content : [])
    .find((part: any) => part.type === "tool-result" && part.toolCallId === "rtk-benchmark");
}

function gitWorkspace(workspace: string, modified: number, untracked: number) {
  const git = (...args: string[]) => execFileSync("git", args, {
    cwd: workspace, env: { ...process.env, LC_ALL: "C" }, stdio: "pipe",
  });
  git("init", "-q", "--initial-branch=benchmark");
  for (let index = 0; index < Math.max(20, modified); index++) writeFileSync(join(workspace, `module-${index}.txt`), "original\n");
  git("add", ".");
  git("-c", "user.name=Example", "-c", "user.email=example@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture");
  for (let index = 0; index < modified; index++) writeFileSync(join(workspace, `module-${index}.txt`), "changed\n");
  for (let index = 0; index < untracked; index++) writeFileSync(join(workspace, `new-${index}.txt`), "untracked\n");
}

type Workload = {
  name: string;
  command: string;
  reduces: boolean;
  git?: [number, number];
  passes?: number;
  failure?: boolean;
  truncated?: boolean;
};

const workloads: Workload[] = [
  { name: "Bun CI shard tests", command: "bun test tests/e2e/ci-shards.test.ts", reduces: true },
  { name: "Bun configured-provider tests", command: "bun test tests/e2e/configured-providers.test.ts", reduces: true },
  { name: "Bun combined project suites", command: "bun test tests/e2e/ci-shards.test.ts tests/e2e/configured-providers.test.ts", reduces: true },
  { name: "Zig reducer tests", command: "zig test src/core/tooling/rtk.zig -O ReleaseSafe", reduces: true },
  { name: "Zig recovery tests", command: "zig test src/core/recovery/recovery.zig -O ReleaseSafe", reduces: true },
  { name: "Zig MCP auth tests", command: "zig test src/mcp/mcp.zig -O ReleaseSafe -lc --test-filter auth", reduces: true },
  { name: "Zig MCP HTTP tests", command: "zig test src/mcp/mcp.zig -O ReleaseSafe -lc --test-filter io.http", reduces: true },
  { name: "Zig MCP core subset", command: "zig test src/mcp/mcp.zig -O ReleaseSafe -lc --test-filter core", reduces: true },
  { name: "Zig MCP protocol subset", command: "zig test src/mcp/mcp.zig -O ReleaseSafe -lc --test-filter protocol", reduces: true },
  { name: "Git status, 5 modified + 10 untracked", command: "git status", git: [5, 10], reduces: true },
  { name: "Git status, 50 modified + 100 untracked", command: "git status", git: [50, 100], reduces: true },
  { name: "Git status, 500 modified + 500 untracked, clipped", command: "git status", git: [500, 500], truncated: true, reduces: false },
  { name: "Git status, clean control", command: "git status", git: [0, 0], reduces: false },
  { name: "Git short status, unsupported control", command: "git status --short", git: [50, 100], reduces: false },
  { name: "Bun generated scale: 200 passing tests", command: "bun test cases.test.ts", passes: 200, reduces: true },
  { name: "Bun generated scale: 1000 pass, clipped", command: "bun test cases.test.ts", passes: 1000, truncated: true, reduces: false },
  { name: "Bun failure control: 200 pass, 1 fail", command: "bun test cases.test.ts", passes: 200, failure: true, reduces: false },
  { name: "Bun truncated-output control: 3000 pass", command: "bun test cases.test.ts", passes: 3000, truncated: true, reduces: false },
];

test.each(workloads)("capture RTK benchmark: $name", async (workload) => {
  const home = createIsolatedTestHome();
  const workspace = join(home, "workspace");
  mkdirSync(workspace);
  mkdirSync(join(home, ".fx"), { recursive: true });
  writeFileSync(join(home, ".fx/settings.json"), JSON.stringify({
    rtk: true, session_titles: false, context: false,
    permission: { bash: { [workload.command]: "allow" } },
  }));
  const gateway = startFakeGateway([
    fakeShellRun("rtk-benchmark", workload.command),
    fakeGatewayFinalText("Benchmark complete."),
  ]);
  try {
    if (workload.git) {
      gitWorkspace(workspace, ...workload.git);
    } else {
      for (const name of ["src", "tests"]) symlinkSync(join(REPO_ROOT, name), join(workspace, name), "dir");
    }
    if (workload.passes) writeFileSync(join(workspace, "cases.test.ts"), `
      import { expect, test } from "bun:test";
      for (let index = 0; index < ${workload.passes}; index++) {
        test(\`JSON round-trip case \${index}\`, () => {
          const value = { index, text: \`value-\${index}\` };
          expect(JSON.parse(JSON.stringify(value))).toEqual(value);
        });
      }
      ${workload.failure ? 'test("intentional failure control", () => expect(1).toBe(2));' : ""}
    `);
    // Warm compilation without executing tests. A cold compiler can exceed
    // shell.run's yield limit and turn this into a running-process benchmark.
    if (workload.command.startsWith("zig test ")) execFileSync("zig", [
      ...workload.command.split(" ").slice(1), "--test-no-exec",
    ], { cwd: workspace, stdio: "pipe", timeout: 120_000 });
    const result = await runFx(["ask", "--json", "--auto", "Run the benchmark command once."], {
      cwd: workspace,
      env: {
        HOME: home, AI_GATEWAY_API_KEY: "benchmark-key", VERCEL_OIDC_TOKEN: undefined,
        FX_MODEL: FAKE_GATEWAY_MODEL, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_AUTO_UPGRADE: "0", FX_SOUND: "0", FX_DISABLE_KEYCHAIN: "1", LC_ALL: "C",
      },
      timeoutMs: 90_000,
    });
    expect(result.code, result.stderr).toBe(0);
    expect(gateway.requests).toHaveLength(2);
    const session = await savedSession(home, JSON.parse(result.stdout).session_id);
    const original = savedToolResults(session.history).find((value) => value.tool_call_id === "rtk-benchmark");
    expect(original).toBeDefined();
    const raw = JSON.parse(original.output);
    expect(raw.exit_code).toBe(workload.failure ? 1 : 0);
    expect(raw.output_truncated === true).toBe(workload.truncated === true);
    const after = JSON.parse(gateway.requests[1]!.body);
    const part = toolPart(after);
    const reduced = typeof part.output.value === "string" ? JSON.parse(part.output.value) : part.output.value;
    expect(reduced.output_delta.includes("[rtk:")).toBe(workload.reduces);
    // Compare one execution against itself, including the same metadata and
    // prompt. Only the output view changes; timings and handles cannot skew it.
    expect({ ...reduced, output_delta: raw.output_delta }).toEqual(raw);
    const before = structuredClone(after);
    toolPart(before).output.value = typeof part.output.value === "string" ? original.output : raw;
    console.log(JSON.stringify({
      name: workload.name, command: workload.command, expected_cases: workloads.length,
      exit_code: raw.exit_code, output_truncated: raw.output_truncated === true,
      output: { before: raw.output_delta, after: reduced.output_delta },
      request: {
        before: JSON.stringify({ prompt: before.prompt, tools: before.tools }),
        after: JSON.stringify({ prompt: after.prompt, tools: after.tools }),
      },
    }));
  } finally {
    gateway.stop();
    cleanupIsolatedTestHome(home);
  }
}, 180_000);
