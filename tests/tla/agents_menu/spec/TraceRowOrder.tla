---- MODULE TraceRowOrder ----
\* Checks runs of the built fx against the rule of RowOrder.tla.
\*
\* tests/tla/drivers/agents_menu/row-order.ts starts fx with held subagents,
\* opens the agent list, lets the subagents finish one at a time, and reads
\* every frame of the list while it does: each subagent row's state and the
\* rows' order, plus `rank`, the order the driver let the subagents finish in,
\* 0 before that. It writes each run as one sequence of frames into
\* TraceRowData.tla.
\*
\* TLC walks every frame sequence. The two rules below are the ones of
\* RowOrder.tla, read from what fx drew: PlaceChangesWithLabel is the same
\* formula, and IdleRowsNewestFirst is IdleRowIsApplied as the driver can see
\* it, since the driver knows which reply is newest.
EXTENDS Integers, Sequences, FiniteSets, TLC, TraceRowData

VARIABLES shown, order, rank, trace, at

vars == <<shown, order, rank>>

Load(f) == shown = f.shown /\ order = f.order /\ rank = f.rank

TraceInit == trace \in 1..Len(RowTraces) /\ at = 1 /\ Load(RowTraces[trace][1])

TraceNext ==
    /\ at < Len(RowTraces[trace])
    /\ at' = at + 1
    /\ trace' = trace
    /\ shown' = RowTraces[trace][at + 1].shown
    /\ order' = RowTraces[trace][at + 1].order
    /\ rank' = RowTraces[trace][at + 1].rank

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, trace, at>>

TypeOK ==
    /\ shown \in [TraceSubs -> {"working", "idle"}]
    /\ order \in Seq(TraceSubs)
    /\ rank \in [TraceSubs -> 0..Cardinality(TraceSubs)]

\* The rows change places only in a frame that changes a row's state: a row
\* never moves by itself after it shows its new state.
PlaceChangesWithLabel == [][order' # order => shown' # shown]_vars

\* Of two rows that show idle, the one that replied later is listed first: a
\* row that shows idle is already placed by its newest reply.
IdleRowsNewestFirst ==
    \A i, j \in DOMAIN order :
        (i < j /\ shown[order[i]] = "idle" /\ shown[order[j]] = "idle")
            => rank[order[i]] >= rank[order[j]]
====
