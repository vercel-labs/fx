// The real fx shell in tmux for the mcp-v2-model scenarios: start it with a
// fake gateway, read its status line once it settles, type `/mcp` verbs, quit.
import { join } from "node:path";
import { binary, shellQuote, targetHelpers } from "../lib/context";
import { fxEnv, save, type Fixture, type ServerEvent } from "./driver";
import type { TraceRecord } from "./trace";

export type Line = { k: string; who: string; why: string; r: number; e: number };

/** The status line's MCP text, from the last lines of the pane (menu.zig statusLine). */
export function parseStatus(pane: string): Line | null {
  const tail = pane.split("\n").filter((l) => l.trim()).slice(-4).join("\n");
  let m: RegExpExecArray | null;
  if ((m = /Signing in to (\S+) · \/mcp/.exec(tail))) return { k: "signing", who: m[1]!, why: "", r: 0, e: 0 };
  if ((m = /(\S+) is waiting for approval · \/mcp/.exec(tail))) return { k: "attn", who: m[1]!, why: "waiting", r: 0, e: 0 };
  if ((m = /(\S+) needs login · \/mcp/.exec(tail))) return { k: "attn", who: m[1]!, why: "login", r: 0, e: 0 };
  if ((m = /(\S+) failed · \/mcp/.exec(tail))) return { k: "attn", who: m[1]!, why: "failed", r: 0, e: 0 };
  if ((m = /(\d+) MCP servers need you · \/mcp/.exec(tail))) return { k: "many", who: "", why: "", r: Number(m[1]), e: 0 };
  return null;
}

export class Shell {
  records: TraceRecord[] = [];
  panes: { at: number; label: string; pane: string }[] = [];
  gateway: { stop(): void; baseUrl: string; chatUrl: string } | null = null;
  tui: any = null;
  constructor(readonly f: Fixture) {}

  async start(extra: Record<string, string> = {}) {
    const { TmuxSession, startFakeGateway } = await targetHelpers();
    this.gateway = startFakeGateway([], { models: [{ id: "openai/gpt-5", type: "language", tags: ["tool-use"] }] });
    this.tui = await TmuxSession.create({
      cmd: shellQuote(binary), cwd: this.f.workspace, isolated: true, width: 160, height: 40, remainOnExit: true,
      stderrPath: join(this.f.base, "stderr.txt"),
      env: fxEnv(this.f, { FX_GATEWAY_BASE_URL: this.gateway!.baseUrl, FX_GATEWAY_CHAT_URL: this.gateway!.chatUrl, FX_MODEL: "openai/gpt-5", ...extra }),
    });
    await this.tui.waitForComposer(20_000);
  }

  async snap(label: string) {
    const pane = await this.tui.capturePane();
    this.panes.push({ at: Date.now(), label, pane });
    return pane;
  }

  /** Waits until the status line has read `want` (or anything, without one) for `stableMs`, and records it. */
  async status(want: Partial<Line> | null, timeoutMs = 20_000, stableMs = 800): Promise<Line | null> {
    const deadline = Date.now() + timeoutMs;
    let last: string | null = null, since = Date.now(), line: Line | null = null;
    while (Date.now() < deadline) {
      // With nothing that needs attention the line says nothing about MCP.
      line = parseStatus(await this.tui.capturePane()) ?? (want?.k === "none" ? { k: "none", who: "", why: "", r: 0, e: 0 } : null);
      const key = JSON.stringify(line);
      if (key !== last) { last = key; since = Date.now(); }
      const fits = want === null || (line !== null && Object.entries(want).every(([k, v]) => (line as never)[k] === v));
      if (fits && line && Date.now() - since >= stableMs) break;
      await Bun.sleep(100);
    }
    await this.snap(`status ${JSON.stringify(want)}`);
    if (line && line.k !== "signing") this.records.push({ event: "status", data: line, at: Date.now() });
    if (line && line.k === "signing") this.records.push({ event: "status", data: { signing: true }, at: Date.now(), note: line.who });
    return line;
  }

  async type(text: string, record?: TraceRecord) {
    if (record) this.records.push({ ...record, at: Date.now() });
    await this.tui.sendText(text);
  }

  async quit(): Promise<number> {
    this.records.push({ event: "quit", at: Date.now() });
    const started = Date.now();
    await this.tui.sendKeys("C-c");
    await Bun.sleep(300);
    const second = Date.now();
    await this.tui.sendKeys("C-c");
    while (!this.tui.paneStatus().dead && Date.now() - started < 10_000) await Bun.sleep(20);
    return Date.now() - second;
  }

  async stop() {
    try { if (this.tui) { save(join(this.f.base, "final-pane.txt"), await this.tui.capturePane().catch(() => "")); await this.tui.kill(); } } catch {}
    this.gateway?.stop();
    save(join(this.f.base, "panes.json"), this.panes);
    save(join(this.f.base, "records-harness.json"), this.records);
  }
}

/** Fixture log lines as model records: exits after quit are its SIGTERM's. */
export function serverRecords(events: ServerEvent[], quitAt: number | null): TraceRecord[] {
  const out: TraceRecord[] = [];
  for (const e of events) {
    const data = { server: e.name };
    if (e.ev === "start") out.push({ event: "spawn", data, at: e.t, note: `pid ${e.pid}` });
    else if (e.ev === "listed") out.push({ event: "ready", data, at: e.t, note: `pid ${e.pid}` });
    else if (e.ev === "eof" || e.ev === "sigterm") {
      const afterQuit = quitAt !== null && e.t >= quitAt;
      out.push({ event: afterQuit ? "term" : "stop", data, at: e.t, note: `pid ${e.pid} ${e.ev}` });
    }
  }
  return out;
}

