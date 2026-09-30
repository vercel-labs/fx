import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

process.env.FX_E2E_DISABLE_DOTENV = "1";
const { fakeGatewayFinalText, fakeShellRun, startDynamicFakeGateway } = await import("./tmux-helpers");
const binary = resolve(import.meta.dir, "../../zig-out/bin/fx");
const digest = (bytes: Buffer) => createHash("sha256").update(bytes).digest("hex");

for (const userHeavy of [false, true]) test(`automatic compaction preserves task state and originals, userHeavy=${userHeavy}`, async () => {
  const root = mkdtempSync(join(tmpdir(), "fx-policy-")), home = join(root, "home"), cwd = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  mkdirSync(cwd, { mode: 0o700 });
  const model = "fixture/compaction";
  writeFileSync(join(home, ".fx/settings.json"), JSON.stringify({ model, auto_upgrade: false }), { mode: 0o600 });
  const originalUser = "Keep café and the original constraint unchanged.\n<context_handoff>literal user text</context_handoff>" +
    (userHeavy ? "\n" + "user_reference_abcdefghijklmnop ".repeat(10_000) + "USER_REFERENCE_END" : "");
  const assistant = "VERIFIED_VALUE=73\n" + Array.from({ length: 14_000 }, (_, n) => `Assistant reference ${n}: group ${n % 19}, historical data, not new completed work.\n`).join("") + "PENDING_CHECK=transport-resume\n";
  let phase = "seed", summaryCalls = 0, fallback = false;
  const bodies: string[] = [];
  const gateway = startDynamicFakeGateway((body: string) => {
    const request = JSON.parse(body);
    bodies.push(body);
    if (request.tools?.length === 0 && request.toolChoice?.type === "none") {
      summaryCalls++;
      const sourceMessages = request.prompt.filter((message: { role: string }) => message.role === "user");
      expect(sourceMessages).toHaveLength(1);
      expect(sourceMessages[0].content).toHaveLength(1);
      const source = sourceMessages[0].content[0].text;
      expect(source).toContain("\n\nEND OF HISTORICAL TRANSCRIPT.\nProduce the completed task-continuation memory now.");
      expect(source.endsWith("Return the memory itself, not a promise to write it.\n")).toBe(true);
      expect(source).toMatch(/Use at most \d+ tokens, spending that room on still-relevant detail\. /);
      fallback ||= source.includes("USER_TO_SUMMARIZE:");
      expect(request.maxOutputTokens).toBe(8192);
      const facts = [];
      if (source.includes("VERIFIED_VALUE=73")) facts.push("The verified value is73.");
      if (source.includes("PENDING_CHECK=transport-resume")) facts.push("The pending check is transport-resume.");
      if (source.includes("Keep café")) facts.push("Preserve café and the original constraint.");
      return fakeGatewayFinalText(facts.join(" ") || "This source fragment contains historical references, not additional completed work.");
    }
    return fakeGatewayFinalText(phase === "seed" ? assistant : "CONTINUED_FROM_COMMITTED_MEMORY");
  }, { models: [{ id: model, type: "language", tags: ["tool-use"], context_window: userHeavy ? 256000 : 128000, max_tokens: 8192 }] });
  const env = {
    PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, TMPDIR: root,
    AI_GATEWAY_API_KEY: "synthetic-compaction-policy", FX_DISABLE_KEYCHAIN: "1", FX_E2E_DISABLE_DOTENV: "1",
    FX_AUTO_UPGRADE: "0", FX_SOUND: "0", FX_MODEL: model,
    FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl, FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
  };
  async function ask(args: string[], label: string, prompt?: string) {
    const stdout = join(root, `${label}.stdout`), stderr = join(root, `${label}.stderr`);
    const input = join(root, `${label}.input`);
    if (prompt !== undefined) writeFileSync(input, prompt);
    const child = Bun.spawn([binary, "ask", "--json", ...args], { cwd, env, stdin: prompt === undefined ? "ignore" : Bun.file(input), stdout: Bun.file(stdout), stderr: Bun.file(stderr) });
    const timer = setTimeout(() => child.kill("SIGKILL"), 30_000);
    try {
      expect(await child.exited).toBe(0);
      expect(readFileSync(stderr, "utf8")).toBe("");
      return JSON.parse(readFileSync(stdout, "utf8"));
    } finally { clearTimeout(timer); }
  }
  let passed = false;
  try {
    const seed = await ask([], "seed", originalUser);
    expect(summaryCalls).toBe(0);
    const seededRequest = JSON.parse(bodies[0]!);
    const seededUser = seededRequest.prompt.findLast((message: { role: string }) => message.role === "user");
    expect(seededUser.content[0].text).toBe(originalUser);
    const sessionDir = join(home, ".fx/sessions", seed.session_id), log = join(sessionDir, "events.jsonl"), before = readFileSync(log);
    phase = "continue";
    const result = await ask(["--resume-id", seed.session_id, "Continue the saved task without losing its pending check."], "continue");
    expect(result.output).toBe("CONTINUED_FROM_COMMITTED_MEMORY");
    expect(summaryCalls).toBeGreaterThan(0);
    expect(fallback).toBe(userHeavy);
    const rows = readFileSync(log, "utf8").trim().split("\n").map(line => JSON.parse(line));
    const checkpoints = rows.filter(row => row.event?.context_checkpoint);
    expect(checkpoints.length).toBe(1);
    const handoff = checkpoints[0].event.context_checkpoint.summary;
    const match = /> fx-compaction-state-v1 (\S+) (\d+) ([a-f0-9]{64})\n/.exec(handoff);
    expect(match).not.toBeNull();
    const bytes = readFileSync(join(sessionDir, "tool-results", match![1]));
    expect(bytes.length).toBe(Number(match![2])); expect(digest(bytes)).toBe(match![3]);
    const state = JSON.parse(bytes.toString());
    expect(state.users.includes(originalUser)).toBe(!userHeavy);
    // An oversized user message becomes a placeholder whose saved original reads back exactly.
    const stubs: { artifact: { handle: string; bytes: number; sha256: string } }[] = state.stubs ?? [];
    expect(stubs).toHaveLength(userHeavy ? 1 : 0);
    for (const stub of stubs) {
      const saved = readFileSync(join(sessionDir, "tool-results", stub.artifact.handle));
      expect(saved.length).toBe(stub.artifact.bytes); expect(digest(saved)).toBe(stub.artifact.sha256);
      expect(saved.toString()).toBe(originalUser);
      expect(handoff).toContain(`full text saved as ${stub.artifact.handle}; key facts are in the summary]`);
    }
    expect(state.summary).toContain("verified value is73");
    expect(state.summary).toContain("transport-resume");
    for (const archive of state.archives) {
      const original = readFileSync(join(sessionDir, "tool-results", archive.handle));
      expect(original.length).toBe(archive.bytes); expect(digest(original)).toBe(archive.sha256);
    }
    const reopened = await ask(["--resume-id", seed.session_id, "Continue after this fresh process restart."], "reopen");
    expect(reopened.output).toBe("CONTINUED_FROM_COMMITTED_MEMORY");
    expect(bodies.at(-1)).toContain("verified value is73");
    expect(readFileSync(log).subarray(0, before.length).equals(before)).toBe(true);
    passed = true;
  } finally {
    gateway.stop();
    if (passed) rmSync(root, { recursive: true, force: true });
    else { writeFileSync(join(root, "requests.json"), JSON.stringify(bodies, null, 2)); console.error(`compaction evidence retained: ${root}`); }
  }
}, 90_000);

for (const shortenedFits of [true, false]) test(`automatic compaction fits an overlong summary from the summary alone, shortenedFits=${shortenedFits}`, async () => {
  const root = mkdtempSync(join(tmpdir(), "fx-policy-fit-")), home = join(root, "home"), cwd = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  mkdirSync(cwd, { mode: 0o700 });
  const model = "fixture/compaction";
  writeFileSync(join(home, ".fx/settings.json"), JSON.stringify({ model, auto_upgrade: false }), { mode: 0o600 });
  const assistant = Array.from({ length: 14_000 }, (_, n) => `Assistant reference ${n}: group ${n % 19}, historical data, not new completed work.\n`).join("");
  const rules = "Standing rules and constraints:\n- Keep the release region at ap-south-9.\n";
  const remaining = "Work remaining:\n- Continue the saved task.";
  const overlong = rules + "Work done:\n" + "- repeated historical detail\n".repeat(2_000) + remaining;
  // A rewrite that still misses the target must be trimmed, never regenerated from the source.
  const shortened = rules + "Work done:\n" + (shortenedFits ? "- Read the historical references.\n" : "- still too much detail\n".repeat(1_500)) + remaining;
  let phase = "seed";
  const summaries: string[] = [], shortenings: string[] = [], bodies: string[] = [];
  const gateway = startDynamicFakeGateway((body: string) => {
    const request = JSON.parse(body);
    bodies.push(body);
    if (request.tools?.length === 0 && request.toolChoice?.type === "none") {
      const system = request.prompt.filter((message: { role: string }) => message.role === "system").map((message: { content: unknown }) => JSON.stringify(message.content)).join("\n");
      const input = request.prompt.findLast((message: { role: string }) => message.role === "user").content[0].text;
      if (system.includes("shortening task-continuation memory")) {
        shortenings.push(input);
        return fakeGatewayFinalText(shortened);
      }
      summaries.push(input);
      return fakeGatewayFinalText(overlong);
    }
    return fakeGatewayFinalText(phase === "seed" ? assistant : "CONTINUED_FROM_COMMITTED_MEMORY");
  }, { models: [{ id: model, type: "language", tags: ["tool-use"], context_window: 128000, max_tokens: 8192 }] });
  const env = {
    PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, TMPDIR: root,
    AI_GATEWAY_API_KEY: "synthetic-compaction-policy", FX_DISABLE_KEYCHAIN: "1", FX_E2E_DISABLE_DOTENV: "1",
    FX_AUTO_UPGRADE: "0", FX_SOUND: "0", FX_MODEL: model,
    FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl, FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
  };
  async function ask(args: string[], label: string) {
    const stdout = join(root, `${label}.stdout`), stderr = join(root, `${label}.stderr`);
    const child = Bun.spawn([binary, "ask", "--json", ...args], { cwd, env, stdin: "ignore", stdout: Bun.file(stdout), stderr: Bun.file(stderr) });
    const timer = setTimeout(() => child.kill("SIGKILL"), 30_000);
    try {
      expect(await child.exited).toBe(0);
      expect(readFileSync(stderr, "utf8")).toBe("");
      return JSON.parse(readFileSync(stdout, "utf8"));
    } finally { clearTimeout(timer); }
  }
  let passed = false;
  try {
    const seed = await ask(["Keep the release region at ap-south-9 for every deploy."], "seed");
    phase = "continue";
    const result = await ask(["--resume-id", seed.session_id, "Continue the saved task."], "continue");
    expect(result.output).toBe("CONTINUED_FROM_COMMITTED_MEMORY");
    // The large source is summarized in chunks that split one target; one rewrite follows.
    const chunks = summaries.length;
    expect(chunks).toBeGreaterThan(0);
    expect(shortenings).toHaveLength(1);
    const chunkTargets = summaries.map(input => Number(/Use at most (\d+) tokens, spending that room/.exec(input)?.[1]));
    const shortening = shortenings[0]!;
    expect(shortening.startsWith("DERIVED_MEMORY_TO_SHORTEN")).toBe(true);
    const target = Number(/Rewrite this memory to at most (\d+) tokens/.exec(shortening)?.[1]);
    for (const chunkTarget of chunkTargets) expect(chunkTarget).toBe(Math.floor(target / chunks));
    expect(shortening).toContain(overlong);
    expect(shortening).not.toContain("Assistant reference");
    expect(shortening).not.toContain("USER_RETAINED:");
    expect(shortening.length).toBeLessThan(chunks * (overlong.length + 2) + 512);
    const sessionDir = join(home, ".fx/sessions", seed.session_id);
    const rows = readFileSync(join(sessionDir, "events.jsonl"), "utf8").trim().split("\n").map(line => JSON.parse(line));
    const checkpoints = rows.filter(row => row.event?.context_checkpoint);
    expect(checkpoints.length).toBe(1);
    const handoff: string = checkpoints[0].event.context_checkpoint.summary;
    const match = /> fx-compaction-state-v1 (\S+) (\d+) ([a-f0-9]{64})\n/.exec(handoff);
    const state = JSON.parse(readFileSync(join(sessionDir, "tool-results", match![1]!)).toString());
    if (shortenedFits) {
      expect(state.summary).toBe(shortened);
    } else {
      expect(state.summary.startsWith(rules + "Work done:\n")).toBe(true);
      expect(state.summary).toMatch(/\n\[trimmed \d+ lines here to fit the handoff budget\]\n/);
      expect(state.summary.endsWith(remaining)).toBe(true);
    }
    expect(bodies.at(-1)).toContain("Keep the release region at ap-south-9.");
    passed = true;
  } finally {
    gateway.stop();
    if (passed) rmSync(root, { recursive: true, force: true });
    else { writeFileSync(join(root, "requests.json"), JSON.stringify(bodies, null, 2)); console.error(`compaction evidence retained: ${root}`); }
  }
}, 90_000);

test("mid-turn compaction saves a large current prompt and re-sends it once", async () => {
  const root = mkdtempSync(join(tmpdir(), "fx-policy-midturn-")), home = join(root, "home"), cwd = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  mkdirSync(cwd, { mode: 0o700 });
  const model = "fixture/compaction";
  writeFileSync(join(home, ".fx/settings.json"), JSON.stringify({ model, auto_upgrade: false }), { mode: 0o600 });
  for (let file = 1; file <= 3; file++) {
    writeFileSync(join(cwd, `big-${file}.txt`), Array.from({ length: 700 }, (_, n) => `file${file} row ${n}: ${"x".repeat(40)} value=${(n * 7919 + file) % 100000}\n`).join(""));
  }
  // About 48.7 KB, the pasted build log that failed on a 200K window.
  const logEnd = "PASTE-END digest=LOGDIGEST-4417";
  const prompt = "Here is the failing build log. Investigate it using the big-*.txt files, then report.\n\nPASTE-START\n" +
    Array.from({ length: 750 }, (_, n) => `2026-09-25T10:${String(n % 60).padStart(2, "0")}:00Z build step ${n} ok checksum=${digest(Buffer.from(String(n))).slice(0, 16)}\n`).join("") +
    logEnd + "\n";
  let phase = "seed", step = 0, summaryCalls = 0;
  const requests: { phase: string; summary: boolean; body: any }[] = [];
  const messageText = (message: { content: string | { text?: string }[] }) =>
    typeof message.content === "string" ? message.content : message.content.map(part => part.text ?? "").join("");
  const gateway = startDynamicFakeGateway((body: string) => {
    const request = JSON.parse(body);
    const system = request.prompt.filter((message: { role: string }) => message.role === "system").map((message: { content: unknown }) => JSON.stringify(message.content)).join("\n");
    const toolless = request.tools?.length === 0 && request.toolChoice?.type === "none";
    const summary = toolless && system.includes("task-continuation memory");
    requests.push({ phase, summary, body: request });
    if (summary) {
      summaryCalls++;
      return fakeGatewayFinalText("Standing rules and constraints:\n- The release region is ap-south-9.\nKey facts:\n- The build log ends with LOGDIGEST-4417.\nWork remaining:\n- Report on the build log.");
    }
    if (toolless) return fakeGatewayFinalText("ok");
    if (phase === "seed") return fakeGatewayFinalText("ACK");
    // Keep reading large files in the same turn until compaction runs, then finish it.
    if (summaryCalls === 0 && step < 60) {
      step++;
      return fakeShellRun(`read_${step}`, `/bin/cat big-${(step % 3) + 1}.txt`);
    }
    return fakeGatewayFinalText("PASTE_TURN_DONE");
  }, { models: [{ id: model, type: "language", tags: ["tool-use"], context_window: 200000, max_tokens: 8192 }] });
  const env = {
    PATH: process.env.PATH ?? "/usr/bin:/bin", HOME: home, TMPDIR: root,
    AI_GATEWAY_API_KEY: "synthetic-compaction-policy", FX_DISABLE_KEYCHAIN: "1", FX_E2E_DISABLE_DOTENV: "1",
    FX_AUTO_UPGRADE: "0", FX_SOUND: "0", FX_MODEL: model,
    FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_E2E_GATEWAY_CHAT_URL: gateway.chatUrl, FX_E2E_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
  };
  async function ask(args: string[], label: string) {
    const stdout = join(root, `${label}.stdout`), stderr = join(root, `${label}.stderr`);
    // Tool turns echo command output on stderr, so success is the exit code and JSON result.
    const child = Bun.spawn([binary, "ask", "--json", "--full-access", ...args], { cwd, env, stdin: "ignore", stdout: Bun.file(stdout), stderr: Bun.file(stderr) });
    const timer = setTimeout(() => child.kill("SIGKILL"), 60_000);
    try {
      const code = await child.exited;
      const result = JSON.parse(readFileSync(stdout, "utf8"));
      expect({ label, code, error: result.error ?? null }).toEqual({ label, code: 0, error: null });
      return result;
    } finally { clearTimeout(timer); }
  }
  let passed = false;
  try {
    const seed = await ask(["Remember: the release region is ap-south-9. Reply ACK."], "seed");
    phase = "paste";
    const result = await ask(["--resume-id", seed.session_id, prompt], "paste");
    expect(result.output).toBe("PASTE_TURN_DONE");
    expect(step).toBeGreaterThan(0);
    expect(summaryCalls).toBeGreaterThan(0);
    const summarySource = requests.filter(request => request.summary).flatMap(request => request.body.prompt.map(messageText)).join("\n");
    expect(summarySource).toContain("USER_TO_SUMMARIZE:");
    expect(summarySource).toContain(logEnd);

    const sessionDir = join(home, ".fx/sessions", seed.session_id);
    const rows = readFileSync(join(sessionDir, "events.jsonl"), "utf8").trim().split("\n").map(line => JSON.parse(line));
    const checkpoints = rows.filter(row => row.event?.context_checkpoint);
    expect(checkpoints.length).toBe(1);
    const handoff: string = checkpoints[0].event.context_checkpoint.summary;
    expect(handoff).not.toContain(logEnd);
    const match = /> fx-compaction-state-v1 (\S+) (\d+) ([a-f0-9]{64})\n/.exec(handoff);
    const state = JSON.parse(readFileSync(join(sessionDir, "tool-results", match![1]!)).toString());
    const stubs: { position: number; artifact: { handle: string; bytes: number; sha256: string } }[] = state.stubs ?? [];
    expect(stubs).toHaveLength(1);
    const saved = readFileSync(join(sessionDir, "tool-results", stubs[0]!.artifact.handle));
    expect(saved.length).toBe(stubs[0]!.artifact.bytes); expect(digest(saved)).toBe(stubs[0]!.artifact.sha256);
    expect(saved.toString()).toBe(prompt);
    expect(handoff).toContain(`[user ${stubs[0]!.position} pasted `);
    expect(handoff).toContain(`full text saved as ${stubs[0]!.artifact.handle}; key facts are in the summary]`);

    // The rebuilt request carries the handoff and the verbatim prompt exactly once.
    const post = requests.filter(request => request.phase === "paste" && !request.summary).at(-1)!.body;
    const texts: string[] = post.prompt.map(messageText);
    expect(texts.some(text => text.includes(`full text saved as ${stubs[0]!.artifact.handle}`))).toBe(true);
    expect(texts.filter(text => text === prompt)).toHaveLength(1);
    expect(texts.join("\n").split(logEnd).length - 1).toBe(1);
    passed = true;
  } finally {
    gateway.stop();
    if (passed) rmSync(root, { recursive: true, force: true });
    else { writeFileSync(join(root, "requests.json"), JSON.stringify(requests.map(request => ({ phase: request.phase, summary: request.summary })), null, 2)); console.error(`compaction evidence retained: ${root}`); }
  }
}, 120_000);
