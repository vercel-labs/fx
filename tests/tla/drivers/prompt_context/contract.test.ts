// Runs the real fx binary through the sessions the prompt-cache model covers,
// records every request, and has TLC replay them through the model
// (tests/tla/prompt_context/PromptCache.tla). No model calls: a local fake
// Gateway serves scripted tool calls and replies.
//
// 1. With an Anthropic model the binary must conform to exactly one modeled
//    design, the proposed one, and every design property must hold on the
//    observed requests, as check.sh's exhaustive check of that design says.
//    Each design is checked with mid-session changes riding on the message
//    that caused them (PromptCache Notes, Carrier "message"), as fx sends an
//    agent branch switch on the switching step's tool result.
// 2. With OpenAI GPT-5.6 or later the same holds under the model's OpenAI
//    rules, with the markers in OpenAI's syntax.
// 3. With an older OpenAI model fx sends no markers of its own: the binary
//    must conform to the current design. It is replayed under the OpenAI
//    rules, so a stray OpenAI marker fails as a match to the proposed design;
//    that model's own caching rules are not modeled.
// 4. Controls: a planted marker, a marker in the other family's syntax,
//    missing coverage and empty evidence must not be accepted.
//
// Evidence goes to FX_TLA_OUT or a temp folder: activity.jsonl (every driver
// action), requests.jsonl and requests/ (every Gateway request in full),
// observed.json, timeline.md, and one TLC log per check under tlc/.
import { test } from "bun:test";
import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { artifacts, binary, targetHelpers } from "../lib/context";
import {
  PROPERTIES, checkRuntime, observe, simulate, timelineMarkdown,
  type Design, type Family, type ObservedRequest, type RuntimeResult,
} from "./bridge";
import { activityLogger, collectObservations, type CapturedRequest } from "./scenarios";

const helpers = await targetHelpers();
const log = activityLogger(artifacts);
const TIMEOUT = 900_000;
const ANTHROPIC = "anthropic/claude-sonnet-5.5";
const GPT = "openai/gpt-6.1-sol";
const OTHER: string = helpers.FAKE_GATEWAY_MODEL;
const familyOf = (model: string): Family => (model.startsWith("anthropic/") ? "anthropic" : "openai");
const slug = (model: string) => model.replace(/[^a-z0-9]+/gi, "-");
const folder = (model: string) => {
  const dir = join(artifacts, slug(model));
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  return dir;
};

// Property verdicts from check.sh's exhaustive check of each design. A
// branch switch rides on a message, so even without fx markers the stable
// instructions are read after it (p6-implicit-context.cfg).
const EXPECTED: Record<Design, Record<string, string>> = {
  current: {
    Budget: "HOLDS", SessionReuse: "HOLDS", CrossRepoReuse: "VIOLATED",
    SameWorktreeReuse: "VIOLATED", WorktreeReuse: "VIOLATED", ContextChangeKeepsStable: "HOLDS",
  },
  proposed: {
    Budget: "HOLDS", SessionReuse: "HOLDS", CrossRepoReuse: "HOLDS",
    SameWorktreeReuse: "HOLDS", WorktreeReuse: "HOLDS", ContextChangeKeepsStable: "HOLDS",
  },
};

const capturedByModel = new Map<string, CapturedRequest[]>();
const observedByModel = new Map<string, Promise<ObservedRequest[]>>();
function observations(model: string): Promise<ObservedRequest[]> {
  if (!observedByModel.has(model)) {
    observedByModel.set(model, (async () => {
      const dir = folder(model);
      log("run_start", { binary, model, artifacts: dir });
      const capture = await collectObservations({ binary, helpers, artifacts: dir, model });
      for (const session of capture.sessions) {
        assert.equal(session.exitCode, 0, `session ${session.session} exited ${session.exitCode}; see ${session.stderrFile}`);
        assert.equal(session.timedOut, false, `session ${session.session} timed out`);
      }
      capturedByModel.set(model, capture.requests);
      const family = familyOf(model);
      const { observed, errors } = observe(capture.requests, family);
      writeFileSync(join(dir, "observed.json"), JSON.stringify(observed, null, 2), { mode: 0o600 });
      writeFileSync(join(dir, "timeline.md"), timelineMarkdown(simulate(observed, family)), { mode: 0o600 });
      log("observed", { model, family, requests: observed.length, abstraction_errors: errors });
      assert.deepEqual(errors, [], "every request must match the modeled layout");
      return observed;
    })());
  }
  return observedByModel.get(model)!;
}

const verdicts = new Map<string, Promise<RuntimeResult>>();
function verdict(model: string, design: Design): Promise<RuntimeResult> {
  const key = `${model} ${design}`;
  if (!verdicts.has(key)) {
    verdicts.set(key, (async () => {
      const dir = folder(model);
      const result = await checkRuntime(await observations(model), design, familyOf(model), join(dir, "tlc"), { notes: true });
      writeFileSync(join(dir, `${design}-design.json`), JSON.stringify(result, null, 2), { mode: 0o600 });
      log("design_checked", { model, design, verdict: result.verdict, detail: result.detail, properties: result.properties });
      return result;
    })());
  }
  return verdicts.get(key)!;
}

function explain(result: RuntimeResult): string {
  return `${result.design} ${result.verdict}: ${result.detail}\ncoverage: ${JSON.stringify(result.coverage)}\n` +
    `properties: ${JSON.stringify(result.properties)}\nartifacts: ${artifacts}`;
}

async function conformingDesign(model: string): Promise<RuntimeResult> {
  const [current, proposed] = await Promise.all([verdict(model, "current"), verdict(model, "proposed")]);
  const accepted = [current, proposed].filter((r) => r.verdict === "ACCEPTED");
  assert.equal(accepted.length, 1, `${model}: expected exactly one design to match\n${explain(current)}\n${explain(proposed)}`);
  const result = accepted[0]!;
  for (const property of PROPERTIES) {
    assert.equal(result.properties[property]?.verdict, EXPECTED[result.design][property], `${model} ${property}: ${explain(result)}`);
  }
  writeFileSync(join(folder(model), "conforming-design.txt"), `${result.design}\n`, { mode: 0o600 });
  log("conforming_design", { model, design: result.design });
  return result;
}

test("with an Anthropic model, real fx conforms to the proposed design", async () => {
  const result = await conformingDesign(ANTHROPIC);
  assert.equal(result.design, "proposed", `fx sends the stable cache markers\n${explain(result)}`);
}, TIMEOUT);

test("with GPT-5.6 or later, real fx conforms to the proposed design", async () => {
  const result = await conformingDesign(GPT);
  assert.equal(result.design, "proposed", `fx sends the stable cache breakpoints\n${explain(result)}`);
}, TIMEOUT);

test("with an older model, real fx sends no markers of its own", async () => {
  const result = await conformingDesign(OTHER);
  assert.equal(result.design, "current", `only Anthropic and GPT-5.6 or later take fx markers\n${explain(result)}`);
}, TIMEOUT);

test("bridge rejects a planted marker, missing coverage and empty evidence", async () => {
  const observed = await observations(ANTHROPIC);
  const design: Design = "proposed";
  const reports = join(folder(ANTHROPIC), "tlc");

  // A marker on the skills block, which no design places.
  const planted: ObservedRequest[] = structuredClone(observed);
  planted[0]!.manual = [...new Set([...planted[0]!.manual, 3])].sort((a, b) => a - b);
  const rejected = await checkRuntime(planted, design, "anthropic", join(reports, "control-planted"), { notes: true });
  log("control", { control: "planted_marker", verdict: rejected.verdict });
  assert.equal(rejected.verdict, "REJECTED", explain(rejected));

  // Without the sessions after the branch switches, nothing exercises
  // SameWorktreeReuse or ContextChangeKeepsStable.
  const partial = observed.filter((o) => o.s < 4);
  const missing = await checkRuntime(partial, design, "anthropic", join(reports, "control-partial"), { notes: true });
  log("control", { control: "missing_coverage", verdict: missing.verdict, detail: missing.detail });
  assert.equal(missing.verdict, "INCONCLUSIVE", explain(missing));

  const empty = await checkRuntime([], design, "anthropic", join(reports, "control-empty"), { notes: true });
  log("control", { control: "empty", verdict: empty.verdict });
  assert.equal(empty.verdict, "INCONCLUSIVE", explain(empty));

  // GPT requests read as Anthropic ones: each OpenAI marker is an error, not a
  // block the abstraction quietly drops.
  await observations(GPT);
  const foreign = observe(capturedByModel.get(GPT)!, "anthropic").errors;
  log("control", { control: "foreign_marker", errors: foreign.length });
  assert.ok(foreign.some((e) => e.includes("carries an openai marker on an anthropic request")), `foreign markers: ${JSON.stringify(foreign)}`);
}, TIMEOUT);
