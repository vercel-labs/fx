# Guest-only executable pager experiment

This experiment stores whole arm64 code pages as independent zstd frames and
restores them on first access. It is not a release format. Two physical-host
kernel panics were recorded during earlier testing on macOS 26.5.2. One
identified fx_pagerized directly; the other occurred in ReportCrash, whose
connection to the experiment remains circumstantial. A watchdog, debugger,
or external SSD does not isolate the kernel.
Run experimental binaries only inside a disposable macOS VM.

## Ownership and contract

The experiment owns its offline Mach-O rewriter, freestanding runtime, and
versioned `contract.zig` binary layout. It adds no fx command, session state,
or configuration persistence. Build reports are JSON; runtime failures are
bounded stderr messages and exit codes. No production text/JSON output
contract changes. The build option `macho-headerpad` reserves header space
without changing ordinary builds.

No root E2E owner is added to the PGSO corpus: the guest scripts live here and
require explicit VM orchestration. Their kernel-fault workload must not run
on normal CI hosts. Full CI runs the deterministic static rewriter tests and
Zig contract tests on all native platforms.

## Memory layout

| Region | File backing | Runtime protection |
| --- | --- | --- |
| Original headers and resident text prefix | Signed | RX, never modified |
| Pageable text tail in `__TEXT` | Zerofill | NONE, then RW while loading, then RX |
| Remaining original text and stubs, `__TEXTB` | Signed | RX, maximum RX |
| `__PGCODE` | Signed | RX, maximum RX |
| `__PGSTATE` relocated constants | Anonymous, copied from a template | RW during initialization, then R |
| `__PGSTATE` scratch, lock and page flags | Anonymous | RW, maximum RW |
| `__PGMETA` configuration, initializer, relocations, frames and blob | Signed | R, maximum R |

The stub is position independent and reserves Darwin's x18 register. The
builder uses ELF relocation records; it never guesses pointers from values.
Only explicit ABS64 relocations in anonymous state receive the image slide.
Relocations in code that would require runtime patching are rejected.

The original headers and first partial code page stay outside the pageable
range. Load-command expansion must fit the reserved space. Both legacy dyld
opcode streams and chained fixups are adjusted for the new segment indices.
Unsupported input layouts fail during the static build.

A single atomic owner lock serializes decoding and protects the shared
workspace. Reentry on the same thread exits. Already serviced queued faults
return without rewriting executable pages. Writes to restored code are rejected rather than retried. There is no page eviction. Each
page must decode to exactly 16 KiB and match its stored integrity checksum
before it receives execute permission. The checksum detects corruption;
authentication remains the responsibility of the Mach-O signature.

## Build and static checks on the host

Requires Zig 0.16, Python 3, zstd, and Apple's codesign. The optional C stress
fixture also requires clang. No extra package is linked into fx.

```sh
zig build -Doptimize=ReleaseSmall -Dmacho-headerpad=16384
python3 -m unittest discover -s experiments/pager -p test_rewrite.py -v
zig test experiments/pager/contract.zig
experiments/pager/build_pagerized.sh --eager --output-dir zig-out/pager-eager
experiments/pager/build_pagerized.sh --output-dir zig-out/pager-demand
```

These commands do not execute a pagerized binary. Each output directory
contains `fx`, the ELF stub, linker script, and a build report with source and
output SHA-256 hashes. The builder round-trips every compressed page and
verifies the final Mach-O signature and segment protections.

A runtime VirtualMac check rejects physical hosts before state initialization
or protection changes. This guard is defense against accidental invocation,
not permission to test the binary on the host. `run_supervised.sh` also refuses
physical hosts and provides a guest process timeout only.

## Guest verification

Copy the chosen newly built output to an isolated guest checkout as
`./zig-out/bin/fx`, along with `guest_check.py` and `guest_tui_check.py`. Use SSH
with a dedicated guest key; do not mount the host home or checkout writable.
Record the actual guest macOS version and hardware model.

```sh
python3 guest_check.py --repeat 20 -- ./zig-out/bin/fx -v
python3 guest_check.py -- ./zig-out/bin/fx help
python3 guest_check.py -- ./zig-out/bin/fx status --json
python3 guest_tui_check.py
```

The TUI check attaches a controlling terminal, dismisses onboarding, opens
and closes help, and exits. It fails on abnormal termination, stderr output,
or missing help content. Preserve the JSON results and terminal recording.

Build the independent concurrent-fault fixture on the host, but run it only
inside the guest:

```sh
clang -O2 -Wl,-headerpad,0x4000 experiments/pager/thread_fixture.c -o zig-out/pager-thread-input
experiments/pager/build_pagerized.sh --source zig-out/pager-thread-input --output-dir zig-out/pager-thread
```

Its eight threads simultaneously enter cold functions and verify their return
values. Test multiple fresh launches. Failure injection must additionally
verify rejected page checksums and rejected RW transitions exit cleanly.

The host-side `verify_guest.py` automates transfer with hash verification,
eager and demand CLI checks, a TUI interaction, concurrency, and injected
failure checks. It requires an already running guest with a verified SSH key:

```sh
python3 experiments/pager/verify_guest.py --ssh-host admin@GUEST_IP \
  --key /path/to/guest-key --known-hosts /path/to/known-hosts \
  --build-dir /path/to/builds --report /path/to/guest-verification.json
```

The build directory must contain `eager`, `demand`, `thread-demand`, and
`write-demand` outputs. Build the last using the C fixture with
`-DTEST_WRITE_FAULT=1`; it deliberately writes to a restored code page and
must exit with code 88. The runner records guest OS, boot identity and binary
hashes alongside results. It never runs these binaries locally.

## Limits

A guest pass does not establish host safety. Guest and host kernels can enforce
different executable-memory policies. This experiment does not qualify
notarized distribution, arbitrary Mach-O files, signal-handler coexistence,
post-start fork recovery, or production startup latency. It still owns SIGBUS
and SIGSEGV for the process lifetime. Preserve original panic evidence and
report the confirmed facts separately from suspected kernel mechanisms.

For external storage, keep Tart's home, image cache, VM disk and temporary
files on the same APFS volume using a dedicated wrapper. Keep the drive
attached while the VM is running. The VM still consumes host CPU and RAM.
