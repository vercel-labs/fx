# Contributing to fx

fx is open source and developed in public at [vercel-labs/fx](https://github.com/vercel-labs/fx). The fx team at Vercel maintains it and makes most changes, and pull requests from outside contributors are welcome and go through the same CI checks. Only maintainers can push branches to the repository, add labels, or start optional CI runs. Outside contributors work from a fork, and a maintainer handles those steps for them.

Code conventions live in [AGENTS.md](AGENTS.md): which module owns which behavior, how fx uses Zig 0.17, how permissions and tests are structured, and the rules coding agents follow. Read it before you change code, whether you write the change yourself or with a coding agent.

## Report a problem

Run `/feedback` inside fx to open the feedback form, or [open an issue](https://github.com/vercel-labs/fx/issues/new/choose) with the bug report template. Describe what you did, what you expected, and what happened instead. If something looks wrong in your terminal, `/trace` copies a private diagnostic trace that you can attach. Issues are public, so review the trace and remove secrets before you post it.

Report security vulnerabilities through the [contact page](https://fx.sh/contact), not in a public issue.

## Set up a checkout

You need:

- [Zig 0.17.0](https://ziglang.org/download/), the version CI builds with. Check `zig version` before you build, because an older Zig fails inside `build.zig` with errors such as `no field or member function named 'poisonCache'` that don't mention the version.
- [Bun](https://bun.sh) and [tmux](https://github.com/tmux/tmux) for the end-to-end tests.
- [hyperfine](https://github.com/sharkdp/hyperfine), if you want to run the startup benchmark locally.

The unit tests and most end-to-end tests don't call a model. To try a change that does, sign in as the [README](README.md#quick-start) describes or set `AI_GATEWAY_API_KEY`.

Clone the repository, or your fork if you're an outside contributor, and build fx:

```bash
git clone https://github.com/vercel-labs/fx.git
cd fx
zig build
./zig-out/bin/fx
```

Test your changes with `./zig-out/bin/fx` from your checkout. A bare `fx` runs whichever copy comes first on your `PATH`, which is usually an installed release that doesn't include your change.

fx keeps its settings and sessions in `~/.fx`, and on macOS it stores API keys and OAuth credentials in your Keychain. To try a change against an empty profile without touching your own, give fx a temporary home directory and turn off Keychain storage:

```bash
HOME="$(mktemp -d)" FX_DISABLE_KEYCHAIN=1 ./zig-out/bin/fx
```

## Make a change

Start each change from the latest `main`, and keep each pull request to one change. Put unrelated formatting, renames, and cleanup in their own pull requests, so each one can be reviewed and reverted on its own.

Before you build a feature, answer the questions in the [Adding a Feature](AGENTS.md#adding-a-feature) section of AGENTS.md. They ask which module owns the behavior, what its typed contract is, whether it needs persistence or JSON output, which docs and tests land with it, and how its end-to-end tests are classified for PGSO. If you can't answer them yet, settle the design before you write code. Outside contributors can propose a design in an issue first.

These rules apply to every change:

- `src/main.zig` only wires runtimes together. Feature logic and state belong to the module that owns them.
- Sensitive tool behavior goes through the permission system in `src/core/permissions/permissions.zig`. Don't add a path around it.
- fx has no dependencies outside the Zig standard library. Talk to the maintainers before you add one.
- Don't commit generated state from `.fx/`, `.zig-cache/`, or `zig-out/`.
- Don't commit home-directory paths, real team IDs, or personal project slugs. `scripts/check-public-surface.sh` rejects them in CI, so use `/Users/example/` in fixtures.
- Don't document behavior that doesn't exist yet.

If a coding agent helps with your change, point it at AGENTS.md. Any prose the agent writes for your contribution, including pull request titles and descriptions, commit messages, documentation, and issues, must follow the `technical-writer` skill in `.fx/skills/technical-writer/`.

## Test your change

Run the tests that cover your change, build fx, and then use `./zig-out/bin/fx` to exercise the change yourself. Tests don't always start the full runtime, attach a terminal, or spawn background threads, so a passing suite can still miss a startup crash or a rendering regression. Confirm that fx didn't abort, that stderr is clean, and that the behavior matches what you'll describe in the pull request.

```bash
zig fmt src/
zig build
zig build test
cd tests/e2e
bun install
bun test cli.test.ts
```

Zig unit tests sit in `test` blocks inside the source file they cover, and `zig build test` runs all of them. CI checks formatting with `zig fmt --check src/`. The end-to-end tests run the binary at `zig-out/bin/fx`, so build before you run them. Run only the end-to-end files that cover your change, because CI runs the whole suite on every push. The `tui-*` files drive fx inside tmux.

### Add an end-to-end test file

Every root `tests/e2e/*.test.ts` file needs an entry in the first two files below, and in the third only when it branches on the platform. CI fails when a required entry is missing or stale:

| File | Entry |
| --- | --- |
| `scripts/pgso/corpus.json` | Exactly one classification: training, verification-only, or intentional exclusion |
| `tests/e2e/ci-shard-weights.json` | A weight that balances the four CI shards |
| `tests/e2e/macos-platform-tests.json` | Needed only when the file branches on `process.platform` or `platform()` being `darwin` or `linux` |

The corpus drives the macOS arm64 PGSO build, which profiles fx on the training files, optimizes the code they exercise for speed, and compiles the functions they show to be cold for size. Classify a file as training when it covers common or performance-sensitive behavior. Use verification-only for correctness, recovery, security, or rare behavior that the build must pass without treating it as hot. Use an intentional exclusion only for coverage that is nondeterministic, needs the network or credentials, involves sound, or tests the harness itself, and record the reason. A test added to an existing file inherits that file's classification, and removing a file means removing its entries.

### Reproduce a rendering bug

fx prints into your terminal's scrollback instead of taking over the screen, so many rendering bugs appear only at certain sizes or after a resize. Reproduce a bug at the lowest layer that catches it:

1. A Zig unit test in `src/ui/resize_tests.zig` drives the transcript renderer against an in-process virtual terminal, with no TTY or signals. These tests are the fastest and run in `zig build test`.
2. A tmux test in `tests/e2e/tui-resize.test.ts` covers bugs that need a real terminal and a real `SIGWINCH`. `tests/e2e/tmux-helpers.ts` provides `resizeWindow`, `capturePaneGrid`, and `capturePaneEscapes`.
3. A recorded tape captures a session someone has already seen go wrong. Run fx with `FX_RECORD=/tmp/bug.fxtape`, or with `FX_DEBUG_RECORD=1` to write a private tape under `~/.fx/recordings/`, then replay it without a terminal:

   ```bash
   ./zig-out/bin/fx replay /tmp/bug.fxtape
   ./zig-out/bin/fx replay /tmp/bug.fxtape --golden /tmp/bug.txt
   ```

   `--golden` writes the final screen to a file that you can check in as the expected result.

When a tmux test or a tape exposes a bug, reproduce it as a Zig unit test before you fix it, so the fix lands with its regression test.

### Check startup performance

The `Startup Latency` check fails a pull request when any benchmarked command takes longer than 2 ms on the Linux CI runner. To measure before you push, run:

```bash
./benchmarks/startup.sh --quick
```

The script builds a ReleaseSafe binary and needs hyperfine. On macOS, process and dynamic-loader overhead alone can exceed 2 ms, so compare local numbers between builds instead of against the budget. To measure an interactive launch up to its first frame, `benchmarks/first_frame.py` runs several binaries under the same machine load. In this example, `/tmp/fx-before` is a build of `main`:

```bash
python3 benchmarks/first_frame.py --binary /tmp/fx-before --binary ./zig-out/bin/fx
```

### Run the model evals

The evals in `tests/evals/` drive the agent through `fx ask --json` against real models and need `AI_GATEWAY_API_KEY`. They make billed model calls and their results vary between runs, so they aren't part of the pull request checks.

```bash
cd tests/evals
bun install
bun test
```

## Open a pull request

1. Sign every commit before you push it. `main` accepts only commits with verified signatures, and squash merging is turned off, so a single unsigned commit blocks the merge. GitHub explains how to set up [commit signature verification](https://docs.github.com/en/authentication/managing-commit-signature-verification/about-commit-signature-verification) with an SSH or GPG key.
2. Push your branch. Maintainers push to `vercel-labs/fx`. Outside contributors push to their fork and open the pull request against `main`.
3. Open the pull request as a draft once your focused checks pass, so CI starts on it.
4. Write the title as a plain imperative sentence, such as `Restore feedback report file clipboard`. Leave out bracketed prefixes like `[bug]`, because the type goes in a label.
5. In the description, say what changes for users or callers, why it changes, and how you verified it, including what you ran with `./zig-out/bin/fx`.

### Choose a label

Every pull request needs exactly one `type:` label before it merges. Choose the label that matches the main reason the pull request exists:

| Label | Use it when the pull request |
| --- | --- |
| `type: bug` | Fixes incorrect behavior |
| `type: feature` | Adds a new user-facing capability |
| `type: improvement` | Improves existing user-facing behavior |
| `type: docs` | Changes documentation only |
| `type: maintenance` | Changes internal tooling, dependencies, CI, or code structure without changing user-facing behavior |
| `type: release` | Prepares or repairs a release |
| `type: security` | Fixes or hardens a security boundary |

Only maintainers can add labels. Maintainers add the label when they open the pull request and update it if the scope changes. When a pull request mixes kinds of change, the label follows its main purpose. Outside contributors leave the label off, and a maintainer adds it during review. A missing label never holds a pull request in draft.

## CI checks

CI runs on every push to a pull request, including drafts. Linux x86_64 gates every change, because most fx behavior is the same on every platform. A result counts only for the exact commit it ran on, so each new push needs a new passing run.

These five checks must pass before a pull request merges:

| Check | What it runs |
| --- | --- |
| `Build & Test` | Formatting, the PGSO corpus, the public-surface, compactor-boundary, and indexer-boundary checks, the ReleaseSafe unit tests, and the SDK package jobs |
| `E2E (deterministic)` | Every end-to-end file, split across four weighted shards, plus the MCP conformance baseline |
| `Shellcheck` | `bash -n` and `shellcheck` on the scripts listed in the job, such as `benchmarks/startup.sh` and `scripts/detect-macos-need.sh` |
| `Startup Latency` | The benchmarked CLI commands on a ReleaseSafe build, each held to 2 ms, plus the interactive performance test in `tests/e2e/tui-performance.test.ts` |
| `macOS arm64` | The macOS checks when the change needs them, and otherwise a pass without starting a macOS runner |

CI retries a failed end-to-end file once. A file that passes only on the retry gets a warning annotation, and you should investigate it as a possible race.

`scripts/detect-macos-need.sh` decides whether a change needs macOS. It runs the macOS checks when the change touches:

- A Zig file with a macOS, BSD, or Linux code path
- `build.zig`
- The macOS signing script
- The native SDK addon
- An end-to-end file listed in `tests/e2e/macos-platform-tests.json`
- A shared end-to-end helper that reads the platform

When the detector can't read the change, the `macOS arm64` check fails instead of passing.

Other workflows and benchmark jobs also report on pull requests, such as the `Examples` workflow when `examples/` changes and the `Shell command overhead` benchmark. Only the five checks above are required to merge, but look into any check that fails. Two of the others need more explanation:

- The binary size workflow builds each release target for the pull request and its base commit on native runners, reports the size change, and smoke-tests every target's binary. Growth of 52,429 bytes (0.05 MiB) or more on a platform adds a warning. Investigate growth you can't explain.
- The macOS arm64 PGSO workflow runs on a pull request only when the PGSO pipeline itself changes: `scripts/pgso/` other than `corpus.json`, the `setup-pgso` action, or `.github/workflows/pgso-macos-arm64.yml`. Stable releases always run it. [scripts/pgso/README.md](scripts/pgso/README.md) explains the pipeline and its acceptance gates.

Other runs start only on request:

| Run | Command |
| --- | --- |
| macOS checks | `gh workflow run macos.yml --ref your-branch`, or add the `ci:macos` label |
| PGSO qualification | `gh workflow run pgso-macos-arm64.yml --ref your-branch` |
| Live ACP suite | `gh workflow run ci.yml --ref your-branch -f acp_live=true` |
| Long-turn memory benchmark | `gh workflow run bench.yml --ref your-branch -f long_turn_memory=true` |
| libfx runtime benchmark | `gh workflow run bench.yml --ref your-branch -f libfx_runtime=true` |

Only maintainers can start these runs or add the `ci:macos` label. If you're an outside contributor and your change needs one of them, ask in the pull request and a maintainer will start it. If CI doesn't start at all on your first pull request, a maintainer may need to approve the workflow run.

## Mark it ready for review

Mark the pull request ready when all of these hold for its current commit:

1. All five required checks passed. A queued, cancelled, skipped, or failed run doesn't count, and neither does a run on an earlier commit.
2. You ran `./zig-out/bin/fx` through the changed behavior.
3. The diff against `main` contains only the files this change needs.
4. The documentation that describes the behavior is up to date.

If CI fails, push the smallest fix to the same pull request and wait for a passing run on the new commit.

## Update the docs

Update the documentation in the same pull request as the behavior it describes:

- The `--help` output comes from the command specs in `src/builtins/commands.zig`.
- `sdk/README.md` documents libfx. Update it when libfx's public behavior or setup changes, as [sdk/AGENTS.md](sdk/AGENTS.md) describes.
- Update this file when build steps, development setup, or collaboration rules change.

Change `README.md` only when one of its statements becomes false, or when a change adds a capability as broad as the ones in its feature list. A new option, command, or environment variable belongs in `--help` and the manual.

Don't edit `CHANGELOG.md` or the version in `src/main.zig`. Maintainers write the changelog when they prepare a release.

### Changes to the manual

The user manual at [fx.sh/docs](https://fx.sh/docs) is built from a private repository, so outside contributors can't edit it. When your change makes a manual page wrong or incomplete:

- Maintainers update the page in a companion pull request and link it from theirs.
- Outside contributors add a `## Docs` section to the pull request description with the exact change each affected page needs: the page URL, the section, and the text to add, replace, or remove. A maintainer makes the change in the manual.

For example:

```md
## Docs

- https://fx.sh/docs/configure-fx/permissions, "Change the mode": replace "<current text>" with "<new text>".
- https://fx.sh/docs/using-fx/sessions: add "<new paragraph>" after the first paragraph.
```

## Releases

Maintainers prepare each release in a pull request that bumps `pub const version` in `src/main.zig` and adds the new entry to `CHANGELOG.md`. When that pull request merges, the release workflow finds no tag for the new version, builds the binaries for every platform, creates the tag, and publishes the GitHub Release along with the binaries that the install script and `fx upgrade` download. Never create a version tag by hand. The [Releasing](AGENTS.md#releasing) section of AGENTS.md describes the changelog format and release markers.

To check release artifacts without publishing anything, run **Actions > Release** on `main` with `validate_only` enabled. The run builds every target, runs the PGSO qualification, and notarizes the macOS binaries. It creates no tag or GitHub Release, uploads nothing to the CDN, and changes no update channel.

After CI passes on `main`, the dev release workflow publishes binaries for that commit. Run `fx upgrade --channel dev` to follow those builds, and `fx upgrade --channel stable` to go back to tagged releases.

## License

fx is licensed under [Apache-2.0](LICENSE). Unless you state otherwise, a contribution you submit for inclusion in fx is licensed under the same terms, as section 5 of the license describes.
