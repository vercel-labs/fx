// Runtime scenarios for the launch-flag contract, and how each one maps onto
// a LaunchSelection scenario. The fake Gateway serves CATALOG; the chat route
// accepts exactly the models in TRUTH, like the real Gateway.

export type Path = "ask" | "interactive";
export type ModelReq = "none" | "exact" | "partial_unique" | "partial_ambiguous" | "unknown" | "private_hidden";
export type SpeedReq = "none" | "fast" | "ultrafast" | "off";
export type EffortReq = "none" | "supported" | "unsupported";
export type CatalogMode = "authenticated" | "anonymous" | "failed";
export type Outcome =
  | "sent" | "gateway_error" | "turn_error"
  | "rejected_model" | "rejected_fast" | "rejected_ultrafast" | "rejected_effort"
  | "unknown";
export type Notice = "model" | "fast" | "ultrafast" | "effort";

export const CONFIGURED = "openai/mfv-configured";
export const SUPPORTED_EFFORT = "high";
export const UNSUPPORTED_EFFORT = "minimal";

const efforts = (values: string[]) => [{ type: "effort", values }];
const price = { input: "0.000001", output: "0.000002" };

/** Fast, Ultra and three efforts. */
const FULL = {
  id: "openai/mfv-full", type: "language", owned_by: "openai", tags: ["tool-use", "reasoning"],
  fast_options: [{ type: "toggle" }], reasoning_options: efforts(["low", "medium", SUPPORTED_EFFORT]),
  pricing: { ...price, service_tiers: { priority: { input: "0.000002", output: "0.000004" }, ultrafast: { input: "0.00001", output: "0.00002" } } },
};
/** No Fast, no Ultra, two efforts. */
const plain = (id: string, owned_by: string) => ({
  id, type: "language", owned_by, tags: ["tool-use", "reasoning"],
  reasoning_options: efforts(["low", SUPPORTED_EFFORT]), pricing: { ...price },
});
const PLAIN = plain("anthropic/mfv-plain", "anthropic");
const TERRA_ONE = plain("openai/mfv-terra-one", "openai");
const TERRA_TWO = plain("openai/mfv-terra-two", "openai");
const CONFIGURED_ENTRY = plain(CONFIGURED, "openai");
/** Listed only to an authenticated catalog request. */
const PRIVATE = plain("team/mfv-private", "team");

export const PUBLIC_CATALOG = [FULL, PLAIN, TERRA_ONE, TERRA_TWO, CONFIGURED_ENTRY];
export const AUTHENTICATED_CATALOG = [...PUBLIC_CATALOG, PRIVATE];
export const TRUTH = new Set(AUTHENTICATED_CATALOG.map(entry => entry.id));

export interface Scenario {
  id: string;
  kind: "ideal" | "nonideal";
  path: Path;
  model: ModelReq;
  /** The --model text, when model is not "none". */
  raw?: string;
  /** The catalog ID the raw text should resolve to. */
  canonical?: string;
  speed: SpeedReq;
  effort: EffortReq;
  catalog: CatalogMode;
  /** Capabilities of the model fx would send. */
  fastCap: boolean;
  ultraCap: boolean;
  /** Interactive only: submit before the catalog arrives (slow catalog). */
  early: boolean;
}

const full = { fastCap: true, ultraCap: true };
const none = { fastCap: false, ultraCap: false };
const base = { speed: "none", effort: "none", catalog: "authenticated", early: false } as const;

export const SCENARIOS: Scenario[] = [
  // fx ask, ideal
  { id: "ask-exact", kind: "ideal", path: "ask", model: "exact", raw: FULL.id, canonical: FULL.id, ...base, ...full },
  { id: "ask-exact-fast", kind: "ideal", path: "ask", model: "exact", raw: FULL.id, canonical: FULL.id, ...base, speed: "fast", ...full },
  { id: "ask-exact-ultrafast", kind: "ideal", path: "ask", model: "exact", raw: FULL.id, canonical: FULL.id, ...base, speed: "ultrafast", ...full },
  { id: "ask-exact-effort", kind: "ideal", path: "ask", model: "exact", raw: FULL.id, canonical: FULL.id, ...base, effort: "supported", ...full },
  // fx ask, non-ideal
  { id: "ask-unknown", kind: "nonideal", path: "ask", model: "unknown", raw: "totally/not-a-real-model", ...base, ...none },
  { id: "ask-partial-unique", kind: "nonideal", path: "ask", model: "partial_unique", raw: "mfv-plain", canonical: PLAIN.id, ...base, ...none },
  { id: "ask-partial-ambiguous", kind: "nonideal", path: "ask", model: "partial_ambiguous", raw: "mfv-terra", ...base, ...none },
  { id: "ask-fast-unsupported", kind: "nonideal", path: "ask", model: "exact", raw: PLAIN.id, canonical: PLAIN.id, ...base, speed: "fast", ...none },
  { id: "ask-ultrafast-unsupported", kind: "nonideal", path: "ask", model: "exact", raw: PLAIN.id, canonical: PLAIN.id, ...base, speed: "ultrafast", ...none },
  { id: "ask-effort-unsupported", kind: "nonideal", path: "ask", model: "exact", raw: PLAIN.id, canonical: PLAIN.id, ...base, effort: "unsupported", ...none },
  { id: "ask-configured-fast-unsupported", kind: "nonideal", path: "ask", model: "none", ...base, speed: "fast", ...none },
  { id: "ask-private-anonymous", kind: "nonideal", path: "ask", model: "private_hidden", raw: PRIVATE.id, canonical: PRIVATE.id, ...base, catalog: "anonymous", ...none },
  { id: "ask-unknown-catalog-failed", kind: "nonideal", path: "ask", model: "unknown", raw: "totally/not-a-real-model", ...base, catalog: "failed", ...none },
  { id: "ask-fast-catalog-failed", kind: "nonideal", path: "ask", model: "exact", raw: FULL.id, canonical: FULL.id, ...base, speed: "fast", catalog: "failed", ...full },
  // interactive, ideal
  { id: "tui-exact-fast", kind: "ideal", path: "interactive", model: "exact", raw: FULL.id, canonical: FULL.id, ...base, speed: "fast", ...full },
  // interactive, non-ideal
  { id: "tui-unknown-fast", kind: "nonideal", path: "interactive", model: "unknown", raw: "totally/not-a-real-model", ...base, speed: "fast", ...none },
  { id: "tui-partial-unique", kind: "nonideal", path: "interactive", model: "partial_unique", raw: "mfv-plain", canonical: PLAIN.id, ...base, ...none },
  { id: "tui-ultrafast-unsupported", kind: "nonideal", path: "interactive", model: "exact", raw: PLAIN.id, canonical: PLAIN.id, ...base, speed: "ultrafast", ...none },
  { id: "tui-effort-unsupported", kind: "nonideal", path: "interactive", model: "exact", raw: PLAIN.id, canonical: PLAIN.id, ...base, effort: "unsupported", ...none },
  { id: "tui-private-anonymous", kind: "nonideal", path: "interactive", model: "private_hidden", raw: PRIVATE.id, canonical: PRIVATE.id, ...base, catalog: "anonymous", ...none },
  { id: "tui-fast-unsupported-early", kind: "nonideal", path: "interactive", model: "exact", raw: PLAIN.id, canonical: PLAIN.id, ...base, speed: "fast", early: true, ...none },
];

export function flagArgs(s: Scenario): string[] {
  const args: string[] = [];
  if (s.model !== "none") args.push("--model", s.raw!);
  if (s.speed === "fast") args.push("--fast");
  if (s.speed === "ultrafast") args.push("--ultrafast");
  if (s.speed === "off") args.push("--no-fast");
  if (s.effort === "supported") args.push("--effort", SUPPORTED_EFFORT);
  if (s.effort === "unsupported") args.push("--effort", UNSUPPORTED_EFFORT);
  return args;
}

/** LaunchSelection's model-name class for a model ID fx actually sent. */
/** No scenario passes CONFIGURED as --model, so the order below is unambiguous. */
export function nameClass(s: Scenario, sent: string): "configured" | "canonical" | "raw" | "other" {
  if (sent === CONFIGURED) return "configured";
  if (s.canonical && sent === s.canonical) return "canonical";
  if (s.raw && sent === s.raw) return "raw";
  return "other";
}

/**
 * Classifies an `fx ask` failure that sent no request from its stderr. Launch
 * rejections name the model; the turn-time Ultrafast failure does not.
 */
export function askRejection(stderr: string): Outcome | null {
  if (/^fx ask: (Unknown model "|Model "[^"]*" matches several catalog models)/m.test(stderr)) return "rejected_model";
  if (/^fx ask: Fast mode is not available for model "/m.test(stderr)) return "rejected_fast";
  if (/^fx ask: Ultrafast mode is not available for model "/m.test(stderr)) return "rejected_ultrafast";
  if (/^fx ask: Reasoning effort (is unavailable|"[^"]*" is not available)/m.test(stderr)) return "rejected_effort";
  return null;
}

/** Notice markers printed by interactive launch validation. */
export function noticesIn(text: string): Notice[] {
  const found = new Set<Notice>();
  if (/Unknown model "|matches several catalog models/.test(text)) found.add("model");
  if (/(^|[^a-z])Fast mode is not available for model/.test(text)) found.add("fast");
  if (/Ultrafast mode is not available for model/.test(text)) found.add("ultrafast");
  if (/Reasoning effort "[^"]*" is not available for model|Reasoning effort is unavailable for the active model/.test(text)) found.add("effort");
  return [...found].sort();
}
