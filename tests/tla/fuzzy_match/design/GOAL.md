# Goal

## Problem

Twelve places in fx filter a list as the user types, and each one has its own matcher (`CONTEXT.md`, Surfaces). They disagree. The Models menu matches words across the provider and model and accepts fuzzy letters, `/` commands match only a case-sensitive prefix or substring, skills rank a name prefix above other text, `/resume` and `/mcp` need the query as one unbroken substring, and `/help` and `/settings` need each word to appear somewhere. A query that finds a model finds nothing in the next menu, and every new surface invites another matcher.

## Outcome

One pure engine, `src/core/shared/fuzzy_match.zig`, decides whether an item matches a query and how well. Every surface in `CONTEXT.md` calls it instead of its own matcher. Each surface keeps its own base order, grouping, and windowing; the engine only classifies.

```zig
pub const Tier = enum {
    fuzzy, words, substring, prefix, exact,
    /// `substring` or better: the whole query as typed (R3, R11).
    pub fn isAsTyped(tier: Tier) bool;
};

pub const Field = struct {
    text: []const u8,
    kind: Kind = .name,
    pub const Kind = enum { name, text };
};

pub const Match = struct { tier: Tier, field: usize };

/// null when `query` does not match. `fields` must not be empty.
pub fn match(query: []const u8, fields: []const Field) ?Match;

/// The most fields a ranked listing orders by: a ranked match's `field` is
/// below it.
pub const ranked_field_limit = 8;

/// A ranked listing (R10) over a caller's base positions, without
/// allocating. `Context` has `fn matchAt(self, position: usize) ?Match`.
pub fn Ranking(comptime Context: type) type; // count, at, rankOf, iterator

/// A filtered listing (R11) over the same kind of context.
pub fn Filter(comptime Context: type) type; // init, keeps, count, at
```

`Ranking` is the one implementation of R10 and `Filter` the one implementation of R11, so no surface sorts or falls back its own way. A caller whose base order is not its item order, such as skills by source group, maps positions to items in `matchAt`.

`field` is the index into `fields`. No match is `null`, so `Tier` has no `none`; the model writes it as tier `none`. The engine imports nothing outside `src/core/shared/`: `std`, `display_width.zig` to decode UTF-8 as `AGENTS.md` requires, and `ascii_case.zig` for ASCII case-insensitive search, which `text_utils.zig` shares. It allocates nothing and keeps no state.

## Rules

The model in `spec/FuzzyMatch.tla` defines these rules, and each check cites them by ID.

| ID | Rule |
| --- | --- |
| R1 | Tiers rank `exact > prefix > substring > words > fuzzy`. `none` is no match. |
| R2 | The query is trimmed of spaces, tabs, carriage returns, and newlines at both ends. An empty trimmed query matches every item as `exact` on field 0, so a caller's own order shows through. |
| R3 | Whole query: a `name` field gives `exact` when it equals the query and `prefix` when it starts with it; any field gives `substring` when it contains it. The best tier wins, and ties go to the lowest field index. |
| R4 | Words: the query splits at whitespace, and a word with no word characters is ignored. A word matches a `name` field when its word characters appear consecutively among the field's word characters, so punctuation on either side is ignored. It matches a `text` field when the field contains the word as typed. When every word matches, the item matches as `words`. |
| R5 | Fuzzy: a word that does not match by R4 still matches a `name` field when its word characters appear in order in the field, the first one at the start of a field word. When every word matches by R4 or R5 and at least one only by R5, the item matches as `fuzzy`. `text` fields never match by R5. |
| R6 | A non-empty trimmed query with no word characters, such as `-` or `//`, matches only by R3, as typed, and otherwise matches nothing. |
| R7 | For `words` and `fuzzy`, `field` is the lowest index among the fields that gave each word its best match. |
| R8 | ASCII letters and digits are word characters, and letters compare without case. Every other ASCII byte separates words. Every other character, meaning a valid UTF-8 sequence or one byte that does not start one, is a word character compared exactly. No match splits a UTF-8 sequence. |
| R9 | A field word starts at the first character, after a separator, and where a digit follows a non-digit or a non-digit follows a digit, so `gpt-4o` has the words `gpt`, `4`, and `o`. |
| R10 | A ranked surface lists its matches by tier, best first, then by `field`, lowest first, and otherwise in its own base order. |
| R11 | A filtered surface keeps its base order. It lists the items that match as typed, `substring` or better, when any does, and otherwise every item that matches. |
| R12 | A trimmed query of more than 64 characters, counted as R8 counts them, matches only by R3, as typed, and otherwise matches nothing. |

## Laws

The model checks each law over every query and field it can build from its alphabet. The laws are stated declaratively, apart from the step-by-step definition the code mirrors, so a wrong step breaks a law.

| ID | Law | Property in `MCFuzzyMatch.tla` |
| --- | --- | --- |
| L1 | The step-by-step `Match` equals the declarative definition of R1 to R9. | `MatchIsDeclarative` |
| L2 | Narrowing: once a query has a word character, or while it is blank, typing more never adds a match, so every such prefix of a matching query matches too. A prefix of only punctuation matches only as typed (L10). | `Narrowing` |
| L3 | Nothing that matches today stops matching: an item with a field that contains the whole query matches as `substring` or better, and, once the query has a word character and at most 64 characters (R12), an item where every query word appears in some field matches. | `KeepsSubstringMatches`, `KeepsTokenMatches` |
| L4 | Case never matters for ASCII letters. | `CaseInsensitive` |
| L5 | A `text` field never gives `exact`, `prefix`, or a match by R5. | `TextNeverFuzzy` |
| L6 | Adding a field never lowers an item's tier, and reordering fields of one kind changes only `field`. | `MoreFieldsNeverWorse`, `FieldOrderOnlyMovesIndex` |
| L7 | Greedy matching from the first possible word start finds a fuzzy match whenever one exists, which is what lets the code scan once, and the word-run scan agrees with R4. | `GreedyIsComplete`, `RunIsDeclarative` |
| L8 | A ranked listing is the matching items, each once, sorted by R10 and stable in base order, and every item that matches as `substring` or better comes before every item that matches below it. | `ListingSortedStable`, `LegacyRowsFirst` |
| L9 | A filtered listing shows only matches, each once, in base order. | `FilteredKeepsOrder` |
| L10 | A query of only punctuation matches exactly the items with a field that holds it as typed. | `PunctuationMatchesAsTyped` |
| L11 | A filtered listing shows exactly the as-typed matches when there are any, and otherwise every match, so it is never empty while something matches. | `FilteredPrefersAsTyped` |
| L12 | A query of more than 64 characters matches exactly the items with a field that holds it as typed. | `LongQueriesMatchAsTyped` |

## Decisions

| ID | Decision | Why |
| --- | --- | --- |
| D1 | One engine for every menu and picker listed in `CONTEXT.md`, with no per-surface options. | The point of the change. A surface that needs different matching is out of scope (D7), not a flag. |
| D2 | The engine classifies; callers order. | Surfaces already own different base orders: catalog order, source groups, servers that need attention first, recency with paging. Moving order into the engine would move that ownership too. |
| D3 | `exact` and `prefix` rank above `substring` everywhere. | Typing a full model id or skill name lists it first. Today the Models menu lists every substring match in catalog order, and skills rank an exact name with prefix matches. |
| D4 | No single-letter rule. The `/` menu's rule that one character matches only by prefix goes away, so `/m` lists its prefix matches and then the commands that contain `m`. | A one-letter rule breaks L2: `n` would not match `anthropic` while `nt` does. Planted bug S9 shows it. |
| D5 | A query with no word characters matches only as typed (R6). | The first design matched every item, to keep L2 for every prefix. The E2E suite showed the cost: where Enter takes the highlighted row, `//`, the literal-slash escape, ran `/help`, and `/effort !!` set the effort to `default`. Planted bug S10 is that first rule. The price is that `-` can hide an item that `-a` then shows, so L2 covers prefixes with a word character. |
| D6 | No Unicode case folding. | No current menu folds non-ASCII case, so nothing that matches today depends on it. The `@` file picker keeps its own folding (D7). |
| D7 | Out of scope: the `@` file index matcher, the agent's `lexical_relevance` searches, subagent model overrides in `model_contract.zig`, prefix ghost completions, and fixed argument completions. | `CONTEXT.md`, Out of scope. Each has a contract the engine should not take on. |
| D8 | `/` commands match without case. | R8, and the same as every other menu. |
| D9 | Filtered surfaces fall back to word and fuzzy matches only when nothing matches as typed (R11). | Without a ranking to push them down, near-misses sat beside exact hits: in `/resume`, `workspace B` also listed workspace A because its temporary path holds a `b`, and an exact session marker also listed a newer session whose marker has one more digit. The fallback keeps today's results whenever today's matcher finds anything. Where as-typed matches run out, typing more can show more. |
| D10 | A `$` mention query that holds a byte no skill name continues with, anything but a letter, digit, `_`, or `-`, keeps the mention menu open only for a skill whose name contains the query as typed. Enter takes a completion only from a mention menu that is shown, and otherwise sends the prompt. | Sending a prompt ends a mention at that byte (`matchesSigilSkillAt` in `src/core/skills/skill_runtime.zig`), so `Use $status-second.` names `status-second`. Word matching read `status-second.` as the words `status` and `second`, kept the menu open, and Enter took the completion instead of sending the prompt (`tests/e2e/gateway-stream-lifecycle.test.ts`, "requested skill status reflects prepared content without tool activity"). Names such as `my.skill` still complete as typed. |
| D11 | A query of more than 64 characters matches only as typed (R12). | Every word must match (R4), so the work for each item grows with the number of query words, and only a limit bounds it. Over 5,000 session-sized items the engine took 476 ms per keystroke for a 64 KiB paste of one token, 139 ms for 64 KiB of everyday prose, and 2.8 s for 64 KiB of words every item holds, against 5.1 ms for 64 bytes of those words. The user chose 64. The limit counts characters, as the model does, which for ASCII is the same as bytes, and the code stops counting at the 65th character, so the check costs the same for any paste. A pasted title longer than the limit still matches where it appears as typed. |

## Success criteria

| ID | Criterion | Check |
| --- | --- | --- |
| G1 | Every surface in `CONTEXT.md` uses the engine, through `fuzzy_match.match` or `fuzzy_match.Ranking`, and the matchers it replaces are deleted. | The `callers` stage of `bun run verify` greps each surface for the engine and for each replaced matcher. |
| G2 | Every law holds on the model. | TLC on `MCFuzzyMatch.tla` with each config in `spec/`. |
| G3 | Every planted spec bug is caught by the law it names. | `mutations.json`, `spec`. |
| G4 | The edge table in `cases/edge.json` agrees with the model, before any engine code exists. | The `edge cases` stage: TLC checks every expected match. |
| G5 | The TypeScript oracle the drivers use agrees with the model, and every planted oracle bug is caught. | The `oracle` stage: TLC on the edge table and seeded random cases, and `mutations.json`, `oracle`. |
| G6 | The engine, its `Ranking`, and its `Filter` agree with the model and the oracle. | The `engine` stages: the edge table, seeded random cases checked by TLC, a differential run against the oracle, the laws checked on the engine's answers, and random ranked and filtered listings built by the real `Ranking` and `Filter` and checked by TLC. |
| G7 | Every planted engine bug is caught. | `mutations.json`, `code`. |
| G8 | The engine survives fuzzing. | A `std.testing.fuzz` test in `fuzzy_match.zig` that checks the laws on arbitrary bytes, listed in `tests/fuzz/targets.json` and `src/fuzz_targets.zig`, with inline seeds and any saved inputs in `tests/fuzz/corpus/fuzzy_match/`. |
| G9 | The engine stays fast at realistic and adversarial sizes. | The `stress` stage, with the budgets in Stress budgets. |
| G10 | The built binary's Models and skills menus list exactly what the model says, in order and with the same count. | The `binary` stage. |
| G11 | The repository's own checks pass. | `zig fmt --check src/`, `zig build`, `zig build test`, and the E2E files that cover the changed surfaces. |

## Stress budgets

Measured on the build `zig build -Doptimize=ReleaseSafe` produces, through the harness, with the same inputs for the engine and for today's substring scan (`text_utils.containsIgnoreCase`, every field, the whole query).

| ID | Workload | Budget |
| --- | --- | --- |
| B1 | 5,000 items with a 60-byte `name` field and two 240-byte `text` fields, the sizes of session titles and previews, and 20 realistic queries | Under 5 ms per pass over all items, on average |
| B2 | 1,000 items whose three 240-byte fields are `b` and then 239 `a`, with the 120-byte query of 119 `a` and then `b`. Every position compares about 120 characters and nothing matches, for both scans, and the field holds every query character, so no character filter can skip the work. A query longer than the field would let today's scan stop at once and measure nothing. | At most 4 times today's substring scan on the same input |
| B3 | Item counts of 1,000, 2,000, 4,000, and 8,000 with B1's shapes | Time grows at most linearly: each doubling at most 2.5 times slower |
| B4 | Queries and fields of random bytes up to 4 KiB, including invalid UTF-8 | No crash, and every answer a valid `?Match` |
| B5 | B1's 5,000 items and three 64 KiB pastes: one token, everyday prose, and prose made only of the words B1's items hold | Under 5 ms per pass for each |

## Non-goals

- Changing any surface's base order, grouping, paging, or what Enter and Tab do.
- Highlighting matched characters. No surface in scope highlights today.
- Typo tolerance beyond R5: no transpositions, insertions, or edit distance.
- Unicode case folding (D6).

## What 100% done means

Every item passes for the exact commit that ships.

1. `tests/tla/fuzzy_match/check.sh` exits 0 with every stage enabled.
2. `zig fmt --check src/`, `zig build`, and `zig build test` exit 0.
3. The E2E files that cover the changed surfaces pass with `FX_SOUND=0`.
4. The built `./zig-out/bin/fx` shows the fuzzy matches in the Models menu, the `/` menu, the skills menu, `/resume`, `/mcp`, `/help`, and `/settings`, with clean stderr.
5. `tests/tla/README.md` lists `fuzzy_match/`.
