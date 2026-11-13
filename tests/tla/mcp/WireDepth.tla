---- MODULE WireDepth ----
\* How deep a server's JSON may be when fx writes it again. The engine hands the host
\* any message up to EngineLimit levels deep (src/mcp/protocol/wire.zig, scan_stack_bytes:
\* 2,584 levels for a message, so 2,581 for a listed tool's own value, which sits three
\* levels inside its message);
\* a deeper one it drops, and the call waits (the sibling N6). The host turns a
\* server's JSON into a value at three entry points: a tool call's result
\* (parseCallOutcome), a listed tool (parseTool) and an elicitation form (parseRequest).
\* Writers then write that value, or a part of it, again with std.json.Stringify,
\* which keeps its nesting in a stack of Capacity levels in a safe build (Debug and
\* ReleaseSafe; std/json/Stringify.zig), and aborts past it. A writer may add Wrap
\* levels of its own around the value, such as an envelope.
\*
\* An entry point accepts a message that is at most Limit levels deep and refuses a
\* deeper one with a tool error (src/core/mcp/json_depth.zig, `within`). Skips names
\* entry points that skip the check; none does in the code. NoWriterOverflow: whatever
\* an entry point accepts, every writer behind it can write. The other properties
\* keep the limit honest: a message within it is accepted, one past it is refused, and
\* only a message past the engine's own limit is dropped.
\*
\* Today there is no limit but the engine's (WireDepth.findings.cfg), so a message
\* between Capacity and EngineLimit levels deep is accepted and aborts a writer.
\* Not modelled: an error's data, which the host never writes as the server sent it
\* (src/core/mcp_host/model.zig, render builds the error's envelope itself).
EXTENDS Naturals

CONSTANTS
    Limit,        \* the deepest value an entry point accepts
    Capacity,     \* the nesting a writer's stack holds
    EngineLimit,  \* the deepest message the engine hands the host
    MaxDepth      \* the deepest message tried

Entries == {"result", "tool", "form"}
Writers == {"result", "tool_fields", "form_meta", "form_schema", "bridge"}

EntryOf == [result |-> "result", tool_fields |-> "tool", form_meta |-> "form", form_schema |-> "form", bridge |-> "result"]
Wrap == [result |-> 0, tool_fields |-> 0, form_meta |-> 0, form_schema |-> 0, bridge |-> 2]
Skips == {}
Bound == Limit

ASSUME Limit \in Nat /\ Capacity \in Nat /\ EngineLimit \in Nat /\ MaxDepth \in Nat

Verdicts == {"idle", "accepted", "refused", "dropped"}

VARIABLES
    entry,    \* the entry point the last message reached
    depth,    \* how deep it was
    verdict   \* what happened to it

vars == <<entry, depth, verdict>>

WritersOf(e) == {w \in Writers : EntryOf[w] = e}

Accepts(e, d) == e \in Skips \/ d <= Bound

Verdict(e, d) ==
    IF d > EngineLimit THEN "dropped"
    ELSE IF Accepts(e, d) THEN "accepted"
    ELSE "refused"

TypeOK ==
    /\ entry \in Entries \cup {"none"}
    /\ depth \in 0..MaxDepth
    /\ verdict \in Verdicts

Init ==
    /\ entry = "none"
    /\ depth = 0
    /\ verdict = "idle"

\* A message of depth d reaches entry point e.
Message(e, d) ==
    /\ entry' = e
    /\ depth' = d
    /\ verdict' = Verdict(e, d)

Next == \E e \in Entries, d \in 0..MaxDepth : Message(e, d)

Spec == Init /\ [][Next]_vars

\* Every writer behind an accepted message can write it.
NoWriterOverflow ==
    verdict = "accepted" => \A w \in WritersOf(entry) : depth + Wrap[w] <= Capacity

\* A message within the code's bound is accepted. (Bound is what the code enforces: Limit.)
AcceptedUpToLimit ==
    (verdict # "idle" /\ depth <= Bound /\ depth <= EngineLimit) => verdict = "accepted"

\* A message past the code's bound that the engine handed over is refused.
PastLimitRefused ==
    (verdict # "idle" /\ depth > Bound /\ depth <= EngineLimit) => verdict = "refused"

\* Only a message past the engine's own limit is dropped.
DroppedOnlyPastEngine ==
    verdict = "dropped" <=> (verdict # "idle" /\ depth > EngineLimit)
====
