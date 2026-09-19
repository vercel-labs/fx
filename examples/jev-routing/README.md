# Experimental Jev prompt and subagent routing

The native fx runtime routes each new user prompt and each assignment of an
auto-routed child. Both use the same Jev policy. The model remains stable through
the assignment's model/tool loop, normal retries and busy-child steering.
Persistent children reconsider when they become idle and accept another assignment.

```sh
# Parent prompts only. FX_MODEL also applies to resumed ask processes.
FX_MODEL=jev/auto /absolute/path/to/fx/zig-out/bin/fx ask --no-fast --json 'Explain this code.'

# Children only: parent is pinned, unspecified new child models use Jev.
FX_EXPERIMENT_JEV_SUBAGENT_ROUTING=1 /absolute/path/to/fx/zig-out/bin/fx ask --model moonshotai/kimi-k3 --no-fast 'Delegate the component work.'

# Both, including interactive mode:
FX_EXPERIMENT_JEV_SUBAGENT_ROUTING=1 /absolute/path/to/fx/zig-out/bin/fx --model jev/auto --no-fast
```

ACP accepts the same model ID at startup or through its existing model config
option. `jev/auto` is an fx selection mode; it is never sent as an inference
model to Gateway. A concrete parent or child model bypasses Jev. The child switch
affects creation defaults; existing pinned children remain pinned and existing
auto children remain automatic. A child can also explicitly request `jev/auto`.
All inference candidates use the current Gateway credential and team. Jev
evaluations can use a separate `FX_JEV_GATEWAY_API_KEY` and optional
`FX_JEV_GATEWAY_TEAM`, so evaluation billing does not move inference billing.
The dedicated key never inherits the inference team header.

Jev receives the current assignment, bounded role/objective excerpts and recent
conversation messages. This includes previous assistant text needed to interpret
short follow-ups. The packet is limited to 24 KB; assignments over 12 KB fall
back without evaluation. Excerpts are quoted classification evidence, never
permission authority. Execution still receives normal conversation history.
Model-specific prompt overlays and replay projection use the chosen model.

The policy classifies the current assignment into the existing 12 families and
routine/general/demanding requirements. It chooses Luna for routine work, Kimi
for general work, and Sol for demanding work; general debugging/review and
data/math also choose Sol. This is an unvalidated heuristic, not a prediction
of model success. Classification thresholds are 0.6 for family and 0.75 for
requirements.

Capability checks use the live catalog, current tools/images/effort/fast mode and
an estimate of the full known execution context plus a 32K-token reserve. The normal provider
request-capacity check remains authoritative. Unknown capabilities are ineligible.
`FX_JEV_ALLOWED_MODELS` restricts candidates using comma-separated exact IDs;
an empty value allows none. Account/provider access must also permit the models.
The commands above disable fast mode to measure model choice independently.

On low confidence, unavailable evaluation or invalid answers, retain the previous
eligible routed model when available, otherwise Kimi. A missing eligible fallback
fails closed. Evaluation has a ten-second maximum deadline and honors cancellation.
Paused recovery and manual compaction reuse the selected model without reclassification. Routing
choices are saved in optional turn metadata so resumed prompts preserve continuity.
Sessions created with this experiment require a build that understands that metadata.

Set `FX_TRACE_LOG` and include `quality` in `FX_TRACE_SCOPES` to record one
`event=jev_route` with JSON decision data per routing boundary: origin, selected
model, policy, classification probabilities, fallback reason, elapsed time and
available evaluation token counts. Child trace identity events join the decision
to child/session/work IDs. Evaluation billing is explicitly incomplete in the
usage ledger; unknown cost is not zero. CLI JSON reports the selected model and
normal notices show the decision in interactive output.

Live benchmark results remain pending. The JavaScript utility below remains
available for standalone classifier experiments; native fx needs no Node runtime.

# Standalone JavaScript classifier

Classify the initial task with `typesafe-ai/jev` through AI Gateway, then select
an eligible model using a frozen, deterministic policy. The reusable JavaScript
API also works outside fx. The launcher invokes `fx ask --model` once and keeps
that model for the session. Use the native mode above for prompt and subagent routing. This utility is not a managed Gateway
router. Compaction and hosted benchmark infrastructure are separate experiments.

This is a policy hypothesis, not a trained predictor of model success. The
12-family taxonomy and a routine/general/demanding rubric select among Kimi K3,
GPT 5.6 Luna and GPT 5.6 Sol. Low confidence or evaluator failure retains Kimi K3.
Explicit model choices bypass evaluation. Model availability, tool/vision
requirements and context limits are enforced before selection.

Requires Node 22+ and `AI_GATEWAY_API_KEY` or `VERCEL_OIDC_TOKEN` for inference.
Set `FX_JEV_GATEWAY_API_KEY` to bill only Jev evaluation to a separate account;
`FX_JEV_GATEWAY_TEAM` optionally scopes that evaluation credential.
The Gateway team must permit TypeSafe AI and each candidate model. No dependencies
or installation step are needed. The provider catalog is a dated snapshot, not
proof that the current account has access.

From this directory:

```sh
node --test test/*.test.mjs
printf 'Diagnose the deadlock in this scheduler.' | node src/cli.mjs route
printf 'Diagnose the deadlock in this scheduler.' | node src/cli.mjs run-fx --binary /absolute/path/to/fx/zig-out/bin/fx --trace /tmp/routing.json
```

`--model` supplies an explicit eligible model. `--policy` selects a policy file;
`--prompt-file` reads task text from a file. Otherwise input comes from stdin.
Routing decisions contain the policy hash, selected model, confidence and any
fallback. Provider errors are redacted. Evaluations use a fixed Gateway endpoint,
bounded responses, a 15-second deadline and zero-data-retention routing.

```js
import { route } from './src/router.mjs';
const decision = await route(task, policy, { tools: true, contextTokens: 24000 });
// Use decision.model with AI Gateway or an fx launcher.
```

No quality, latency or cost improvement has been established. Benchmark this
policy on held-out tasks and include classifier usage and fallback frequency.
