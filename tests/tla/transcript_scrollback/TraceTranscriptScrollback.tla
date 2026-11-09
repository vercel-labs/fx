---- MODULE TraceTranscriptScrollback ----
\* Checks traces of the built fx against TranscriptScrollback.
\*
\* tests/tla/drivers/transcript_scrollback/binary-to-spec.ts resumes a long
\* saved session, submits a prompt while the resume still publishes, and reads
\* what each committed frame did from the trace log: the rows it scrolled, the
\* top of the screen, the transcript area, the rows of the flow, and the
\* history mark the runtime claimed. It writes the run as one sequence of
\* states into TraceData.tla, with the scrollback each frame's scroll made.
\*
\* TLC walks the trace. ConformsToSpec holds when every recorded step is a
\* step of the model's Next, so the frame after the handoff scrolled exactly
\* the rows the model says it must. The law names below re-export the model's
\* laws, checked on what the binary did. The driver writes the constants into
\* the config of each run, from the trace.
EXTENDS Integers, Sequences, TraceData

CONSTANTS PublishedRows, MaxArea, MaxGrowth, MaxSubmits, MaxStep, Rule

VARIABLES phase, total, view, area, sb, mark, armed, submits, trace, at

TS == INSTANCE TranscriptScrollback

vars == <<phase, total, view, area, sb, mark, armed, submits>>

Load(s) ==
    /\ phase = s.phase /\ total = s.total /\ view = s.view /\ area = s.area
    /\ sb = s.sb /\ mark = s.mark /\ armed = s.armed /\ submits = s.submits

LoadNext(s) ==
    /\ phase' = s.phase /\ total' = s.total /\ view' = s.view /\ area' = s.area
    /\ sb' = s.sb /\ mark' = s.mark /\ armed' = s.armed /\ submits' = s.submits

TraceInit == trace \in 1..Len(Traces) /\ at = 1 /\ Load(Traces[trace][1])

TraceNext ==
    /\ at < Len(Traces[trace])
    /\ at' = at + 1
    /\ trace' = trace
    /\ LoadNext(Traces[trace][at + 1])

TraceSpec == TraceInit /\ [][TraceNext]_<<vars, trace, at>>

\* Every trace starts where the model starts.
StartsAtInit == at = 1 => TS!Init

\* Every recorded step is a step of the model.
ConformsToSpec == [][TS!Next]_vars

\* The laws of TranscriptScrollback, on what the binary did.
TypeOK == TS!TypeOK
InOrderOnce == TS!InOrderOnce
NothingAbove == TS!NothingAbove
NothingBoth == TS!NothingBoth
MarkHonest == TS!MarkHonest
====
