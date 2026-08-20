# Persistent IPython and Background Agent Architecture

This note describes the kernel and daemon behavior currently implemented in
fx. It also marks the resident-worker features that are planned but are not
available yet.

## Ownership

`src/core/kernel/runtime.zig` owns the persistent IPython process and its
bounded request and response framing. Each root agent runtime owns one runtime:
the interactive `App`, a headless `ask` context, or an ACP server state where
that host supports IPython. Every child agent receives the same runtime and
root-session identity, so a root agent and its child agents share one IPython
namespace. Unrelated root sessions are isolated: changing the root identity
stops the old worker before the new one starts.

`src/tools/agent/ipython.zig` owns the model-facing `ipython` tool contract.
The normal tool admission and permission paths remain authoritative. The
kernel is execution state, not product state: the session runtime, transcript,
model calls, tools, permissions, subagent tree, and durable session records
remain owned by the existing agent and session modules.

`src/core/daemon/daemon.zig` owns the local background-agent supervisor,
private job records, process identity checks, retained-log limits, and the Unix
socket request loop. A submitted job is a detached, one-shot invocation of the
supervisor's exact `fx ask --json` executable path. The daemon does not own a
second agent runtime or a second kernel implementation. Existing
`src/core/background/` code continues to track shell background processes.

## Typed contracts and output

The kernel runtime exposes a typed `Provider` seam for tests and an
`ExecutionResult` containing bounded stdout, stderr, an optional result,
status, and duration. Production uses one framed IPython worker per root
runtime. Code is limited to 256 KiB, output defaults to 64 KiB, and protocol
frames are bounded to 2 MiB.

The daemon accepts versioned JSONL requests for status, jobs, show, submit,
stop, and shutdown. The CLI adds `start` as an explicit supervisor startup
operation. Daemon snapshots and command results use the shared output
contracts, so `--json` and text output describe the same state. A public job
snapshot contains its ID, state, PID when known, working directory, prompt,
log path, and exit code. It never exposes the process-instance token. That
token is private fencing data retained only in the job record used by the
supervisor.

## Kernel setup and lifecycle

On first use, fx bootstraps the managed interpreter at
`~/.fx/kernel-venv/bin/python` and installs `ipython==9.16.1`. Bootstrap is
serialized with a private profile lock and uses `uv` when available, with a
Python venv and pip fallback. Set `FX_IPYTHON_PYTHON` to use an existing
interpreter instead; it must be able to import the required IPython package.
The production kernel host is enabled on Linux and macOS.

The worker starts lazily in the root workspace, serializes execution, and is
stopped with its owning root runtime or when its root session identity changes.
Interactive, headless `ask`, and ACP root runtimes each follow that lifecycle
where IPython is available. Child agents share the root runtime; they do not
create one kernel each.
There is no cross-session namespace persistence or kernel snapshot/restore in
this stage.

## Daemon commands and lifecycle

The implemented commands are:

```text
fx daemon start
fx daemon status [--json]
fx daemon submit [--cwd PATH] -- <prompt>
fx daemon jobs [--json]
fx daemon show <job-id> [--json]
fx daemon stop <job-id> [--json]
fx daemon shutdown [--json]
```

`submit` starts the supervisor if necessary, queues a detached one-shot
`fx ask --json` job, and returns its job ID before the client exits. The worker
continues after the submitting CLI exits. Job metadata, stdout, and stderr are
stored below `~/.fx/daemon/jobs/`; `show` reports the metadata and log path.
`stop` requests termination of one job. `shutdown` stops running jobs and the
supervisor. The supervisor socket and identity record are under
`~/.fx/daemon/`.

The supervisor retains at most 64 job records. Before accepting another job,
it removes the oldest settled record and its logs; if all 64 retained jobs are
still active, submission fails without starting another process. Requests and
responses have a 512 KiB frame limit and a five-second socket I/O timeout.

This stage does not implement a resident interactive worker, attach,
reconnect, prompt streaming, event replay, or handoff of an active session.
Those are future daemon stages and must add explicit leases, resumable event
cursors, and recovery tests before they are documented as user behavior.

## Security and persistence boundaries

Kernel code executes with the user's operating-system permissions. The IPython
runtime is not a sandbox and must not bypass fx permission admission. IPython
approval is tool-level rather than a filesystem boundary. Detached jobs retain
the normal `fx ask` permission policy; daemon submission is not an
authorization grant.

Daemon directories, socket, job records, and logs are created with private
permissions. Job records include process-instance tokens so a recycled PID is
not treated as the original worker. Code, output, protocol frames, and prompts
are bounded. Stdout and stderr are drained concurrently while a job runs, and
only the latest 4 MiB of each stream is retained. The daemon uses its own exact
executable path with a canonical working directory and does not accept
arbitrary executable paths through the public command. Restart the supervisor
after switching fx builds.

## IPython versus Julia benchmark

The harness in `benchmarks/kernel_runtime.py` used the same line-framed test
protocol, state-retention check, numeric workload, 1 MiB output, and
resident-process measurement for both runtimes. It compares equivalent
persistent-worker behavior rather than fx's production length-prefixed JSON
framing. RSS comes from Linux `/proc`; other platforms report it as
unavailable. This recorded Linux run used twenty startup runs, five hundred
warm cells, and one hundred workload runs:

| Runtime | First usable median | First usable p95 | Warm cell median | Warm cell p95 | First workload | Warm numeric | RSS | 1 MiB output |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| IPython 9.16.1 | 350.2 ms | 408.8 ms | 514.2 µs | 777.9 µs | 7.4 ms | 7852.9 µs | 45.3 MiB | 22.8 ms |
| Julia 1.12.7 | 744.1 ms | 880.9 ms | 473.7 µs | 738.7 µs | 49.0 ms | 324.9 µs | 296.6 MiB | 159.1 ms |

Julia wins the warmed numeric loop. IPython wins startup, first workload,
resident memory, and large-output transfer, so IPython is the selected fx
kernel. Julia was installed and benchmarked on the development host, but is
not exposed as a second backend or a runtime-selection command.

These numbers are host-specific observations, not product latency budgets.
Re-run the harness after changing the worker protocol or bootstrap
environment. A typical invocation is:

```bash
python3 benchmarks/kernel_runtime.py \
  --python /path/to/python-with-ipython \
  --julia /path/to/julia \
  --startup-runs 20 \
  --warm-runs 500 \
  --workload-runs 100
```

## Verification and PGSO

Focused tests should cover provider framing, singleton identity, root and child
namespace sharing, session isolation, bootstrap locking, output limits, and
daemon request parsing, job records, process fencing, and shutdown. A
credential-free deterministic daemon E2E can cover submit, jobs, show, stop,
and shutdown; classify that root test exactly once in
`scripts/pgso/corpus.json`. Attach/reconnect and crash-recovery tests belong to
the future resident-worker stage. Dedicated stale-PID recovery and adversarial
fencing owners are Verification-only; ordinary public-output, stop, and other
deterministic command flows can be Training.
