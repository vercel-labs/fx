--------------------------- MODULE ClipboardRead ---------------------------
(***************************************************************************)
(* Reading a clipboard image through the terminal with the kitty           *)
(* clipboard protocol, OSC 5522 (`Reader` in                               *)
(* src/ui/terminal/clipboard_protocol.zig, driven by                       *)
(* src/core/app/terminal_clipboard_runtime.zig).                           *)
(*                                                                         *)
(* fx asks the terminal for `image/png` when it cannot read the clipboard  *)
(* itself, as over SSH. Two actors write to one input stream: the terminal *)
(* and the person typing. fx reads it one token at a time.                 *)
(*                                                                         *)
(*   - The terminal first answers the mode query (DECRQM 5522), or         *)
(*     ignores it, as tmux does. Then it may answer the read with packets: *)
(*     OK, DATA, DONE, or an error. A packet is four tokens: the head of   *)
(*     its prefix (`ESC ] 55`, or from `ESC ]` while a request is open),   *)
(*     the rest of the prefix, its body, and its terminator. The theme     *)
(*     monitor holds the head until the rest of the prefix comes. The      *)
(*     terminal writes a packet in one piece and the stream keeps its      *)
(*     order, so no key lands inside one, but the network may stall        *)
(*     between its tokens, and the terminal may stop for good in the       *)
(*     middle of one.                                                      *)
(*   - Every deadline is an action that may fire at any time, so replies   *)
(*     can arrive after fx gave up on them, and stale replies of an old    *)
(*     request can meet a new one. The protocol carries no request id, so  *)
(*     fx cannot tell them apart; the model only requires that each        *)
(*     request ends with exactly one outcome.                              *)
(*   - Keys are whole tokens. A key that starts with ESC can end a packet  *)
(*     early in the code, which this model does not split. The bytes       *)
(*     before the head, a lone ESC that may be the Escape key, or less     *)
(*     than `ESC ] 55` with no request open, are outside the model too:    *)
(*     the theme monitor types them after its short timeout, as it does    *)
(*     for every terminal reply. The mode report's head is handled like a  *)
(*     packet's in the code and is not split here.                         *)
(*                                                                         *)
(* `Mutation` enables one deliberately broken rule:                        *)
(*   "no_resync"           a timed-out packet gives input back at once, so *)
(*                         its late rest reaches the composer.             *)
(*   "accept_idle_packets" a packet that arrives with no request open      *)
(*                         produces an outcome.                            *)
(*   "no_mode_deadline"    fx waits for the mode report forever, which a   *)
(*                         terminal that ignores the query never sends.    *)
(*   "no_size_check"       DATA grows the image past its limit.            *)
(*   "ask_while_pending"   Ctrl+V starts a request while one is open.      *)
(*   "resync_timeout"      the resync after a timed-out packet ends on a   *)
(*                         timer, so a longer stall types the packet's     *)
(*                         rest into the composer.                         *)
(*   "type_stalled_start"  the theme monitor types a held head that        *)
(*                         stalled, as it types a partial reply that may   *)
(*                         be a key.                                       *)
(*   "no_start_resync"     the theme monitor drops a stalled head but the  *)
(*                         reader does not drop the rest of its packet.    *)
(*                                                                         *)
(* Ctrl+V is a key like any other: fx starts a request when it reads the   *)
(* key with no reply owning input and no request pending.                  *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS MaxRequests, MaxKeys, MaxChunks, MaxImage, Mutation

ASSUME MaxRequests \in Nat \ {0}
ASSUME MaxKeys \in Nat
ASSUME MaxChunks \in Nat
ASSUME MaxImage \in Nat \ {0}
ASSUME Mutation \in {"none", "no_resync", "accept_idle_packets",
                     "no_mode_deadline", "no_size_check", "ask_while_pending",
                     "resync_timeout", "type_stalled_start", "no_start_resync"}

Kinds == {"OK", "DATA", "DONE", "EPERM", "ENOSYS", "BAD"}
Outcomes == {"image", "no_image", "unsupported", "denied", "timed_out",
             "too_large", "malformed"}
Phases == {"idle", "await_mode", "await_reply", "receiving", "discarding"}
Active == {"await_mode", "await_reply", "receiving"}

\* What a terminal may send for one request.
Replies ==
    {<<>>, <<"mode_no">>, <<"mode_yes">>,
     <<"mode_yes", "EPERM">>, <<"mode_yes", "ENOSYS">>,
     <<"mode_yes", "OK", "BAD", "DONE">>}
    \cup
    {<<"mode_yes", "OK">> \o [i \in 1..n |-> "DATA"] \o <<"DONE">> :
        n \in 0..MaxChunks}

Tokens ==
    {<<"key", c>> : c \in {"letter", "other", "ctrl_v"}}
    \cup {<<"mode", m>> : m \in {"yes", "no"}}
    \cup {<<"head">>, <<"start">>, <<"end">>}
    \cup {<<"body", k>> : k \in Kinds}

VARIABLES
    phase,      \* the reader's request phase
    own,        \* who takes input first: "none", "packet", or "resync"
    held,       \* the theme monitor holds a packet's head: "none" or "head"
    body,       \* the body kind of the packet being read, or "none"
    image,      \* DATA packets of the open transfer
    presses,    \* Ctrl+V presses so far
    requests,   \* requests fx started
    outcomes,   \* outcomes fx produced
    leaked,     \* a reply token reached the composer
    term,       \* replies the terminal has still to send, oldest first
    sending,    \* the rest of the packet the terminal is writing
    wire,       \* tokens on their way to fx
    keys        \* keys typed so far

vars == <<phase, own, held, body, image, presses, requests, outcomes, leaked,
          term, sending, wire, keys>>

TypeOK ==
    /\ phase \in Phases
    /\ own \in {"none", "packet", "resync"}
    /\ held \in {"none", "head"}
    /\ body \in Kinds \cup {"none"}
    /\ image \in Nat
    /\ presses \in 0..MaxRequests
    /\ requests \in 0..MaxRequests
    /\ outcomes \in Nat
    /\ leaked \in BOOLEAN
    /\ term \in Seq({"mode_yes", "mode_no"} \cup Kinds)
    /\ sending \in Seq(Tokens)
    /\ wire \in Seq(Tokens)
    /\ keys \in 0..MaxKeys

Init ==
    /\ phase = "idle"
    /\ own = "none"
    /\ held = "none"
    /\ body = "none"
    /\ image = 0
    /\ presses = 0
    /\ requests = 0
    /\ outcomes = 0
    /\ leaked = FALSE
    /\ term = <<>>
    /\ sending = <<>>
    /\ wire = <<>>
    /\ keys = 0

-----------------------------------------------------------------------------
(* The reader's request rules, as functions of the phase.                  *)

\* finish: the request ends; nothing more of it is expected.
Finish ==
    /\ phase' = "idle"
    /\ image' = 0
    /\ outcomes' = outcomes + 1

\* fail: the request ends in the middle of its transfer; the rest of the
\* transfer is consumed until it ends.
Fail ==
    IF phase \in Active
    THEN /\ phase' = "discarding"
         /\ image' = 0
         /\ outcomes' = outcomes + 1
    ELSE UNCHANGED <<phase, image, outcomes>>

\* A whole packet with body kind k ends.
ApplyPacket(k) ==
    CASE phase = "idle" ->
            IF Mutation = "accept_idle_packets" /\ k \in {"DONE", "EPERM", "ENOSYS"}
            THEN /\ outcomes' = outcomes + 1
                 /\ UNCHANGED <<phase, image>>
            ELSE UNCHANGED <<phase, image, outcomes>>
      [] phase = "discarding" ->
            /\ phase' = IF k \in {"DONE", "EPERM", "ENOSYS"} THEN "idle" ELSE "discarding"
            /\ UNCHANGED <<image, outcomes>>
      [] k = "OK" ->
            IF phase = "receiving" THEN Fail
            ELSE /\ phase' = "receiving"
                 /\ UNCHANGED <<image, outcomes>>
      [] k = "DATA" ->
            IF phase # "receiving" THEN Fail
            ELSE IF image = MaxImage /\ Mutation # "no_size_check" THEN Fail
            ELSE /\ image' = image + 1
                 /\ UNCHANGED <<phase, outcomes>>
      [] k \in {"DONE", "EPERM", "ENOSYS"} -> Finish
      [] k = "BAD" -> Fail

ApplyMode(m) ==
    IF phase = "await_mode"
    THEN IF m = "yes"
         THEN /\ phase' = "await_reply"
              /\ UNCHANGED <<image, outcomes>>
         ELSE Finish
    ELSE UNCHANGED <<phase, image, outcomes>>

-----------------------------------------------------------------------------
(* The person.                                                             *)

\* Neither key lands inside a packet the terminal is writing.
PressCtrlV ==
    /\ presses < MaxRequests
    /\ sending = <<>>
    /\ wire' = Append(wire, <<"key", "ctrl_v">>)
    /\ presses' = presses + 1
    /\ UNCHANGED <<phase, own, held, body, image, requests, outcomes, leaked, term, sending, keys>>

TypeKey ==
    /\ keys < MaxKeys
    /\ sending = <<>>
    /\ \E c \in {"letter", "other"} : wire' = Append(wire, <<"key", c>>)
    /\ keys' = keys + 1
    /\ UNCHANGED <<phase, own, held, body, image, presses, requests, outcomes, leaked, term, sending>>

-----------------------------------------------------------------------------
(* The terminal.                                                           *)

SendMode ==
    /\ sending = <<>>
    /\ term # <<>>
    /\ Head(term) \in {"mode_yes", "mode_no"}
    /\ wire' = Append(wire, <<"mode", IF Head(term) = "mode_yes" THEN "yes" ELSE "no">>)
    /\ term' = Tail(term)
    /\ UNCHANGED <<phase, own, held, body, image, presses, requests, outcomes, leaked, sending, keys>>

StartPacket ==
    /\ sending = <<>>
    /\ term # <<>>
    /\ Head(term) \in Kinds
    /\ sending' = <<<<"head">>, <<"start">>, <<"body", Head(term)>>, <<"end">>>>
    /\ term' = Tail(term)
    /\ UNCHANGED <<phase, own, held, body, image, presses, requests, outcomes, leaked, wire, keys>>

SendToken ==
    /\ sending # <<>>
    /\ wire' = Append(wire, Head(sending))
    /\ sending' = Tail(sending)
    /\ UNCHANGED <<phase, own, held, body, image, presses, requests, outcomes, leaked, term, keys>>

\* The terminal stops for good in the middle of a packet, as when it or the
\* SSH connection dies; nothing it still owed is sent.
StopMidPacket ==
    /\ sending # <<>>
    /\ Len(sending) < 4
    /\ sending' = <<>>
    /\ term' = <<>>
    /\ UNCHANGED <<phase, own, held, body, image, presses, requests, outcomes, leaked, wire, keys>>

-----------------------------------------------------------------------------
(* fx reads one token.                                                     *)

\* fx writes the request, and the terminal decides its reply.
StartRequest ==
    /\ \E reply \in Replies : term' = term \o reply
    /\ requests' = requests + 1
    /\ phase' = "await_mode"
    /\ UNCHANGED <<image, outcomes>>

\* Input that nobody owns: the theme monitor routes replies, and keys go to
\* the composer. The decoder ignores a bare terminator. Called from a resync,
\* or after the monitor drops a broken head, too, which this token ends.
ReadUnowned(tok) ==
    CASE tok = <<"key", "ctrl_v">> ->
            /\ own' = "none"
            /\ held' = "none"
            /\ IF phase = "idle" \/ Mutation = "ask_while_pending"
               THEN StartRequest
               ELSE UNCHANGED <<phase, image, requests, outcomes, term>>
            /\ UNCHANGED <<body, leaked>>
      [] tok[1] = "key" ->
            /\ own' = "none"
            /\ held' = "none"
            /\ UNCHANGED <<phase, body, image, requests, outcomes, leaked, term>>
      [] tok[1] = "mode" ->
            /\ own' = "none"
            /\ held' = "none"
            /\ ApplyMode(tok[2])
            /\ UNCHANGED <<body, requests, leaked, term>>
      [] tok[1] = "head" ->
            /\ own' = "none"
            /\ held' = "head"
            /\ UNCHANGED <<phase, body, image, requests, outcomes, leaked, term>>
      [] tok[1] \in {"start", "body"} ->
            /\ own' = "none"
            /\ held' = "none"
            /\ leaked' = TRUE
            /\ UNCHANGED <<phase, body, image, requests, outcomes, term>>
      [] tok[1] = "end" ->
            /\ own' = "none"
            /\ held' = "none"
            /\ UNCHANGED <<phase, body, image, requests, outcomes, leaked, term>>

\* The theme monitor holds a packet's head. The rest of the prefix starts the
\* packet; anything else means the head was a broken reply, so the monitor
\* drops it and reads the token on its own.
ReadHeld(tok) ==
    IF tok[1] = "start"
    THEN /\ own' = "packet"
         /\ held' = "none"
         /\ body' = "none"
         /\ UNCHANGED <<phase, image, requests, outcomes, leaked, term>>
    ELSE ReadUnowned(tok)

\* Inside a packet every token is the packet's.
ReadInPacket(tok) ==
    /\ CASE tok[1] = "end" ->
            /\ own' = "none"
            /\ body' = "none"
            /\ ApplyPacket(body)
            /\ UNCHANGED leaked
         [] tok[1] = "body" ->
            /\ body' = IF body = "none" THEN tok[2] ELSE "BAD"
            /\ UNCHANGED <<phase, own, image, outcomes, leaked>>
         [] OTHER ->
            /\ body' = "BAD"
            /\ UNCHANGED <<phase, own, image, outcomes, leaked>>
    /\ UNCHANGED <<held, requests, term>>

\* After a packet or its head timed out: the rest of its prefix, packet text,
\* and letters are dropped, the terminator ends the resync, and anything else
\* ends it and is read as unowned input. The resync has no timer, so the next
\* key that cannot be packet text, such as Enter or Ctrl+V, always gets
\* through.
ReadInResync(tok) ==
    CASE tok[1] \in {"start", "body"} \/ tok = <<"key", "letter">> ->
            UNCHANGED <<phase, own, held, body, image, requests, outcomes, leaked, term>>
      [] tok[1] = "end" ->
            /\ own' = "none"
            /\ UNCHANGED <<phase, held, body, image, requests, outcomes, leaked, term>>
      [] OTHER -> ReadUnowned(tok)

Read ==
    /\ wire # <<>>
    /\ LET tok == Head(wire) IN
        CASE own = "packet" -> ReadInPacket(tok)
          [] own = "resync" -> ReadInResync(tok)
          [] held = "head" -> ReadHeld(tok)
          [] OTHER -> ReadUnowned(tok)
    /\ wire' = Tail(wire)
    /\ UNCHANGED <<presses, sending, keys>>

-----------------------------------------------------------------------------
(* fx's deadlines. Each may fire whenever its timer could be running.      *)

ModeTimeout ==
    /\ Mutation # "no_mode_deadline"
    /\ own # "packet"
    /\ phase = "await_mode"
    /\ Finish
    /\ UNCHANGED <<own, held, body, presses, requests, leaked, term, sending, wire, keys>>

\* No status packet at all ends the request; a transfer that stops between
\* packets fails, so its late packets are consumed.
ReplyTimeout ==
    /\ own # "packet"
    /\ phase \in {"await_reply", "receiving"}
    /\ IF phase = "await_reply" THEN Finish ELSE Fail
    /\ UNCHANGED <<own, held, body, presses, requests, leaked, term, sending, wire, keys>>

DiscardTimeout ==
    /\ own # "packet"
    /\ phase = "discarding"
    /\ phase' = "idle"
    /\ UNCHANGED <<own, held, body, image, presses, requests, outcomes, leaked, term, sending, wire, keys>>

PacketTimeout ==
    /\ own = "packet"
    /\ own' = IF Mutation = "no_resync" THEN "none" ELSE "resync"
    /\ body' = "none"
    /\ Fail
    /\ UNCHANGED <<held, presses, requests, leaked, term, sending, wire, keys>>

\* The head stalled for the packet timeout. The monitor drops it, and the
\* reader drops the rest of its packet and ends the request
\* (`Reader.dropReplyStart`).
StartTimeout ==
    /\ held = "head"
    /\ held' = "none"
    /\ CASE Mutation = "type_stalled_start" ->
            /\ leaked' = TRUE
            /\ UNCHANGED <<phase, own, body, image, outcomes>>
         [] Mutation = "no_start_resync" ->
            /\ Fail
            /\ UNCHANGED <<own, body, leaked>>
         [] OTHER ->
            /\ own' = "resync"
            /\ Fail
            /\ UNCHANGED <<body, leaked>>
    /\ UNCHANGED <<presses, requests, term, sending, wire, keys>>

ResyncTimeout ==
    /\ Mutation = "resync_timeout"
    /\ own = "resync"
    /\ own' = "none"
    /\ UNCHANGED <<phase, held, body, image, presses, requests, outcomes, leaked, term, sending, wire, keys>>

-----------------------------------------------------------------------------

FxNext ==
    \/ Read
    \/ ModeTimeout \/ ReplyTimeout \/ DiscardTimeout
    \/ PacketTimeout \/ StartTimeout \/ ResyncTimeout

Next ==
    \/ PressCtrlV \/ TypeKey
    \/ SendMode \/ StartPacket \/ SendToken \/ StopMidPacket
    \/ FxNext

\* fx keeps reading and its timers keep running. The terminal and the
\* person may stop at any time.
Fairness ==
    /\ WF_vars(Read)
    /\ WF_vars(ModeTimeout)
    /\ WF_vars(ReplyTimeout)
    /\ WF_vars(DiscardTimeout)
    /\ WF_vars(PacketTimeout)
    /\ WF_vars(StartTimeout)
    /\ WF_vars(ResyncTimeout)

Spec == Init /\ [][Next]_vars /\ Fairness
SafetySpec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties.                                                             *)

\* No token of a reply is typed into the composer.
NoReplyInComposer == ~leaked

\* Each request ends with exactly one outcome, and at most one is open.
OneOutcomePerRequest ==
    /\ outcomes <= requests
    /\ requests <= outcomes + 1
    /\ (requests = outcomes + 1) <=> (phase \in Active)

\* The image never grows past its limit.
ImageBounded == image <= MaxImage

\* Every request ends, whatever the terminal does.
EveryRequestEnds == (requests > outcomes) ~> (requests = outcomes)

\* A packet never holds input for good. A resync holds it only until the
\* next byte that cannot be packet text.
PacketEnds == (own = "packet") ~> (own # "packet")

\* The theme monitor never holds a head for good.
HeadEnds == (held = "head") ~> (held = "none")

=============================================================================
