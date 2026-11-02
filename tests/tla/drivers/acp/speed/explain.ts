// Diagnostic only: prints each observed step beside the state the spec
// predicts, to explain a TLC rejection. TLC remains the oracle; this mirrors
// tests/tla/acp/AcpSpeed.tla for readability and assumes a deterministic start.
//
//   bun tests/tla/drivers/acp/speed/explain.ts <report>/traces/<name>
import { join } from "node:path";

const SUP_FAST = new Set(["openai/gpt-6-astra", "openai/gpt-5.6-priority"]);
const SUP_ULTRA = new Set(["openai/gpt-6-astra"]);

const dir = process.argv[2];
if (!dir) throw new Error("usage: bun tests/tla/drivers/acp/speed/explain.ts <trace dir>");
const plan = await Bun.file(join(dir, "plan.json")).json();
const observations = await Bun.file(join(dir, "observations.json")).json();

let model: string = plan.initialModel;
let fast: boolean = plan.defaultFast;
let ultra = false;
let prompted = false;
const short = (m: string) => m.split("/").pop();
const view = () => `${short(model)} fast=${SUP_FAST.has(model) ? fast : "absent"} ultra=${SUP_ULTRA.has(model) ? ultra : "absent"}`;

console.log(`init ${short(plan.initialModel)} defaultFast=${plan.defaultFast}`);
for (const [index, o] of observations.entries()) {
  let expectOk = true;
  let expectSpeed = "none";
  switch (o.op) {
    case "fast": {
      const b = o.arg === "true";
      if (b && !SUP_FAST.has(model)) expectOk = false;
      else { fast = b; if (b) ultra = false; }
      break;
    }
    case "ultrafast": {
      const b = o.arg === "true";
      if (b && !SUP_ULTRA.has(model)) expectOk = false;
      else { ultra = b; if (b) fast = false; }
      break;
    }
    case "model":
      model = o.arg; fast = fast && SUP_FAST.has(model); ultra = ultra && SUP_ULTRA.has(model);
      break;
    case "unknown":
      expectOk = false;
      break;
    case "prompt":
      prompted = true;
      expectSpeed = ultra ? "ultrafast" : fast && SUP_FAST.has(model) ? "fast" : "standard";
      break;
  }
  const seen = o.hasView ? `${short(o.view.model)} fast=${o.view.fast} ultra=${o.view.ultra}` : "";
  const want = o.hasView ? view() : "";
  const mismatch = o.ok !== expectOk || (o.op === "prompt" && o.speed !== expectSpeed) || (o.hasView && seen.replace(/"/g, "") !== want);
  console.log(`${mismatch ? "!!" : "  "} ${String(index + 1).padStart(2)} ${o.op.padEnd(9)} ${String(o.arg).split("/").pop()!.padEnd(16)} ok=${o.ok} speed=${o.speed.padEnd(9)} seen[${seen}]${mismatch ? ` want[ok=${expectOk} speed=${expectSpeed} ${want}]` : ""}${prompted ? "" : " (before first prompt)"}`);
}
