# Measure RTK output reduction

The capture runs the built `./zig-out/bin/fx` against a local fake model server.
Each workload executes once. It compares the model's reduced view with the
original result from that same execution's saved session. Handles, timings,
instructions, tool definitions, and all other request content stay identical.
No model API is called.

Build the binary first. From the repository root inside a development container
or VM with Zig, Bun, and Git, capture the real test and Git output:

```bash
FX_E2E_DISABLE_DOTENV=1 bun test benchmarks/rtk.test.ts > /tmp/rtk-corpus.jsonl
```

The capture includes 11 Bun CI shard tests, four Zig reducer tests, dirty Git
status with five modified and ten untracked files, and unchanged clean-status
and unsupported-short-status controls. Failed capture assertions stop the run.

Count bytes and tokens with the optional measurement image. These commands use
the host's Docker installation; Python packages stay inside the image:

```bash
docker build -t fx-rtk-tokenizer -f benchmarks/rtk_tokenizer.Dockerfile benchmarks
docker run --rm -i --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges \
  --mount "type=bind,source=$(pwd)/benchmarks/rtk_tokens.py,target=/counter.py,readonly" \
  fx-rtk-tokenizer /counter.py < /tmp/rtk-corpus.jsonl
```

Move the capture file out of the development container if counting in a separate
one. The counter uses [tiktoken 0.12.0](https://github.com/openai/tiktoken/tree/0.12.0)
with `o200k_base` and `cl100k_base`. Output counts cover `output_delta`; request
counts tokenize the serialized prompt and tool definitions as a context proxy.
They are not provider-reported usage or a cost benchmark. Results depend on the
workload, and omission notices count toward the reduced result. A later request
for the original output can offset savings. Runtime dependencies are unchanged.

## Recorded sample

Linux x86_64, fx 0.0.16 with this change, Zig 0.17.0,
Bun 1.4.2, and tiktoken 0.12.0. These are `o200k_base` counts from one run.

| Workload | Output bytes | Output tokens | Output token reduction | Prompt + tools JSON tokens |
| --- | ---: | ---: | ---: | ---: |
| Bun CI shard tests | 1163 → 243 | 307 → 76 | 75.2% | 4530 → 4289 (5.3% less) |
| Zig reducer tests | 368 → 110 | 87 → 26 | 70.1% | 4300 → 4236 (1.5% less) |
| Git status, dirty | 574 → 471 | 180 → 149 | 17.2% | 4451 → 4406 (1.0% less) |
| Git status, clean control | 58 → 58 | 12 → 12 | 0.0% | 4208 → 4208 (0.0% less) |
| Git short status, unsupported control | 210 → 210 | 90 → 90 | 0.0% | 4310 → 4310 (0.0% less) |

The three eligible workloads save approximately 75%, 70%, and 17% of output
tokens with `cl100k_base` as well. Test timings, temporary paths, and replay
handles can change between captures, so exact counts may vary. The script
emits both encodings. The capture checks all five workloads.
