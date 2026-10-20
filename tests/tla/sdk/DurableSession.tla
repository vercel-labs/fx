---------------------------- MODULE DurableSession ----------------------------
(***************************************************************************)
(* One libfx session, one turn, two workers sharing one World.             *)
(*                                                                         *)
(* The turn is: a model step that calls one tool, the tool, then a model   *)
(* step that answers. Workers take the session with a lease whose entries  *)
(* form a chain in the session log. The World accepts every write (the     *)
(* "bump and report" behavior of world-vercel 5.0.1 and world-local), so a *)
(* write counts only when its writer still heads the chain, and a writer   *)
(* that does not learns it at that write and stops.                        *)
(*                                                                         *)
(* A worker reads the log, then claims: it writes the input and its lease, *)
(* which continues the chain where the worker read it. Its first model     *)
(* request goes out while the claim is written, and the turn continues     *)
(* from what the worker read; until the claim lands it writes nothing,     *)
(* shows nothing and runs no tool. A claim counts only when the chain has  *)
(* not moved since the read; a refused one leaves the worker to read       *)
(* again. With ClaimFenced = FALSE a claim counts on a stale read          *)
(* (Witness-NoClaimFence).                                                 *)
(*                                                                         *)
(* The UI stream is a separate World stream with no fencing, so a replaced *)
(* worker's late lines land in it. A worker that takes the session over    *)
(* writes its first line, turn_resume or turn_start, before it continues,  *)
(* and readers hide any line whose epoch is lower than one before it.      *)
(*                                                                         *)
(* A worker can freeze while it waits on the model or a tool; others then  *)
(* treat its lease as dead and may take the session over. A frozen worker  *)
(* that never wakes is a crash. One that wakes carries on until its next   *)
(* write, so two workers can be active at once (the witness below).        *)
(*                                                                         *)
(* With Heartbeat, a holder renews a short lease while it runs, as on a    *)
(* World that cannot tell whether a holder lives. A freeze is then any     *)
(* stall long enough for the lease to run out, and a renewal is a write:   *)
(* one that lands after a worker wakes keeps its lease when it still heads *)
(* the chain, and stops it when another worker took the session over.      *)
(* Its own clock tells a woken worker that its lease ran out, so with      *)
(* StalledWait it shows nothing more until a renewal of its own lands: a   *)
(* replaced worker that wakes adds no line to the stream (LateLine). With  *)
(* StalledWait = FALSE its late lines land (Witness-LeasedStaleShown).     *)
(*                                                                         *)
(* With QueueHeld, the queue shows whether a holder lives, as Vercel       *)
(* Queues does: a holder's delivery keeps its message from every other     *)
(* delivery while it runs, and nothing is renewed. A freeze is the queue   *)
(* giving up on that delivery, and only the delivery it hands the holder's *)
(* message to treats the lease as dead; every other worker still finds it  *)
(* held.                                                                   *)
(*                                                                         *)
(* Shortly before its deadline a worker's own timer stops it: it cuts off  *)
(* the call still running, hands the open turn back to the log, and the    *)
(* same message comes back for a new delivery. So a lease that runs out at *)
(* the deadline never leaves its worker running, and two workers are       *)
(* active at once only when one of them froze. With SelfStop = FALSE the   *)
(* platform ends the lease while the worker runs on (Witness-NoSelfStop).  *)
(*                                                                         *)
(* A step the deadline cuts off is cut off again in each delivery when it  *)
(* always outlasts one. After MaxCutoffs cut-offs in a row with no record  *)
(* between, the next delivery stops running it: a cut-off call is answered *)
(* as possibly run, and a model request cancels the turn. With             *)
(* CutoffBound = FALSE it is run again forever (Witness-NoCutoffBound).    *)
(*                                                                         *)
(* The tool is one of three kinds. A "lookup" is idempotent and does not   *)
(* write, so its call runs ahead: it starts at once and its intent follows *)
(* it to the chain. A crash before that intent lands loses the call, and   *)
(* the next worker asks the model again, which names a new execution id.   *)
(* A "write" is idempotent but writes, keying its effect on the execution  *)
(* id, and a "send" has effects: both start only once their intent counts, *)
(* so a call with effects is never unrecorded and a write reruns only      *)
(* under the id its intent names. With WritesWait = FALSE a write runs     *)
(* ahead too, and runs under two ids (Witness-WriteRunsAhead).             *)
(*                                                                         *)
(* A turn's end is two writes: the record that ends it in the chain, then  *)
(* its turn_end line and the release. A worker that crashes between them   *)
(* leaves a done turn no reader sees end. With Repair, a worker that finds *)
(* such a turn, its holder gone without letting the session go, claims the *)
(* session and writes the missing turn_end; without it nothing reads a     *)
(* done session again (Witness-NoEndRepair).                               *)
(*                                                                         *)
(* With Refused, the harness refuses the turn's input when the turn runs,  *)
(* as fx refuses a malformed prompt an earlier libfx stored (today's       *)
(* prompt() refuses one before storing it): the turn ends before any       *)
(* record, through an `ended` entry outside the chain, which even a        *)
(* replaced worker's write lands, then its turn_end line. A crash between  *)
(* the two needs the same repair (Witness-NoRefusedRepair); libfx had it   *)
(* only for a turn a record ended, which on this graph is no repair at     *)
(* all.                                                                    *)
(*                                                                         *)
(* A turn's end says how the turn ended: the model's answer ends it        *)
(* end_turn, a model request the cut-off bound stops ends it cancelled,    *)
(* and a refused input ends it with an error. With RecordsHow, the record  *)
(* or `ended` entry that ends the turn says so in the same write, and a    *)
(* worker that writes a crashed holder's missing turn_end writes that.     *)
(* Without it, as before libfx recorded how a turn ended, such a worker    *)
(* can only write unknown (Witness-NoEndHow, Witness-NoRefusedHow).        *)
(*                                                                         *)
(* The model's answer streams as ReplyParts text lines, written before its *)
(* record, which lands while some of them are still on their way: Model2   *)
(* lands the record with the first k of them, 0 <= k <= ReplyParts, and    *)
(* EndLine writes the rest, then turn_end. A holder that crashes between   *)
(* the two leaves the reply cut short. With RecordsReply, the record that  *)
(* ends the turn holds its reply, so a worker that writes the missing      *)
(* turn_end first shows, in one line, the parts that the text lines the    *)
(* turn's shown lines end with are not: it reads the stream once its      *)
(* claim lands. Without it, as before, it writes only turn_end, and the    *)
(* reply stays cut short (Witness-NoReplyRepair).                          *)
(*                                                                         *)
(* With SavesReply, as fx saves a finished reply before the turn's end, the *)
(* model's answer lands first a record that saves the reply, and the       *)
(* record that ends the turn follows it, in the same record or one of its  *)
(* own (Commit). A holder that crashes between the two leaves the turn     *)
(* open with its reply saved: the worker that resumes it writes            *)
(* turn_resume, asks the model nothing, and its engine streams none of the *)
(* reply, since the stream holds it. With ResumeFills that worker shows    *)
(* the part of the reply the stream does not, before its turn_end, as one  *)
(* that writes a crashed holder's missing end does; without it the reply   *)
(* stays cut short (Witness-NoResumeFill). Both read the turn's text       *)
(* across turn_resume lines (Unshown), since the resumed worker's own text *)
(* adds to the reply the text before its turn_resume line.                 *)
(*                                                                         *)
(* With Restarts, the worker that resumes such a turn may restart its      *)
(* answer instead, as fx does when the resume brings inputs the saved      *)
(* answer never saw: it shows a notice as a text line that is no part of   *)
(* the answer, then streams the answer again. The turn's text then ends    *)
(* with the crashed holder's start of the answer, that notice, and the     *)
(* resumed worker's start of it. With ReplyAtLine, a worker that writes    *)
(* the end finds the answer's shown start on a line of its own (Unshown);  *)
(* without it, as before, it shows the whole answer again after the        *)
(* resumed worker's start of it (Witness-NoReplyAtLine).                   *)
(*                                                                         *)
(* With LateCancel, the user may cancel the turn while the record that     *)
(* ends it is on its way to the log, after the record that saved its       *)
(* answer. With EndDecides the turn ends as that record says, and the      *)
(* cancel stops nothing; without it, as libfx had it, the worker's         *)
(* turn_end says the turn was cancelled while the log says it ended        *)
(* end_turn (Witness-NoEndDecides).                                        *)
(*                                                                         *)
(* `act` names each step and its worker, so a driver can replay any path   *)
(* of the state graph against the real code and compare every state:       *)
(* tests/tla/drivers/drive.mjs.                                            *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Workers,     \* the processes that can run the session
    Tool,        \* "lookup" (idempotent, no writes), "write" (idempotent,
                 \* writes) or "send" (has effects)
    WritesWait,  \* whether a write waits for its intent before it starts
    MaxEpoch,    \* bound on lease claims
    MaxFreezes,  \* bound on freezes
    SelfStop,    \* whether a worker stops itself before its deadline
    ClaimFenced, \* whether a claim on a stale read is refused
    MaxCutoffs,  \* cut-offs of one step in a row before it is not run again
    CutoffBound, \* whether that bound applies
    Heartbeat,   \* whether a holder renews a short lease while it runs
    QueueHeld,   \* whether only the queue's redelivery of a frozen holder's
                 \* message frees its lease
    Repair,      \* whether a worker writes the turn_end a crashed holder
                 \* left unwritten
    Refused,     \* whether the harness refuses the turn's input, so it ends
                 \* before any record
    RecordsHow,  \* whether the entry that ends the turn says how it ended
    RecordsReply, \* whether the record that ends the turn holds its reply
    ReplyParts,  \* how many text lines the model's answer streams as
    StalledWait, \* whether a worker whose renewed lease ran out by its own
                 \* clock shows nothing until a renewal of its own lands
    SavesReply,  \* whether the answer saves the reply in a record before
                 \* the record that ends the turn
    ResumeFills, \* whether a worker that ends a resumed turn with its saved
                 \* reply first shows what of it the stream does not
    Restarts,    \* whether a resume may restart a saved answer, showing a
                 \* notice that is no part of it first
    ReplyAtLine, \* whether a worker that writes the end finds the answer's
                 \* shown start on a line of its own
    LateCancel,  \* whether the user may cancel the turn while the record
                 \* that ends it is on its way
    EndDecides   \* whether the turn then ends as that record says

ASSUME Tool \in {"lookup", "write", "send"}
ASSUME WritesWait \in BOOLEAN
ASSUME SelfStop \in BOOLEAN
ASSUME ClaimFenced \in BOOLEAN
ASSUME MaxCutoffs \in Nat
ASSUME CutoffBound \in BOOLEAN
ASSUME Heartbeat \in BOOLEAN
ASSUME QueueHeld \in BOOLEAN
ASSUME Repair \in BOOLEAN
ASSUME Refused \in BOOLEAN
ASSUME RecordsHow \in BOOLEAN
ASSUME RecordsReply \in BOOLEAN
ASSUME ReplyParts \in Nat /\ ReplyParts >= 1
ASSUME StalledWait \in BOOLEAN
ASSUME SavesReply \in BOOLEAN
ASSUME ResumeFills \in BOOLEAN
ASSUME Restarts \in BOOLEAN /\ ReplyAtLine \in BOOLEAN
ASSUME LateCancel \in BOOLEAN /\ EndDecides \in BOOLEAN
ASSUME ~(QueueHeld /\ Heartbeat)

None == "none"
\* The parts of the model's answer, in the order it streams them.
Parts == 1..ReplyParts
\* What a text line that is no part of the answer carries instead, such as
\* the notice fx shows when it restarts an answer.
Notice == 0
Max(S) == CHOOSE m \in S : \A n \in S : n <= m
Min(S) == CHOOSE m \in S : \A n \in S : m <= n
\* How a turn ended, as a turn_end line says it: "none" on any other line,
\* but "resume" on a turn_resume line the answer's text reads across
\* (ResumeLine).
How == {"none", "end_turn", "cancelled", "error", "unknown"}
\* "ahead": a call that ran ahead runs while its intent is on its way.
\* "closing": the record that saves the answer is in the chain and the one
\* that ends the turn is on its way. "delivering": a worker continues a turn
\* whose answer was saved, and its record that ends the turn is on its way.
\* "ending": the turn's end is in the chain and its turn_end line is not
\* written yet.
Waiting == {"announce", "model1", "ahead", "tool", "model2", "closing", "delivering", "ending"}
\* A deadline while a call waits for its intent writes behind that intent,
\* in the log's order, so it is Intent and then Deadline.
Busy == {"model1", "tool", "model2"}
\* "saved": the answer is saved, and the turn is still open.
Progress == {"start", "intent", "result", "saved", "done"}

\* A cut-off call of this tool runs again.
Idempotent == Tool \in {"lookup", "write"}
\* Its calls start before their intent is stored.
RunsAhead == Tool = "lookup" \/ (Tool = "write" /\ ~WritesWait)

VARIABLES
    pc,        \* where each worker is in the turn
    epoch,     \* the lease epoch each worker last claimed
    frozen,    \* whether a worker is frozen
    lease,     \* the lease at the head of the chain
    progress,  \* how far the chain has recorded the turn
    runs,      \* how many times the tool has started
    ids,       \* how many execution ids it started under: each model response
               \* that starts a call names a new one, and a rerun keeps it
    ui,        \* each line in the UI stream: its writer's epoch, whether
               \* that writer still headed the chain when it wrote, whether
               \* it is the turn's turn_end, what it says (How), and the
               \* parts of the answer's text it carries
    freezes,   \* freezes so far
    froze,     \* whether a worker froze since it last claimed the session
    chain,     \* how many counted writes the chain holds
    cutoffs,   \* deadline cut-offs in a row since the turn's last record
    seen,      \* what each worker read before its claim
    lapse,     \* with QueueHeld: "open" once the queue gave up on the
               \* holder's delivery, the worker it then handed the
               \* holder's message to, or "none"
    how,       \* how the turn ended, "none" until it did
    endHow,    \* what the turn_end line each worker writes says
    owed,      \* the text lines, as the parts each carries, that each worker
               \* writes before its turn_end line
    act        \* the step that led here

vars == <<pc, epoch, frozen, lease, progress, runs, ids, ui, freezes, froze, chain, cutoffs, seen, lapse, how, endHow, owed, act>>
ending == <<how, endHow>>

TypeOK ==
    /\ pc \in [Workers -> {"none", "early", "announce", "model1", "ahead", "tool", "model2", "closing", "delivering", "ending", "done", "stopped"}]
    /\ epoch \in [Workers -> 0..MaxEpoch]
    /\ frozen \in [Workers -> BOOLEAN]
    /\ lease \in [holder: Workers \cup {None}, epoch: 0..MaxEpoch, live: BOOLEAN]
    /\ progress \in Progress
    /\ runs \in 0..(MaxEpoch + 1)
    /\ ids \in 0..(MaxEpoch + 1)
    /\ ui \in Seq([e: 0..MaxEpoch, legit: BOOLEAN, end: BOOLEAN, how: How \cup {"resume"}, text: SUBSET (Parts \cup {Notice})])
    /\ freezes \in 0..MaxFreezes
    /\ froze \in [Workers -> BOOLEAN]
    /\ chain \in Nat
    /\ cutoffs \in Nat
    /\ seen \in [Workers -> [chain: Nat, progress: Progress, epoch: 0..MaxEpoch, cutoffs: Nat]]
    /\ lapse \in Workers \cup {"none", "open"}
    /\ how \in How \ {"unknown"}
    /\ endHow \in [Workers -> How]
    /\ owed \in [Workers -> Seq(SUBSET Parts)]
    /\ act \in [name: {"Init", "Start", "Claim", "Announce", "Model1", "Intent", "ToolEnd", "Model2",
                       "Commit", "EndLine", "Freeze", "Wake", "Deadline", "Expire", "Cancel"},
                w: Workers \cup {None}]

Init ==
    /\ pc = [w \in Workers |-> "none"]
    /\ epoch = [w \in Workers |-> 0]
    /\ frozen = [w \in Workers |-> FALSE]
    /\ lease = [holder |-> None, epoch |-> 0, live |-> FALSE]
    /\ progress = "start"
    /\ runs = 0
    /\ ids = 0
    /\ ui = <<>>
    /\ freezes = 0
    /\ froze = [w \in Workers |-> FALSE]
    /\ chain = 0
    /\ cutoffs = 0
    /\ seen = [w \in Workers |-> [chain |-> 0, progress |-> "start", epoch |-> 0, cutoffs |-> 0]]
    /\ lapse = "none"
    /\ how = "none"
    /\ endHow = [w \in Workers |-> "none"]
    /\ owed = [w \in Workers |-> <<>>]
    /\ act = [name |-> "Init", w |-> None]

\* A worker's writes count while its claim heads the lease chain.
Heads(w) == lease.holder = w /\ lease.epoch = epoch[w]

\* A line w writes now, and the turn_end line it writes now, which says
\* how the turn ended as w knows it.
Line(w) == [e |-> epoch[w], legit |-> Heads(w), end |-> FALSE, how |-> "none", text |-> {}]
EndOf(w) == [e |-> epoch[w], legit |-> Heads(w), end |-> TRUE, how |-> endHow[w], text |-> {}]
\* The turn_resume line w writes when it continues the turn. Only with
\* SavesReply can the answer's text come before it, so only then does it say
\* "resume", the text reading across it; elsewhere it is like any other line,
\* and every graph a driver walks is as before.
ResumeLine(w) == [Line(w) EXCEPT !.how = IF SavesReply THEN "resume" ELSE "none"]
\* The notice w shows as a text line when it restarts the answer.
NoticeLine(w) == [Line(w) EXCEPT !.text = {Notice}]
\* The text lines w writes now, each carrying the parts `lines` gives it.
TextLines(w, lines) == [k \in 1..Len(lines) |-> [Line(w) EXCEPT !.text = lines[k]]]
\* The answer's parts from..to as its worker streams them, one line each.
PartsFrom(from, to) == [k \in 1..(to - from + 1) |-> {from + k - 1}]

\* w ends the turn `reason`, in the record or `ended` entry it writes now,
\* and its turn_end line will say so.
Ends(w, reason) ==
    /\ how' = reason
    /\ endHow' = [endHow EXCEPT ![w] = reason]

\* What a worker that writes the turn_end of a turn another ended can say:
\* how the entry that ended it says, or, where entries do not say, unknown.
Recorded == IF RecordsHow THEN how ELSE "unknown"

\* A write that does not count may still have put a line in the UI stream.
MaybeLine(w) == ui' \in {ui, Append(ui, Line(w))}

\* w writes no line now: its renewed lease ran out while it was frozen, so
\* it shows nothing until a renewal of its own lands, and that renewal,
\* fenced out, stops it. Only a renewed lease shows its holder, by its own
\* clock, that it may have run out; a lease the queue holds does not.
Gated(w) == StalledWait /\ Heartbeat /\ froze[w] /\ ~Heads(w)

\* The line a write that does not count may have put in the UI stream, as
\* MaybeLine, unless w writes none.
LateLine(w) == IF Gated(w) THEN UNCHANGED ui ELSE MaybeLine(w)

\* The lines w writes now, whether or not it heads the chain: `lines`, or
\* none when it writes none.
Writes(w, lines) == IF Gated(w) THEN <<>> ELSE lines

\* What can land of the lines w owes when it froze waiting to write them:
\* all of them, or when it writes none, the first or nothing. libfx checks
\* a line when its write starts, so the first may have been on its way to
\* the World, past that check, when w froze; the rest start after w wakes.
Landing(w, lines) == IF Gated(w) THEN {SubSeq(lines, 1, k) : k \in 0..1} ELSE {lines}

\* The lines every reader shows: each line no earlier line outranks. The
\* same stored stream always shows the same lines.
ShownAt(lines) == {i \in 1..Len(lines) : \A j \in 1..(i - 1) : lines[j].e <= lines[i].e}

\* What w reads now: where the chain stands and how far it recorded the turn.
Read == [chain |-> chain, progress |-> progress, epoch |-> lease.epoch, cutoffs |-> cutoffs]

\* Whether a reader shows the turn's end.
EndShown == \E i \in ShownAt(ui) : ui[i].end

\* Of the lines at positions `at`, those after the last that has no text,
\* where with `across` a turn_resume line that says "resume" is not one.
TailOf(at, across) == LET plain == {i \in at : ui[i].text = {} /\ ~(across /\ ui[i].how = "resume")}
                          last == IF plain = {} THEN 0 ELSE Max(plain)
                      IN {i \in at : i > last}
TextTail(at) == TailOf(at, FALSE)
\* The parts the lines at positions `at` carry.
PartsAt(at) == UNION {ui[i].text : i \in at}
IsStart(parts) == \E k \in 0..ReplyParts : parts = 1..k

\* What a worker that writes the end of a turn whose answer it did not
\* stream shows of the answer first, as one line: the parts after those the
\* text lines the shown lines end with carry, read across turn_resume lines.
\* With ReplyAtLine those lines are read from the first one whose text from
\* there on is the answer's start, since the answer starts a line of its
\* own; the lines before it hold a restarted answer and its notice, and
\* all of the answer is owed when none is (sdk/durable.js unshownReply).
\* Without it, as before, they are read whole, or else from the last
\* turn_resume line, or not at all (Witness-NoReplyAtLine).
Unshown == LET tail == TailOf(ShownAt(ui), TRUE)
               from(p) == PartsAt({i \in tail : i >= p})
               starts == {p \in tail : ui[p].text # {} /\ IsStart(from(p))}
               across == PartsAt(tail)
               since == PartsAt(TextTail(ShownAt(ui)))
               shown == IF ReplyAtLine
                        THEN IF starts = {} THEN {} ELSE from(Min(starts))
                        ELSE IF IsStart(across) THEN across
                        ELSE IF IsStart(since) THEN since
                        ELSE {}
               rest == Parts \ shown
           IN IF rest # {} THEN <<rest>> ELSE <<>>

\* What a worker that writes a crashed holder's missing turn_end shows of the
\* answer first. Only with RecordsReply does the record it read hold the
\* answer.
Repaired == IF RecordsReply /\ how = "end_turn" THEN Unshown ELSE <<>>

\* The work a worker finds when it reads the log: the turn, or, with Repair,
\* the end of a done turn that no reader shows, its holder never having let
\* the session go.
Unfinished == progress # "done" \/ (Repair /\ lease.holder # None /\ ~EndShown)

\* Whether w, reading now, finds work it can claim. With QueueHeld, a frozen
\* holder's lease is dead only to the delivery its message was handed to.
CanClaim(w) == Unfinished /\ (lease.holder = None \/ (~lease.live /\ (~QueueHeld \/ lapse = w)))

\* w receives work for the session, reads the log, and finds no live worker
\* holding it. It writes its claim and sends its first model request at
\* once; nothing it does shows or counts until the claim lands. With
\* QueueHeld, the work that finds a frozen holder is that holder's message,
\* which the queue hands to w.
Start(w) ==
    /\ pc[w] \in {"none", "stopped"}
    /\ ~frozen[w]
    /\ lease.epoch < MaxEpoch
    /\ \/ /\ CanClaim(w)
          /\ UNCHANGED lapse
       \/ /\ QueueHeld
          /\ Unfinished
          /\ lease.holder # None
          /\ ~lease.live
          /\ lapse = "open"
          /\ lapse' = w
    /\ pc' = [pc EXCEPT ![w] = "early"]
    /\ seen' = [seen EXCEPT ![w] = Read]
    /\ UNCHANGED <<epoch, frozen, lease, progress, runs, ids, ui, freezes, froze, chain, cutoffs, ending, owed>>
    /\ act' = [name |-> "Start", w |-> w]

\* w's claim lands. Its lease continues the chain where w read it, so it
\* counts only when nothing counted since. Its first line follows; until
\* then a replaced worker's late lines still show. A refused claim wrote
\* nothing that counts, and w reads the log again in the same delivery.
\* MaxEpoch bounds only the model: a claim that would pass it never lands.
Claim(w) ==
    /\ pc[w] = "early"
    /\ ~frozen[w]
    /\ IF chain = seen[w].chain \/ ~ClaimFenced
          THEN /\ seen[w].epoch < MaxEpoch
               /\ lease' = [holder |-> w, epoch |-> seen[w].epoch + 1, live |-> TRUE]
               /\ epoch' = [epoch EXCEPT ![w] = seen[w].epoch + 1]
               /\ chain' = chain + 1
               \* A claim on a done turn only writes its end, saying what
               \* the log says of how it ended, after what of the answer the
               \* stream it reads now does not show.
               /\ pc' = [pc EXCEPT ![w] = IF seen[w].progress = "done" THEN "ending" ELSE "announce"]
               /\ endHow' = [endHow EXCEPT ![w] = IF seen[w].progress = "done" THEN Recorded ELSE "none"]
               /\ owed' = [owed EXCEPT ![w] = IF seen[w].progress = "done" THEN Repaired ELSE <<>>]
               /\ froze' = [froze EXCEPT ![w] = FALSE]
               /\ lapse' = "none"
               /\ UNCHANGED seen
          ELSE /\ UNCHANGED <<lease, epoch, chain, froze, lapse, endHow, owed>>
               /\ IF CanClaim(w)
                     THEN /\ pc' = [pc EXCEPT ![w] = "early"]
                          /\ seen' = [seen EXCEPT ![w] = Read]
                     ELSE /\ pc' = [pc EXCEPT ![w] = "none"]
                          /\ UNCHANGED seen
    /\ UNCHANGED <<frozen, progress, runs, ids, ui, freezes, cutoffs, how>>
    /\ act' = [name |-> "Claim", w |-> w]

\* w writes turn_start or turn_resume and waits for it to land, then
\* continues the turn from what it read before its claim. A call left
\* running is rerun only when it is safe to run twice, under the execution id
\* its intent names; otherwise the model is told it may have partly run,
\* which is stored as the call's result, its viewers see the call end with
\* that answer, and the turn goes on to the answer. The records this writes are left out
\* of `chain`: in the code it follows its claim at once, and fewer chain
\* moves only let the model do more. A step
\* cut off MaxCutoffs times in a row is not run again: a call is answered
\* as possibly run, and a model request cancels the turn, whose end only
\* the chain's head writes. With Refused, a turn that has recorded nothing
\* ends at once: its `ended` entry is outside the chain, so it lands whether
\* or not w still heads it. A turn whose answer was saved goes on to end with
\* that answer, asking the model nothing (Commit), or with Restarts asks
\* the model again, after a notice that it restarts the answer.
Announce(w) ==
    /\ pc[w] = "announce"
    /\ ~frozen[w]
    /\ LET from == seen[w].progress
           spent == CutoffBound /\ seen[w].cutoffs >= MaxCutoffs
           rerun == from = "intent" /\ Idempotent /\ ~spent
       IN IF Refused /\ from = "start"
          THEN \* turn_start; turn_end follows in EndLine
               /\ progress' = "done"
               /\ Ends(w, "error")
               /\ pc' = [pc EXCEPT ![w] = "ending"]
               /\ ui' = ui \o Writes(w, <<Line(w)>>)
               /\ UNCHANGED <<runs, lease, chain, cutoffs, lapse>>
          ELSE IF spent /\ from \in {"start", "result"}
          THEN /\ UNCHANGED runs
               /\ IF Heads(w)
                     THEN /\ progress' = "done"
                          /\ Ends(w, "cancelled")
                          \* turn_resume; turn_end follows in EndLine
                          /\ pc' = [pc EXCEPT ![w] = "ending"]
                          /\ ui' = Append(ui, ResumeLine(w))
                          /\ chain' = chain + 1
                          /\ cutoffs' = 0
                          /\ UNCHANGED <<lease, lapse>>
                     ELSE /\ pc' = [pc EXCEPT ![w] = "stopped"]
                          /\ ui' = ui \o Writes(w, <<ResumeLine(w)>>)
                          /\ UNCHANGED <<progress, lease, chain, cutoffs, lapse, ending>>
          ELSE /\ UNCHANGED ending
               /\ \E restart \in IF Restarts /\ from = "saved" THEN BOOLEAN ELSE {FALSE} :
                     /\ pc' = [pc EXCEPT ![w] =
                                CASE from = "start" -> "model1"
                                  [] from = "intent" -> IF rerun THEN "tool" ELSE "model2"
                                  [] from \in {"result", "done"} -> "model2"
                                  [] from = "saved" -> IF restart THEN "model2" ELSE "delivering"]
                     \* turn_start, or turn_resume, then tool_start for a rerun,
                     \* tool_end for a call answered as possibly run, or the
                     \* notice of a restarted answer
                     /\ ui' = ui \o Writes(w, CASE from = "start" -> <<Line(w)>>
                                                [] from = "intent" -> <<ResumeLine(w), Line(w)>>
                                                [] restart -> <<ResumeLine(w), NoticeLine(w)>>
                                                [] OTHER -> <<ResumeLine(w)>>)
               /\ runs' = IF rerun THEN runs + 1 ELSE runs
               \* a call answered as possibly run is the turn's next record
               /\ IF from = "intent" /\ ~rerun /\ Heads(w)
                     THEN /\ progress' = "result"
                          /\ cutoffs' = 0
                     ELSE UNCHANGED <<progress, cutoffs>>
               /\ UNCHANGED <<lease, chain, lapse>>
    /\ UNCHANGED <<epoch, frozen, ids, freezes, froze, seen, owed>>
    /\ act' = [name |-> "Announce", w |-> w]

\* The model asks for the tool, under a new execution id. A call that runs
\* ahead starts at once, even in a worker that was replaced and does not know
\* it yet, and its intent is still on its way; a replaced worker that already
\* saw its successor's claim has that intent refused at once and stops. The
\* progress that saw the response may land before the intent, as a record of
\* its own that moves the chain but holds no call: a worker that resumes from
\* it asks the model again, as from the turn's start. Any other call starts
\* only once its intent is in the chain: after a crash only a recorded intent
\* reruns a call under the same id, and a call with effects is never
\* unrecorded.
Model1(w) ==
    /\ pc[w] = "model1"
    /\ ~frozen[w]
    /\ IF RunsAhead
          THEN /\ runs' = runs + 1
               /\ ids' = ids + 1
               /\ \/ /\ pc' = [pc EXCEPT ![w] = "ahead"]
                     /\ ui' = ui \o Writes(w, <<Line(w)>>)
                     /\ \/ UNCHANGED <<chain, cutoffs>>
                        \/ /\ Heads(w)
                           /\ chain' = chain + 1
                           /\ cutoffs' = 0
                  \/ /\ ~Heads(w)
                     /\ pc' = [pc EXCEPT ![w] = "stopped"]
                     /\ LateLine(w)
                     /\ UNCHANGED <<chain, cutoffs>>
               /\ UNCHANGED progress
          ELSE /\ IF Heads(w)
                     THEN /\ progress' = "intent"
                          /\ runs' = runs + 1
                          /\ ids' = ids + 1
                          /\ pc' = [pc EXCEPT ![w] = "tool"]
                          /\ ui' = Append(ui, Line(w))
                     ELSE /\ pc' = [pc EXCEPT ![w] = "stopped"]
                          /\ LateLine(w)
                          /\ UNCHANGED <<progress, runs, ids>>
               /\ chain' = IF Heads(w) THEN chain + 1 ELSE chain
               /\ cutoffs' = IF Heads(w) THEN 0 ELSE cutoffs
    /\ UNCHANGED <<epoch, frozen, lease, freezes, froze, seen, lapse, ending, owed>>
    /\ act' = [name |-> "Model1", w |-> w]

\* The intent of a call that ran ahead lands. It counts where w still heads
\* the chain, and w goes on with its call; a w that was replaced learns so at
\* this write and stops, its call cut off.
Intent(w) ==
    /\ pc[w] = "ahead"
    /\ ~frozen[w]
    /\ IF Heads(w)
          THEN /\ progress' = "intent"
               /\ pc' = [pc EXCEPT ![w] = "tool"]
               /\ chain' = chain + 1
               /\ cutoffs' = 0
               /\ UNCHANGED ui
          ELSE /\ pc' = [pc EXCEPT ![w] = "stopped"]
               /\ LateLine(w)
               /\ UNCHANGED <<progress, chain, cutoffs>>
    /\ UNCHANGED <<epoch, frozen, lease, runs, ids, freezes, froze, seen, lapse, ending, owed>>
    /\ act' = [name |-> "Intent", w |-> w]

\* The tool returns, and its result goes to the chain.
ToolEnd(w) ==
    /\ pc[w] = "tool"
    /\ ~frozen[w]
    /\ IF Heads(w)
          THEN /\ progress' = "result"
               /\ pc' = [pc EXCEPT ![w] = "model2"]
               /\ ui' = Append(ui, Line(w))
          ELSE /\ pc' = [pc EXCEPT ![w] = "stopped"]
               /\ LateLine(w)
               /\ UNCHANGED progress
    /\ chain' = IF Heads(w) THEN chain + 1 ELSE chain
    /\ cutoffs' = IF Heads(w) THEN 0 ELSE cutoffs
    /\ UNCHANGED <<epoch, frozen, lease, runs, ids, freezes, froze, seen, lapse, ending, owed>>
    /\ act' = [name |-> "ToolEnd", w |-> w]

\* The model answers, and the record that ends the turn lands, saying it
\* ended end_turn, while the answer's text streams: the first `landed` of
\* its lines have landed, and w still writes the rest. Its turn_end line is
\* a write of its own, EndLine. A replaced worker's answer still streams,
\* unless it writes none (Gated). With SavesReply the record that saves the
\* answer lands first; the one that ends the turn goes in the same record,
\* or follows it in one of its own (Commit).
Model2(w) ==
    /\ pc[w] = "model2"
    /\ ~frozen[w]
    /\ \E landed \in 0..ReplyParts :
          /\ ui' = ui \o Writes(w, TextLines(w, PartsFrom(1, landed)))
          /\ IF Heads(w)
                THEN /\ owed' = [owed EXCEPT ![w] = PartsFrom(landed + 1, ReplyParts)]
                     /\ \/ /\ progress' = "done"
                           /\ Ends(w, "end_turn")
                           /\ pc' = [pc EXCEPT ![w] = "ending"]
                        \/ /\ SavesReply
                           /\ progress' = "saved"
                           /\ pc' = [pc EXCEPT ![w] = "closing"]
                           /\ UNCHANGED ending
                ELSE /\ pc' = [pc EXCEPT ![w] = "stopped"]
                     /\ UNCHANGED <<progress, ending, owed>>
    /\ chain' = IF Heads(w) THEN chain + 1 ELSE chain
    /\ cutoffs' = IF Heads(w) THEN 0 ELSE cutoffs
    /\ UNCHANGED <<epoch, frozen, lease, runs, ids, freezes, froze, seen, lapse>>
    /\ act' = [name |-> "Model2", w |-> w]

\* The record that ends the turn lands after the one that saved its answer.
\* A worker that continued the turn from its saved answer asked the model
\* nothing and streamed none of the answer: with ResumeFills it first shows
\* the part of it the stream does not, read once this record lands, as one
\* that writes a crashed holder's missing turn_end does. A worker another
\* took the session from learns so at this write and stops; the text it
\* still had on its way lands, unless it writes none (Gated).
Commit(w) ==
    /\ pc[w] \in {"closing", "delivering"}
    /\ ~frozen[w]
    /\ IF Heads(w)
          THEN /\ progress' = "done"
               \* A cancel that came while this record was on its way only
               \* shows in w's turn_end without EndDecides (Cancel).
               /\ how' = "end_turn"
               /\ endHow' = [endHow EXCEPT ![w] = IF endHow[w] = "cancelled" THEN "cancelled" ELSE "end_turn"]
               /\ pc' = [pc EXCEPT ![w] = "ending"]
               /\ owed' = [owed EXCEPT ![w] =
                              IF pc[w] = "closing" THEN owed[w]
                              ELSE IF RecordsReply /\ ResumeFills THEN Unshown
                              ELSE <<>>]
               /\ chain' = chain + 1
               /\ cutoffs' = 0
               /\ UNCHANGED ui
          ELSE /\ pc' = [pc EXCEPT ![w] = "stopped"]
               /\ \E landing \in Landing(w, TextLines(w, owed[w])) : ui' = ui \o landing
               /\ owed' = [owed EXCEPT ![w] = <<>>]
               /\ UNCHANGED <<progress, ending, chain, cutoffs>>
    /\ UNCHANGED <<epoch, frozen, lease, runs, ids, freezes, froze, seen, lapse>>
    /\ act' = [name |-> "Commit", w |-> w]

\* w writes the text lines it still owes, then the turn's turn_end line,
\* then lets the session go. A worker another took the session from still
\* writes its lines, which readers hide behind the other's, and then learns
\* it was replaced and stops, unless it writes none (Gated): then only a
\* line already on its way when it froze lands (Landing).
EndLine(w) ==
    /\ pc[w] = "ending"
    /\ ~frozen[w]
    /\ \E landing \in Landing(w, TextLines(w, owed[w]) \o <<EndOf(w)>>) : ui' = ui \o landing
    /\ owed' = [owed EXCEPT ![w] = <<>>]
    /\ IF Heads(w)
          THEN /\ pc' = [pc EXCEPT ![w] = "done"]
               /\ lease' = [lease EXCEPT !.holder = None, !.live = FALSE]
               /\ chain' = chain + 1
               /\ lapse' = "none"
          ELSE /\ pc' = [pc EXCEPT ![w] = "stopped"]
               /\ UNCHANGED <<lease, chain, lapse>>
    /\ UNCHANGED <<epoch, frozen, progress, runs, ids, freezes, froze, cutoffs, seen, ending>>
    /\ act' = [name |-> "EndLine", w |-> w]

\* The user cancels the turn while w's record that ends it is on its way to
\* the log, after the record that saved its answer. With EndDecides the
\* turn ends as that record says: the cancel stops nothing, and w's engine
\* still shows the rest of the answer. Without it, as libfx had it, the
\* engine answers the cancel, and w's turn_end says the turn was cancelled.
Cancel(w) ==
    /\ LateCancel
    /\ pc[w] \in {"closing", "delivering"}
    /\ ~frozen[w]
    /\ endHow[w] = "none"
    /\ endHow' = [endHow EXCEPT ![w] = IF EndDecides THEN "none" ELSE "cancelled"]
    /\ UNCHANGED <<pc, epoch, frozen, lease, progress, runs, ids, ui, freezes, froze, chain, cutoffs, seen, lapse, how, owed>>
    /\ act' = [name |-> "Cancel", w |-> w]

\* w freezes while it waits; its lease no longer counts as alive. With
\* QueueHeld, the queue gives up on its delivery and will hand its message on.
Freeze(w) ==
    /\ pc[w] \in Waiting
    /\ ~frozen[w]
    /\ freezes < MaxFreezes
    /\ frozen' = [frozen EXCEPT ![w] = TRUE]
    /\ freezes' = freezes + 1
    /\ froze' = [froze EXCEPT ![w] = TRUE]
    /\ lease' = IF lease.holder = w THEN [lease EXCEPT !.live = FALSE] ELSE lease
    /\ lapse' = IF QueueHeld /\ lease.holder = w /\ lapse = "none" THEN "open" ELSE lapse
    /\ UNCHANGED <<pc, epoch, progress, runs, ids, ui, chain, cutoffs, seen, ending, owed>>
    /\ act' = [name |-> "Freeze", w |-> w]

\* w wakes and carries on from where it waited. With Heartbeat its next
\* renewal may land first: it keeps the lease where w still heads the chain,
\* and stops w where another worker took the session over.
Wake(w) ==
    /\ frozen[w]
    /\ frozen' = [frozen EXCEPT ![w] = FALSE]
    /\ \/ UNCHANGED <<pc, lease, chain>>
       \/ /\ Heartbeat
          /\ Heads(w)
          /\ lease' = [lease EXCEPT !.live = TRUE]
          /\ chain' = chain + 1
          /\ UNCHANGED pc
       \/ /\ Heartbeat
          /\ ~Heads(w)
          /\ pc' = [pc EXCEPT ![w] = "stopped"]
          /\ UNCHANGED <<lease, chain>>
    /\ UNCHANGED <<epoch, progress, runs, ids, ui, freezes, froze, cutoffs, seen, lapse, ending, owed>>
    /\ act' = [name |-> "Wake", w |-> w]

\* Shortly before its deadline, w's own timer stops it and cuts off the call
\* still running; a frozen worker's timer does not run. w writes turn_yield,
\* hands the open turn back to the log and releases the session, and the
\* same message comes back at once. w takes it again, or, where the platform
\* routes it elsewhere, any worker may. A worker that was replaced without
\* knowing it learns so at the release and stops.
Deadline(w) ==
    /\ SelfStop
    /\ pc[w] \in Busy
    /\ ~frozen[w]
    /\ IF Heads(w)
          THEN /\ ui' = Append(ui, Line(w))
               /\ chain' = chain + 1
               \* its release names the turn whose step it cut off
               /\ cutoffs' = cutoffs + 1
               /\ \/ /\ lease.epoch < MaxEpoch
                     /\ lease' = [holder |-> w, epoch |-> lease.epoch + 1, live |-> TRUE]
                     /\ epoch' = [epoch EXCEPT ![w] = lease.epoch + 1]
                     /\ pc' = [pc EXCEPT ![w] = "announce"]
                     /\ froze' = [froze EXCEPT ![w] = FALSE]
                     \* it reads the log after its release and continues from there
                     /\ seen' = [seen EXCEPT ![w] = [chain |-> chain + 1, progress |-> progress, epoch |-> lease.epoch, cutoffs |-> cutoffs + 1]]
                  \/ /\ lease' = [lease EXCEPT !.holder = None, !.live = FALSE]
                     /\ pc' = [pc EXCEPT ![w] = "none"]
                     /\ UNCHANGED <<epoch, froze, seen>>
               /\ lapse' = "none"
          ELSE /\ pc' = [pc EXCEPT ![w] = "stopped"]
               /\ LateLine(w)
               /\ UNCHANGED <<epoch, lease, froze, chain, cutoffs, seen, lapse>>
    /\ UNCHANGED <<frozen, progress, runs, ids, freezes, ending, owed>>
    /\ act' = [name |-> "Deadline", w |-> w]

\* Without the self-stop: the deadline passes while w is still busy, and its
\* lease runs out while it runs on.
Expire(w) ==
    /\ ~SelfStop
    /\ pc[w] \in Busy
    /\ ~frozen[w]
    /\ Heads(w)
    /\ lease.live
    /\ lease' = [lease EXCEPT !.live = FALSE]
    /\ UNCHANGED <<pc, epoch, frozen, progress, runs, ids, ui, freezes, froze, chain, cutoffs, seen, lapse, ending, owed>>
    /\ act' = [name |-> "Expire", w |-> w]

Next ==
    \E w \in Workers :
        \/ Start(w) \/ Claim(w) \/ Announce(w) \/ Model1(w) \/ Intent(w) \/ ToolEnd(w) \/ Model2(w)
        \/ Commit(w) \/ EndLine(w) \/ Freeze(w) \/ Wake(w) \/ Deadline(w) \/ Expire(w) \/ Cancel(w)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties *)

\* A call with effects never starts twice.
EffectsAtMostOnce == Tool = "send" => runs <= 1

\* The deadline cuts off one step at most MaxCutoffs times in a row: the
\* delivery after that does not run it again.
HandoffsBounded == cutoffs <= MaxCutoffs

\* A write or a send starts only after its intent counts in the chain.
CallAfterIntent == Tool \in {"write", "send"} => (runs > 0 => progress # "start")

\* A write or a send runs under one execution id: a rerun after a crash uses
\* the id its intent names, so a service that dedupes on it changes nothing
\* twice. A lookup whose intent never landed may run again under a new id
\* (Witness-LookupNewId), and so would a write that ran ahead
\* (Witness-WriteRunsAhead).
OneExecutionId == Tool \in {"write", "send"} => ids <= 1

\* Witness, expected to FAIL for lookup: a call starts before its intent is
\* in the chain, so lookup really runs ahead.
EveryCallAfterIntent == runs > 0 => progress # "start"

\* Witness, expected to FAIL for lookup: it runs under a second execution
\* id after a crash lost its intent.
IdsAtMostOne == ids <= 1

\* Only the chain's head ends the turn. It is about the record that ends a
\* turn, which only the head writes: a refused turn's `ended` entry is
\* outside the chain, so a worker replaced while it refused the turn can
\* write it too, and the refuse graph does not check this.
DoneByHead == progress = "done" => \E w \in Workers : pc[w] \in {"ending", "done"}

\* No reader hides a line its writer wrote while it headed the chain.
LegitShown == \A i \in 1..Len(ui) : ui[i].legit => i \in ShownAt(ui)

\* No reader shows the turn end twice unless a worker froze since it
\* claimed: one whose lease ran out while it was frozen can wake and write
\* its late turn_end before the worker that took the session over writes
\* the end it found missing, and the stream refuses neither (the window
\* NoStaleShown shows). No reader shows the end before the turn ended.
EndShownOnce == Cardinality({i \in ShownAt(ui) : ui[i].end}) <= 1 \/ \E w \in Workers : froze[w]
EndAfterDone == EndShown => progress = "done"

\* Every turn_end a reader shows says how the turn ended, also one a worker
\* wrote for a turn a crashed holder ended: the entry that ended the turn
\* says how, in the same write (DUR-20, DUR-64). Without RecordsHow that
\* worker can only say unknown (Witness-NoEndHow, Witness-NoRefusedHow).
EndSaysHow == \A i \in ShownAt(ui) : ui[i].end => ui[i].how = how

\* Every turn_end a reader shows that its worker wrote while it headed the
\* chain, of a turn the model answered, follows the whole answer, each part
\* once: among the shown lines written by a head, the text lines after the
\* last other one before it, read across turn_resume lines (DUR-20, DUR-38,
\* DUR-64). That holds for the end a worker writes for a crashed holder's
\* turn too, and for one a worker writes for a turn it ended with the answer
\* saved before a crash: it shows the parts the holder's lines never did,
\* and none they did. A frozen holder that wakes may still show its own late
\* lines, which no head wrote: the window NoStaleShown shows. Without
\* RecordsReply, that worker shows none of the answer, which a crash cut
\* short (Witness-NoReplyRepair), and without ResumeFills neither does one
\* that ends a turn with its saved answer (Witness-NoResumeFill).
\* With Restarts, the answer is the one after the last notice that it
\* restarted: the lines before that notice hold the answer it restarted.
ReplyShownOnce ==
    how = "end_turn" =>
        \A i \in ShownAt(ui) :
            (ui[i].end /\ ui[i].legit) =>
                LET tail == TailOf({j \in ShownAt(ui) : j < i /\ ui[j].legit}, TRUE)
                    notices == {j \in tail : Notice \in ui[j].text}
                    run == {j \in tail : notices = {} \/ j > Max(notices)}
                IN \A p \in Parts : Cardinality({j \in run : p \in ui[j].text}) = 1

\* ReplyShownOnce, unless a replaced worker's text line shows. The leased
\* graph checks this in its place. There a replaced worker's late line is at
\* most the one it had on its way when it froze (StaleShownPerFreeze), but
\* when that line is a part of the answer it can still land between its
\* successor's claim and first line: then the reader sees that part twice,
\* or the successor counts it as shown and the head's own lines lack it.
\* The saved graph checks it too: a worker that ends a turn with its saved
\* answer reads the stream once its turn_resume landed, so it counts a late
\* line that landed before that as shown, as readers do.
ReplyShownOnceUnlessLate ==
    \/ ReplyShownOnce
    \/ \E i \in ShownAt(ui) : ~ui[i].legit /\ ui[i].text # {}

\* A step of w's own work, as opposed to a freeze, a wake or the platform's.
Works(w) ==
    \/ Start(w) \/ Claim(w) \/ Announce(w) \/ Model1(w) \/ Intent(w) \/ ToolEnd(w) \/ Model2(w)
    \/ Commit(w) \/ EndLine(w) \/ Deadline(w)

\* A done turn whose end no reader shows never leaves the workers that have
\* not crashed with nothing to do, while claims are left. Every path is
\* finite, so each one ends with the turn's end shown, every worker crashed,
\* or the model's claims spent. Without Repair, a holder that crashes
\* between the turn's end record and its turn_end line leaves the turn
\* without an end for good (Witness-NoEndRepair): every worker that reads
\* the log finds the turn done and nothing to do.
EndRecoverable ==
    (progress = "done" /\ ~EndShown /\ lease.epoch < MaxEpoch /\ \E w \in Workers : ~frozen[w])
        => \E w \in Workers : ~frozen[w] /\ ENABLED Works(w)

Active(w) == pc[w] \in Waiting /\ ~frozen[w]

\* Two workers are active at once only when one of them froze since it
\* claimed the session. A clock that stops is the one case left, and only a
\* World that refuses stale writes closes it.
TwoActiveNeedsFreeze ==
    \A v, w \in Workers : v # w /\ Active(v) /\ Active(w) => froze[v] \/ froze[w]

\* Witness, expected to FAIL: a replaced worker's line can still show when
\* it lands between its successor's claim and first line. Only a World
\* that refuses stale stream writes closes that window.
NoStaleShown == \A i \in ShownAt(ui) : ui[i].legit

\* Where its own clock tells a woken worker it may have been replaced, the
\* window narrows to one line a freeze: with Heartbeat and StalledWait every
\* replaced worker froze, and once it wakes it writes no line, so only the
\* one it had on its way when it froze can show (Landing). The leased graph
\* checks this; Witness-LeasedStaleShown breaks it without StalledWait,
\* where a woken worker's owed text and turn_end all show.
StaleShownPerFreeze == Cardinality({i \in ShownAt(ui) : ~ui[i].legit}) <= freezes

\* The stream as stored, expected to FAIL: late lines land out of order.
UiInOrder == \A i \in 1..(Len(ui) - 1) : ui[i].e <= ui[i + 1].e

\* Witness, expected to FAIL: two workers active at once.
NotTwoActive ==
    ~(\E v, w \in Workers :
        /\ v # w
        /\ Active(v)
        /\ Active(w))
=============================================================================
