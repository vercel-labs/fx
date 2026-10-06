# Model routing for agent-cast work

Route bounded implementation tasks to a workhorse model, routine tasks to a
smaller model, and consequential design review to a stronger model. Evaluate
the result through task acceptance gates; the model's confidence is not a gate.

The following models are exposed by this session's collaboration tools.
Official OpenAI documentation checked on 6 October 2026 describes their roles.
These assignments are workload choices, not measured savings or a guarantee of
account-specific billing.

| Work | Assigned model | Initial effort | Escalation |
| --- | --- | --- | --- |
| Ledger checks, bounded schema changes, source inventories, fixture plumbing | `gpt-6-luna` | `low` or `medium` | Sol if the bounded task fails its contract after a repair |
| Typed contracts, cache implementation, adapters, runtime integration | `gpt-6.1-sol` | `medium`; `high` for ownership and concurrency | Astra for unresolved correctness or architectural tradeoffs |
| Exact authority, effect equivalence, recovery, uncertain mutations, milestone review | `gpt-6-astra` | `high` | Coordinator resolves findings with concrete receipts |
| Integration and operator handoff in this thread | Current session | Inherited | Delegate independent bounded work rather than replaying the thread |

[GPT-6 Luna](https://developers.openai.com/api/docs/models/gpt-6-luna) is described
as an efficient model for focused, high-volume work.
[GPT-6.1 Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol) is positioned
for complex work at lower cost than Astra. Use
[GPT-6 Astra](https://developers.openai.com/api/docs/models/gpt-6-astra) for demanding
reasoning and coding review. Compare quality and cost on these tasks rather
than assuming a universal ranking.

## Token and cost controls

1. Start delegated workers with a short task brief and no full-history fork.
2. Give each worker an explicit source allowlist and one owned file scope.
3. Reuse verified findings; do not repeat the landscape research for each task.
4. Limit a scope to two repair rounds before coordinator review and reassignment.
5. Return changed files, exact check results, unresolved issues, and ownership
   requirements in the handoff.
6. Run deterministic tooling for formatting, validation, and fixtures. Use model
   review for the decisions those checks cannot establish.
7. Keep actual usage fields `null` when collaboration tools expose no token
   receipts. Never estimate them from file size, elapsed time, or prose length.

Smaller briefs reduce token volume. Model selection changes the expected cost
of that work; it does not itself reduce the number of tokens. Track retries and
accepted task outcomes when comparing routing policies.

The session currently has no user-specified spending ceiling. The policy uses
bounded task batches. A hard budget needs provider usage receipts and an
enforceable accounting boundary; this ledger alone does not supply either.

## Assignment receipt

The initial delegation used:

| Worker | Task | Requested model |
| --- | --- | --- |
| `agent_cast_ledger_tools` | Read-only ledger checker and bounded validation repair | `gpt-6-luna`, `medium` |
| `agent_cast_core` | Planner contracts, immutable executor, CLI, and compiler repair | `gpt-6.1-sol`, `high` |
| `agent_cast_contract_review` | Exact binding, ownership, and equivalence review | `gpt-6-astra`, `high` |

These are observed assignment settings. Provider token counts and actual billed
cost were not returned by the collaboration interface and remain unknown.
