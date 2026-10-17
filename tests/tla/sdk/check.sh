#!/bin/sh
# Model-checks DurableSession.tla with TLC, confirms each witness is
# violated, and writes the state graphs ../drivers/drive.mjs walks against
# the code.
#
# Needs Java 11+ and tla2tools.jar:
#   brew install openjdk
#   mkdir -p ~/.local/share/tla
#   curl -fL -o ~/.local/share/tla/tla2tools.jar \
#     https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar
#
# Then drive the code along the graphs with the drivers in ../drivers/:
#   bun ../drivers/drive.mjs send && bun ../drivers/drive.mjs lookup
#   bun ../drivers/drive.mjs write && bun ../drivers/drive.mjs cutoff
#   bun ../drivers/drive.mjs leased   # the Heartbeat graph, on a World without liveness
#   bun ../drivers/drive.mjs queue    # the QueueHeld graph, on a World whose queue shows it
#   bun ../drivers/drive.mjs refuse   # the Refused graph: a turn that ends before any record
#   bun ../drivers/drive-agents.mjs   # AgentRouting
#   bun ../drivers/drive-steer.mjs ideal && bun ../drivers/drive-steer.mjs faults   # DurableSteer
#   bun ../drivers/drive-tenants.mjs   # TenantIsolation
set -eu
cd "$(dirname "$0")"

jar="${TLA2TOOLS_JAR:-$HOME/.local/share/tla/tla2tools.jar}"
[ -f "$jar" ] || { echo "tla2tools.jar not found at $jar (set TLA2TOOLS_JAR)" >&2; exit 2; }
java=""
for candidate in "${JAVA_HOME:+$JAVA_HOME/bin/java}" /opt/homebrew/opt/openjdk/bin/java /usr/local/opt/openjdk/bin/java "$(command -v java 2>/dev/null || true)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ] && "$candidate" -version >/dev/null 2>&1; then java="$candidate"; break; fi
done
[ -n "$java" ] || { echo "no working Java runtime (set JAVA_HOME or brew install openjdk)" >&2; exit 2; }

# A new private folder per run for logs and TLC state, so nothing planted in
# the temp folder can redirect them. Logs print on failure, so it is removed.
work="$(mktemp -d "${TMPDIR:-/tmp}/libfx-model-tlc.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p graphs
status=0
for tool in send lookup write cutoff leased queue refuse; do
    echo "== DurableSession ($tool)"
    if ! "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC -deadlock -workers 1 -cleanup \
        -metadir "$work/$tool" -dump dot,actionlabels "graphs/$tool" \
        -config "DurableSession-$tool.cfg" DurableSession.tla > "$work/$tool.log" 2>&1; then
        cat "$work/$tool.log"; status=1; continue
    fi
    grep -E 'distinct states|depth of' "$work/$tool.log"
done
# Each witness must break the invariant named after it: it shows the model
# reaches that state. NoSelfStop breaks TwoActiveNeedsFreeze: without the
# self-stop, two workers are active at once with no freeze at all.
# NoClaimFence breaks EffectsAtMostOnce: a claim that counts on a stale read
# continues the turn from before a call with effects started, and runs it
# again. NoCutoffBound breaks HandoffsBounded: without the bound, a call
# that outlasts every delivery is cut off and run again forever.
# LeasedTwoActive breaks NotTwoActive with Heartbeat: a renewed lease ends a
# woken worker's run at its next renewal, not before, so two can still be
# active at once until it lands.
# LookupRunsAhead breaks EveryCallAfterIntent: a lookup starts before its
# intent is in the chain. LookupNewId breaks IdsAtMostOne: a crash before
# that intent lands has the model ask again, under a new execution id.
# WriteRunsAhead breaks OneExecutionId: a write that ran ahead the same way
# would run under two ids, which is why a write waits for its intent.
# NoEndRepair breaks EndRecoverable: without Repair, a holder that crashes
# between a turn's end record and its turn_end line leaves a done turn no
# reader sees end, and every worker that reads the log finds nothing to do.
# NoRefusedRepair breaks it the same way for a turn the harness refused,
# which ends through an `ended` entry and no record: libfx repaired only a
# turn a record ended, which on the refuse graph is no repair at all.
for pair in UiInOrder:UiInOrder NoStaleShown:NoStaleShown NotTwoActive:NotTwoActive \
    NoSelfStop:TwoActiveNeedsFreeze NoClaimFence:EffectsAtMostOnce NoCutoffBound:HandoffsBounded \
    LeasedTwoActive:NotTwoActive LookupRunsAhead:EveryCallAfterIntent LookupNewId:IdsAtMostOne \
    WriteRunsAhead:OneExecutionId NoEndRepair:EndRecoverable NoRefusedRepair:EndRecoverable; do
    witness="${pair%%:*}" invariant="${pair#*:}"
    if "$java" -cp "$jar" tlc2.TLC -deadlock -workers auto -cleanup -metadir "$work/w-$witness" \
        -config "Witness-$witness.cfg" DurableSession.tla 2>&1 | grep -q -E "Invariant $invariant is violated"; then
        echo "== witness $witness reached"
    else
        echo "== witness $witness NOT reached" >&2; status=1
    fi
done
# DurableSteer.tla: where each message a user sends ends up. The ideal graph
# has no faults, and the faults graph adds cancels, deadline handoffs and
# client retries.
for graph in ideal faults; do
    echo "== DurableSteer ($graph)"
    if ! "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC -deadlock -workers 1 -cleanup \
        -metadir "$work/steer-$graph" -dump dot,actionlabels "graphs/steer-$graph" \
        -config "DurableSteer-$graph.cfg" DurableSteer.tla > "$work/steer-$graph.log" 2>&1; then
        cat "$work/steer-$graph.log"; status=1; continue
    fi
    grep -E 'distinct states|depth of' "$work/steer-$graph.log"
done
# Each witness turns one rule off and must break the property it protects:
# without Interrupt a steer waits on a streaming reply, without HandBack a
# cancel loses a steer that never reached the model, without JoinBeforeStart
# a steer sent before the first turn starts runs as a turn of its own,
# without Dedupe a retried steer reaches the model twice, without
# ReadAfterTool a steer stored while a tool runs misses the request after
# its result when the worker has not read the log since, without
# CallWaits a steer sent once a reply ended in a tool call ends the turn and
# runs as a turn of its own, and without ReadAtEnd so does one another
# server stores while the last reply streams.
for pair in NoInterrupt:NoSteerWaitsOnReply NoHandBack:NothingLost \
    NoJoinBeforeStart:PreStartJoins NoDedupe:AtMostOnce NoReadAfterTool:SteerInNextRequest \
    NoCallWait:NoParkedSteer NoReadAtEnd:NoParkedSteer; do
    witness="${pair%%:*}" invariant="${pair#*:}"
    if "$java" -cp "$jar" tlc2.TLC -deadlock -workers auto -cleanup -metadir "$work/sw-$witness" \
        -config "SteerWitness-$witness.cfg" DurableSteer.tla 2>&1 | grep -q -E "Invariant $invariant is violated"; then
        echo "== steer witness $witness reached"
    else
        echo "== steer witness $witness NOT reached" >&2; status=1
    fi
done

# UiStream.tla: a session's UI stream as a reader in another process sees it
# while a worker writes it. libfx writes each line before the next unless
# the World keeps a batch's order, as Vercel's does: on either World the
# live reader gets what a replay gets. The witness writes batches to a World
# that writes a batch's chunks in parallel, as libfx did on world-local, and
# the live reader gets a line under another cursor than a replay gives it.
for config in local vercel; do
    echo "== UiStream ($config)"
    if ! "$java" -cp "$jar" tlc2.TLC -deadlock -workers 1 -cleanup -metadir "$work/ui-$config" \
        -config "UiStream-$config.cfg" UiStream.tla > "$work/ui-$config.log" 2>&1; then
        cat "$work/ui-$config.log"; status=1; continue
    fi
    grep -E 'distinct states|depth of' "$work/ui-$config.log"
done
if "$java" -cp "$jar" tlc2.TLC -deadlock -workers auto -cleanup -metadir "$work/uw-Batched" \
    -config UiStreamWitness-Batched.cfg UiStream.tla 2>&1 | grep -q -E "Invariant LiveIsReplay is violated"; then
    echo "== ui witness Batched reached"
else
    echo "== ui witness Batched NOT reached" >&2; status=1
fi

# AgentRouting.tla: which agent runs a session's turns when an app has
# several. Its graph is what ../drivers/drive-agents.mjs walks, with process p2
# lacking one agent; every sender stores its input before it queues it. Drains is checked under fairness, a simulation runs a larger
# config, and each witness breaks RunsOnOwner: NoNames is routing without
# names, as before them, and NoOwnerCheck a worker that runs any session it
# is handed.
for config in send; do
    echo "== AgentRouting ($config)"
    if ! "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC -deadlock -workers 1 -cleanup \
        -metadir "$work/agents-$config" -dump dot,actionlabels "graphs/agents-$config" \
        -config "AgentRouting-$config.cfg" AgentRouting.tla > "$work/agents-$config.log" 2>&1; then
        cat "$work/agents-$config.log"; status=1; continue
    fi
    grep -E 'distinct states|depth of' "$work/agents-$config.log"
done
for config in drains-send; do
    if "$java" -cp "$jar" tlc2.TLC -deadlock -workers auto -cleanup -metadir "$work/agents-$config" \
        -config "AgentRouting-$config.cfg" AgentRouting.tla > "$work/agents-$config.log" 2>&1; then
        echo "== AgentRouting ($config): Drains holds"
    else
        cat "$work/agents-$config.log"; status=1
    fi
done
if "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC -simulate num=20000 -depth 50 -deadlock -workers auto -cleanup \
    -metadir "$work/agents-sim" -config AgentRouting-sim.cfg AgentRouting.tla > "$work/agents-sim.log" 2>&1; then
    echo "== AgentRouting (simulation): $(grep -E 'states checked' "$work/agents-sim.log" | tail -1)"
else
    cat "$work/agents-sim.log"; status=1
fi
for witness in NoNames NoOwnerCheck; do
    if "$java" -cp "$jar" tlc2.TLC -deadlock -workers auto -cleanup -metadir "$work/w-$witness" \
        -config "Witness-$witness.cfg" AgentRouting.tla 2>&1 | grep -q -E "Invariant RunsOnOwner is violated"; then
        echo "== witness $witness reached"
    else
        echo "== witness $witness NOT reached" >&2; status=1
    fi
done

# TenantIsolation.tla: tenants whose agents share one process, and an
# attacker who can post to its route. Its graph, with every rule on, is what
# ../drivers/drive-tenants.mjs walks; SentRuns is checked under fairness.
# Each witness turns one rule off and must break what it protects:
# TrustBody runs a forged delivery, ShareName runs one tenant's prompt on
# another's agent, RouteByName strands a prompt on another store,
# NoAdmission stores an oversized input, and Today, every rule off as libfx
# was before them, runs a prompt in another tenant's store. The dev graph,
# two tenants on one store under NODE_ENV=development, is what
# ../drivers/drive-tenants.mjs --development walks. DevReplaces shows a
# replaced agent's prompt running on its replacement, DevOtherStore that a
# replacement on another store under the same key leaves it unrun, and
# DevOldestWins that without NewestWins an agent created on the default store
# that learns its store late replaces a newer agent there, as libfx did.
for config in route dev; do
    echo "== TenantIsolation ($config)"
    if ! "$java" -XX:+UseParallelGC -cp "$jar" tlc2.TLC -deadlock -workers 1 -cleanup \
        -metadir "$work/tenants-$config" -dump dot,actionlabels "graphs/tenants-$config" \
        -config "TenantIsolation-$config.cfg" TenantIsolation.tla > "$work/tenants-$config.log" 2>&1; then
        cat "$work/tenants-$config.log"; status=1
    else
        grep -E 'distinct states|depth of' "$work/tenants-$config.log"
    fi
done
for config in drains dev-drains; do
    if "$java" -cp "$jar" tlc2.TLC -deadlock -workers auto -cleanup -metadir "$work/tenants-$config" \
        -config "TenantIsolation-$config.cfg" TenantIsolation.tla > "$work/tenants-$config.log" 2>&1; then
        echo "== TenantIsolation ($config): SentRuns holds"
    else
        cat "$work/tenants-$config.log"; status=1
    fi
done
for pair in "TrustBody:Invariant OnlySentRuns is violated" "ShareName:Invariant RunsOnSenderAgent is violated" \
    "RouteByName:Temporal properties were violated" "NoAdmission:Invariant StoredWithinLimit is violated" \
    "Today:Invariant RunsInSenderStore is violated" "DevReplaces:Invariant RunsOnSenderAgent is violated" \
    "DevOtherStore:Temporal properties were violated" "DevOldestWins:Invariant ReplacedByNewer is violated"; do
    witness="${pair%%:*}" verdict="${pair#*:}"
    if "$java" -cp "$jar" tlc2.TLC -deadlock -workers auto -cleanup -metadir "$work/tw-$witness" \
        -config "TenantWitness-$witness.cfg" TenantIsolation.tla 2>&1 | grep -q -F "$verdict"; then
        echo "== tenant witness $witness reached"
    else
        echo "== tenant witness $witness NOT reached" >&2; status=1
    fi
done
exit "$status"
