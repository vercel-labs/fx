// Runs the real fx binary through every launch-flag scenario the
// LaunchSelection TLA+ model covers (tests/tla/cli/LaunchSelection.tla), then has TLC
// replay what fx did through the model. No model calls: a local fake Gateway
// serves the catalog and accepts only models that exist.
//
// 1. The binary must conform to exactly one modeled design, current or proposed.
// 2. Controls: tampered and empty evidence must not be accepted.
// 3. With FX_TLA_PROPOSED=1: the binary must conform to the proposed design.
//    This fails until fx validates launch flags.
import { test } from "bun:test";
import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts, binary, shellQuote, targetHelpers } from "../lib/context";
import { checkTrace, type Design, type Observation, type ObservedRequest, type TraceResult } from "./bridge";
import {
  AUTHENTICATED_CATALOG, CONFIGURED, PUBLIC_CATALOG, SCENARIOS, SUPPORTED_EFFORT, TRUTH,
  askRejection, flagArgs, nameClass, noticesIn, type Outcome, type Scenario,
} from "./scenarios";

const { startDynamicFakeGateway, fakeGatewayFinalText, TmuxSession } = await targetHelpers();
const reports = join(artifacts, "tlc");
mkdirSync(reports, { recursive: true });
const TIMEOUT = 900_000;
const DONE_WORD = "MFV_DONE_7";
const PROMPT = "Reply with the done word.";
const SLOW_CATALOG_MS = 4_000;

const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

async function waitUntil(condition: () => boolean, timeoutMs: number): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (condition()) return true;
    await sleep(50);
  }
  return condition();
}

interface Fixture {
  root: string; home: string; workspace: string;
  gateway: any;
  env: Record<string, string>;
  catalogRequests: Array<{ authorized: boolean; status: number }>;
  catalogServed: () => boolean;
  rejectedModels: string[];
}

function fixture(s: Scenario): Fixture {
  const root = join(artifacts, s.id);
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx/settings.json"), JSON.stringify({ auto_upgrade: false, model: CONFIGURED }));
  const catalogRequests: Fixture["catalogRequests"] = [];
  const rejectedModels: string[] = [];
  let served = false;
  let gateway: any;
  gateway = startDynamicFakeGateway(() => {
    const model = gateway.requests.at(-1)?.headers.get("ai-language-model-id") ?? "";
    if (!TRUTH.has(model)) {
      rejectedModels.push(model);
      return Response.json({ error: { type: "model_not_found", message: `Model '${model}' not found` } }, { status: 404 });
    }
    return fakeGatewayFinalText(DONE_WORD);
  }, {
    models: async (request: Request) => {
      const authorized = Boolean(request.headers.get("authorization"));
      let response: Response;
      if (s.catalog === "failed") {
        response = new Response("catalog unavailable", { status: 500 });
      } else if (s.catalog === "anonymous" && authorized) {
        response = Response.json({ error: { message: "unauthorized" } }, { status: 401 });
      } else {
        if (s.early) await sleep(SLOW_CATALOG_MS);
        response = Response.json({ data: s.catalog === "anonymous" ? PUBLIC_CATALOG : AUTHENTICATED_CATALOG });
      }
      catalogRequests.push({ authorized, status: response.status });
      if (response.status === 200 || s.catalog === "failed") served = true;
      return response;
    },
  });
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) if (value !== undefined && key !== "FX_MODEL") env[key] = value;
  Object.assign(env, {
    HOME: home, TMPDIR: root,
    AI_GATEWAY_API_KEY: "fake-mfv-key", FX_PROVIDER: "gateway",
    FX_GATEWAY_BASE_URL: gateway.baseUrl, FX_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_CHAT_URL: gateway.chatUrl,
    FX_TEST_GATEWAY_MODELS_URL: `${gateway.baseUrl}/coding-agent/v1/models`,
    FX_SOUND: "0", FX_AUTO_UPGRADE: "0", FX_DISABLE_KEYCHAIN: "1", FX_E2E_DISABLE_DOTENV: "1",
    // Kept with the scenario evidence so an unexpected outcome can be traced.
    FX_TRACE_LOG: join(root, "trace.log"), FX_TRACE_SCOPES: "agent,core,gateway,auth,session",
  });
  return { root, home, workspace, gateway, env, catalogRequests, catalogServed: () => served, rejectedModels };
}

function wireOf(s: Scenario, f: Fixture, indicator: ObservedRequest["indicator"]): ObservedRequest {
  const first = f.gateway.requests[0];
  if (!first) return { present: false, model: "none", indicator: "unobserved", wireFast: false, wireUltra: false, wireEffort: "none" };
  const sent = first.headers.get("ai-language-model-id") ?? "";
  let body: any = {};
  try { body = JSON.parse(first.body); } catch {}
  const reasoning = body.reasoning;
  return {
    present: true,
    model: nameClass(s, sent),
    indicator,
    wireFast: body.providerOptions?.gateway?.speed === "fast",
    wireUltra: body.providerOptions?.openai?.serviceTier === "ultrafast",
    wireEffort: reasoning === undefined ? "none" : reasoning === SUPPORTED_EFFORT ? "supported" : "other",
  };
}

function requestEvidence(f: Fixture) {
  const first = f.gateway.requests[0];
  let body: any = {};
  try { body = JSON.parse(first?.body ?? "{}"); } catch {}
  return {
    mainRequests: f.gateway.requests.length,
    sentModel: first?.headers.get("ai-language-model-id") ?? null,
    reasoning: body.reasoning ?? null,
    providerOptions: body.providerOptions ?? null,
    rejectedModels: f.rejectedModels,
    catalogRequests: f.catalogRequests,
  };
}

async function observeAsk(s: Scenario): Promise<Observation> {
  const f = fixture(s);
  try {
    const argv = ["ask", "--no-save", "--auto", ...flagArgs(s), PROMPT];
    const child = Bun.spawn([binary, ...argv], {
      cwd: f.workspace, env: f.env, stdin: "ignore", stdout: "pipe", stderr: "pipe",
    });
    const timer = setTimeout(() => child.kill(), 60_000);
    const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
    clearTimeout(timer);
    let outcome: Outcome = "unknown";
    const requests = f.gateway.requests.length;
    if (requests > 0) {
      if (f.rejectedModels.length > 0) outcome = "gateway_error";
      else if (code === 0 && stdout.includes(DONE_WORD)) outcome = "sent";
    } else {
      outcome = askRejection(stderr) ?? (code !== 0 ? "turn_error" : "unknown");
    }
    return {
      id: s.id, scenario: s, orderFree: false, outcome, notices: [], req: wireOf(s, f, "unobserved"),
      evidence: { argv, exitCode: code, stdout: stdout.slice(-2000), stderr: stderr.slice(-2000), ...requestEvidence(f) },
    };
  } finally {
    f.gateway.stop();
  }
}

function footerLine(pane: string): string {
  return pane.split("\n").map(line => line.trimEnd()).filter(Boolean).at(-1) ?? "";
}

async function observeInteractive(s: Scenario): Promise<Observation> {
  const f = fixture(s);
  const cmd = [binary, ...flagArgs(s)].map(shellQuote).join(" ");
  const session = await TmuxSession.create({ cmd, cwd: f.workspace, env: f.env, width: 140, height: 40, isolated: true, startupWaitMs: 300 });
  try {
    await session.waitForComposer(20_000);
    if (!s.early) {
      await waitUntil(f.catalogServed, 15_000);
      await sleep(1_500);
    }
    const footer = footerLine(await session.capturePane());
    const indicator = footer.includes("⚡") ? "on" : "off";
    const catalogSeenAtSubmit = f.catalogServed();
    await session.sendText(PROMPT);
    let outcome: Outcome = "unknown";
    const sentRequest = await waitUntil(() => f.gateway.requests.length > 0, s.early ? SLOW_CATALOG_MS + 10_000 : 10_000);
    if (sentRequest) {
      if (await waitUntil(() => f.rejectedModels.length > 0, 1_500)) {
        outcome = "gateway_error";
      } else {
        const done = await session.waitForText(DONE_WORD, 15_000).then(() => true, () => false);
        if (done) outcome = "sent";
      }
    } else {
      outcome = "turn_error";
    }
    if (s.early) {
      await waitUntil(f.catalogServed, 15_000);
      await sleep(2_000);
    } else {
      await sleep(500);
    }
    const scrollback = await session.captureFullScrollback();
    return {
      id: s.id, scenario: s, orderFree: s.early, outcome, notices: noticesIn(scrollback), req: wireOf(s, f, indicator),
      evidence: { cmd, footerAtSubmit: footer, catalogSeenAtSubmit, scrollbackTail: scrollback.split("\n").slice(-40).join("\n"), ...requestEvidence(f) },
    };
  } finally {
    await session.kill();
    f.gateway.stop();
  }
}

let observed: Promise<Observation[]> | undefined;
function observations(): Promise<Observation[]> {
  observed ??= (async () => {
    const out: Observation[] = [];
    for (const s of SCENARIOS) {
      const observation = s.path === "ask" ? await observeAsk(s) : await observeInteractive(s);
      console.log(`${s.kind.padEnd(8)} ${s.id.padEnd(34)} outcome=${observation.outcome} notices=[${observation.notices}] req=${JSON.stringify(observation.req)}`);
      out.push(observation);
    }
    writeFileSync(join(artifacts, "observations.json"), JSON.stringify(out, null, 2));
    return out;
  })();
  return observed;
}

const verdicts = new Map<Design, Promise<TraceResult>>();
function verdict(design: Design): Promise<TraceResult> {
  if (!verdicts.has(design)) {
    verdicts.set(design, observations().then(async list => {
      const result = await checkTrace(list, design, reports);
      writeFileSync(join(artifacts, `trace-${design}.json`), JSON.stringify(result, null, 2));
      console.log(`trace ${design}: ${result.verdict} ${result.firstMismatch ?? ""} ${result.detail}`);
      return result;
    }));
  }
  return verdicts.get(design)!;
}

test("real fx conforms to exactly one modeled design", async () => {
  const [current, proposed] = await Promise.all([verdict("current"), verdict("proposed")]);
  const accepted = [current, proposed].filter(result => result.verdict === "ACCEPTED").map(result => result.design);
  writeFileSync(join(artifacts, "summary.json"), JSON.stringify({ binary, conforms: accepted, current, proposed }, null, 2));
  assert.equal(accepted.length, 1, `expected exactly one conforming design, got [${accepted}]: current=${current.detail}; proposed=${proposed.detail}`);
}, TIMEOUT);

test("bridge rejects tampered and empty evidence", async () => {
  const list = await observations();
  const conforming = (await verdict("current")).verdict === "ACCEPTED" ? "current" : "proposed";
  const tampered = list.map(item => ({ ...item, req: { ...item.req } }));
  const target = tampered.find(item => item.req.present)!;
  target.req.wireFast = !target.req.wireFast;
  const result = await checkTrace(tampered, conforming, reports);
  assert.equal(result.verdict, "REJECTED", `tampered evidence for ${target.id} was ${result.verdict}`);
  assert.equal(result.firstMismatch, target.id);
  assert.equal((await checkTrace([], conforming, reports)).verdict, "TOOL_ERROR");
}, TIMEOUT);

test.skipIf(process.env.FX_TLA_PROPOSED !== "1")("real fx meets the proposed design", async () => {
  const proposed = await verdict("proposed");
  assert.equal(proposed.verdict, "ACCEPTED", proposed.detail);
  assert.equal((await verdict("current")).verdict, "REJECTED");
}, TIMEOUT);
