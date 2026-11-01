// Prompt images as blobs of a v2 session (D89) through the real binary,
// judged by TLC. Each scenario runs `fx ask` against a fake gateway, then
// writes what it observed, every turn's first request and saved user item
// and the session's blobs folder, as one line per step of
// tests/tla/session_manager/PromptImages.tla, and has TLC check the lines
// through trace/PromptImagesTrace.tla. A note is observed as naming an image
// only when the file it names is that image's blob in the request's own
// session, so TLC rejects any other note. Faults planted into a kept run
// must be rejected. A converted v1 session's import is observed by its user
// item. Forks, which only the terminal makes, are checked by the spec and by
// session_adapter.zig's D89 test.
import { expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts, binary, testEnvironment, worktree } from "../lib/context";
import { runTlc, sha256File, TLA_ROOT } from "../lib/tlc";

const { fakeGatewayTitleDefault, TITLE_GENERATION_MARKER } = await import(join(worktree, "tests", "e2e", "tmux-helpers.ts"));
const { solidPng } = await import(join(worktree, "tests", "e2e", "fixtures", "image-encoding.ts"));
const { copyV1Fixture } = await import(join(worktree, "tests", "e2e", "saved-sessions.ts"));

const TIMEOUT = 60_000;
// Tagged for image input, so images go to the model inline.
const MODEL = "google/gemini-2.5-flash";
const TRACE_SPECS = ["PromptImagesTrace.tla", "PromptImagesTrace.cfg"];
const MODEL_SPECS = ["PromptImages.tla"];

type Line = Record<string, unknown>;
const set = (values: Iterable<string>) => ({ $set: [...new Set(values)].sort() });

function sseText(text: string) {
  return new Response(
    `data: ${JSON.stringify({ type: "text-delta", id: "a", delta: text })}\n\n` +
      `data: ${JSON.stringify({ type: "finish", finishReason: { unified: "stop", raw: "stop" }, usage: { inputTokens: { total: 1 }, outputTokens: { total: 1 } } })}\n\n` +
      "data: [DONE]\n\n",
    { headers: { "content-type": "text/event-stream" } },
  );
}

function fixture(name: string) {
  const root = mkdtempSync(join(artifacts, `prompt-images-${name}-`));
  const home = join(root, "home"), workspace = join(root, "workspace");
  mkdirSync(join(home, ".fx"), { recursive: true, mode: 0o700 });
  mkdirSync(workspace, { mode: 0o700 });
  writeFileSync(join(home, ".fx", "settings.json"), JSON.stringify({ permission: {} }));
  const sessionsRoot = join(home, ".fx", "sessions", "v2");
  const requests: string[] = [];
  const server = Bun.serve({
    port: 0,
    async fetch(req) {
      if (new URL(req.url).pathname === "/coding-agent/v1/models") {
        return Response.json({ data: [{ id: MODEL, type: "language", tags: ["vision", "file-input", "tool-use"] }] });
      }
      if (req.method !== "POST") return new Response("not found", { status: 404 });
      const body = await req.text();
      if (body.includes(TITLE_GENERATION_MARKER)) return fakeGatewayTitleDefault();
      requests.push(body);
      return sseText("seen");
    },
  });
  const env = testEnvironment({
    HOME: home, AI_GATEWAY_API_KEY: "synthetic-prompt-images-fixture", FX_TEST_SKIP_ONBOARDING: "1",
    FX_GATEWAY_BASE_URL: `http://127.0.0.1:${server.port}`,
    FX_GATEWAY_CHAT_URL: `http://127.0.0.1:${server.port}/v4/ai/language-model`,
    FX_MODEL: MODEL, NO_COLOR: "1",
  });
  // Each distinct image gets the next label, d1, d2, ..., in the order seen.
  const labels = new Map<string, string>();
  const label = (digest: string) => {
    if (!labels.has(digest)) labels.set(digest, `d${labels.size + 1}`);
    return labels.get(digest)!;
  };
  const lines: Line[] = [];
  return {
    root, home, sessionsRoot, requests, lines, label,
    image(name: string, width: number, height: number): string {
      const path = join(workspace, name);
      writeFileSync(path, solidPng(width, height));
      return path;
    },
    /// One `fx ask` turn; its first request and its user item become lines.
    async ask(session: "source" | "fork", images: string[], resume?: string): Promise<string> {
      const before = requests.length;
      const args = ["ask", "--json", ...(resume ? ["--resume", resume] : [])];
      for (const image of images) args.push("--image", image);
      args.push("Look at the images.");
      const proc = Bun.spawn([binary, ...args], { cwd: workspace, env, stdout: "pipe", stderr: "pipe" });
      const [stdout, stderr, exitCode] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
      expect(stderr).toBe("");
      expect(exitCode).toBe(0);
      expect(requests.length).toBe(before + 1);
      const id = JSON.parse(stdout).session_id as string;
      const asked = images.map(path => label(sha256File(path)));
      lines.push(observeRequest(requests[before]!, session, asked, join(sessionsRoot, id), label));
      lines.push(observeWrite(join(sessionsRoot, id), session, label));
      return id;
    },
    blobs(session: "source" | "fork", id: string) {
      lines.push({ event: "Blobs", s: session, blobs: set(blobLabels(join(sessionsRoot, id), label)) });
    },
    stop() { server.stop(true); },
  };
}

/// The request's images: those sent inline, and those whose note names the
/// image's own blob in `sessionDir`. A note naming any other file is
/// observed under a label that no digest has, which TLC cannot match.
function observeRequest(body: string, s: string, asked: string[], sessionDir: string, label: (d: string) => string): Line {
  const sent: string[] = [], noted: string[] = [];
  const prompt = JSON.parse(body).prompt as Array<{ content?: unknown }>;
  for (const message of prompt) {
    if (!Array.isArray(message.content)) continue;
    for (const part of message.content as Array<Record<string, any>>) {
      if (part.type === "file" && part.data?.type === "data") {
        sent.push(label(new Bun.CryptoHasher("sha256").update(Buffer.from(part.data.data, "base64")).digest("hex")));
      }
      if (part.type !== "text") continue;
      for (const match of String(part.text).matchAll(/^\[Image #\d+ \([^)]*\) is saved at ("(?:[^"\\]|\\.)*")\.\]$/gm)) {
        const path = JSON.parse(match[1]!) as string;
        const digest = path.split("/").pop()!;
        let named = "unsaved";
        try {
          if (path === join(sessionDir, "blobs", digest) && sha256File(path) === digest) named = label(digest);
        } catch {}
        noted.push(named);
      }
    }
  }
  return { event: "Request", s, asked: set(asked), sent: set(sent), noted: set(noted) };
}

/// The session's user item `at`, the last by default: each image by how the
/// item keeps it, and the blobs the item lists.
function observeWrite(sessionDir: string, s: string, label: (d: string) => string, at = -1): Line {
  const items = readFileSync(join(sessionDir, "log.jsonl"), "utf8").split("\n").filter(Boolean)
    .map(line => JSON.parse(line)).filter(line => line.kind === "item" && line.type === "user");
  const item = items.at(at);
  const refs: string[] = [], inline: string[] = [];
  for (const image of item.data.images as Array<Record<string, any>>) {
    if (typeof image.blob === "string") refs.push(label(image.blob));
    else if (typeof image.inline_data === "string") {
      inline.push(label(new Bun.CryptoHasher("sha256").update(Buffer.from(image.inline_data, "base64")).digest("hex")));
    }
  }
  // These runs store no other blob, so the item lists images only.
  const listed = ((item.blobs ?? []) as string[]).map(label);
  return { event: "Write", s, refs: set(refs), inline: set(inline), listed: set(listed) };
}

function blobLabels(sessionDir: string, label: (d: string) => string): string[] {
  return readdirSync(join(sessionDir, "blobs")).map(label);
}

async function judge(name: string, lines: Line[]) {
  const dir = join(artifacts, name);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "trace.ndjson"), lines.map(line => JSON.stringify(line)).join("\n") + "\n");
  const convert = Bun.spawnSync(["python3", join(TLA_ROOT, "session_manager", "trace", "to_tla.py"), join(dir, "trace.ndjson"), join(dir, "TraceData.tla")]);
  expect(convert.exitCode).toBe(0);
  for (const spec of MODEL_SPECS) writeFileSync(join(dir, spec), readFileSync(join(TLA_ROOT, "session_manager", spec)));
  const run = await runTlc(dir, "PromptImagesTrace", "PromptImagesTrace.cfg", TRACE_SPECS, join(TLA_ROOT, "session_manager", "trace"));
  const matched = Math.max(0, ...[...run.output.matchAll(/<<"matched_lines", (\d+)>>/g)].map(m => Number(m[1])));
  return { accepted: run.violated === "TraceIncomplete", matched, lines: lines.length, dir };
}

test("prompt images become blobs the notes name, across a resume (D89)", async () => {
  const f = fixture("resume");
  try {
    const a = f.image("a.png", 20, 10), b = f.image("b.png", 10, 20);
    const id = await f.ask("source", [a]);
    // The same image again and a new one: one blob each, both noted.
    await f.ask("source", [a, b], id);
    f.blobs("source", id);
    const verdict = await judge("resume", f.lines);
    expect(verdict).toMatchObject({ accepted: true, matched: f.lines.length });

    // Planted faults: a note naming the image's source file, an item that
    // keeps a saved image inline, and a blob the item does not list.
    const noteSource = f.lines.map(line => line.event === "Request" ? { ...line, noted: set([...(line.noted as any).$set, "unsaved"]) } : line);
    expect((await judge("planted-note", noteSource)).accepted).toBe(false);
    const keptInline = f.lines.map((line, index) => index === 1 ? { ...line, refs: set([]), inline: (line as any).refs } : line);
    expect((await judge("planted-inline", keptInline)).accepted).toBe(false);
    const unlisted = f.lines.map((line, index) => index === 1 ? { ...line, listed: set([]) } : line);
    expect((await judge("planted-unlisted", unlisted)).accepted).toBe(false);
  } finally {
    f.stop();
  }
}, TIMEOUT * 3);

test("an image the session cannot save stays inline with no note, and a saved one keeps its note (D89)", async () => {
  const f = fixture("refused");
  try {
    const a = f.image("a.png", 20, 10), c = f.image("c.png", 12, 12);
    const id = await f.ask("source", [a]);
    // The store can no longer add blobs: `a` is stored already, `c` is not.
    const blobs = join(f.sessionsRoot, id, "blobs");
    chmodSync(blobs, 0o500);
    try {
      await f.ask("source", [a, c], id);
    } finally {
      chmodSync(blobs, 0o700);
    }
    f.blobs("source", id);
    const verdict = await judge("refused", f.lines);
    expect(verdict).toMatchObject({ accepted: true, matched: f.lines.length });
    const second = f.lines[2] as any;
    expect(second.noted.$set).toEqual(["d1"]);
  } finally {
    f.stop();
  }
}, TIMEOUT * 2);

test("a converted v1 session's prompt images become blobs its next request names (D89)", async () => {
  const f = fixture("converted");
  try {
    // v0.0.14 saved one turn with twenty attachments of one image.
    const [id] = copyV1Fixture(f.home, "many-images");
    const v1Images = join(f.home, ".fx", "sessions", id, "images");
    for (const name of readdirSync(v1Images)) f.label(sha256File(join(v1Images, name)));
    // Resuming converts the session, then sends a new image with the old.
    await f.ask("source", [f.image("b.png", 10, 20)], id);
    // The import wrote its item before the request went out.
    f.lines.unshift(observeWrite(join(f.sessionsRoot, id), "source", f.label, 0));
    f.blobs("source", id);
    const verdict = await judge("converted", f.lines);
    expect(verdict).toMatchObject({ accepted: true, matched: f.lines.length });
    // The spec allows an image the store refused to stay inline, so the
    // writable store's import must have saved it.
    expect(f.lines[0]).toMatchObject({ refs: { $set: ["d1"] }, inline: { $set: [] } });
    expect((f.lines[1] as any).noted.$set).toEqual(["d1", "d2"]);

    // A planted fault: the imported item does not list its blob.
    const unlisted = f.lines.map((line, index) => index === 0 ? { ...line, listed: set([]) } : line);
    expect((await judge("planted-import-unlisted", unlisted)).accepted).toBe(false);
  } finally {
    f.stop();
  }
}, TIMEOUT * 2);
