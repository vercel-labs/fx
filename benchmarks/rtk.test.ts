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

function gitWorkspace(workspace: string, dirty: boolean) {
  const git = (...args: string[]) => execFileSync("git", args, {
    cwd: workspace, env: { ...process.env, LC_ALL: "C" }, stdio: "pipe",
  });
  git("init", "-q", "--initial-branch=benchmark");
  for (let index = 0; index < 20; index++) writeFileSync(join(workspace, `module-${index}.txt`), "original\n");
  git("add", ".");
  git("-c", "user.name=Example", "-c", "user.email=example@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture");
  if (dirty) {
    for (let index = 0; index < 5; index++) writeFileSync(join(workspace, `module-${index}.txt`), "changed\n");
    for (let index = 0; index < 10; index++) writeFileSync(join(workspace, `new-${index}.txt`), "untracked\n");
  }
}

const workloads = [
  { name: "Bun CI shard tests", command: "bun test tests/e2e/ci-shards.test.ts", reduces: true },
  { name: "Zig reducer tests", command: "zig test src/core/tooling/rtk.zig -O ReleaseSafe", reduces: true },
  { name: "Git status, dirty", command: "git status", git: "dirty", reduces: true },
  { name: "Git status, clean control", command: "git status", git: "clean", reduces: false },
  { name: "Git short status, unsupported control", command: "git status --short", git: "dirty", reduces: false },
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
      gitWorkspace(workspace, workload.git === "dirty");
    } else {
      for (const name of ["src", "tests"]) symlinkSync(join(REPO_ROOT, name), join(workspace, name), "dir");
    }
    const result = await runFx(["ask", "--json", "--auto", "Run the benchmark command once."], {
      cwd: workspace,
      env: {
        HOME: home, AI_GATEWAY_API_KEY: "benchmark-key", VERCEL_OIDC_TOKEN: undefined,
        FX_MODEL: FAKE_GATEWAY_MODEL, FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_AUTO_UPGRADE: "0", FX_SOUND: "0", FX_DISABLE_KEYCHAIN: "1", LC_ALL: "C",
      },
      timeoutMs: 60_000,
    });
    expect(result.code, result.stderr).toBe(0);
    expect(gateway.requests).toHaveLength(2);
    const session = await savedSession(home, JSON.parse(result.stdout).session_id);
    const original = savedToolResults(session.history).find((value) => value.tool_call_id === "rtk-benchmark");
    expect(original).toBeDefined();
    const raw = JSON.parse(original.output);
    expect(raw.exit_code).toBe(0);
    expect(raw.output_truncated).not.toBe(true);
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
      name: workload.name, command: workload.command,
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
}, 90_000);
