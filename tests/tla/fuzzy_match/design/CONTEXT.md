# Context: how fx menus match typed text

Line numbers refer to `origin/main` at `d4abfbd90`, which includes the Models menu matcher from #1477. `git show d4abfbd90:<path>` shows each file as cited.

## Surfaces

Every place below filters a list by what the user types. Each keeps its base order and calls the engine for the match. "Ranked" surfaces order matches by R10 through `Ranking`; "filtered" surfaces keep their base order and fall back to word and fuzzy matches only when nothing matches as typed, by R11 through `Filter`.

| # | Surface | Matcher today | Fields the engine gets (`name` / `text`) | Base order | Listing |
| --- | --- | --- | --- | --- | --- |
| 1 | Models menu (`/model` then Enter, Ctrl+P) and inline `/model <query>` suggestions | `matchModelQuery` (`src/core/app/model_cache_runtime.zig:374`), called by `modelMenuItemMatch` and `modelCompletions` | id, then the model's own name after the last `/` / none | Catalog order, after the provider tab | Ranked |
| 2 | `/model <query>` with Enter and no suggestion list | `resolveModelQueryFromIds` (`src/core/session/session_commands.zig:1425`), scoring with `fuzzyModelScore` (`:1760`) | as row 1 | Catalog order | First ranked match |
| 3 | `/` menu, commands | `completionCommandMatchRank` and `bestCompletionCommandMatch` (`src/core/slash_commands/command_specs.zig:520`, `:528`): exact, then prefix, then substring, case-sensitive, substring only past one character | command, aliases shown in completion / none | Registry order | Ranked; the matched alias is the one shown |
| 4 | Skills: the `/skills` menu, the `$` menu, and the skills in the `/` menu | `skillMatchRank` (`src/core/skills/skill_runtime.zig:1380`): name prefix, then name substring, then description, source label, or path substring | name / description, source label, path | Source group, then catalog order (`SkillMenuView`, `:1330`) | Ranked |
| 5 | `/resume` | `matchesQuery` (`src/core/session/session_catalog.zig:129`): title, workspace path, or preview substring | title / workspace path, preview | Most recent first, paged (`applySessionPickerCatalogPage`, `src/core/app/app_session_runtime.zig:683`) | Filtered |
| 6 | `/mcp` server list | `matches` (`src/core/mcp_host/menu.zig:86`), called at `:287` | server name / none | Working servers, then those needing attention, each by name (`:279-291`) | Filtered |
| 7 | `/mcp` tools on a server's screen | `toolMatches` (`src/core/mcp_host/menu.zig:103`): name or description substring | tool name / description | The server's tool order | Filtered |
| 8 | `/mcp <verb> <server>` suggestions | `runtimeArgMatches` (`src/core/slash_commands/command_specs.zig:892`): prefix of `VERB NAME` | server name / none, after the verb matches by prefix as today | The completion list | Filtered |
| 9 | `/help` menu | `helpCatalogSpecMatches` (`src/core/slash_commands/command_specs.zig:457`): every word a substring of the command, help entry, description, category, or an alias | command, aliases / help entry, description, category label | Category, then registry order (`:430-455`) | Filtered |
| 10 | `/settings` | `matchesQuery` and `tokenMatches` (`src/core/config/settings_catalog.zig:383`, `:391`): every word a substring of the label, description, value, or id | label, id / description, value | Category order | Filtered |
| 11 | `/provider` columns and teams, the effort and speed pickers | `filterAnnotatedLabels` and `filterCompletionLabels` (`src/core/input/picker_state.zig:561`, `:546`), and `effortCompletionValues` (`src/core/app/input_completion_runtime.zig:1475`): label substring | label / none | List order | Filtered |
| 12 | Login team picker | `teamMatchesQuery` (`src/core/auth/auth_runtime.zig:1471`): name or slug substring | name, slug / none | Team order | Filtered |

Every column except the last two comes from the current code. Rows 1 and 2 add the model's own name as a second name field so that typing it exactly lists it first, which `fuzzyModelScore` did with a bonus for an id ending in `/` and the query: `gpt-4o` finds `openai/gpt-4o` before `openai/gpt-4o-mini` whatever the catalog order. Rows 3 and 4 differ from the engine in ways `GOAL.md` decides: row 3 is case-sensitive (D8) and has a single-character rule (D4), and row 4 also trims `/` from the query, which the engine does not need because the `/` menu passes the query without its slash and `$` mentions without their dollar sign.

## Out of scope

| Matcher | Where | Why the engine does not take it |
| --- | --- | --- |
| The `@` file picker | `src/core/workspace/file_index.zig:1-9` | It searches up to 100,000 paths per keystroke from pre-lowercased buffers, rejects impossible paths with a per-path ASCII bitmap, ranks by best alignment, returns highlight spans, and folds Unicode case. A per-item field API would be slower and would drop the spans. |
| The agent's capability and skill search | `src/core/shared/lexical_relevance.zig`, `src/core/tooling/capability_retrieval.zig`, `src/tools/skills/skill_search.zig` | They rank natural-language requests by word relevance. Fuzzy hits would hand the agent the wrong tools. |
| Subagent model overrides | `matchCatalogModel` (`src/core/subagent/model_contract.zig:30`) | It resolves only confident matches and relies on `fuzzyModelScore`'s fixed score bands (`:41-45`). `fuzzyModelScore` stays for it. |
| Ghost completions | `firstSlashCompletion` (`command_specs.zig:490`), `firstSkillNameCompletion` (`skill_runtime.zig:1399`) | They complete the text already typed, so they must stay prefix matches. |
| Fixed argument completions | `argCompletionMatches` (`command_specs.zig:1031`) for `/permissions`, `/statusline`, `/sound`, `/workspace`, and `/allowlist` | They complete command syntax one word at a time. With the engine, `/allowlist local a` would also offer `local remove`. |

## Contracts

- The engine is called on the UI thread, per keystroke, and by some surfaces once per rendered row: the Models menu walks its list once per tier for each row (`modelMenuItemAt`, `model_cache_runtime.zig:300`). It must not allocate or block.
- Queries are at most 256 bytes in every menu that stores one (`model_cache_runtime.zig:197`, `skill_runtime.zig:1433`, `app_session_runtime.zig:458`). Session titles and previews are at most 240 bytes each (`src/core/session/session_display_metadata.zig:13`, `:15`).
- Every matcher in scope folds only ASCII case today: `text_utils.containsIgnoreCase` (`src/core/shared/text_utils.zig:5`), `std.ascii.findIgnoreCase`, and `std.ascii.startsWithIgnoreCase`.
- No surface saves a match. The engine's answer lives for one call.
- Nothing runs at startup, so the 2 ms startup budget (`AGENTS.md`, Benchmarks) is unaffected.

## Constraints

- Zig 0.17, standard library only. The engine imports nothing outside `src/core/shared/`: `std`, `ascii_case.zig` for ASCII case-insensitive search, and `display_width.zig` for UTF-8 decoding, which `AGENTS.md` requires instead of `std.unicode.utf8Decode`. `display_width.zig` imports only `unicode_display_data.zig` outside its tests, so the drivers can build their harness from the real file with `zig build-exe -M`, as `tests/tla/drivers/image_route/lib.ts` does.
- `src/core/shared/` is the home for basics that `src/core/`, `src/ui/`, and the libfx entry points share.

## Existing code that makes the wrong design look easy

1. A case-insensitive substring helper is one import away everywhere, so most surfaces grew their own variant. `command_specs.zig:476`, `model_contract.zig:72`, and `lexical_relevance.zig:157` each keep a private copy.
2. Skills and models already rank their matches (`skill_runtime.zig:1378-1392`, `model_cache_runtime.zig:300-311`). Putting ordering in the engine looks natural, but every surface orders differently, and `/resume` pages by date with a continuation (`app_session_runtime.zig:683-742`), which a ranked order would break. D2 keeps order with the callers.
3. The `/` menu's single-character rule (`command_specs.zig:523`) looks like noise control, but it means typing more can show more. D4 drops it.
4. The merged Models matcher treats every non-ASCII byte as a separator (`isAlphanumeric` in `containsAlphanumericRun`, `model_cache_runtime.zig`). That is harmless for model ids, which are ASCII, but it would make a session title in another language unsearchable by words. R8 makes non-ASCII characters word characters.
5. `fuzzyModelScore` already exists and is public, so reusing it for every surface looks cheap. Its lower bands match when any one word appears (`session_commands.zig:1802-1811`), which suits picking one model and floods a filtered list.

## Fakes the drivers use

| Fake | Where | Stands in for |
| --- | --- | --- |
| The fake gateway's catalog | `startFakeGateway` in `tests/e2e/tmux-helpers.ts`, from `tests/tla/drivers/fuzzy_match/binary.ts` | The model catalog the Models menu lists |
| Skill folders in an isolated home | `tests/tla/drivers/fuzzy_match/binary.ts` | Installed skills for the skills menu |
| The harness | `tests/tla/drivers/fuzzy_match/harness.zig` | Nothing: it reads one case per line, calls the real `fuzzy_match.match`, and prints the answer |

The drivers never reimplement the engine. The TypeScript oracle in `oracle.ts` is a second implementation of the model, checked against TLC, used only to compute expectations quickly for large and random runs.
