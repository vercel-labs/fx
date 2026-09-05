# Long-turn memory

Saved agent turns keep messages and tool results alive across model steps. The
turn arena must therefore survive until finalization. Temporary work has a
shorter lifetime:

* Recovery checkpoint reconstruction uses a separate arena. Persistence sinks
  synchronously copy or serialize the borrowed checkpoint before returning.
* Provider attempts use a separate arena for HTTP and response-parser scratch.
  Successful or failed owned results are copied to the caller's allocator before
  that arena is destroyed. Deferred usage references and failure diagnostics
  are included in the copy. Stable borrowed provider results remain borrowed.

Both scopes release temporary storage on success, cancellation and error. The
step limit, history contents, request semantics and retry policy are unchanged.
The native prepared request body already uses the resetting overlay arena.

## Measure a long saved turn

On Linux, build the native binary and run the local Gateway fixture:

```sh
zig build -Doptimize=ReleaseSafe
python3 benchmarks/long_turn_memory.py --output /tmp/fx-memory-proof --steps 1000
```

The output directory must not already exist. Each step reads a changing file
of approximately 1 KiB. The fixture supplies deterministic responses and never
contacts a paid model. It discards request bodies and samples only fx RSS from
`/proc/<pid>/status` every 100 ms. The fx process has a 2 GiB address-space limit,
a 600-second deadline and disabled core dumps. Use `--steps 5` for a short smoke.

`measurements.json` records the binary SHA-256, RSS samples, request count and
retained history measurements. It measures pending execution snapshots and
completed v4 conversation events separately. Compare current retained output
with RSS growth; serialized history is not a measurement of allocator capacity.
A run that exits with `OutOfMemory` does not count as completing the workload.

Focused unit regressions cover 1000 growing checkpoints and 1000 provider
attempts, including cancellation, transport failure, provider failure and a
failed checkpoint save. Result-copy tests destroy the source allocator before
reading the copied response, deferred usage and diagnostics, and inject failures
at each copy allocation to verify cleanup.
