# Fx Render Lab

Render Lab is the runtime evidence system for Fx terminal rendering bugs. It exists because rendering failures usually happen after the binary is running inside a real terminal, not during compile time. The lab turns those failures into artifacts that can be replayed, analyzed, and compared without relying on screenshots or manual descriptions.

The core rule is:

```text
Screenshots are optional human context. They are not the pass/fail oracle.
The oracle is byte replay plus terminal-owned text/grid capture.
```

## What This System Proves

Render Lab is designed to answer these questions:

- Did the freshly built Fx binary emit coherent terminal bytes?
- Did replaying those bytes through `fx replay` produce the expected model?
- Did the real terminal-owned text/grid settle after each user-visible event?
- Did old shell scrollback stay outside Fx-owned viewport rows?
- Did quit, relaunch, resize, and native clear-scrollback actions preserve the intended boundaries?
- Did the terminal keep changing after an event when the scenario expected it to be idle?

It intentionally does not claim pixel-perfect proof. Font shaping, colors, ligatures, and cursor paint are outside the default oracle unless a later adapter adds a bounded visual layer. Native screenshots may be attached for human inspection, but analyzer failures must come from bytes, text/grid state, scrollback, trace logs, or stability evidence.

## Where The Pieces Live

```text
tests/e2e/render-lab/
  index.ts        default CLI, tmux scenario, artifact writer
  native.ts       opt-in native Terminal.app, Ghostty, and Warp adapters
  analyzer.ts     invariant checks over captured frames and traces
  evidence.ts     bounded runtime witness and frame hashes
  report.ts       static HTML inspection report
  types.ts        artifact and frame contracts

tests/e2e/tui-render-lab.test.ts
  default-safe Bun wrapper for CI-style verification
```

## Scenario Layers

Use the lowest layer that can prove the bug.

```text
Zig VT tests
  Fastest. Pure renderer and terminal model logic. No real PTY.

tmux Render Lab
  Deterministic real PTY coverage. Good for resize, scrollback, cursor, ANSI, relaunch.

FX_RECORD tape and fx replay
  Byte-level recording of what Fx wrote plus replay through the built-in virtual terminal.

Native Render Lab
  Opt-in platform proof for Terminal.app, Ghostty, Warp, and UI-only actions such as Command-K.

Optional native visual capture
  Human evidence only. Not the pass/fail oracle.
```

## Default Scenario

The default deterministic scenario is `same-shell-relaunch`.

It drives one tmux shell through this shape:

1. Start a shell with temp `HOME`, `ZDOTDIR`, history, and workdir.
2. Print shell markers and wrapped lines before Fx starts.
3. Launch the freshly built `zig-out/bin/fx`.
4. Run no-key slash commands that write to the transcript, such as `/allowlist`.
5. Quit Fx.
6. Print more shell markers in the same shell.
7. Relaunch Fx.
8. Resize narrow, wide, and back.
9. Quit and relaunch a third time.
10. Capture final state, replay artifacts, trace logs, and report HTML.

Command:

```bash
cd /Users/example/Developer/Fx/fx-worktree-rendering
zig build
cd tests/e2e
bun run render-lab -- --scenario same-shell-relaunch --runs 1 --out /private/tmp/fx-render-lab
```

Default test wrapper:

```bash
cd /Users/example/Developer/Fx/fx-worktree-rendering/tests/e2e
bun test tui-render-lab.test.ts
```

This wrapper is CI-safe apart from requiring tmux. It does not require `AI_GATEWAY_API_KEY`.

## Native Scenarios

List available scenarios:

```bash
cd /Users/example/Developer/Fx/fx-worktree-rendering/tests/e2e
bun run render-lab -- --list-scenarios
```

Current native scenarios:

```text
native-ghostty-relaunch
native-terminal-app-relaunch
native-terminal-app-command-k
native-warp-relaunch
```

Native scenarios are opt-in because they open and control real terminal applications. Default tests must not run them.

Common gate:

```bash
FX_RENDER_LAB_NATIVE=1 bun run render-lab -- --scenario native-terminal-app-relaunch --runs 1 --out /private/tmp/fx-native
```

Ghostty and Warp use clipboard-based selected-text capture, so they require an extra explicit gate:

```bash
FX_RENDER_LAB_NATIVE=1 FX_RENDER_LAB_NATIVE_ALLOW_CLIPBOARD=1 \
  bun run render-lab -- --scenario native-ghostty-relaunch --runs 1 --out /private/tmp/fx-native-ghostty
```

The Command-K scenario requires a second gate because it triggers real terminal clear-scrollback behavior:

```bash
FX_RENDER_LAB_NATIVE=1 FX_RENDER_LAB_NATIVE_COMMAND_K=1 \
  bun run render-lab -- --scenario native-terminal-app-command-k --runs 1 --out /private/tmp/fx-native-command-k
```

Do not treat tmux clear-history as proof for Terminal.app or Ghostty Command-K. Tmux can approximate a clear, but Command-K is a UI-level terminal action.

## Runtime Witness

The witness system lives in `evidence.ts`.

Every frame is captured only at an event boundary, such as:

- shell command output observed
- Fx launch requested
- Fx prompt visible
- slash command output visible
- Fx quit requested
- shell prompt visible after quit
- resize applied
- final state captured

Before writing a frame, the witness samples the terminal-owned visible state until it is stable:

```text
stable samples: 3
max settle time: 1200ms
sample interval: 120ms
```

If the state settles, the frame records:

- capture source, for example `tmux-pane` or `terminal-app-contents`
- stable status
- sample count
- settle duration
- SHA-256 of the visible grid
- SHA-256 of scrollback text
- SHA-256 of trace tail

If the state does not settle before the budget, the analyzer emits:

```text
unstable-frame-capture
```

This is how the lab avoids unbounded screenshots or window captures. It never captures 1000 copies per second. It samples a bounded text oracle only around meaningful events.

## Artifact Bundle

Each run writes one directory:

```text
run-<timestamp>-<n>/
  manifest.json
  runtime-evidence.json
  trace.log
  render.fxtape
  replay-summary.json
  final-grid.txt
  failure.md
  repro.sh
  report.html
  replay/
    manifest.json
    frames/
      0001.json
      0001.grid.txt
```

Important files:

- `manifest.json`: top-level run metadata, binary hash, markers, frame list, analyzer failures.
- `runtime-evidence.json`: compact witness summary for every frame.
- `trace.log`: Fx debug trace for repaint, resize, footer, input, and related scopes.
- `render.fxtape`: byte-level replay tape produced by the freshly built Fx binary.
- `replay-summary.json`: structured `fx replay` output.
- `final-grid.txt`: replay golden output for the final tape state.
- `failure.md`: short human-readable failure list.
- `repro.sh`: command to recreate the scenario.
- `report.html`: static frame-by-frame report with highlights, diffs, trace tail, and first failing invariant.
- `replay/frames/*.json`: full frame data, including grid, scrollback, trace tail, cursor, and witness evidence.
- `replay/frames/*.grid.txt`: visible terminal grid for quick text inspection.

## Analyzer Invariants

The analyzer checks the earliest failing frame it can identify.

Current invariant classes include:

- at most one active Fx logo block
- at most one active footer block
- footer rows stay inside terminal bounds
- footer rows do not contain transcript markers
- divider widths match the current terminal width closely enough
- cursor coordinates stay inside frame bounds
- shell markers do not appear inside the Fx-owned viewport band
- shell markers are preserved in final scrollback unless explicitly cleared
- markers cleared by a native clear-scrollback scenario stay absent
- trace does not show excessive footer clean or repaint spam
- frame capture reached a stable visible state before the settle budget expired

The marker rules are the core scrollback oracle:

```text
Shell rows printed before launch must remain shell-owned.
Fx must not replay old shell rows into its active viewport.
Native clear-scrollback must not allow pre-clear rows to return.
```

## Debugging Workflow

For rendering or byte issues, use this loop.

1. Build the current binary.

```bash
zig build
```

2. Run the deterministic same-shell lab.

```bash
cd tests/e2e
bun run render-lab -- --scenario same-shell-relaunch --runs 1 --out /private/tmp/fx-render-lab
```

3. Open `failure.md`. If it has failures, inspect the first one.

4. Open `report.html` and jump to the failing frame.

5. Compare:

- visible grid
- previous and next frame diff
- highlighted logo/footer/shell/submitted rows
- trace tail near the frame
- witness stability and frame hashes

6. If the bug only appears in a specific terminal app, run the matching native scenario with the explicit gate.

7. If native fails and tmux passes, the issue is likely terminal-app behavior, terminal capture behavior, or a terminal-specific Fx code path such as `TERM_PROGRAM=Apple_Terminal`.

8. Fix the rendering or capture code.

9. Re-run:

```bash
zig build
zig build test
cd tests/e2e
bun test tui-render-lab.test.ts
```

10. Run the relevant direct artifact scenario again and keep the new artifact path in the run notes.

## Interpreting Common Failures

`single-active-logo`

More than one Fx logo block is visible in the active viewport. Usually means old Fx startup output was replayed or not cleared correctly.

`single-active-footer`

More than one footer block is visible. Usually points to footer cleanup, viewport ownership, or stale repaint rows.

`footer-transcript-overlap`

A marker appeared in a footer-owned row. This usually means transcript and footer row ownership overlapped.

`shell-marker-in-fx-band`

A shell marker was found inside the active Fx viewport band. This is the primary old-scrollback-replayed-as-Fx-content failure.

`shell-marker-preserved`

A shell marker that should still be present is missing from final scrollback. On native Terminal.app, this can expose platform-specific scrollback suppression behavior.

`cleared-shell-marker-absent`

A marker printed before native clear-scrollback reappeared after the clear. This is a real Command-K style regression.

`divider-width`

Divider rows do not match the current terminal width closely enough after resize.

`cursor-bounds`

The terminal-reported cursor is outside the captured frame bounds.

`footer-clean-spam` or `repaint-spam`

Trace logs show repeated idle work above the configured threshold.

`unstable-frame-capture`

The terminal-owned visible state did not settle after an event within the bounded witness budget. Do not trust that frame as a stable final state. Investigate ongoing repaint, animation, clean loop, terminal echo, or adapter capture noise.

## Native Adapter Notes

Terminal.app:

- Uses AppleScript `contents` from a native Terminal window.
- Does not require clipboard capture for the relaunch scenario.
- Command-K requires System Events and the explicit `FX_RENDER_LAB_NATIVE_COMMAND_K=1` gate.
- Current native smoke exposed an Apple Terminal path where the first shell marker was missing by final relaunch. Keep that failure visible until the product behavior is fixed or the invariant is intentionally revised.

Ghostty:

- Uses real Ghostty app launch.
- Uses selected-text clipboard capture.
- Requires `FX_RENDER_LAB_NATIVE_ALLOW_CLIPBOARD=1`.
- Useful when Ghostty scrollback, resize, or terminal-specific behavior diverges from tmux.

Warp:

- Uses real Warp app launch.
- Uses selected-text clipboard capture.
- Requires `FX_RENDER_LAB_NATIVE_ALLOW_CLIPBOARD=1`.
- Warp private OSC/DCS behavior should be metadata only unless a future adapter can expose a stable byte/text contract for it.

## Adding A Scenario

Add a new scenario only if it fits the existing runner and artifact model.

Do:

- add scenario dispatch in `index.ts` or `native.ts`
- reuse `RenderLabManifest`, `RenderLabFrame`, analyzer, report, and witness evidence
- capture at event boundaries
- add unique shell or submitted markers
- make native scenarios opt-in
- keep default CI deterministic and no-key
- write a focused wrapper test when the behavior can be checked safely by default

Do not:

- create a second runner
- add a parallel artifact format
- make default CI open native apps
- make screenshots the oracle
- poll windows continuously
- require an API key for deterministic rendering coverage
- weaken invariants to make a native platform failure pass

## Shipping Bar For Rendering Fixes

Before claiming a rendering or byte-path fix works:

```bash
zig build
zig build test
zig fmt src/
cd tests/e2e
bun test tui-render-lab.test.ts
bun run render-lab -- --scenario same-shell-relaunch --runs 1 --out /private/tmp/fx-render-lab
../../zig-out/bin/fx status --json
git diff --check
```

Use the exact freshly built binary from this checkout. Do not run bare `fx`.

If the bug was reported in a native terminal, also run the matching native scenario and include the artifact path in the run notes.

The desired end state is:

```text
my working = your working
```

That does not mean every machine is identical. It means the artifact contains enough runtime evidence to locate the difference: emitted bytes, replay model, terminal-owned text/grid, scrollback, trace behavior, or unstable runtime state.
