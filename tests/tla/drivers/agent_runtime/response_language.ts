// Runs the built fx binary along tests/tla/agent_runtime/ResponseLanguage.tla
// and has TLC check every turn it observes (ResponseLanguageTrace.tla).
//
// Each turn is one `fx ask` of a labeled prompt against a local fake gateway
// that serves a script of replies: English or Korean text, text too short to
// name its script, and tool calls with English or Korean text. The prompts
// cover plain English, English that names a language or has an accented name
// or a terse clause, and requests in Vietnamese, Indonesian, Malay, Spanish,
// and Chinese that quote English. Each prompt's labels say what the model
// needs to know about it (ResponseLanguage.tla, Prompts). The driver runs every
// script up to --depth replies for every prompt, then --random seeded longer
// ones. When fx asks for more replies than the script holds, the gateway
// serves English text, and that reply is part of what was observed.
//
// For each turn it records the replies served, what each request carried (the
// prompt, tool results, or the correction), which replies' text reached the
// output, and how the turn ended. TLC replays the turns through the model's
// own actions. --self-check also replays them through the model of fx before
// the fix of #809 (Rule = "today"), which must reject them.
//
// Usage (from the repository root, after zig build):
//   bun tests/tla/drivers/agent_runtime/response_language.ts
//   bun tests/tla/drivers/agent_runtime/response_language.ts --self-check
//   bun tests/tla/drivers/agent_runtime/response_language.ts --depth 1 --random 200 --seed 7 --jobs 8
//
// Exit codes: 0 every turn accepted (and the self-check rejected), 1 a turn the
// model cannot produce, 2 a toolchain, build, or harness failure.
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { binary, targetHelpers, testEnvironment } from "../lib/context";
import { TLA_ROOT, outDir, runTlc, writeJson } from "../lib/tlc";

type Kind = "latin" | "nonlatin" | "unclear" | "tool_latin" | "tool_nonlatin";
type Reply = { script: "latin" | "nonlatin" | "unclear"; tools: boolean };
type Carry = "prompt" | "tools" | "correction" | "unknown";
type KeptPart = "prose" | "calls_only" | "dropped";
type Outcome = "answered" | "failed_language" | "unknown";
type Labels = {
  lang: "english" | "other";
  script: "latin" | "nonlatin" | "none";
  word: boolean;
  switch: boolean;
  accent: boolean;
  bare: boolean;
};
type Prompt = { text: string; labels: Labels };
type Observation = {
  id: string;
  prompt: Prompt;
  replies: Reply[];
  sent: Carry[];
  kept: KeptPart[];
  outcome: Outcome;
  evidence: { exit: number; output: string; tail: string; seconds: number };
};
type Verdict = "ACCEPTED" | "REJECTED" | "TOOL_ERROR";

const KINDS: Kind[] = ["latin", "nonlatin", "unclear", "tool_latin", "tool_nonlatin"];
const MODEL = "openai/gpt-5.5";
// The correction fx adds after it drops a reply (src/core/agent/runtime/orchestrator.zig).
const CORRECTION = "The previous candidate used a different language";
const CONTROL = "<response_language_control>";
// The notice fx prints when it ends a turn for its language.
const FAILURE = "The model response used a different language than your request";
const tlaDir = join(TLA_ROOT, "agent_runtime");

const english = (text: string, labels: Partial<Labels> = {}): Prompt => ({
  text,
  labels: { lang: "english", script: "latin", word: true, switch: false, accent: false, bare: false, ...labels },
});
const other = (text: string, labels: Partial<Labels>): Prompt => ({
  text,
  labels: { lang: "other", script: "latin", word: true, switch: false, accent: false, bare: false, ...labels },
});

const PROMPTS: Prompt[] = [
  english("The lockfile is broken again. Say what you will inspect next."),
  english("Please read notes.txt and explain the result."),
  english("Why does `zig build test` fail on this branch?"),
  english("Translate the following into Korean. The lockfile is broken again.", { switch: true }),
  english("Ask José to review the lockfile.", { accent: true }),
  english("Run zig build. Then tell me why the lockfile is broken.", { bare: true }),
  english("Fix lockfile parsing.", { word: false, bare: true }),
  other("Dịch nội dung sau sang tiếng Hàn. The lockfile is broken again.", { accent: true, bare: true }),
  other("Dịch sang Korean: The lockfile is broken again.", { accent: true, switch: true }),
  other("Terjemahkan ke bahasa Korea. The lockfile is broken again.", { bare: true }),
  other("Terjemahkan ke bahasa Korea\n\nThe lockfile is broken again and the build fails when you run it.", { bare: true }),
  other("The lockfile is broken again. Sila terjemahkan ayat ini ke bahasa Korea.", { bare: true }),
  other("Traduce esto al coreano. The lockfile is broken again.", { bare: true }),
  other("请把下面的内容翻译成韩语。The lockfile is broken again.", { script: "nonlatin" }),
];

// Each reply's text is distinct, so the output shows which replies fx kept.
const KOREAN = [
  "잠금 파일이 다시 손상되었습니다.",
  "의존성 목록을 먼저 확인하겠습니다.",
  "빌드 설정을 다시 검토하겠습니다.",
  "마지막 커밋의 변경 사항을 살펴보겠습니다.",
  "테스트 결과를 정리해서 알려드리겠습니다.",
  "캐시를 지우고 다시 시도하겠습니다.",
  "설정 파일의 권한을 확인하겠습니다.",
  "로그를 모아서 원인을 찾겠습니다.",
];
const prose = (kind: Kind, n: number): string => {
  switch (kind) {
    case "latin":
    case "tool_latin":
      return `Answer ${n} says the lockfile parser is fine.`;
    case "nonlatin":
    case "tool_nonlatin":
      return KOREAN[(n - 1) % KOREAN.length]!;
    case "unclear":
      return `OK ${n}.`;
  }
};
const replyOf = (kind: Kind): Reply => ({
  script: kind === "latin" || kind === "tool_latin" ? "latin" : kind === "unclear" ? "unclear" : "nonlatin",
  tools: kind.startsWith("tool_"),
});

function option(name: string, fallback: number): number {
  const at = process.argv.indexOf(name);
  if (at < 0) return fallback;
  const value = Number(process.argv[at + 1]);
  if (!Number.isInteger(value) || value < 0) throw new Error(`${name} takes a whole number`);
  return value;
}

const options = {
  selfCheck: process.argv.includes("--self-check"),
  depth: option("--depth", 2),
  random: option("--random", 40),
  seed: option("--seed", 1),
  jobs: option("--jobs", 8),
};

// mulberry32: a small seeded generator, so a failing random script replays.
function generator(seed: number) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function cases(): Array<{ prompt: Prompt; script: Kind[] }> {
  const result: Array<{ prompt: Prompt; script: Kind[] }> = [];
  const grow = (prefix: Kind[]) => {
    if (prefix.length > 0) for (const prompt of PROMPTS) result.push({ prompt, script: prefix });
    if (prefix.length === options.depth) return;
    for (const kind of KINDS) grow([...prefix, kind]);
  };
  grow([]);
  const next = generator(options.seed);
  for (let i = 0; i < options.random; i++) {
    const length = 3 + Math.floor(next() * 3);
    const script = Array.from({ length }, () => KINDS[Math.floor(next() * KINDS.length)]!);
    result.push({ prompt: PROMPTS[Math.floor(next() * PROMPTS.length)]!, script });
  }
  return result;
}

async function runTurn(helpers: any, id: string, prompt: Prompt, script: Kind[], scratch: string): Promise<Observation> {
  const { fakeGatewaySse } = helpers;
  const served: Kind[] = [];
  const respond = (kind: Kind, n: number): Response => {
    const text = { type: "text-delta", id: `t${n}`, delta: prose(kind, n) };
    if (kind.startsWith("tool_")) {
      return fakeGatewaySse([
        text,
        { type: "tool-call", toolCallId: `call_${n}`, toolName: "glob_files", input: { pattern: "*" } },
        { type: "finish", finishReason: { unified: "tool-calls", raw: "tool_calls" } },
      ]);
    }
    return fakeGatewaySse([text, { type: "finish", finishReason: { unified: "stop", raw: "stop" } }]);
  };
  const gateway = helpers.startDynamicFakeGateway(() => {
    const kind: Kind = script[served.length] ?? "latin";
    served.push(kind);
    return respond(kind, served.length);
  }, { models: [{ id: MODEL, type: "language", tags: ["tool-use"] }] });
  // The real path: fx reads its profile through it, and /tmp is a link on macOS.
  const root = realpathSync(mkdtempSync(join(scratch, `${id}-`)));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}", { mode: 0o600 });
  writeFileSync(join(workspace, "notes.txt"), "fixture\n");
  try {
    const started = performance.now();
    const child = Bun.spawn([binary, "ask", "--json", "--auto", "--no-save", prompt.text], {
      cwd: workspace,
      env: testEnvironment({
        HOME: home,
        FX_HOME: join(home, ".fx"),
        AI_GATEWAY_API_KEY: "fake-response-language-driver-key",
        FX_GATEWAY_BASE_URL: gateway.baseUrl,
        FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
        FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
        FX_MODEL: MODEL,
      }),
      stdin: "ignore",
      stdout: "pipe",
      stderr: "pipe",
    });
    const timer = setTimeout(() => child.kill(9), 60_000);
    const [stdout, stderr, exit] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    clearTimeout(timer);
    const seconds = Number(((performance.now() - started) / 1000).toFixed(2));
    let output = "";
    try {
      output = String(JSON.parse(stdout.trim()).output ?? "");
    } catch {
      output = "";
    }
    let corrected = false;
    const sent: Carry[] = gateway.requests.map((request: { body: string }, index: number) => {
      if (index === 0) return request.body.includes(CORRECTION) ? "unknown" : "prompt";
      if (request.body.includes(CORRECTION) && !corrected) {
        corrected = true;
        return "correction";
      }
      // After the correction, fx repeats it as the last user message of
      // every request in the turn; the message before it says what the
      // request carries.
      const messages = JSON.parse(request.body).prompt as Array<{ role: string; content: unknown }>;
      const carried = messages.filter((message) =>
        !(message.role === "user" && JSON.stringify(message.content).includes(CONTROL))
      );
      return carried.at(-1)?.role === "tool" ? "tools" : "unknown";
    });
    const kept: KeptPart[] = served.map((kind, index) =>
      output.includes(prose(kind, index + 1)) ? "prose" : kind.startsWith("tool_") ? "calls_only" : "dropped"
    );
    let outcome: Outcome = "unknown";
    if (exit === 0) outcome = "answered";
    else if (exit === 1 && stderr.includes(FAILURE)) outcome = "failed_language";
    return {
      id,
      prompt,
      replies: served.map(replyOf),
      sent,
      kept,
      outcome,
      evidence: { exit, output: output.slice(0, 400), tail: `${stdout}\n${stderr}`.slice(-400), seconds },
    };
  } finally {
    gateway.stop();
    rmSync(root, { recursive: true, force: true });
  }
}

const str = (value: string) => JSON.stringify(value);
const seq = (values: string[]) => `<<${values.map(str).join(", ")}>>`;
const bool = (value: boolean) => (value ? "TRUE" : "FALSE");

function observedModule(observations: Observation[]): string {
  const labels = (l: Labels) =>
    `[lang |-> ${str(l.lang)}, script |-> ${str(l.script)}, word |-> ${bool(l.word)}, ` +
    `switch |-> ${bool(l.switch)}, accent |-> ${bool(l.accent)}, bare |-> ${bool(l.bare)}]`;
  const replies = (rs: Reply[]) =>
    `<<${rs.map((r) => `[script |-> ${str(r.script)}, tools |-> ${bool(r.tools)}]`).join(", ")}>>`;
  const value = (o: Observation) =>
    `[prompt |-> ${labels(o.prompt.labels)}, replies |-> ${replies(o.replies)}, ` +
    `sent |-> ${seq(o.sent)}, kept |-> ${seq(o.kept)}, outcome |-> ${str(o.outcome)}]`;
  return [
    "----------------------- MODULE ResponseLanguageObserved -----------------------",
    "(* Generated by tests/tla/drivers/agent_runtime/response_language.ts. Do not edit. *)",
    "EXTENDS Sequences",
    `Observed == << ${observations.map(value).join(",\n  ")} >>`,
    "=============================================================================",
    "",
  ].join("\n");
}

async function runTrace(observations: Observation[], rule: string, parent: string): Promise<{ verdict: Verdict; dir: string }> {
  const dir = mkdtempSync(join(parent, `trace-${rule}-`));
  writeFileSync(join(dir, "ResponseLanguageObserved.tla"), observedModule(observations));
  writeFileSync(join(dir, "trace.cfg"), [
    "SPECIFICATION TraceSpec",
    "CONSTANTS",
    `  Rule = ${str(rule)}`,
    '  Bug = "none"',
    "  MaxRequests = 1000",
    "  AllowUnmarked = FALSE",
    "INVARIANT NotAllMatched",
    "CHECK_DEADLOCK FALSE",
    "",
  ].join("\n"));
  const run = await runTlc(dir, "ResponseLanguageTrace.tla", "trace.cfg",
    ["ResponseLanguage.tla", "ResponseLanguageTrace.tla"], tlaDir);
  if (run.exitCode === 12 && run.violated === "NotAllMatched") return { verdict: "ACCEPTED", dir };
  if (run.exitCode === 0 && run.output.includes("Model checking completed. No error has been found.")) {
    return { verdict: "REJECTED", dir };
  }
  return { verdict: "TOOL_ERROR", dir };
}

// The first observation the model cannot produce: the shortest rejected prefix.
async function firstMismatch(observations: Observation[], rule: string, parent: string): Promise<Observation | null> {
  let low = 1;
  let high = observations.length;
  while (low < high) {
    const middle = Math.floor((low + high) / 2);
    const { verdict } = await runTrace(observations.slice(0, middle), rule, parent);
    if (verdict === "TOOL_ERROR") return null;
    if (verdict === "ACCEPTED") low = middle + 1;
    else high = middle;
  }
  return observations[low - 1] ?? null;
}

async function main(): Promise<number> {
  const helpers = await targetHelpers();
  const out = outDir("response_language");
  const scratch = join(out, "turns");
  mkdirSync(scratch, { recursive: true });
  const all = cases();
  const observations: Observation[] = new Array(all.length);
  const started = performance.now();
  let next = 0;
  // A turn that fails before the gateway serves any reply, such as a local
  // connection dropped under load, says nothing about the guard. It runs
  // again, at most twice, and is reported.
  const harnessRetries: string[] = [];
  const workers = Array.from({ length: Math.max(1, options.jobs) }, async () => {
    while (next < all.length) {
      const index = next++;
      const { prompt, script } = all[index]!;
      let observation = await runTurn(helpers, `turn${index}`, prompt, script, scratch);
      for (let attempt = 1; attempt < 3 && observation.replies.length === 0; attempt++) {
        harnessRetries.push(`turn${index}: ${observation.evidence.tail.replace(/\s+/g, " ").slice(-200)}`);
        observation = await runTurn(helpers, `turn${index}`, prompt, script, scratch);
      }
      observations[index] = observation;
    }
  });
  await Promise.all(workers);
  for (const retry of harnessRetries) console.log(`harness retry (no reply served): ${retry}`);
  const unreached = observations.find((o) => o.replies.length === 0);
  if (unreached) {
    console.log(`TOOL_ERROR: turn ${unreached.id} never reached the gateway: ${JSON.stringify(unreached.evidence)}`);
    return 2;
  }
  const seconds = ((performance.now() - started) / 1000).toFixed(1);
  writeJson(join(out, "observations.json"), observations);
  const counts: Record<string, number> = {};
  for (const o of observations) {
    const key = `${o.prompt.labels.lang}:${o.outcome}:${o.sent.includes("correction") ? "corrected" : "direct"}`;
    counts[key] = (counts[key] ?? 0) + 1;
  }
  console.log(`${observations.length} turns of ${binary} in ${seconds}s, ${JSON.stringify(counts)}`);
  console.log(`observations: ${join(out, "observations.json")}`);

  const unknown = observations.find((o) => o.outcome === "unknown" || o.sent.includes("unknown"));
  if (unknown) {
    console.log(`REJECTED: turn ${unknown.id} ended in a way the driver cannot read: ${JSON.stringify(unknown)}`);
    return 1;
  }

  const design = await runTrace(observations, "fixed", out);
  console.log(`design: ${design.verdict} (TLC work ${design.dir})`);
  if (design.verdict === "TOOL_ERROR") return 2;
  if (design.verdict === "REJECTED") {
    const mismatch = await firstMismatch(observations, "fixed", out);
    console.log(`first turn the model cannot produce: ${JSON.stringify(mismatch)}`);
    return 1;
  }
  if (options.selfCheck) {
    const today = await runTrace(observations, "today", out);
    console.log(`self-check, the model of fx before the fix of #809: ${today.verdict} (must be REJECTED)`);
    if (today.verdict !== "REJECTED") return today.verdict === "TOOL_ERROR" ? 2 : 1;
  }
  console.log("ACCEPTED");
  return 0;
}

try {
  process.exit(await main());
} catch (error) {
  console.error(error);
  process.exit(2);
}
