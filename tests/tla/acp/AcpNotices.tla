----------------------------- MODULE AcpNotices -----------------------------
(***************************************************************************)
(* How `fx acp` sends the text the agent runtime emits about a turn, to a  *)
(* client that advertises ACP v1 Session Notices                           *)
(* (clientCapabilities.session.notices = {}) and to one that does not      *)
(* (src/acp/prompt.zig pushText, pushSystemNotice, pushTurnFailureNotice,  *)
(* pushHttpError, pushDiffBlock, and pushContextNotice).                   *)
(*                                                                         *)
(* The runtime tags each text with its kind: the TextEmission variants in  *)
(* src/core/agent/runtime/deps.zig, plus the system-notice, turn-failure-  *)
(* notice, HTTP-failure, diff, and context-notice callbacks. A text is     *)
(* blank when it holds only whitespace, such as the "\n" the runtime sends *)
(* after a line.                                                           *)
(*                                                                         *)
(* ACP v1 says an agent must not rely on a notice for fatal-error          *)
(* reporting, and that notices are not session history. So the text that  *)
(* says why a turn failed (turn_failure, turn_failure_notice, and the HTTP *)
(* failure that ends the request) and the text fx saves as the reply       *)
(* (saved_reply) stay agent messages for every client, as do the reply and *)
(* diff previews. The rest reaches a notices client as one notice per      *)
(* message and a plain client as the agent messages it gets today.         *)
(*                                                                         *)
(* A turn ends for one of five causes, and each cause has a text: an HTTP  *)
(* failure, a provider error event, a response-language failure, the step  *)
(* limit, and a second empty reply. Which callback carries a cause's text  *)
(* is KindFor. The turn-failure notice is the callback of the two causes   *)
(* whose other hosts show a system notice (the TUI styles it, fx ask       *)
(* prefixes [notice]) and only ACP needs as a message. A text that ends a  *)
(* turn is flagged, and no flagged text may be a notice                    *)
(* (NoTurnEndingNotice).                                                   *)
(*                                                                         *)
(* Each sent text also carries the message it lands in. A notice still     *)
(* ends the assistant's message, as the same text did when it was a        *)
(* message, so the reply that follows starts a new one (AssistantSplit).   *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS
    Mode,     \* "fixed"; "before", fx before this rule; a head; or a planted bug
    MaxSteps  \* emissions per turn

Modes == {"fixed", "before", "head_provider_error", "head_language",
          "failure_notice", "saved_reply_notice", "fragment_notice",
          "plain_notice", "no_rotate"}

Kinds == {"assistant", "operational", "restarted", "turn_failure",
          "turn_failure_notice", "saved_reply", "system", "http_failure",
          "diff", "context"}

\* Why a turn ends, and the marker of a text that is no turn's ending.
Causes == {"http", "provider_error", "language", "step_limit", "second_empty"}
NoCause == "none"

\* The callback that carries the text of a cause. The heads are fx before
\* the turn-failure notice: its two system-notice exits still use "system".
KindFor(c) ==
    CASE c = "http" -> "http_failure"
      [] c \in {"step_limit", "second_empty"} -> "turn_failure"
      [] c = "provider_error" ->
            IF Mode = "head_provider_error" THEN "system" ELSE "turn_failure_notice"
      [] c = "language" ->
            IF Mode = "head_language" THEN "system" ELSE "turn_failure_notice"

\* Kinds the runtime can send as whitespace alone.
Blankable == {"assistant", "operational", "restarted", "turn_failure", "saved_reply"}

\* Kinds that stay in the conversation for every client.
MessageKinds == {"assistant", "turn_failure", "turn_failure_notice", "saved_reply",
                 "http_failure", "diff"}

\* Kinds that say why a turn failed.
FailureKinds == {"turn_failure", "turn_failure_notice", "http_failure"}

\* Kinds a notices client gets as notices.
NoticeKinds == {"operational", "restarted", "system", "context"}

\* The severity a kind's notice has. Failures appear here only so a
\* planted bug that turns them into notices has a well-formed severity.
Severity(k) ==
    CASE k \in FailureKinds -> "error"
      [] k = "system" -> "warning"
      [] OTHER -> "info"

Message == [type |-> "message", severity |-> "-"]
Nothing == [type |-> "none", severity |-> "-"]
Notice(k) == [type |-> "notice", severity |-> Severity(k)]

Fixed(notices, k, blank) ==
    IF ~notices \/ k \in MessageKinds THEN Message
    ELSE IF blank THEN Nothing
    ELSE Notice(k)

\* fx before this rule: only context notices reach a notices client as
\* notices; everything else is an agent message.
Before(notices, k) ==
    IF notices /\ k = "context" THEN Notice(k) ELSE Message

\* What fx acp sends for one emission.
Send(notices, k, blank) ==
    CASE Mode = "before" -> Before(notices, k)
      \* Planted: failure text sent as an error notice.
      [] Mode = "failure_notice" ->
            IF notices /\ k \in FailureKinds /\ ~blank
            THEN Notice(k) ELSE Fixed(notices, k, blank)
      \* Planted: "Done." and the length-limit retry text sent as notices.
      [] Mode = "saved_reply_notice" ->
            IF notices /\ k = "saved_reply" /\ ~blank
            THEN Notice(k) ELSE Fixed(notices, k, blank)
      \* Planted: every fragment its own notice, blank ones too.
      [] Mode = "fragment_notice" ->
            IF notices /\ k \in NoticeKinds
            THEN Notice(k) ELSE Fixed(notices, k, blank)
      \* Planted: notices sent without the client's capability.
      [] Mode = "plain_notice" ->
            IF k \in NoticeKinds /\ ~blank
            THEN Notice(k) ELSE Fixed(notices, k, blank)
      [] OTHER -> Fixed(notices, k, blank)

\* The message group an emission moves to. Text that becomes a notice
\* still moves the group, so the next reply starts a new message; a
\* context notice to a notices client leaves it, as it always has.
GroupAfter(notices, k, group) ==
    CASE k = "assistant" -> "assistant"
      [] k = "context" /\ notices -> group
      \* Planted: a notice leaves the group, so the reply after it joins
      \* the message before it.
      [] Mode = "no_rotate" /\ Send(notices, k, FALSE).type = "notice" -> group
      [] OTHER -> "operational"

VARIABLES
    notices,  \* the client advertised session.notices
    sent,     \* what fx sent for each emission, in order
    group,    \* the message group the last emission left: "none", "assistant", "operational"
    msgId,    \* the current message's number
    lastMsg   \* the number of the last message sent, 0 before any

vars == <<notices, sent, group, msgId, lastMsg>>

Outputs == [type : {"message", "notice", "none"}, severity : {"info", "warning", "error", "-"}]
Sent == [kind : Kinds, blank : BOOLEAN, ends : BOOLEAN, out : Outputs, msg : Nat, same : BOOLEAN]

TypeOK ==
    /\ notices \in BOOLEAN
    /\ sent \in Seq(Sent)
    /\ group \in {"none", "assistant", "operational"}
    /\ msgId \in Nat
    /\ lastMsg \in Nat

Init ==
    /\ notices \in BOOLEAN
    /\ sent = <<>>
    /\ group = "none"
    /\ msgId = 0
    /\ lastMsg = 0

\* The runtime emits one text of kind k. When cause is a Causes member, the
\* text is the one that ends the turn for that cause.
Emit(k, blank, cause) ==
    /\ Len(sent) < MaxSteps
    /\ blank => k \in Blankable
    /\ cause # NoCause => (k = KindFor(cause) /\ ~blank)
    /\ LET out == Send(notices, k, blank)
           g == GroupAfter(notices, k, group)
           id == IF g # group THEN msgId + 1 ELSE msgId
       IN /\ sent' = Append(sent, [kind |-> k, blank |-> blank, ends |-> (cause # NoCause),
                                   out |-> out, msg |-> id,
                                   same |-> (out.type = "message" /\ id = lastMsg)])
          /\ group' = g
          /\ msgId' = id
          /\ lastMsg' = IF out.type = "message" THEN id ELSE lastMsg
    /\ UNCHANGED notices

\* A new model attempt starts (TextEmission.assistant_started).
Start ==
    /\ Len(sent) < MaxSteps
    /\ group' = "none"
    /\ UNCHANGED <<notices, sent, msgId, lastMsg>>

Next == Start \/ \E k \in Kinds, b \in BOOLEAN, c \in Causes \cup {NoCause} : Emit(k, b, c)

Spec == Init /\ [][Next]_vars

----------------------------------------------------------------------------
(* Rules. *)

Idx == 1..Len(sent)

\* ACP v1: no notice to a client that did not advertise them.
NoticeNeedsCapability == \A i \in Idx : sent[i].out.type = "notice" => notices

\* A plain client sees every text as an agent message, as before.
PlainClientUnchanged == ~notices => \A i \in Idx : sent[i].out.type = "message"

\* The text that says why a turn failed is always delivered as a message.
FailureReportIsMessage ==
    \A i \in Idx : sent[i].kind \in FailureKinds => sent[i].out.type = "message"

\* No text that ends a turn is a notice, whatever the cause: a client may
\* ignore a notice, and the text is then the only reason the turn ended.
NoTurnEndingNotice ==
    \A i \in Idx : sent[i].ends => sent[i].out.type = "message"

\* The reply, what fx saves as the reply, and diffs stay messages, so live
\* output matches what session/load replays.
ConversationStaysMessages ==
    \A i \in Idx : sent[i].kind \in {"assistant", "saved_reply", "diff"} => sent[i].out.type = "message"

\* The bug: a notices client gets fx's other text as notices.
OperationalAsNotice ==
    notices => \A i \in Idx : (sent[i].kind \in NoticeKinds /\ ~sent[i].blank) => sent[i].out.type = "notice"

\* One notice per message: a blank fragment never becomes a notice.
OneNoticePerMessage == \A i \in Idx : sent[i].out.type = "notice" => ~sent[i].blank

NoticeSeverity ==
    \A i \in Idx : sent[i].out.type = "notice" => sent[i].out.severity = Severity(sent[i].kind)

\* Two assistant texts with fx's own text between them land in two messages.
AssistantSplit ==
    \A i, j \in Idx :
        (/\ i < j
         /\ sent[i].kind = "assistant" /\ sent[j].kind = "assistant"
         /\ \E m \in (i + 1)..(j - 1) : sent[m].kind \notin {"assistant", "context"})
        => sent[i].msg # sent[j].msg

ASSUME Mode \in Modes /\ MaxSteps \in Nat
=============================================================================
