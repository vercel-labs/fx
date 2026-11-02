---------------------------- MODULE PromptImages ----------------------------
(* A v2 session's prompt images as blobs of the session (D89, amending D44).

   A turn's images are saved as blobs before its first request is built
   and before its user item is written. The request sends every image's
   bytes, and its note names the saved file of each image that has one. The
   user item names each saved image by its digest and lists the blobs the
   turn stored, so a fork, which hard-links only listed blobs, can read
   them. An image whose save fails stays inside the item and gets no note.
   A conversion imports v1's turns the same way, but with no request.

   An image is its digest: attaching the same image twice attaches one
   digest, and its blob is stored once. Blobs are never deleted, so a note
   that was true when its request was sent stays true.

   Checked by tests/tla/session_manager/check.sh; mutants.py plants the bugs
   each invariant exists to catch, and
   tests/tla/drivers/session_manager/prompt-images.test.ts has TLC check
   real runs against this spec through trace/PromptImagesTrace.tla. *)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS Digests, MaxRequests, MaxItems

\* Images are interchangeable: every property holds for each alike.
Symmetry == Permutations(Digests)

Sessions == {"source", "fork"}
Forms == {"ref", "inline"}
\* `asked` is what the user attached; `images` how the item keeps each one.
Item == [asked : SUBSET Digests, images : [Digests -> Forms \cup {"none"}],
         listed : SUBSET Digests]

VARIABLES
    up,         \* the fx process is running
    forked,     \* the fork exists
    blobs,      \* [Sessions -> SUBSET Digests]: files in each blobs folder
    log,        \* [Sessions -> Seq(Item)]: each session's user items
    pending,    \* [Sessions -> SUBSET Digests]: stored, not yet listed (memory)
    turn,       \* the turn being prepared, or none
    requests    \* Seq([s, asked, sent, noted]): what each request carried

vars == <<up, forked, blobs, log, pending, turn, requests>>

\* `requested` and `written` say whether the turn's first request was built
\* and its user item written. The code writes the item first, before the
\* request goes out; the spec allows either order.
NoTurn == [phase |-> "none", s |-> "source", asked |-> {},
           form |-> [d \in Digests |-> "none"],
           requested |-> FALSE, written |-> FALSE]

TypeOK ==
    /\ up \in BOOLEAN /\ forked \in BOOLEAN
    /\ blobs \in [Sessions -> SUBSET Digests]
    /\ \A s \in Sessions : log[s] \in Seq(Item)
    /\ pending \in [Sessions -> SUBSET Digests]
    /\ turn.phase \in {"none", "open"}
    /\ turn.s \in Sessions /\ turn.asked \subseteq Digests
    /\ turn.form \in [Digests -> Forms \cup {"none", "unsaved"}]
    /\ turn.requested \in BOOLEAN /\ turn.written \in BOOLEAN

Init ==
    /\ up = TRUE /\ forked = FALSE
    /\ blobs = [s \in Sessions |-> {}]
    /\ log = [s \in Sessions |-> <<>>]
    /\ pending = [s \in Sessions |-> {}]
    /\ turn = NoTurn
    /\ requests = <<>>

Open(s) == s = "source" \/ forked

\* Images an earlier turn of `s` saved, by how its item keeps them.
Earlier(s, f) == {d \in Digests : \E k \in 1..Len(log[s]) : log[s][k].images[d] = f}

\* A prompt with images starts its turn.
Begin(s, asked) ==
    /\ up /\ Open(s) /\ turn.phase = "none" /\ asked # {}
    /\ Len(log[s]) < MaxItems /\ Len(requests) < MaxRequests
    /\ turn' = [phase |-> "open", s |-> s, asked |-> asked,
                form |-> [d \in Digests |-> IF d \in asked THEN "unsaved" ELSE "none"],
                requested |-> FALSE, written |-> FALSE]
    /\ UNCHANGED <<up, forked, blobs, log, pending, requests>>

\* A conversion imports each v1 turn before the session's first request and
\* before any fork. v1 sent the turn's request long ago, so the turn saves
\* its images, or keeps them inline, and writes its item with no request.
Import(asked) ==
    /\ up /\ ~forked /\ requests = <<>> /\ turn.phase = "none" /\ asked # {}
    /\ Len(log["source"]) < MaxItems
    /\ turn' = [phase |-> "open", s |-> "source", asked |-> asked,
                form |-> [d \in Digests |-> IF d \in asked THEN "unsaved" ELSE "none"],
                requested |-> TRUE, written |-> FALSE]
    /\ UNCHANGED <<up, forked, blobs, log, pending, requests>>

\* Every image is saved as a blob or kept inline.
Saved == \A d \in turn.asked : turn.form[d] # "unsaved"

\* The image's bytes become a blob named by their digest; the same bytes
\* stored again cost one stat. The blob waits to be listed.
Save(d) ==
    /\ up /\ turn.phase = "open" /\ turn.form[d] = "unsaved"
    /\ blobs' = [blobs EXCEPT ![turn.s] = @ \cup {d}]
    /\ pending' = [pending EXCEPT ![turn.s] = @ \cup {d}]
    /\ turn' = [turn EXCEPT !.form[d] = "ref"]
    /\ UNCHANGED <<up, forked, log, requests>>

\* The store refuses (disk full, permissions): the image stays inline.
SaveFails(d) ==
    /\ up /\ turn.phase = "open" /\ turn.form[d] = "unsaved"
    /\ turn' = [turn EXCEPT !.form[d] = "inline"]
    /\ UNCHANGED <<up, forked, blobs, log, pending, requests>>

\* The first request is built once every image is saved or kept inline. It
\* sends every image of the session, and notes those with a blob.
Request ==
    /\ up /\ turn.phase = "open" /\ ~turn.requested
    /\ Saved
    /\ requests' = Append(requests,
         [s |-> turn.s,
          asked |-> turn.asked,
          sent |-> {d \in turn.asked : turn.form[d] \in Forms}
                   \cup Earlier(turn.s, "ref") \cup Earlier(turn.s, "inline"),
          noted |-> {d \in turn.asked : turn.form[d] = "ref"} \cup Earlier(turn.s, "ref")])
    /\ turn' = [turn EXCEPT !.requested = TRUE]
    /\ UNCHANGED <<up, forked, blobs, log, pending>>

\* The user item: each image by the form its save gave it, listing every
\* blob the turn stored.
Write ==
    /\ up /\ turn.phase = "open" /\ ~turn.written
    /\ Saved
    /\ log' = [log EXCEPT ![turn.s] = Append(@,
         [asked |-> turn.asked,
          images |-> [d \in Digests |-> IF d \in turn.asked THEN turn.form[d] ELSE "none"],
          listed |-> pending[turn.s]])]
    /\ pending' = [pending EXCEPT ![turn.s] = {}]
    /\ turn' = [turn EXCEPT !.written = TRUE]
    /\ UNCHANGED <<up, forked, blobs, requests>>

\* The turn ends once its request was sent and its item written.
Finish ==
    /\ up /\ turn.phase = "open" /\ turn.requested /\ turn.written
    /\ turn' = NoTurn
    /\ UNCHANGED <<up, forked, blobs, log, pending, requests>>

\* A crash loses memory: the turn and the unlisted blobs' names. The blob
\* files stay, unreferenced.
Crash ==
    /\ up /\ up' = FALSE
    /\ turn' = NoTurn /\ pending' = [s \in Sessions |-> {}]
    /\ UNCHANGED <<forked, blobs, log, requests>>

Restart == /\ ~up /\ up' = TRUE /\ UNCHANGED <<forked, blobs, log, pending, turn, requests>>

\* A fork between turns copies the source's items and hard-links the blobs
\* they list (D44).
Fork ==
    /\ up /\ ~forked /\ turn.phase = "none" /\ Len(log["source"]) > 0
    /\ forked' = TRUE
    /\ log' = [log EXCEPT !["fork"] = log["source"]]
    /\ blobs' = [blobs EXCEPT !["fork"] =
         UNION {log["source"][k].listed : k \in 1..Len(log["source"])}]
    /\ UNCHANGED <<up, pending, turn, requests>>

Next ==
    \/ \E s \in Sessions, a \in SUBSET Digests : Begin(s, a)
    \/ \E a \in SUBSET Digests : Import(a)
    \/ \E d \in Digests : Save(d) \/ SaveFails(d)
    \/ Request \/ Write \/ Finish \/ Crash \/ Restart \/ Fork

Spec == Init /\ [][Next]_vars

\* Every note names a file that holds that image's bytes in the request's
\* own session. Blobs are never removed, so it stays true after the send.
NoteNamesBlob == \A k \in 1..Len(requests) : requests[k].noted \subseteq blobs[requests[k].s]

\* Every image an item names by digest has its blob in that session,
\* including a fork's copy of the item.
RefHasBlob ==
    \A s \in Sessions : \A k \in 1..Len(log[s]) : \A d \in Digests :
        log[s][k].images[d] = "ref" => d \in blobs[s]

\* An item keeps every image the user attached, as a blob or inline.
ItemKeepsImages ==
    \A s \in Sessions : \A k \in 1..Len(log[s]) :
        {d \in Digests : log[s][k].images[d] \in Forms} = log[s][k].asked

\* Every request sends every image the user attached to its turn.
RequestSendsAll == \A k \in 1..Len(requests) : requests[k].asked \subseteq requests[k].sent

=============================================================================
