// Connects the requests the real fx binary sent to TLC.
//
// 1. Each captured agent request becomes PromptCache blocks: the tools, then
//    the stable instruction groups (base, skills, project, mcp), the turn
//    context, the runtime notes, then one block per user message and per run
//    of assistant and tool messages; a run whose tool result carries a
//    delivered <scoped-rules> block is "asstc", PromptCache's message carrier.
//    A message-level or part-level marker in
//    the run's family syntax marks the block it ends:
//    providerOptions.anthropic.cacheControl for Anthropic,
//    providerOptions.openai.promptCacheBreakpoint for OpenAI. Layout drift, a
//    marker inside a group, a marker in the other family's syntax, or a
//    system message after the conversation started is an abstraction error,
//    never a guess.
// 2. The blocks become PromptCacheObserved.tla. PromptCacheTrace replays them
//    through PromptCache's provider cache. A check passes only when TLC stops
//    on the ReplayIncomplete sentinel: every request replayed, nothing failed.
// 3. Missing coverage (no request that exercises a property) is INCONCLUSIVE,
//    not a pass.
//
// simulate() mirrors the model in TypeScript only to print a timeline for
// people. Verdicts come from TLC.
import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { TLA_ROOT, runTlc, type TlcRun } from "../lib/tlc";
import type { CapturedRequest } from "./scenarios";

export type Design = "current" | "proposed";
/** Whose cache rules and marker syntax a run uses: PromptCache's Family. */
export type Family = "anthropic" | "openai";
export type Verdict = "ACCEPTED" | "REJECTED" | "INCONCLUSIVE" | "TOOL_ERROR";
export type PropertyVerdict = "HOLDS" | "VIOLATED" | "TOOL_ERROR";

export const PROPERTIES = ["Budget", "SessionReuse", "CrossRepoReuse", "SameWorktreeReuse", "WorktreeReuse", "ContextChangeKeepsStable"] as const;
/** Checked by midsession.test.ts on sessions with mid-session context changes. */
export const MID_PROPERTIES = ["MidSessionKeepsHistory", "PreviousFullyReused"] as const;
export type Property = (typeof PROPERTIES)[number] | (typeof MID_PROPERTIES)[number];

export interface Block { k: string; v: string }

export interface ObservedRequest {
  seq: number;
  w: string;
  repo: string;
  s: number;
  req: Block[];
  manual: number[];
  /** The block position of the user message that carries a named skill's text, or 0. */
  skillUser: number;
}

export interface Abstraction {
  blocks: Block[];
  manual: number[];
  /** The block position of the user message that carries a named skill's text, or 0. */
  skillUser: number;
  /** Prompt message indexes that make up each block, in block order. */
  sources: number[][];
  errors: string[];
}

export interface RuntimeResult {
  version: 1;
  design: Design;
  family: Family;
  verdict: Verdict;
  detail: string;
  requests: number;
  coverage: Record<Property, number>;
  properties: Partial<Record<Property, { verdict: PropertyVerdict; detail?: string; log?: string }>>;
  conformanceLog?: string;
  hashes: Record<string, string>;
}

const tlaDir = join(TLA_ROOT, "prompt_context");
const SPECS = ["PromptCache.tla", "PromptCacheTrace.tla"];
const ORDER = ["base", "skills", "project", "mcp", "ctx", "rt"] as const;

const sha = (text: string) => createHash("sha256").update(text).digest("hex");
const short = (text: string) => sha(text).slice(0, 16);

/** Blocks today's fx inserts ahead of the history mid-session. */
const INSERTED = ["scoped", "skill"] as const;
const SKILL_TEXT = "Explicitly invoked skill content for this query:";
/** Opens the short note a turn saves in place of a named skill's text (src/core/skills/skill_invocation.zig skill_used_open_tag). */
const SKILL_USED = "<fx-skill-used>";

type SystemKind = (typeof ORDER)[number] | (typeof INSERTED)[number] | "other";

function systemKind(content: string): SystemKind {
  // Rules delivered at tool time: scoped rules with the guidance preamble, but no project rules.
  if (content.includes("<scoped-rules") && !content.includes("<project-rules")) return "scoped";
  if (content.startsWith(SKILL_TEXT)) return "skill";
  if (content.startsWith("Skills provide task instructions") || content.includes("<available_skills>")) return "skills";
  if (content.startsWith("<project-instructions-guidance>") || content.includes("<project-rules")) return "project";
  if (content.startsWith("Configured MCP servers")) return "mcp";
  if (content.startsWith("<fx-turn-context>")) return "ctx";
  if (content.startsWith("Runtime context:") || content.startsWith("<response_language_control>")) return "rt";
  return "other";
}

const MARKER: Record<Family, (providerOptions: any) => unknown> = {
  anthropic: (options) => options?.anthropic?.cacheControl,
  openai: (options) => options?.openai?.promptCacheBreakpoint,
};

function hasMarker(message: any, family: Family): boolean {
  const marker = MARKER[family];
  if (marker(message?.providerOptions)) return true;
  if (Array.isArray(message?.content)) {
    return message.content.some((part: any) => marker(part?.providerOptions));
  }
  return false;
}

/** A system message inside the conversation, as a note carrier sends it, or null. */
function noteKind(content: string): "note" | "skilltext" | "skillnote" | null {
  if (content.startsWith("<fx-context-update>") || content.includes("<scoped-rules")) return "note";
  if (content.startsWith(SKILL_TEXT)) return "skilltext";
  if (content.startsWith("<fx-skill-used")) return "skillnote";
  return null;
}

/** The note a resumed turn's user message carries when earlier shell handles are gone (src/core/session/session.zig stale_shell_handles_note). */
export const STALE_SHELL_NOTE = "Runtime context: fx restarted since this session was last active";

/** Opens the note a changed runtime context rides in (src/core/agent/runtime/runtime_context.zig update_open_tag). */
export const RUNTIME_UPDATE = "<fx-context-update>";

function text(message: any): string {
  return typeof message.content === "string" ? message.content : JSON.stringify(message.content);
}

/** Turns one captured agent request body into PromptCache blocks. */
export function abstractRequest(body: string, family: Family): Abstraction {
  const errors: string[] = [];
  let parsed: any;
  try {
    parsed = JSON.parse(body);
  } catch {
    return { blocks: [], manual: [], skillUser: 0, sources: [], errors: ["body is not JSON"] };
  }
  const prompt: any[] = Array.isArray(parsed.prompt) ? parsed.prompt : [];
  const blocks: Block[] = [{ k: "tools", v: short(JSON.stringify(parsed.tools ?? [])) }];
  const sources: number[][] = [[]];
  let skillUser = 0;
  const marked: boolean[] = [false];
  if (Array.isArray(parsed.tools) && parsed.tools.some((tool: any) => tool?.providerOptions)) {
    errors.push("a tool carries providerOptions; tool markers are not modeled");
  }
  const other: Family = family === "anthropic" ? "openai" : "anthropic";
  prompt.forEach((message, n) => {
    if (hasMarker(message, other)) errors.push(`message ${n} carries an ${other} marker on an ${family} request`);
  });

  // Stable instruction groups and the overlay.
  let group = 0; // index into ORDER
  let i = 0;
  const groups: { kind: string; messages: number[] }[] = [{ kind: "base", messages: [] }];
  for (; i < prompt.length && prompt[i].role === "system"; i += 1) {
    const kind = systemKind(text(prompt[i]));
    if (kind === "other") {
      if (groups.at(-1)!.kind === "ctx" || groups.at(-1)!.kind === "rt") {
        errors.push(`unclassified system message ${i} after the turn context`);
      }
      groups.at(-1)!.messages.push(i);
      continue;
    }
    if (kind === "scoped" || kind === "skill") {
      // Today's fx: rules delivered this turn follow the MCP group and move
      // after the project rules on later turns; a named skill's text comes
      // right before the turn context.
      const after = groups.at(-1)!.kind;
      const allowed = kind === "scoped" ? ["project", "mcp"] : ["mcp", "scoped"];
      if (!allowed.includes(after)) errors.push(`system message ${i} (${kind}) follows ${after}`);
      groups.push({ kind, messages: [i] });
      continue;
    }
    const at = ORDER.indexOf(kind as (typeof ORDER)[number]);
    if (kind === "rt" && groups.at(-1)!.kind === "rt") {
      groups.at(-1)!.messages.push(i);
      continue;
    }
    if (at <= group) {
      errors.push(`system message ${i} (${kind}) is out of order after ${ORDER[group]}`);
      groups.at(-1)!.messages.push(i);
      continue;
    }
    group = at;
    groups.push({ kind, messages: [i] });
  }
  const kinds = groups.map((g) => g.kind).filter((k) => !(INSERTED as readonly string[]).includes(k));
  if (JSON.stringify(kinds) !== JSON.stringify(ORDER)) {
    errors.push(`instruction groups ${kinds.join(",")} differ from ${ORDER.join(",")}`);
  }
  for (const g of groups) {
    if (g.messages.length === 0) {
      errors.push(`empty ${g.kind} group`);
      continue;
    }
    blocks.push({ k: g.kind, v: short(g.messages.map((m) => text(prompt[m])).join("\u0000")) });
    sources.push(g.messages);
    g.messages.forEach((m, n) => {
      if (hasMarker(prompt[m], family) && n !== g.messages.length - 1) errors.push(`marker inside the ${g.kind} group (message ${m})`);
    });
    marked.push(hasMarker(prompt[g.messages.at(-1)!], family));
  }

  // The conversation.
  for (; i < prompt.length; i += 1) {
    const role = prompt[i].role;
    if (role === "system") {
      const kind = noteKind(text(prompt[i]));
      if (kind === null) {
        errors.push(`system message ${i} after the conversation started`);
        continue;
      }
      blocks.push({ k: kind, v: short(text(prompt[i])) });
      sources.push([i]);
      marked.push(hasMarker(prompt[i], family));
      continue;
    }
    if (role === "user") {
      // A turn's message carries the stale-shell note, a runtime context
      // update, a named skill's text or the short note saved in its place:
      // PromptCache's message carrier.
      const content = text(prompt[i]);
      const skill = content.includes(SKILL_TEXT);
      const carries = skill || content.includes(SKILL_USED) || content.includes(STALE_SHELL_NOTE) || content.includes(RUNTIME_UPDATE);
      blocks.push({ k: carries ? "userc" : "user", v: short(content) });
      if (skill) skillUser = blocks.length;
      sources.push([i]);
      marked.push(hasMarker(prompt[i], family));
      continue;
    }
    // One model response is one block: an assistant message and the tool
    // results that follow it. Rules fx delivered ride on a tool result; an
    // escaped tag (&lt;scoped-rules) in tool output is not a block.
    const last = blocks.at(-1)!;
    if ((last.k === "asst" || last.k === "asstc") && role !== "assistant") {
      sources.at(-1)!.push(i);
      last.v = short(sources.at(-1)!.map((m) => text(prompt[m])).join("\u0000"));
      if (role === "tool" && (text(prompt[i]).includes("<scoped-rules") || text(prompt[i]).includes(RUNTIME_UPDATE))) last.k = "asstc";
      if (marked.at(-1)) errors.push(`marker inside an assistant run (before message ${i})`);
      marked[marked.length - 1] = hasMarker(prompt[i], family);
    } else {
      blocks.push({ k: "asst", v: short(text(prompt[i])) });
      sources.push([i]);
      marked.push(hasMarker(prompt[i], family));
    }
  }
  // A session's first message can carry a note, such as a named skill's text.
  if (!blocks.some((b) => b.k === "user" || b.k === "userc")) errors.push("no user message");
  const manual = marked.flatMap((m, n) => (m ? [n + 1] : []));
  return { blocks, manual, skillUser, sources, errors };
}

/** Abstracts every agent request, in send order. Title requests are a separate prefix and are left out. */
export function observe(requests: CapturedRequest[], family: Family): { observed: ObservedRequest[]; errors: string[] } {
  const observed: ObservedRequest[] = [];
  const errors: string[] = [];
  for (const request of requests.filter((r) => r.kind === "agent").sort((a, b) => a.seq - b.seq)) {
    const a = abstractRequest(request.body, family);
    for (const e of a.errors) errors.push(`request ${request.seq} (session ${request.session}): ${e}`);
    observed.push({ seq: request.seq, w: request.worktree, repo: request.repo, s: request.session, req: a.blocks, manual: a.manual, skillUser: a.skillUser });
  }
  return { observed, errors };
}

function word(value: string): string {
  if (!/^[a-z0-9_]+$/.test(value)) throw new Error(`refusing unsafe TLA+ string: ${JSON.stringify(value)}`);
  return `"${value}"`;
}

export function observedModule(observed: ObservedRequest[]): string {
  const record = (o: ObservedRequest) => {
    const req = o.req.map((b) => `[k |-> ${word(b.k)}, v |-> ${word(b.v)}]`).join(", ");
    return `  [w |-> ${word(o.w)}, repo |-> ${word(o.repo)}, s |-> ${o.s}, manual |-> {${o.manual.join(", ")}}, skill |-> ${o.skillUser},\n` +
      `   req |-> << ${req} >>]`;
  };
  return [
    "------------------------ MODULE PromptCacheObserved ------------------------",
    "(* Written by tests/tla/drivers/prompt_context/bridge.ts from a real run. *)",
    "Observed == <<",
    observed.map(record).join(",\n"),
    ">>",
    "=============================================================================",
    "",
  ].join("\n");
}

interface Derived { first: boolean; prev: ObservedRequest | null; changed: boolean; worktreeSeen: boolean; worktreeCtxChanged: boolean; repoSeen: boolean; anySeen: boolean }

/** The same derivations PromptCacheTrace makes, for coverage and the timeline. */
export function derive(observed: ObservedRequest[]): Derived[] {
  return observed.map((o, n) => {
    const earlier = observed.slice(0, n);
    const sameSession = earlier.filter((e) => e.s === o.s);
    const prev = sameSession.at(-1) ?? null;
    const ctx = (r: ObservedRequest) => r.req.find((b) => b.k === "ctx")?.v;
    // The messages that carry a change (Carrier "message").
    const carried = (r: ObservedRequest) => r.req.filter((b) => b.k === "asstc" || b.k === "userc").length;
    const sameWorktree = earlier.filter((e) => e.w === o.w);
    return {
      first: prev === null,
      prev,
      // The context changed: in the turn context, or on a message that carries it.
      changed: prev !== null && (ctx(prev) !== ctx(o) || carried(o) > carried(prev)),
      worktreeSeen: sameWorktree.length > 0,
      worktreeCtxChanged: sameWorktree.length > 0 && ctx(sameWorktree.at(-1)!) !== ctx(o),
      repoSeen: earlier.some((e) => e.repo === o.repo),
      anySeen: n > 0,
    };
  });
}

/** How many requests exercise each property's condition. */
export function coverage(observed: ObservedRequest[]): Record<Property, number> {
  const d = derive(observed);
  // The runtime block changed since the previous request of the session, as
  // when fx put a notice in the instructions mid-session.
  const rt = (r: ObservedRequest) => r.req.find((b) => b.k === "rt")?.v;
  const rtChanged = (x: Derived, n: number) => x.prev !== null && rt(x.prev) !== rt(observed[n]!);
  return {
    Budget: observed.length,
    SessionReuse: d.filter((x) => !x.first && !x.changed).length,
    CrossRepoReuse: d.filter((x, n) => x.first && x.anySeen && observed.slice(0, n).some((e) => e.w !== observed[n]!.w)).length,
    SameWorktreeReuse: d.filter((x) => x.first && x.worktreeCtxChanged).length,
    // A new worktree of a repository that already ran.
    WorktreeReuse: d.filter((x) => x.first && !x.worktreeSeen && x.repoSeen).length,
    ContextChangeKeepsStable: d.filter((x) => x.changed).length,
    // A request at or after a mid-session change: inserted, noted, carried or switched.
    MidSessionKeepsHistory: d.filter((x, n) => !x.first && (x.changed || rtChanged(x, n) ||
      [observed[n]!, x.prev!].some((r) => r.req.some((b) => MID_KINDS.has(b.k))))).length,
    PreviousFullyReused: d.filter((x, n) => !x.first && (x.changed || rtChanged(x, n) ||
      [observed[n]!, x.prev!].some((r) => r.req.some((b) => MID_KINDS.has(b.k))))).length,
  };
}

const MID_KINDS = new Set(["scoped", "skill", "note", "skilltext", "skillnote", "asstc", "userc"]);
const USER_KINDS = new Set(["user", "userc"]);
const MESSAGE_KINDS = new Set(["user", "userc", "asst", "asstc"]);

export interface TimelineRow {
  seq: number; s: number; w: string; first: boolean; changed: boolean;
  blocks: number; manual: number[]; breakpoints: number[]; read: number;
}

/** Diagnostic mirror of PromptCache's provider cache. TLC decides; this explains. */
export function simulate(observed: ObservedRequest[], family: Family): TimelineRow[] {
  const cache = new Set<string>();
  const key = (req: Block[], n: number) => JSON.stringify(req.slice(0, n));
  const d = derive(observed);
  return observed.map((o, n) => {
    const sorted = (xs: number[]) => [...new Set(xs)].sort((a, b) => a - b);
    const lastUser = Math.max(...o.req.flatMap((b, j) => (USER_KINDS.has(b.k) ? [j + 1] : [])));
    let bps: number[];
    let read = 0;
    if (family === "anthropic") {
      // PromptCache Hit: any written prefix up to the furthest breakpoint.
      bps = sorted([...o.manual, o.req.length, lastUser - 1]);
      for (let m = 1; m <= Math.max(...bps); m += 1) if (cache.has(key(o.req, m))) read = m;
      for (const bp of bps) cache.add(key(o.req, bp));
    } else {
      // PromptCache Lookup: only lookup candidates; the developer block end is written too.
      const instr = o.req.findIndex((b) => b.k === "rt") + 1;
      const eligible = o.req.flatMap((b, j) => (j + 1 > instr && MESSAGE_KINDS.has(b.k) ? [j + 1] : []));
      bps = sorted([...o.manual, Math.max(instr, ...eligible)]);
      for (const m of sorted([...bps, ...eligible, instr])) if (cache.has(key(o.req, m))) read = m;
      for (const bp of [...bps, instr]) cache.add(key(o.req, bp));
    }
    return { seq: o.seq, s: o.s, w: o.w, first: d[n]!.first, changed: d[n]!.changed, blocks: o.req.length, manual: o.manual, breakpoints: bps, read };
  });
}

export function timelineMarkdown(rows: TimelineRow[]): string {
  const lines = [
    "Diagnostic timeline, computed by bridge.ts simulate(); TLC gives the verdicts.",
    "Block order: tools, base, skills, project, mcp, turn context, runtime notes, then the conversation. Rules delivered",
    "mid-session ride on the tool result that reached them (asstc); before P6 they and a named skill's text added blocks before the turn context.",
    "",
    "| request | session | worktree | first | context changed | blocks | manual markers | all markers | blocks read |",
    "|---|---|---|---|---|---|---|---|---|",
  ];
  for (const r of rows) {
    lines.push(`| ${r.seq} | ${r.s} | ${r.w} | ${r.first ? "yes" : "no"} | ${r.changed ? "yes" : "no"} | ${r.blocks} | ` +
      `${r.manual.join(",") || "none"} | ${r.breakpoints.join(",")} | ${r.read} |`);
  }
  return `${lines.join("\n")}\n`;
}

function cfg(design: Design, family: Family, notes: boolean, invariants: string[]): string {
  return ["SPECIFICATION Spec", "CONSTANTS", `  Design = "${design}"`, `  Family = "${family}"`, `  Notes = ${notes ? "TRUE" : "FALSE"}`,
    `  Carrier = "message"`, "INVARIANTS",
    ...invariants.map((x) => `  ${x}`), ""].join("\n");
}

async function trace(dir: string, observed: ObservedRequest[], design: Design, family: Family, notes: boolean, invariants: string[]): Promise<TlcRun> {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "PromptCacheObserved.tla"), observedModule(observed));
  writeFileSync(join(dir, "PromptCacheTrace.cfg"), cfg(design, family, notes, invariants));
  return runTlc(dir, "PromptCacheTrace", "PromptCacheTrace.cfg", SPECS, tlaDir, ["-deadlock"]);
}

/**
 * Checks the observed requests against one design: conformance first, then
 * each property on the same replay. Writes every TLC run under `reports`.
 */
export interface CheckOptions {
  /** PromptCache Notes with Carrier "message": mid-session changes ride on the message that caused them. */
  notes?: boolean;
  properties?: readonly Property[];
}

export async function checkRuntime(
  observed: ObservedRequest[], design: Design, family: Family, reports: string, options: CheckOptions = {},
): Promise<RuntimeResult> {
  const notes = options.notes ?? false;
  const properties = options.properties ?? PROPERTIES;
  const cover = coverage(observed);
  const hashes: Record<string, string> = {};
  for (const spec of SPECS) hashes[spec] = sha(readFileSync(join(tlaDir, spec), "utf8"));
  const base: RuntimeResult = { version: 1, design, family, verdict: "INCONCLUSIVE", detail: "", requests: observed.length, coverage: cover, properties: {}, hashes };
  const missing = properties.filter((p) => cover[p] === 0);
  if (observed.length === 0 || missing.length > 0) {
    return { ...base, detail: observed.length === 0 ? "no requests" : `no request exercises ${missing.join(", ")}` };
  }
  hashes["PromptCacheObserved.tla"] = sha(observedModule(observed));
  const tag = notes ? `${design}-notes` : design;
  const conformance = await trace(join(reports, tag, "conforms"), observed, design, family, notes, ["Conforms", "ReplayIncomplete"]);
  base.conformanceLog = join(reports, tag, "conforms", "tlc.log");
  if (conformance.violated === "Conforms") return { ...base, verdict: "REJECTED", detail: `requests do not match the ${design} layout and markers` };
  if (conformance.violated !== "ReplayIncomplete") {
    return { ...base, verdict: "TOOL_ERROR", detail: `TLC exit ${conformance.exitCode}: ${conformance.output.slice(-400)}` };
  }
  for (const property of properties) {
    const dir = join(reports, tag, property);
    const run = await trace(dir, observed, design, family, notes, ["Conforms", property, "ReplayIncomplete"]);
    const verdict: PropertyVerdict = run.violated === "ReplayIncomplete" ? "HOLDS" : run.violated === property ? "VIOLATED" : "TOOL_ERROR";
    base.properties[property] = { verdict, log: join(dir, "tlc.log"), ...(verdict === "TOOL_ERROR" ? { detail: run.output.slice(-400) } : {}) };
  }
  return { ...base, verdict: "ACCEPTED", detail: `${observed.length} requests replayed` };
}

