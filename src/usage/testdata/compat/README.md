# Compatibility fixtures

Files an fx binary that predates the usage module wrote in an isolated HOME, against a loopback fake AI Gateway with a fake key, plus the bytes that binary's own encoders derived from them. The codec and report tests read them through `fixtures.zig`, so a change that alters any byte older fx binaries read or write fails a test.

- `fx-home/`: the profile ledger, sidecars, sessions-v2 logs, and recovery markers as written.
- `cli/`: what `fx usage` printed for that home.
- `cases/` and `derived/`: every snapshot and record, and the bytes older fx re-serializes them to.
- `capture.json`: the scenarios and the requests the fake received.

No file holds credential material. `credential_identity` values are fx's credential authority for a source slot, which contains no key bytes.
