// A fake AI Gateway that checks preserved reasoning the way Claude 4.6+ and
// OpenAI GPT-6+ do, for provider-compaction.test.ts and the TLA+ driver in
// tests/tla/drivers/compaction/.
//
// Every reply's reasoning is signed with a SIG_<label> value and bound to the
// request that produced it. A later request that sends that reasoning after
// anything else, with the provider's own blocks read as the conversation they
// stand for, is an edit: the fake answers it with the provider's 400. The
// compaction request (providerOptions.anthropic.compaction or
// openai.compactionTrigger) is answered with frames recorded from AI Gateway
// (fixtures/provider-compaction/, AI SDK streamText, test billing lane), each
// with its own block key, or with the failure the caller asks for. A model
// outside those two families gets unsigned reasoning and no check, as a
// provider without preserved reasoning answers.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import type { FakeGatewayModel } from "./tmux-helpers";

const { fakeGatewayFinalText, fakeGatewaySse, startDynamicFakeGateway } = await import("./tmux-helpers");

const FIXTURES = join(import.meta.dir, "fixtures/provider-compaction");
const SIGNATURE = /SIG_[A-Za-z0-9_]+/g;
const CACHE_MARKERS = new Set(["cacheControl", "promptCacheBreakpoint"]);

export type Message = { role: string; content: unknown; providerOptions?: unknown };
export type Body = { prompt: Message[]; tools?: unknown[]; toolChoice?: { type?: string }; providerOptions?: Record<string, any> };

export type FamilyName = "anthropic" | "openai";

export type Family = {
  name: FamilyName;
  model: string;
  signed: (signature: string) => Record<string, unknown>;
  /** The block key of a part fx sends back, or null for any other part. */
  blockKey: (part: any) => string | null;
  /** A recorded compaction reply whose block carries `key`. */
  compactionReply: (key: string) => string;
};

function frames(sse: string): any[] {
  return sse.split("\n").filter((line) => line.startsWith("data: {")).map((line) => JSON.parse(line.slice(6)));
}

const anthropicSse = readFileSync(join(FIXTURES, "anthropic-compaction.sse"), "utf8");
const openaiSse = readFileSync(join(FIXTURES, "openai-compaction.sse"), "utf8");
const anthropicSignature: string = frames(anthropicSse).find((frame) => frame.type === "text-start")!.providerMetadata.anthropic.signature;
const openaiBlock = frames(openaiSse).find((frame) => frame.kind === "openai.compaction")!.providerMetadata.openai;

export const FAMILIES: Record<FamilyName, Family> = {
  anthropic: {
    name: "anthropic",
    model: "anthropic/claude-fable-5.2",
    signed: (signature) => ({ anthropic: { signature } }),
    blockKey: (part) => (part?.type === "text" && part?.providerOptions?.anthropic?.type === "compaction" ? part.providerOptions.anthropic.signature ?? null : null),
    compactionReply: (key) => anthropicSse.split(anthropicSignature).join(key),
  },
  openai: {
    name: "openai",
    model: "openai/gpt-6.1-sol",
    signed: (signature) => ({ openai: { reasoningEncryptedContent: signature } }),
    blockKey: (part) => (part?.type === "custom" && part?.kind === "openai.compaction" ? part.providerOptions?.openai?.itemId ?? null : null),
    compactionReply: (key) => openaiSse.split(openaiBlock.itemId).join(key).split(openaiBlock.encryptedContent).join(`sealed-${key}`),
  },
};

export function familyOf(model: string): Family {
  return model.startsWith("openai/") ? FAMILIES.openai : FAMILIES.anthropic;
}

/** Whether the model binds its reasoning to what came before it. */
export function bindsReasoning(model: string): boolean {
  return model.startsWith("anthropic/") || model.startsWith("openai/");
}

export function withoutCacheMarkers(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(withoutCacheMarkers);
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [key, inner] of Object.entries(value as Record<string, unknown>)) {
      if (CACHE_MARKERS.has(key)) continue;
      const next = withoutCacheMarkers(inner);
      if (next && typeof next === "object" && !Array.isArray(next) && Object.keys(next).length === 0) continue;
      out[key] = next;
    }
    return out;
  }
  return value;
}

export function leadingSystem(prompt: Message[]): number {
  let index = 0;
  while (index < prompt.length && prompt[index]!.role === "system") index += 1;
  return index;
}

export function isCompactionRequest(body: Body): boolean {
  return body.providerOptions?.anthropic?.compaction !== undefined || body.providerOptions?.openai?.compactionTrigger === true;
}

/** fx's own summary: its notes request, after the conversation or alone. */
export function isFxSummaryRequest(body: Body): boolean {
  return JSON.stringify(body.prompt).includes("You write compaction notes");
}

export function lastUserText(body: Body): string {
  const user = [...body.prompt].reverse().find((message: Message) => message.role === "user");
  return JSON.stringify(user?.content ?? "");
}

/** The signatures one message carries. */
export function signaturesOf(message: Message): string[] {
  return JSON.stringify(message.content).match(SIGNATURE) ?? [];
}

/** The block key one message carries, for any family. */
export function blockKeyOf(message: Message): string | null {
  if (message.role !== "assistant" || !Array.isArray(message.content)) return null;
  for (const part of message.content as unknown[]) {
    const key = FAMILIES.anthropic.blockKey(part) ?? FAMILIES.openai.blockKey(part);
    if (key !== null) return key;
  }
  return null;
}

function usage(body: string) {
  return { inputTokens: { total: Math.ceil(body.length / 4) }, outputTokens: { total: 5 } };
}

function signedReasoning(family: Family | null, label: string, text: string): object[] {
  const id = `reasoning_${label}`;
  return [
    { type: "reasoning-start", id },
    { type: "reasoning-delta", id, delta: text },
    family ? { type: "reasoning-end", id, providerMetadata: family.signed(`SIG_${label}`) } : { type: "reasoning-end", id },
  ];
}

/** A reply: a shell call that echoes, or the turn's final answer. `hold`
 * never answers; `overflow` refuses the request for its size. */
export type StepReply = { kind: "tool"; text?: string } | { kind: "final"; text: string } | { kind: "hold" } | { kind: "overflow" };

/** How the provider answers a compaction request. `hold` never answers. */
export type CompactionReply =
  | { kind: "block" }
  | { kind: "status"; status: number }
  | { kind: "no_block" }
  | { kind: "answer" }
  | { kind: "empty" }
  | { kind: "cut" }
  | { kind: "oversized" }
  | { kind: "hold" };

export type Observed = {
  index: number;
  model: string;
  kind: "agent" | "compaction" | "fx_summary";
  body: Body;
  /** For a compaction answered with a block, its key. */
  block?: string;
  /** Signatures the reply carried. */
  signatures: string[];
};

export type ProviderGatewayOptions = {
  models: FakeGatewayModel[];
  /** The model fx asks for when a request carries no model header. */
  defaultModel: string;
  step: (request: Observed) => StepReply;
  compaction: (request: Observed) => CompactionReply;
  /** Called when a held compaction or step request arrives. */
  onHold?: (request: Observed) => void;
};

export function startProviderGateway(options: ProviderGatewayOptions) {
  const origins = new Map<string, { family: FamilyName; prompt: unknown[]; tools: unknown }>();
  const blocks = new Map<string, { family: FamilyName; covers: unknown[] }>();
  const edits: string[] = [];
  const observed: Observed[] = [];
  const counts = { provider: 0, fx: 0, blocks: 0 };
  let gateway: ReturnType<typeof startDynamicFakeGateway>;

  const canonical = (family: Family, prompt: Message[]): unknown[] => {
    const out: unknown[] = [];
    for (const message of prompt) {
      const key = blockKeyOf(message);
      if (key !== null && blocks.get(key)?.family === family.name) out.push(...blocks.get(key)!.covers);
      else out.push(withoutCacheMarkers(message));
    }
    return out;
  };

  const reject = (message: string) => new Response(JSON.stringify({ error: { type: "invalid_request_error", message } }), { status: 400, headers: { "content-type": "application/json" } });

  gateway = startDynamicFakeGateway(async (raw: string) => {
    const body = JSON.parse(raw) as Body;
    const model = gateway.requests.at(-1)?.headers.get("ai-language-model-id") ?? options.defaultModel;
    const family = familyOf(model);
    const binds = bindsReasoning(model);
    const kind: Observed["kind"] = isCompactionRequest(body) ? "compaction" : isFxSummaryRequest(body) ? "fx_summary" : "agent";
    const request: Observed = { index: observed.length, model, kind, body, signatures: [] };
    observed.push(request);
    for (const [index, message] of binds ? body.prompt.entries() : []) {
      const key = blockKeyOf(message);
      if (key !== null && blocks.get(key)?.family !== family.name) {
        edits.push(`request ${request.index}: block ${key} sent to ${model} at prompt.${index}`);
        return reject(`messages.${index}: a compaction block this model did not write.`);
      }
      if (message.role !== "assistant") continue;
      for (const signature of signaturesOf(message)) {
        const origin = origins.get(signature);
        if (!origin) continue;
        if (origin.family !== family.name) {
          edits.push(`request ${request.index}: ${signature} from ${origin.family} sent to ${model} at prompt.${index}`);
          continue;
        }
        const before = canonical(family, body.prompt.slice(0, index));
        if (Bun.deepEquals(before, origin.prompt, true) && Bun.deepEquals(withoutCacheMarkers(body.tools ?? []), origin.tools, true)) continue;
        edits.push(`request ${request.index}: ${signature} at prompt.${index}`);
        return reject(`messages.${index}: Invalid \`signature\` in \`thinking\` block.`);
      }
    }
    if (kind === "compaction") {
      counts.provider += 1;
      const answer = options.compaction(request);
      switch (answer.kind) {
        case "block": {
          counts.blocks += 1;
          const key = `BLK_${counts.blocks}_${family.name}`;
          // The block stands for the conversation it summarized, after the
          // instructions that stay in front of it.
          blocks.set(key, { family: family.name, covers: canonical(family, body.prompt).slice(leadingSystem(body.prompt)) });
          request.block = key;
          return new Response(family.compactionReply(key), { headers: { "content-type": "text/event-stream" } });
        }
        case "status":
          return new Response(JSON.stringify({ error: { type: "overloaded_error", message: "Overloaded" } }), { status: answer.status, headers: { "content-type": "application/json" } });
        case "no_block":
          return fakeGatewaySse([{ type: "text-delta", id: "t", delta: "I cannot summarize this." }, { type: "finish", finishReason: { unified: "stop", raw: "end_turn" }, usage: usage(raw) }]);
        case "answer":
          // The model answered the conversation, with its signed reasoning,
          // instead of compacting it.
          return fakeGatewaySse([
            ...signedReasoning(family, `answer${request.index}`, "Answer the question."),
            { type: "text-delta", id: "t", delta: "Here is my answer." },
            { type: "finish", finishReason: { unified: "stop", raw: "end_turn" }, usage: usage(raw) },
          ]);
        case "empty":
          return fakeGatewaySse([{ type: "finish", finishReason: { unified: "stop", raw: "end_turn" }, usage: usage(raw) }]);
        case "cut":
          return new Response(family.compactionReply("BLK_cut").split("\n").filter((line) => !line.includes("\"finish\"")).join("\n").replace(/data: \[DONE\]\n*/g, ""), { headers: { "content-type": "text/event-stream" } });
        case "oversized": {
          const huge = "x".repeat(4 * 1024 * 1024 + 16);
          return fakeGatewaySse([
            { type: "custom", kind: "openai.compaction", providerMetadata: { openai: { type: "compaction", itemId: "BLK_huge", encryptedContent: huge } } },
            { type: "text-start", id: "0", providerMetadata: { anthropic: { type: "compaction", signature: "BLK_huge" } } },
            { type: "text-delta", id: "0", delta: huge },
            { type: "text-end", id: "0" },
            { type: "finish", finishReason: family.name === "anthropic" ? { unified: "other", raw: "compaction" } : { unified: "stop" }, usage: usage(raw) },
          ]);
        }
        case "hold":
          options.onHold?.(request);
          return new Promise<Response>(() => {});
      }
    }
    if (kind === "fx_summary") {
      counts.fx += 1;
      return fakeGatewayFinalText("Turn 1\nIn between: none");
    }
    const answer = options.step(request);
    if (answer.kind === "hold") {
      options.onHold?.(request);
      return new Promise<Response>(() => {});
    }
    if (answer.kind === "overflow") {
      return Response.json({ error: { type: "invalid_request_error", code: "context_length_exceeded", message: "The request exceeds the context window." } }, { status: 400 });
    }
    const label = `s${request.index}`;
    if (binds) request.signatures.push(`SIG_${label}`);
    const reasoning = signedReasoning(binds ? family : null, label, answer.kind === "tool" ? "Run the command." : "Answer now.");
    const frames = answer.kind === "tool"
      ? [
          ...reasoning,
          ...(answer.text ? [{ type: "text-delta", id: `text_${label}`, delta: answer.text }] : []),
          { type: "tool-call", toolCallId: `call_${label}`, toolName: "shell", input: JSON.stringify({ request: { action: "run", command: "echo ok", yield_time_ms: 2000 } }) },
          { type: "finish", finishReason: { unified: "tool-calls", raw: "tool_use" }, usage: usage(raw) },
        ]
      : [
          ...reasoning,
          { type: "text-delta", id: `answer_${label}`, delta: answer.text },
          { type: "finish", finishReason: { unified: "stop", raw: "end_turn" }, usage: usage(raw) },
        ];
    if (binds) origins.set(`SIG_${label}`, { family: family.name, prompt: canonical(family, body.prompt), tools: withoutCacheMarkers(body.tools ?? []) });
    return fakeGatewaySse(frames);
  }, { models: options.models });

  return { gateway, edits, observed, counts, blocks };
}
