---------------------------- MODULE PasteEvents ----------------------------
(***************************************************************************)
(* Kitty paste events (DECSET ?5522h / OSC 5522) for fx, Design A of       *)
(* docs/ghostty-paste-events/plan.md.                                      *)
(*                                                                         *)
(* fx sets mode 5522 at startup (non-tmux) and resets it on every exit     *)
(* path (normal exit, signal/hangup, Ctrl+Z suspend; set again on resume). *)
(* When the person pastes with mode 5522 on, the terminal sends an         *)
(* unsolicited listing: OK(pw) -> DATA(mime list) -> DONE. fx records the  *)
(* input owner at the listing's OK, picks image/png only when the recorded *)
(* owner is composer and image/png is listed (else a text MIME, else       *)
(* notice/drop), and sends one read with pw.                               *)
(*                                                                         *)
(* Keys the person types can arrive between any two packets and may change *)
(* the current owner; they are never mistaken for reply bytes, and listing *)
(* or reply bytes never reach a text box. At most one clipboard request is *)
(* outstanding at a time (a listing arriving while Ctrl+V or an earlier    *)
(* paste read is open is dropped with a busy notice). Passwords are        *)
(* single-use: a second read with the same password gets EPERM.            *)
(*                                                                         *)
(* `Mutation` enables one deliberately broken rule (or `current_today`):   *)
(*   "current_today"               mode 5522 never set, listings dropped   *)
(*   "paste_uses_current_owner"    routes text to current owner at DONE    *)
(*   "no_exit_mode_reset"          exit/suspend leaves mode 5522 on        *)
(*   "paste_attach_in_modal"       allows image/png when owner is modal    *)
(*   "listing_while_busy_accepted" accepts listing while read is open      *)
(*   "no_reply_deadline"           no timeout on stalled reply             *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS MaxPastes, MaxKeys, MaxCtrlV, Mutation

ASSUME MaxPastes \in Nat \ {0}
ASSUME MaxKeys \in Nat
ASSUME MaxCtrlV \in Nat
ASSUME Mutation \in {"none", "current_today", "paste_uses_current_owner",
                     "no_exit_mode_reset", "paste_attach_in_modal",
                     "listing_while_busy_accepted", "no_reply_deadline"}

Owners == {"composer", "modal", "decision"}
MimeLists == {"png_text", "text", "unknown", "empty"}
Settlements == {"attach", "text_paste", "notice"}

VARIABLES
    mode5522,         \* "off" or "on"
    lifecycle,        \* "running", "suspended", "exited"
    activeOwner,      \* current UI input owner: "composer", "modal", "decision"
    pasteOwner,       \* owner recorded at listing OK, or "none"
    recordedOwner,    \* [1..MaxPastes -> Owners \cup {"none"}]: recorded owner per paste
    phase,            \* "idle", "listing", "await_reply", "receiving"
    discardListing,   \* TRUE while consuming a busy-dropped listing's DATA/DONE
    ctrlVOpen,        \* TRUE while a Ctrl+V read is open
    openReads,        \* count of accepted open clipboard requests (Ctrl+V or paste)
    listingMimes,     \* MIME list from current listing, or "none"
    readKind,         \* "none", "image", "text"
    pwState,          \* "none", "fresh", "used", "expired"
    term,             \* packets waiting to be put on wire by the terminal
    wire,             \* tokens on their way to fx
    leaked,           \* TRUE if listing or reply bytes reached a text box
    pastesStarted,    \* number of paste events started
    activePaste,      \* paste index (1..MaxPastes) owning current listing/read, or 0
    settledCount,     \* [1..MaxPastes -> Nat]: number of settlements per paste
    imgCompPaste,     \* [1..MaxPastes -> BOOLEAN]: paste was image-in-composer
    attachedPaste,    \* [1..MaxPastes -> BOOLEAN]: paste settled as attach
    failedPaste,      \* [1..MaxPastes -> BOOLEAN]: paste failed / dropped busy
    lastSettlement,   \* last settlement kind, or "none"
    textOwner,        \* [1..MaxPastes -> Owners \cup {"none"}]: owner that got text_paste
    lastAttachOwner,  \* owner when last attach occurred, or "none"
    keys,             \* keys typed so far
    ctrlVs,           \* Ctrl+V reads started so far
    suspends          \* Ctrl+Z suspends so far

vars == <<mode5522, lifecycle, activeOwner, pasteOwner, recordedOwner, phase,
          discardListing, ctrlVOpen, openReads, listingMimes, readKind, pwState,
          term, wire, leaked, pastesStarted, activePaste, settledCount,
          imgCompPaste, attachedPaste, failedPaste, lastSettlement,
          textOwner, lastAttachOwner, keys, ctrlVs, suspends>>

Tokens ==
    {<<"key", o>> : o \in Owners}
    \cup {<<"list_ok", p, m>> : p \in 1..MaxPastes, m \in MimeLists}
    \cup {<<"list_data">>, <<"list_done">>,
          <<"reply_ok">>, <<"reply_data">>, <<"reply_done">>, <<"reply_eperm">>}

TypeOK ==
    /\ mode5522 \in {"off", "on"}
    /\ lifecycle \in {"running", "suspended", "exited"}
    /\ activeOwner \in Owners
    /\ pasteOwner \in Owners \cup {"none"}
    /\ recordedOwner \in [1..MaxPastes -> Owners \cup {"none"}]
    /\ phase \in {"idle", "listing", "await_reply", "receiving"}
    /\ discardListing \in BOOLEAN
    /\ ctrlVOpen \in BOOLEAN
    /\ openReads \in Nat
    /\ listingMimes \in MimeLists \cup {"none"}
    /\ readKind \in {"none", "image", "text"}
    /\ pwState \in {"none", "fresh", "used", "expired"}
    /\ term \in Seq(Tokens)
    /\ wire \in Seq(Tokens)
    /\ leaked \in BOOLEAN
    /\ pastesStarted \in 0..MaxPastes
    /\ activePaste \in 0..MaxPastes
    /\ settledCount \in [1..MaxPastes -> 0..2]
    /\ imgCompPaste \in [1..MaxPastes -> BOOLEAN]
    /\ attachedPaste \in [1..MaxPastes -> BOOLEAN]
    /\ failedPaste \in [1..MaxPastes -> BOOLEAN]
    /\ lastSettlement \in Settlements \cup {"none"}
    /\ textOwner \in [1..MaxPastes -> Owners \cup {"none"}]
    /\ lastAttachOwner \in Owners \cup {"none"}
    /\ keys \in 0..MaxKeys
    /\ ctrlVs \in 0..MaxCtrlV
    /\ suspends \in 0..1

Init ==
    /\ mode5522 = IF Mutation = "current_today" THEN "off" ELSE "on"
    /\ lifecycle = "running"
    /\ activeOwner = "composer"
    /\ pasteOwner = "none"
    /\ recordedOwner = [p \in 1..MaxPastes |-> "none"]
    /\ phase = "idle"
    /\ discardListing = FALSE
    /\ ctrlVOpen = FALSE
    /\ openReads = 0
    /\ listingMimes = "none"
    /\ readKind = "none"
    /\ pwState = "none"
    /\ term = <<>>
    /\ wire = <<>>
    /\ leaked = FALSE
    /\ pastesStarted = 0
    /\ activePaste = 0
    /\ settledCount = [p \in 1..MaxPastes |-> 0]
    /\ imgCompPaste = [p \in 1..MaxPastes |-> FALSE]
    /\ attachedPaste = [p \in 1..MaxPastes |-> FALSE]
    /\ failedPaste = [p \in 1..MaxPastes |-> FALSE]
    /\ lastSettlement = "none"
    /\ textOwner = [p \in 1..MaxPastes |-> "none"]
    /\ lastAttachOwner = "none"
    /\ keys = 0
    /\ ctrlVs = 0
    /\ suspends = 0

-----------------------------------------------------------------------------
(* Person & lifecycle actions.                                             *)

TypeKey ==
    /\ lifecycle = "running"
    /\ keys < MaxKeys
    /\ \E nextOwner \in Owners :
        wire' = Append(wire, <<"key", nextOwner>>)
    /\ keys' = keys + 1
    /\ UNCHANGED <<mode5522, lifecycle, activeOwner, pasteOwner, recordedOwner,
                   phase, discardListing, ctrlVOpen, openReads, listingMimes,
                   readKind, pwState, term, leaked, pastesStarted, activePaste,
                   settledCount, imgCompPaste, attachedPaste, failedPaste,
                   lastSettlement, textOwner, lastAttachOwner, ctrlVs,
                   suspends>>

StartCtrlV ==
    /\ lifecycle = "running"
    /\ ctrlVs < MaxCtrlV
    /\ phase = "idle"
    /\ ~ctrlVOpen
    /\ ctrlVOpen' = TRUE
    /\ openReads' = openReads + 1
    /\ ctrlVs' = ctrlVs + 1
    /\ UNCHANGED <<mode5522, lifecycle, activeOwner, pasteOwner, recordedOwner,
                   phase, discardListing, listingMimes, readKind, pwState, term,
                   wire, leaked, pastesStarted, activePaste, settledCount,
                   imgCompPaste, attachedPaste, failedPaste, lastSettlement,
                   textOwner, lastAttachOwner, keys, suspends>>

FinishCtrlV ==
    /\ lifecycle = "running"
    /\ ctrlVOpen
    /\ ctrlVOpen' = FALSE
    /\ openReads' = IF openReads > 0 THEN openReads - 1 ELSE 0
    /\ UNCHANGED <<mode5522, lifecycle, activeOwner, pasteOwner, recordedOwner,
                   phase, discardListing, listingMimes, readKind, pwState, term,
                   wire, leaked, pastesStarted, activePaste, settledCount,
                   imgCompPaste, attachedPaste, failedPaste, lastSettlement,
                   textOwner, lastAttachOwner, keys, ctrlVs, suspends>>

PersonPaste ==
    /\ lifecycle = "running"
    /\ pastesStarted < MaxPastes
    /\ term = <<>>
    /\ LET p == pastesStarted + 1 IN
       /\ pastesStarted' = p
       /\ \E m \in MimeLists :
            /\ imgCompPaste' = [imgCompPaste EXCEPT ![p] =
                                (activeOwner = "composer" /\ m = "png_text"
                                 /\ ~ctrlVOpen /\ phase = "idle" /\ wire = <<>>)]
            /\ IF mode5522 = "on"
               THEN /\ term' = <<<<"list_ok", p, m>>, <<"list_data">>, <<"list_done">>>>
                    /\ pwState' = "fresh"
               ELSE /\ UNCHANGED <<term, pwState>>
    /\ UNCHANGED <<mode5522, lifecycle, activeOwner, pasteOwner, recordedOwner,
                   phase, discardListing, ctrlVOpen, openReads, listingMimes,
                   readKind, wire, leaked, activePaste, settledCount,
                   attachedPaste, failedPaste, lastSettlement, textOwner,
                   lastAttachOwner, keys, ctrlVs, suspends>>

ExitNormal ==
    /\ lifecycle = "running"
    /\ lifecycle' = "exited"
    /\ mode5522' = IF Mutation = "no_exit_mode_reset" THEN mode5522 ELSE "off"
    /\ UNCHANGED <<activeOwner, pasteOwner, recordedOwner, phase, discardListing,
                   ctrlVOpen, openReads, listingMimes, readKind, pwState, term,
                   wire, leaked, pastesStarted, activePaste, settledCount,
                   imgCompPaste, attachedPaste, failedPaste, lastSettlement,
                   textOwner, lastAttachOwner, keys, ctrlVs, suspends>>

ExitSignalOrHangup ==
    /\ lifecycle = "running"
    /\ lifecycle' = "exited"
    /\ mode5522' = IF Mutation = "no_exit_mode_reset" THEN mode5522 ELSE "off"
    /\ UNCHANGED <<activeOwner, pasteOwner, recordedOwner, phase, discardListing,
                   ctrlVOpen, openReads, listingMimes, readKind, pwState, term,
                   wire, leaked, pastesStarted, activePaste, settledCount,
                   imgCompPaste, attachedPaste, failedPaste, lastSettlement,
                   textOwner, lastAttachOwner, keys, ctrlVs, suspends>>

Suspend ==
    /\ lifecycle = "running"
    /\ suspends < 1
    /\ suspends' = suspends + 1
    /\ lifecycle' = "suspended"
    /\ mode5522' = IF Mutation = "no_exit_mode_reset" THEN mode5522 ELSE "off"
    /\ UNCHANGED <<activeOwner, pasteOwner, recordedOwner, phase, discardListing,
                   ctrlVOpen, openReads, listingMimes, readKind, pwState, term,
                   wire, leaked, pastesStarted, activePaste, settledCount,
                   imgCompPaste, attachedPaste, failedPaste, lastSettlement,
                   textOwner, lastAttachOwner, keys, ctrlVs>>

Resume ==
    /\ lifecycle = "suspended"
    /\ lifecycle' = "running"
    /\ mode5522' = IF Mutation = "current_today" THEN "off" ELSE "on"
    /\ UNCHANGED <<activeOwner, pasteOwner, recordedOwner, phase, discardListing,
                   ctrlVOpen, openReads, listingMimes, readKind, pwState, term,
                   wire, leaked, pastesStarted, activePaste, settledCount,
                   imgCompPaste, attachedPaste, failedPaste, lastSettlement,
                   textOwner, lastAttachOwner, keys, ctrlVs, suspends>>

-----------------------------------------------------------------------------
(* Terminal packet transmission (keys may interleave between any packets). *)

TerminalSendPacket ==
    /\ lifecycle = "running"
    /\ term # <<>>
    /\ wire' = Append(wire, Head(term))
    /\ term' = Tail(term)
    /\ UNCHANGED <<mode5522, lifecycle, activeOwner, pasteOwner, recordedOwner,
                   phase, discardListing, ctrlVOpen, openReads, listingMimes,
                   readKind, pwState, leaked, pastesStarted, activePaste,
                   settledCount, imgCompPaste, attachedPaste, failedPaste,
                   lastSettlement, textOwner, lastAttachOwner, keys, ctrlVs,
                   suspends>>

TerminalPrepareReply ==
    /\ lifecycle = "running"
    /\ phase = "await_reply"
    /\ term = <<>>
    /\ wire = <<>>
    /\ IF pwState = "fresh"
       THEN \E outcome \in {"ok", "eperm", "stall", "too_large"} :
            IF outcome = "ok"
            THEN /\ term' = <<<<"reply_ok">>, <<"reply_data">>, <<"reply_done">>>>
                 /\ pwState' = "used"
                 /\ UNCHANGED failedPaste
            ELSE IF outcome = "eperm"
            THEN /\ term' = <<<<"reply_eperm">>>>
                 /\ pwState' = "expired"
                 /\ failedPaste' = [failedPaste EXCEPT ![activePaste] = TRUE]
            ELSE IF outcome = "too_large"
            THEN /\ term' = <<<<"reply_ok">>, <<"reply_data">>>>
                 /\ pwState' = "used"
                 /\ failedPaste' = [failedPaste EXCEPT ![activePaste] = TRUE]
            ELSE /\ term' = <<>>
                 /\ failedPaste' = [failedPaste EXCEPT ![activePaste] = TRUE]
                 /\ UNCHANGED pwState
       ELSE \* Second read with the same password gets EPERM.
            /\ term' = <<<<"reply_eperm">>>>
            /\ failedPaste' = [failedPaste EXCEPT ![activePaste] = TRUE]
            /\ UNCHANGED pwState
    /\ UNCHANGED <<mode5522, lifecycle, activeOwner, pasteOwner, recordedOwner,
                   phase, discardListing, ctrlVOpen, openReads, listingMimes,
                   readKind, wire, leaked, pastesStarted, activePaste,
                   settledCount, imgCompPaste, attachedPaste, failedPaste,
                   lastSettlement, textOwner, lastAttachOwner, keys, ctrlVs,
                   suspends>>

-----------------------------------------------------------------------------
(* fx reads tokens from the input stream.                                  *)

Settle(p, kind, owner) ==
    /\ settledCount' = [settledCount EXCEPT ![p] = @ + 1]
    /\ lastSettlement' = kind
    /\ IF kind = "attach"
       THEN /\ attachedPaste' = [attachedPaste EXCEPT ![p] = TRUE]
            /\ lastAttachOwner' = owner
            /\ UNCHANGED textOwner
       ELSE IF kind = "text_paste"
       THEN /\ textOwner' = [textOwner EXCEPT ![p] = owner]
            /\ UNCHANGED <<attachedPaste, lastAttachOwner>>
       ELSE UNCHANGED <<attachedPaste, textOwner, lastAttachOwner>>

Read ==
    /\ lifecycle = "running"
    /\ wire # <<>>
    /\ LET tok == Head(wire) IN
       /\ wire' = Tail(wire)
       /\ CASE tok[1] = "key" ->
                /\ activeOwner' = tok[2]
                /\ UNCHANGED <<pasteOwner, recordedOwner, phase, discardListing,
                               openReads, listingMimes, readKind, activePaste,
                               settledCount, imgCompPaste, attachedPaste,
                               failedPaste, lastSettlement, textOwner,
                               lastAttachOwner>>
            [] tok[1] = "list_ok" ->
                LET p == tok[2]
                    m == tok[3]
                IN /\ UNCHANGED activeOwner
                   /\ (IF Mutation = "current_today"
                       THEN UNCHANGED <<pasteOwner, recordedOwner, phase,
                                      discardListing, openReads, listingMimes,
                                      readKind, activePaste, settledCount,
                                      imgCompPaste, attachedPaste, failedPaste,
                                      lastSettlement, textOwner, lastAttachOwner>>
                       ELSE IF (ctrlVOpen \/ phase # "idle")
                               /\ Mutation # "listing_while_busy_accepted"
                       THEN \* Busy: drop incoming listing with a busy notice.
                            /\ discardListing' = TRUE
                            /\ failedPaste' = [failedPaste EXCEPT ![p] = TRUE]
                            /\ Settle(p, "notice", "none")
                            /\ UNCHANGED <<pasteOwner, recordedOwner, phase,
                                           openReads, listingMimes, readKind,
                                           activePaste, imgCompPaste>>
                       ELSE
                            /\ phase' = "listing"
                            /\ activePaste' = p
                            /\ pasteOwner' = activeOwner
                            /\ recordedOwner' = [recordedOwner EXCEPT ![p] = activeOwner]
                            /\ listingMimes' = m
                            /\ openReads' = openReads + 1
                            /\ IF activeOwner # "composer"
                               THEN imgCompPaste' = [imgCompPaste EXCEPT ![p] = FALSE]
                               ELSE UNCHANGED imgCompPaste
                            /\ UNCHANGED <<discardListing, readKind, settledCount,
                                           attachedPaste, failedPaste,
                                           lastSettlement, textOwner,
                                           lastAttachOwner>>)
            [] tok[1] = "list_data" ->
                UNCHANGED <<activeOwner, pasteOwner, recordedOwner, phase,
                               discardListing, openReads, listingMimes,
                               readKind, activePaste, settledCount,
                               imgCompPaste, attachedPaste, failedPaste,
                               lastSettlement, textOwner, lastAttachOwner>>
            [] tok[1] = "list_done" ->
                /\ UNCHANGED activeOwner
                /\ (IF discardListing
                    THEN /\ discardListing' = FALSE
                         /\ UNCHANGED <<pasteOwner, recordedOwner, phase, openReads,
                                        listingMimes, readKind, activePaste,
                                        settledCount, imgCompPaste, attachedPaste,
                                        failedPaste, lastSettlement, textOwner,
                                        lastAttachOwner>>
                    ELSE IF phase = "listing"
                    THEN LET targetOwner == IF Mutation = "paste_uses_current_owner"
                                            THEN activeOwner ELSE pasteOwner
                             canAttach == (targetOwner = "composer")
                                          \/ (Mutation = "paste_attach_in_modal"
                                              /\ targetOwner = "modal")
                         IN IF targetOwner = "decision"
                               \/ listingMimes \in {"empty", "unknown"}
                            THEN /\ phase' = "idle"
                                 /\ pasteOwner' = "none"
                                 /\ listingMimes' = "none"
                                 /\ readKind' = "none"
                                 /\ openReads' = IF openReads > 0 THEN openReads - 1 ELSE 0
                                 /\ Settle(activePaste, "notice", targetOwner)
                                 /\ activePaste' = 0
                                 /\ UNCHANGED <<discardListing, recordedOwner,
                                                imgCompPaste, failedPaste>>
                            ELSE LET chosen == IF canAttach /\ listingMimes = "png_text"
                                               THEN "image" ELSE "text"
                                 IN /\ phase' = "await_reply"
                                    /\ readKind' = chosen
                                    /\ listingMimes' = "none"
                                    /\ pasteOwner' = targetOwner
                                    /\ UNCHANGED <<recordedOwner, discardListing,
                                                   openReads, activePaste,
                                                   settledCount, imgCompPaste,
                                                   attachedPaste, failedPaste,
                                                   lastSettlement, textOwner,
                                                   lastAttachOwner>>
                    ELSE UNCHANGED <<pasteOwner, recordedOwner, phase, discardListing,
                                   openReads, listingMimes, readKind, activePaste,
                                   settledCount, imgCompPaste, attachedPaste,
                                   failedPaste, lastSettlement, textOwner,
                                   lastAttachOwner>>)
            [] tok[1] = "reply_ok" ->
                /\ IF phase = "await_reply"
                   THEN phase' = "receiving"
                   ELSE phase' = phase
                /\ UNCHANGED <<activeOwner, pasteOwner, recordedOwner,
                               discardListing, openReads, listingMimes,
                               readKind, activePaste, settledCount,
                               imgCompPaste, attachedPaste, failedPaste,
                               lastSettlement, textOwner, lastAttachOwner>>
            [] tok[1] = "reply_data" ->
                UNCHANGED <<activeOwner, pasteOwner, recordedOwner, phase,
                               discardListing, openReads, listingMimes,
                               readKind, activePaste, settledCount,
                               imgCompPaste, attachedPaste, failedPaste,
                               lastSettlement, textOwner, lastAttachOwner>>
            [] tok[1] = "reply_done" ->
                /\ UNCHANGED activeOwner
                /\ (IF phase = "receiving"
                    THEN LET kind == IF readKind = "image" THEN "attach" ELSE "text_paste"
                             dest == IF kind = "text_paste" /\ Mutation = "paste_uses_current_owner"
                                     THEN activeOwner ELSE pasteOwner
                         IN /\ phase' = "idle"
                            /\ pasteOwner' = "none"
                            /\ readKind' = "none"
                            /\ openReads' = IF openReads > 0 THEN openReads - 1 ELSE 0
                            /\ Settle(activePaste, kind, dest)
                            /\ activePaste' = 0
                            /\ UNCHANGED <<recordedOwner, discardListing,
                                           listingMimes, imgCompPaste, failedPaste>>
                    ELSE UNCHANGED <<pasteOwner, recordedOwner, phase, discardListing,
                                   openReads, listingMimes, readKind, activePaste,
                                   settledCount, imgCompPaste, attachedPaste,
                                   failedPaste, lastSettlement, textOwner,
                                   lastAttachOwner>>)
            [] tok[1] = "reply_eperm" ->
                /\ UNCHANGED activeOwner
                /\ (IF phase \in {"await_reply", "receiving"}
                    THEN /\ phase' = "idle"
                         /\ pasteOwner' = "none"
                         /\ readKind' = "none"
                         /\ openReads' = IF openReads > 0 THEN openReads - 1 ELSE 0
                         /\ failedPaste' = [failedPaste EXCEPT ![activePaste] = TRUE]
                         /\ Settle(activePaste, "notice", "none")
                         /\ activePaste' = 0
                         /\ UNCHANGED <<recordedOwner, discardListing, listingMimes,
                                        imgCompPaste>>
                    ELSE UNCHANGED <<pasteOwner, recordedOwner, phase, discardListing,
                                   openReads, listingMimes, readKind, activePaste,
                                   settledCount, imgCompPaste, attachedPaste,
                                   failedPaste, lastSettlement, textOwner,
                                   lastAttachOwner>>)
    /\ UNCHANGED <<mode5522, lifecycle, ctrlVOpen, pwState, term, leaked,
                   pastesStarted, keys, ctrlVs, suspends>>

ReplyTimeout ==
    /\ lifecycle = "running"
    /\ Mutation # "no_reply_deadline"
    /\ phase \in {"await_reply", "receiving"}
    /\ term = <<>>
    /\ wire = <<>>
    /\ phase' = "idle"
    /\ pasteOwner' = "none"
    /\ readKind' = "none"
    /\ openReads' = IF openReads > 0 THEN openReads - 1 ELSE 0
    /\ failedPaste' = [failedPaste EXCEPT ![activePaste] = TRUE]
    /\ Settle(activePaste, "notice", "none")
    /\ activePaste' = 0
    /\ UNCHANGED <<mode5522, lifecycle, activeOwner, recordedOwner,
                   discardListing, ctrlVOpen, listingMimes, pwState, term,
                   wire, leaked, pastesStarted, imgCompPaste, keys, ctrlVs,
                   suspends>>

-----------------------------------------------------------------------------

Next ==
    \/ TypeKey \/ StartCtrlV \/ FinishCtrlV \/ PersonPaste
    \/ ExitNormal \/ ExitSignalOrHangup \/ Suspend \/ Resume
    \/ TerminalSendPacket \/ TerminalPrepareReply \/ Read \/ ReplyTimeout

Fairness ==
    /\ WF_vars(TerminalSendPacket)
    /\ WF_vars(Read)
    /\ WF_vars(ReplyTimeout)
    /\ WF_vars(Resume)

Spec == Init /\ [][Next]_vars /\ Fairness
SafetySpec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Invariants & Liveness.                                                  *)

NoListingOrReplyInTextBox == ~leaked

OneSettlementPerPasteEvent ==
    \A p \in 1..MaxPastes : settledCount[p] <= 1

NoImageOutsideComposer ==
    lastAttachOwner \in {"none", "composer"}

PasteTextToRecordedOwner ==
    \A p \in 1..MaxPastes :
        (textOwner[p] # "none") => (textOwner[p] = recordedOwner[p])

OneRequestAtATime ==
    openReads <= 1

ModeOffAfterExit ==
    (lifecycle \in {"suspended", "exited"}) => (mode5522 = "off")

EveryPasteEventSettles ==
    (\E p \in 1..pastesStarted : settledCount[p] = 0 /\ lifecycle = "running") ~>
        ((\A p \in 1..pastesStarted : settledCount[p] = 1) \/ lifecycle = "exited")

PasteWithImageAttaches ==
    \A p \in 1..MaxPastes :
        (imgCompPaste[p] /\ ~failedPaste[p] /\ lifecycle = "running") ~>
            (attachedPaste[p] \/ failedPaste[p] \/ ~imgCompPaste[p] \/ lifecycle = "exited")

=============================================================================
