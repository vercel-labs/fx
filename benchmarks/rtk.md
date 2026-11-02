# Measure RTK output reduction

The capture runs the built `./zig-out/bin/fx` against a local fake model server.
Each workload executes once. It compares that execution's saved original model
view with the RTK request view. Timings, handles, instructions, tool definitions,
and other request content stay identical. No model API is called.

## Run the capture

Build the binary first. From the repository root inside a development container
or VM with Zig, Bun, and Git, capture the output:

```bash
FX_E2E_DISABLE_DOTENV=1 bun test benchmarks/rtk.test.ts > /tmp/rtk-corpus.jsonl
```

Use `--init` when starting a Docker development container so orphaned children
are reaped. Zig tests are compiled with `--test-no-exec` before capture. This
warms compilation without running the tests and keeps cold compilation from
exceeding the shell tool's yield limit.

The corpus contains 18 workloads: nine runs of project tests, five Git cases,
and four generated Bun scale/failure cases. The project runs execute 373 tests;
combined Bun suites and MCP subsets overlap, so this is not a unique-test count.
Generated JSON round-trip tests are stress data, separate from project tests.

The complete 243-test MCP suite passes standalone with an init process, but two
child-reaping tests fail when nested under fx's managed subprocess supervisor.
The corpus uses MCP auth, HTTP, core, and protocol groups instead. This does not
establish that the complete MCP suite passes inside an agent shell.

## Count tokens

The optional counter image keeps Python packages off the host:

```bash
docker build -t fx-rtk-tokenizer -f benchmarks/rtk_tokenizer.Dockerfile benchmarks
docker run --rm -i --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges \
  --mount "type=bind,source=$(pwd)/benchmarks/rtk_tokens.py,target=/counter.py,readonly" \
  fx-rtk-tokenizer /counter.py < /tmp/rtk-corpus.jsonl
```

Move the corpus out of the development container if counting in a separate one.
The counter uses [tiktoken 0.12.0](https://github.com/openai/tiktoken/tree/0.12.0)
with `o200k_base` and `cl100k_base`. It rejects an incomplete corpus and records
exit status, clipping, test summaries, bytes, and both token counts.

Output counts cover `output_delta`, including omission notices. Request counts
tokenize serialized prompt and tool definitions immediately after one command,
without a long conversation history. This is a context proxy, not provider usage
or a cost benchmark. Model framing, tokenizer, caching, and later full-output
reads affect actual usage. Runtime dependencies are unchanged.

## Recorded sample

Linux x86_64, fx 0.0.16 with this change, Zig 0.17.0, Bun 1.4.2, and tiktoken
0.12.0. The table uses `o200k_base`; timings, temporary paths, and replay handles
can change counts between runs. Test counts come from visible test summaries.

| Workload | Tests passed/failed | Output bytes | Output tokens | Output reduction | Prompt + tools JSON tokens |
| --- | ---: | ---: | ---: | ---: | ---: |
| Bun CI shard tests | 11/0 | 1163 → 243 | 307 → 76 | 75.2% | 4535 → 4294 (5.3% less) |
| Bun configured-provider tests | 52/0 | 5808 → 748 | 1147 → 171 | 85.1% | 5412 → 4390 (18.9% less) |
| Bun combined project suites | 63/0 | 6869 → 798 | 1411 → 184 | 87.0% | 5698 → 4414 (22.5% less) |
| Zig reducer tests | 4/0 | 368 → 110 | 87 → 26 | 70.1% | 4298 → 4234 (1.5% less) |
| Zig recovery tests | 29/0 | 2156 → 189 | 535 → 45 | 91.6% | 4769 → 4252 (10.8% less) |
| Zig MCP auth tests | 38/0 | 3385 → 376 | 837 → 89 | 89.4% | 5089 → 4306 (15.4% less) |
| Zig MCP HTTP tests | 18/0 | 1502 → 112 | 400 → 26 | 93.5% | 4628 → 4237 (8.4% less) |
| Zig MCP core subset | 105/0 | 9959 → 512 | 2444 → 124 | 94.9% | 6756 → 4336 (35.8% less) |
| Zig MCP protocol subset | 53/0 | 4404 → 206 | 1086 → 47 | 95.7% | 5347 → 4257 (20.4% less) |
| Git status, 5 modified + 10 untracked | — | 574 → 471 | 180 → 149 | 17.2% | 4447 → 4402 (1.0% less) |
| Git status, 50 modified + 100 untracked | — | 2864 → 2761 | 1035 → 1004 | 3.0% | 5663 → 5618 (0.8% less) |
| Git status, 500 modified + 500 untracked, clipped | — | 14586 → 14586 | 5124 → 5124 | 0.0% | 11417 → 11417 (0.0% less) |
| Git status, clean control | — | 58 → 58 | 12 → 12 | 0.0% | 4211 → 4211 (0.0% less) |
| Git short status, unsupported control | — | 2230 → 2230 | 900 → 900 | 0.0% | 5248 → 5248 (0.0% less) |
| Bun generated scale: 200 passing tests | 200/0 | 6465 → 6315 | 1877 → 1813 | 3.4% | 6282 → 6213 (1.1% less) |
| Bun generated scale: 1000 pass, clipped | 1000/0 | 15670 → 15670 | 4455 → 4455 | 0.0% | 9161 → 9161 (0.0% less) |
| Bun failure control: 200 pass, 1 fail | 200/1 | 6617 → 6617 | 1915 → 1915 | 0.0% | 6332 → 6332 (0.0% less) |
| Bun truncated-output control: 3000 pass | — | 15681 → 15681 | 4620 → 4620 | 0.0% | 9311 → 9311 (0.0% less) |

## What the results establish

- Complete project test logs save 70–96% of visible output tokens in this sample.
  Their serialized-request reductions range from 1.5% to 35.8%.
- Git status retains every path and removes only advice. Increasing the number
  of paths makes the relative saving smaller.
- fx already limits the inline JSON shell-result envelope to 16 KiB. RTK leaves
  clipped results unchanged, so larger logs can show zero additional savings.
  Output counts for those rows cover the existing clipped view, not the full log.
- Very fast Bun tests often omit timings. This version retains those pass lines;
  the generated 200-test run therefore saves only 3.4% of output tokens.
- Failed, clean, unsupported, and clipped controls save 0%. The 3,000-test
  control's visible excerpt lacks the final summary, so its test count is blank.
- Cargo output is supported by the implementation but is not benchmarked here.

These are workload-specific results, not a general claim about context or cost.
The counter emits both encodings so differences can be inspected directly.
