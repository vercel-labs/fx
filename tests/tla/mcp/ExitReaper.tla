---- MODULE ExitReaper ----
\* What becomes of fx's stdio servers when fx goes, by exit or crash
\* (src/mcp/io/process.zig). At exit fx sends each server's
\* process group SIGTERM and waits for none. A helper process, started before
\* the first server, hears over a pipe each group that starts ("+") and each
\* one fx reaps ("-"). When fx is gone the pipe closes; the helper reads it to
\* the end, sends SIGTERM to the groups it still lists, waits a grace, then
\* sends SIGKILL.
\*
\* A server instance is one process: alive, a zombie once it has died, then
\* reaped by fx, or by init once fx is gone. A stubborn one ignores SIGTERM
\* and closed stdin and dies only of SIGKILL. Once reaped, its id may name a
\* stranger's group, but only while fx runs: a pid comes round again only
\* after the system has handed out every other one, far longer than the grace.
\*
\* Not modelled: a crash between a spawn and its "+", a few instructions, which
\* leaves that server unlisted; NoSurvivor covers only servers fx has told.
EXTENDS Naturals, Sequences

CONSTANTS Inst   \* the server processes fx may start, each at most once

VARIABLES
    fx,        \* "up", "exiting" (SIGTERM sent), or "gone"
    st,        \* [Inst -> "unborn", "alive", "zombie", or "reaped"]
    stubborn,  \* [Inst -> BOOLEAN]
    termed,    \* [Inst -> BOOLEAN]: it has had SIGTERM
    told,      \* [Inst -> BOOLEAN]: fx has written its "+"
    pipe,      \* messages written and not yet read, oldest first
    list,      \* the groups the helper holds
    helper,    \* "none", "reading", "grace", or "done"
    stranger,  \* [Inst -> BOOLEAN]: its id now names someone else's group
    stray      \* the helper has signalled a stranger's group

vars == <<fx, st, stubborn, termed, told, pipe, list, helper, stranger, stray>>

TypeOK ==
    /\ fx \in {"up", "exiting", "gone"}
    /\ st \in [Inst -> {"unborn", "alive", "zombie", "reaped"}]
    /\ stubborn \in [Inst -> BOOLEAN]
    /\ termed \in [Inst -> BOOLEAN]
    /\ told \in [Inst -> BOOLEAN]
    /\ list \subseteq Inst
    /\ helper \in {"none", "reading", "grace", "done"}
    /\ stranger \in [Inst -> BOOLEAN]
    /\ stray \in BOOLEAN

Init ==
    /\ fx = "up"
    /\ st = [i \in Inst |-> "unborn"]
    /\ stubborn = [i \in Inst |-> FALSE]
    /\ termed = [i \in Inst |-> FALSE]
    /\ told = [i \in Inst |-> FALSE]
    /\ pipe = <<>>
    /\ list = {}
    /\ helper = "none"
    /\ stranger = [i \in Inst |-> FALSE]
    /\ stray = FALSE

Running == fx \in {"up", "exiting"}

\* Before the first server: the helper and its pipe.
StartHelper ==
    /\ Running /\ helper = "none"
    /\ helper' = "reading"
    /\ UNCHANGED <<fx, st, stubborn, termed, told, pipe, list, stranger, stray>>

\* A server starts; one that starts after the exit signal gets SIGTERM at once.
Spawn(i) ==
    /\ Running /\ helper # "none" /\ st[i] = "unborn"
    /\ st' = [st EXCEPT ![i] = "alive"]
    /\ \E b \in BOOLEAN : stubborn' = [stubborn EXCEPT ![i] = b]
    /\ termed' = [termed EXCEPT ![i] = (fx = "exiting")]
    /\ UNCHANGED <<fx, told, pipe, list, helper, stranger, stray>>

\* fx writes the group's "+" just after the spawn, whatever the server has
\* done since, and before the exit watcher that reaps it starts. Without a
\* helper there is no pipe to write to.
Tell(i) ==
    /\ Running /\ st[i] # "unborn" /\ ~told[i]
    /\ told' = [told EXCEPT ![i] = TRUE]
    /\ pipe' = IF helper = "none" THEN pipe ELSE Append(pipe, <<"+", i>>)
    /\ UNCHANGED <<fx, st, stubborn, termed, list, helper, stranger, stray>>

\* A server that isn't stubborn may die at any time, and does once it has
\* SIGTERM or its stdin has closed.
Die(i) ==
    /\ st[i] = "alive" /\ ~stubborn[i]
    /\ st' = [st EXCEPT ![i] = "zombie"]
    /\ UNCHANGED <<fx, stubborn, termed, told, pipe, list, helper, stranger, stray>>

\* fx's exit watcher reaps a dead server and writes its "-" under the same
\* lock (pid_lock), so its id can't come round before the helper is told.
Reap(i) ==
    /\ Running /\ st[i] = "zombie" /\ told[i]
    /\ st' = [st EXCEPT ![i] = "reaped"]
    /\ pipe' = Append(pipe, <<"-", i>>)
    /\ UNCHANGED <<fx, stubborn, termed, told, list, helper, stranger, stray>>

\* Once fx is gone, init reaps its orphans.
InitReaps(i) ==
    /\ fx = "gone" /\ st[i] = "zombie"
    /\ st' = [st EXCEPT ![i] = "reaped"]
    /\ UNCHANGED <<fx, stubborn, termed, told, pipe, list, helper, stranger, stray>>

\* A reaped id comes round again, for a stranger's group, while fx runs.
Reuse(i) ==
    /\ fx = "up" /\ st[i] = "reaped" /\ ~stranger[i]
    /\ stranger' = [stranger EXCEPT ![i] = TRUE]
    /\ UNCHANGED <<fx, st, stubborn, termed, told, pipe, list, helper, stray>>

\* fx's exit: SIGTERM to every live group, and it waits for none.
ExitSignal ==
    /\ fx = "up"
    /\ fx' = "exiting"
    /\ termed' = [i \in Inst |-> termed[i] \/ st[i] = "alive"]
    /\ UNCHANGED <<st, stubborn, told, pipe, list, helper, stranger, stray>>

Exit ==
    /\ fx = "exiting"
    /\ fx' = "gone"
    /\ UNCHANGED <<st, stubborn, termed, told, pipe, list, helper, stranger, stray>>

\* fx crashes or is killed: it sends nothing.
Crash ==
    /\ Running
    /\ fx' = "gone"
    /\ UNCHANGED <<st, stubborn, termed, told, pipe, list, helper, stranger, stray>>

\* The helper reads what fx wrote, also after fx is gone.
Read ==
    /\ helper = "reading" /\ pipe # <<>>
    /\ LET m == Head(pipe) IN
         list' = IF m[1] = "+" THEN list \cup {m[2]} ELSE list \ {m[2]}
    /\ pipe' = Tail(pipe)
    /\ UNCHANGED <<fx, st, stubborn, termed, told, helper, stranger, stray>>

\* The pipe has closed and been read to the end: SIGTERM to each group still
\* listed, then the grace.
Closed ==
    /\ helper = "reading" /\ fx = "gone" /\ pipe = <<>>
    /\ helper' = "grace"
    /\ termed' = [i \in Inst |-> termed[i] \/ (i \in list /\ st[i] = "alive")]
    /\ stray' = (stray \/ \E i \in list : stranger[i])
    /\ UNCHANGED <<fx, st, stubborn, told, pipe, list, stranger>>

\* The grace is over: SIGKILL to each group still listed.
GraceOver ==
    /\ helper = "grace"
    /\ helper' = "done"
    /\ st' = [i \in Inst |-> IF i \in list /\ st[i] = "alive" THEN "zombie" ELSE st[i]]
    /\ stray' = (stray \/ \E i \in list : stranger[i])
    /\ UNCHANGED <<fx, stubborn, termed, told, pipe, list, stranger>>

Next ==
    \/ StartHelper \/ ExitSignal \/ Exit \/ Crash \/ Read \/ Closed \/ GraceOver
    \/ \E i \in Inst : Spawn(i) \/ Tell(i) \/ Die(i) \/ Reap(i) \/ InitReaps(i) \/ Reuse(i)

Fairness ==
    /\ WF_vars(Exit) /\ WF_vars(Read) /\ WF_vars(Closed) /\ WF_vars(GraceOver)
    /\ \A i \in Inst : WF_vars(Tell(i)) /\ WF_vars(Die(i)) /\ WF_vars(InitReaps(i))

Spec == Init /\ [][Next]_vars /\ Fairness

\* The helper never signals a group that is no longer one of fx's servers.
NoStrayKill == ~stray

\* The helper's SIGKILL reaches only servers that have had SIGTERM.
KillOnlyAfterTerm ==
    [][helper = "grace" /\ helper' = "done" => \A i \in list : st[i] = "alive" => termed[i]]_vars

\* Once fx is gone, every server it told the helper about stops.
NoSurvivor == fx = "gone" ~> \A i \in Inst : told[i] => st[i] # "alive"
====
