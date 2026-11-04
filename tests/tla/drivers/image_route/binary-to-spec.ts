// Binary to spec: drives the built fx binary through `fx ask` turns against a
// fake gateway, records what each turn did, and has TLC check every turn
// against ImageRoute (BinaryImageRoute.tla).
//
// The harness checks src/core/images/image_route.zig alone. This stage
// checks the shell around it through the real binary: the request flags the
// orchestrator computes from the session, the projections that attach or
// withhold images, the vision tool, and the notices. A flag computed from
// the wrong source, such as counting an earlier turn's image as one attached
// now, passes every core check and fails here.
//
// Each session is one saved fx session with its own HOME, and each turn is
// one `fx ask` process that sees one catalog view: listed with vision,
// listed without it, missing the model, or down (its host refuses
// connections, as an unreachable gateway does). The matrix runs every view
// with and without an image attached now, after a turn that left an image
// in the history and after none. The random sessions, seeded so a failure
// replays, mix views and attachments over several turns.
//
// Run alone: bun binary-to-spec.ts [--bin PATH] [--seed N] [--sessions N]
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { join } from "node:path";
import { binary, testEnvironment } from "../lib/context.ts";
import { REPO_ROOT, outDir } from "../lib/tlc.ts";
import { checkTlc, seededRandom, specFiles, toTla, type CheckedTlc, type Request as RouteRequest, type View } from "./lib.ts";

const MODEL = "moonshotai/kimi-k3";
// The vision tool's model, listed so the fallback route can finish a turn.
const VISION_MODEL = "google/gemini-2.5-flash";
const IMAGE = join(REPO_ROOT, "tests", "e2e", "fixtures", "placeholder-logo.png");

// What the binary prints, matched by stable prefixes of its own text.
const UNKNOWN_NOTE = "was not sent with this request: fx could not confirm image input support";
const DEAD_END_NOTE = "was not sent with this request: this model does not accept inline images";
const CATALOG_DOWN_NOTICE = "aren't reaching the model right now";

export type ViewName = "vision" | "no_vision" | "missing" | "down";
export const VIEW_NAMES: ViewName[] = ["vision", "no_vision", "missing", "down"];
const VIEWS: Record<ViewName, View> = {
  vision: { kind: "listed", vision: true, file_input: false },
  no_vision: { kind: "listed", vision: false, file_input: false },
  missing: { kind: "missing", vision: false, file_input: false },
  down: { kind: "down", vision: false, file_input: false },
};

export type Turn = { view: ViewName; attach: boolean };
export type Seen = {
  kind: string;
  reason: string;
  notified: boolean;
  inline_now: boolean;
  inline_earlier: boolean;
  vision_tool: boolean;
  vision_required: boolean;
  references: boolean;
  earlier_note: string;
};
export type Observation = { session: string; turn: number; view: View; req: RouteRequest; seen: Seen; exit: number; error: string | null };

function sseText(text: string) {
  return sse([{ type: "text-delta", id: "answer", delta: text }], "stop");
}

function sse(parts: object[], finish: string) {
  return new Response(
    [
      ...parts.map((part) => `data: ${JSON.stringify(part)}\n\n`),
      `data: ${JSON.stringify({ type: "finish", finishReason: { unified: finish, raw: finish }, usage: { inputTokens: { total: 1 }, outputTokens: { total: 1 } } })}\n\n`,
      "data: [DONE]\n\n",
    ].join(""),
    { headers: { "content-type": "text/event-stream" } },
  );
}

/// One fake gateway per session. The catalog answers with the current
/// turn's view; model requests are recorded per turn and answered so every
/// route can finish: a required vision call is made with the ids the request
/// offers, its evidence request gets evidence for them, and anything else
/// gets plain text.
class FakeGateway {
  view: ViewName = "vision";
  requests: string[] = [];
  private visionIds: number[] = [];
  private server: ReturnType<typeof Bun.serve>;

  constructor() {
    this.server = Bun.serve({ port: 0, fetch: (req) => this.answer(req) });
  }

  get base() { return `http://127.0.0.1:${this.server.port}`; }
  get chatUrl() { return `${this.base}/v4/ai/language-model`; }
  stop() { this.server.stop(true); }

  private catalog(): Response {
    const listed = (id: string, tags: string[]) => ({ id, type: "language", tags });
    const vision = listed(VISION_MODEL, ["vision", "tool-use"]);
    switch (this.view) {
      case "vision": return Response.json({ data: [listed(MODEL, ["vision", "tool-use"]), vision] });
      case "no_vision": return Response.json({ data: [listed(MODEL, ["tool-use"]), vision] });
      case "missing": return Response.json({ data: [vision] });
      case "down": return new Response("down", { status: 503 });
    }
  }

  private async answer(req: Request): Promise<Response> {
    if (new URL(req.url).pathname.endsWith("/v1/models")) return this.catalog();
    if (req.method !== "POST") return new Response("not found", { status: 404 });
    const body = await req.text();
    if (body.includes("Generate a short title")) return sseText("Image route session");
    if (body.includes("fx_vision_evidence")) {
      const images = this.visionIds.map((image_id) => ({ image_id, status: "ok", summary: `image ${image_id}`, visible_text: [], details: [] }));
      return sseText(JSON.stringify({ images }));
    }
    this.requests.push(body);
    if (body.includes('"toolChoice":{"type":"required"}') && body.includes('"name":"vision"')) {
      const offered = /<available_images>([\s\S]*?)<\/available_images>/.exec(body)?.[1] ?? "";
      this.visionIds = [...offered.matchAll(/\[Image #(\d+)\]/g)].map((match) => Number(match[1]));
      const input = { image_ids: this.visionIds, focus: "describe the image" };
      return sse([{ type: "tool-call", toolCallId: `vision_${this.requests.length}`, toolName: "vision", input }], "tool-calls");
    }
    return sseText("OK");
  }
}

/// An address nothing listens on, so connecting is refused at once.
async function refusedBase(): Promise<string> {
  return await new Promise((resolve) => {
    const socket = createServer();
    socket.listen(0, "127.0.0.1", () => {
      const port = (socket.address() as { port: number }).port;
      socket.close(() => resolve(`http://127.0.0.1:${port}`));
    });
  });
}

async function runSession(bin: string, dir: string, name: string, turns: Turn[], refused: string): Promise<Observation[]> {
  const root = mkdtempSync(join(dir, "session-"));
  const home = join(root, "home");
  const workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true });
  mkdirSync(workspace, { recursive: true });
  writeFileSync(join(home, ".fx", "settings.json"), "{}");
  const gateway = new FakeGateway();
  const observations: Observation[] = [];
  let sessionId = "";
  // Images earlier turns left in the session's history, by their base64.
  const earlier: string[] = [];
  try {
    for (const [index, turn] of turns.entries()) {
      gateway.view = turn.view;
      gateway.requests = [];
      let imageData = "";
      const args = ["ask", "--json", "--auto", "--no-color"];
      if (sessionId) args.push("--resume", sessionId);
      if (turn.attach) {
        // A distinct image per turn, so a request body shows which ones it carries.
        const path = join(workspace, `turn-${index + 1}.png`);
        copyFileSync(IMAGE, path);
        writeFileSync(path, Buffer.concat([readFileSync(path), Buffer.from(`${name} turn ${index + 1}`)]));
        imageData = readFileSync(path).toString("base64");
        args.push("--image", path);
      }
      args.push(`Turn ${index + 1}: reply OK.`);
      const proc = Bun.spawn([bin, ...args], {
        cwd: workspace,
        stdout: "pipe",
        stderr: "pipe",
        env: testEnvironment({
          HOME: home,
          TMPDIR: root,
          AI_GATEWAY_API_KEY: "fake-image-route-key",
          FX_MODEL: MODEL,
          FX_GATEWAY_BASE_URL: turn.view === "down" ? refused : gateway.base,
          FX_GATEWAY_CHAT_URL: gateway.chatUrl,
        }),
      });
      const timer = setTimeout(() => proc.kill("SIGKILL"), 30_000);
      const [stdout, stderr, exit] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
      clearTimeout(timer);
      let json: { session_id?: string; error?: string } = {};
      try { json = JSON.parse(stdout.trim().split("\n").at(-1) ?? "{}"); } catch { json = {}; }

      // The flags the spec says the shell computes from this turn.
      const req: RouteRequest = {
        user_images: turn.attach,
        earlier_images: earlier.length > 0,
        pending_images: turn.attach,
        tool_images: false,
        fallback: true,
        catalog_down: turn.view === "down",
      };
      const body = gateway.requests[0];
      const error = json.error ?? null;
      const seen: Seen = { kind: "send", reason: "none", notified: false, inline_now: false, inline_earlier: false, vision_tool: false, vision_required: false, references: false, earlier_note: "none" };
      if (body === undefined) {
        seen.kind = exit !== 0 && error ? "fail" : "error";
        seen.reason = error === "ModelImageCapabilityUnavailable" ? "capability_unknown"
          : error === "SubscriptionNativeImageUnavailable" ? "no_native_image"
          : `exit ${exit}: ${error ?? stderr.trim().slice(0, 200)}`;
      } else {
        seen.notified = stderr.includes(CATALOG_DOWN_NOTICE);
        seen.inline_now = turn.attach && body.includes(imageData);
        seen.inline_earlier = earlier.some((data) => body.includes(data));
        seen.vision_tool = body.includes('"name":"vision"');
        seen.vision_required = body.includes('"toolChoice":{"type":"required"}');
        seen.references = body.includes("<available_images>");
        seen.earlier_note = body.includes(UNKNOWN_NOTE) ? "unknown" : body.includes(DEAD_END_NOTE) ? "dead_end" : "none";
      }
      observations.push({ session: name, turn: index + 1, view: VIEWS[turn.view], req, seen, exit, error });
      // A turn that finished is saved, and its image stays in the history.
      if (exit === 0) {
        sessionId ||= json.session_id ?? "";
        if (turn.attach) earlier.push(imageData);
      }
    }
  } finally {
    gateway.stop();
  }
  return observations;
}

export function matrixSessions(): { name: string; turns: Turn[] }[] {
  const sessions: { name: string; turns: Turn[] }[] = [];
  for (const before of [false, true]) {
    for (const view of VIEW_NAMES) {
      for (const attach of [false, true]) {
        const last: Turn = { view, attach };
        sessions.push({
          name: `${before ? "after an image" : "first turn"}, ${view}, ${attach ? "image now" : "text only"}`,
          turns: before ? [{ view: "vision", attach: true }, last] : [last],
        });
      }
    }
  }
  return sessions;
}

export function randomSessions(seed: number, count: number, maxTurns: number): { name: string; turns: Turn[] }[] {
  const random = seededRandom(seed);
  const sessions: { name: string; turns: Turn[] }[] = [];
  for (let i = 0; i < count; i += 1) {
    const length = 2 + Math.floor(random() * (maxTurns - 1));
    const turns: Turn[] = [];
    for (let t = 0; t < length; t += 1) {
      // The down catalog is the reported case, so it comes up often.
      const roll = random();
      const view: ViewName = roll < 0.35 ? "down" : VIEW_NAMES[Math.floor(random() * 3)]!;
      turns.push({ view, attach: random() < 0.4 });
    }
    sessions.push({ name: `random ${i + 1} (seed ${seed})`, turns });
  }
  return sessions;
}

export type Mismatch = { observation: Observation; expected: string };
export type BinaryToSpecResult = {
  /// Every turn conforms. With `-continue`, TLC 2.19 still ends by saying
  /// no error was found, so this reads the violations it reported instead.
  ok: boolean;
  sessions: number;
  turns: number;
  observationsPath: string;
  tlc: CheckedTlc;
  /// The turns TLC found violating, the first only unless `all` was set.
  mismatches: Mismatch[];
};

/// The turns TLC reports violating BinaryConforms: for each error trace, its
/// last state names the turn (`at`) and what the model expected.
function mismatchesFrom(output: string, observations: Observation[]): Mismatch[] {
  const found: Mismatch[] = [];
  for (const chunk of output.split("Error: Invariant BinaryConforms is violated.").slice(1)) {
    const last = chunk.split(/\nState \d+:/).at(-1) ?? "";
    const at = Number(/\/\\ at = (\d+)/.exec(last)?.[1] ?? NaN);
    const expected = /\/\\ expected = (\[[\s\S]*?\])\s*(?:\n\s*\n|\n\/\\|$)/.exec(last)?.[1]?.replace(/\s+/g, " ") ?? "(not in TLC's output)";
    const observation = observations[at - 1];
    if (observation && !found.some((m) => m.observation === observation)) found.push({ observation, expected });
  }
  return found;
}

export async function binaryToSpec(options: { bin: string; dir: string; seed: number; randomSessions: number; maxTurns: number; all?: boolean }): Promise<BinaryToSpecResult> {
  if (!existsSync(options.bin)) throw new Error(`no fx binary at ${options.bin}; run zig build, or point FX_BIN at one`);
  const sessions = [...matrixSessions(), ...randomSessions(options.seed, options.randomSessions, options.maxTurns)];
  mkdirSync(options.dir, { recursive: true });
  const refused = await refusedBase();
  const observations: Observation[] = [];
  for (const session of sessions) observations.push(...await runSession(options.bin, options.dir, session.name, session.turns, refused));

  const observationsPath = join(options.dir, "observations.json");
  writeFileSync(observationsPath, `${JSON.stringify(observations, null, 1)}\n`);
  const checked = await checkObservations(join(options.dir, "tlc"), observations, options.all ?? false);
  return { ...checked, sessions: sessions.length, turns: observations.length, observationsPath };
}

/// Has TLC check `observations` against the model in `dir`. The binary
/// stage runs it on what the binary did, and its self-check on doctored
/// copies, which it must reject.
export async function checkObservations(dir: string, observations: Observation[], all: boolean): Promise<{ ok: boolean; tlc: CheckedTlc; mismatches: Mismatch[] }> {
  const data = [
    "---- MODULE BinaryData ----",
    "EXTENDS Sequences",
    "Observations == <<",
    observations.map((o) => `  \\* ${o.session}, turn ${o.turn}\n  ${toTla({ view: o.view, req: o.req, seen: o.seen })}`).join(",\n"),
    ">>",
    "====",
    "",
  ].join("\n");
  const files = {
    ...specFiles(),
    "BinaryImageRoute.tla": readFileSync(join(REPO_ROOT, "tests", "tla", "image_route", "spec", "BinaryImageRoute.tla"), "utf8"),
    "BinaryImageRoute.cfg": readFileSync(join(REPO_ROOT, "tests", "tla", "image_route", "spec", "BinaryImageRoute.cfg"), "utf8"),
    "BinaryData.tla": data,
  };
  const tlc = await checkTlc(dir, "BinaryImageRoute", "BinaryImageRoute.cfg", files, all ? ["-continue"] : []);
  const ok = tlc.verdict === "pass" && !tlc.output.includes("Error: Invariant BinaryConforms is violated.");
  return { ok, tlc, mismatches: mismatchesFrom(tlc.output, observations) };
}

/// Copies of `observations` with one turn misreported, each as a binary
/// with a known bug would show it. The model must reject every one, or the
/// binary stage could pass whatever the binary did.
export function doctoredObservations(observations: Observation[]): { name: string; observations: Observation[] }[] {
  const doctor = (name: string, pick: (o: Observation) => boolean, change: (seen: Seen) => Seen) => {
    const index = observations.findIndex(pick);
    if (index < 0) return null;
    const copy = observations.map((o) => ({ ...o, seen: { ...o.seen } }));
    copy[index]!.seen = change(copy[index]!.seen);
    return { name, observations: copy };
  };
  const none: Seen = { kind: "send", reason: "none", notified: false, inline_now: false, inline_earlier: false, vision_tool: false, vision_required: false, references: false, earlier_note: "none" };
  return [
    doctor("an earlier image fails a text-only turn (the reported bug)",
      (o) => o.seen.earlier_note === "unknown",
      () => ({ ...none, kind: "fail", reason: "capability_unknown" })),
    doctor("an unconfirmed earlier image is sent inline",
      (o) => o.seen.earlier_note === "unknown",
      (seen) => ({ ...seen, earlier_note: "none", inline_earlier: true })),
    doctor("a down catalog withholds an earlier image without telling the user",
      (o) => o.seen.earlier_note === "unknown" && o.seen.notified,
      (seen) => ({ ...seen, notified: false })),
    doctor("an image attached now is sent while support is unknown",
      (o) => o.seen.kind === "fail" && o.seen.reason === "capability_unknown",
      () => ({ ...none })),
  ].filter((entry): entry is { name: string; observations: Observation[] } => entry !== null);
}

if (import.meta.main) {
  const flag = (name: string) => {
    const index = process.argv.indexOf(name);
    return index >= 0 ? process.argv[index + 1] : undefined;
  };
  const started = performance.now();
  const result = await binaryToSpec({
    bin: flag("--bin") ?? binary,
    dir: outDir("image-route-binary"),
    seed: Number(flag("--seed") ?? process.env.FX_IMAGE_ROUTE_SEED ?? "20261022"),
    randomSessions: Number(flag("--sessions") ?? process.env.FX_IMAGE_ROUTE_BINARY_SESSIONS ?? "8"),
    maxTurns: 5,
    // Standalone runs list every turn that disagrees, not just the first.
    all: true,
  });
  const { ok } = result;
  console.log(`${ok ? "PASS" : "FAIL"} binary to spec: ${result.sessions} sessions, ${result.turns} turns, ${result.mismatches.length} disagree with the model, ${((performance.now() - started) / 1000).toFixed(1)} s; observations ${result.observationsPath}`);
  for (const { observation, expected } of result.mismatches) {
    const view = observation.view.kind === "listed" ? `listed(vision=${observation.view.vision})` : observation.view.kind;
    console.log(`  mismatch: ${observation.session}, turn ${observation.turn}, catalog ${view}`);
    console.log(`    flags:    ${toTla(observation.req)}`);
    console.log(`    expected: ${expected}`);
    console.log(`    binary:   ${toTla(observation.seen)}`);
  }
  if (!ok && result.mismatches.length === 0) console.log(result.tlc.output.slice(-3000));
  process.exitCode = ok ? 0 : 1;
}
