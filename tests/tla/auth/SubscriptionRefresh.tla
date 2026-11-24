------------------------- MODULE SubscriptionRefresh -------------------------
(***************************************************************************)
(* A Grok or Codex subscription login (src/core/auth/): how fx reads the   *)
(* saved expiry, and who holds the refresh token while a refresh reply is  *)
(* checked and saved. An MCP login (src/mcp/auth/client.zig) is the third  *)
(* provider: how fx reads its saved expiry and skew before a request.      *)
(*                                                                         *)
(* `fx status` reads the saved login without refreshing it                 *)
(* (loadStoredGrokCredential and loadStoredChatGptCredential in            *)
(* credentials.zig). `fx ask` refreshes a login that reads as expired      *)
(* (refreshSession in grok_oauth.zig and chatgpt_oauth.zig), then sends    *)
(* the prompt.                                                             *)
(*                                                                         *)
(* The saved expiry is whatever i64 the auth file holds. TLC's integers    *)
(* are 32-bit, so the model uses MinInt..MaxInt with a margin of Skew and  *)
(* a clock at Now. tests/tla/drivers/auth/driver.ts maps each real value   *)
(* it saves onto this range in order, keeping the margin's boundaries.     *)
(*                                                                         *)
(* An MCP login saves its own margin, skew_ms, beside the expiry: any i64  *)
(* too. Before each request beforeSend asks whether the clock plus that    *)
(* skew has reached the expiry, and the request then waits for a refresh   *)
(* (due) or goes out with the saved token (sent). The sum is saturating:   *)
(* it never overflows, a skew at MaxInt reaches every expiry, and an       *)
(* expiry at MinInt is always passed. A number beyond i64 does not parse   *)
(* and is no expiry at all, a case the model leaves out.                   *)
(*                                                                         *)
(* A refresh reply holds a new access token, perhaps a rotated refresh     *)
(* token, and a lifetime. refreshReplacement checks the account, takes the *)
(* refresh token (the rotated one, or a copy of the saved one) under an    *)
(* errdefer, checks the lifetime, and builds the replacement session.      *)
(* refreshSession saves it, or deletes the saved login when anything       *)
(* fails. Each refresh-token buffer records its holders: the reply, the    *)
(* errdefer's local, the replacement, and the saved session. A holder      *)
(* frees what it holds when its scope ends, and a second free of the same  *)
(* buffer crashes fx.                                                      *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    Providers,        \* {"codex", "grok", "mcp"}: the first two run the same steps
    Expiries,         \* the saved expiries explored, within MinInt..MaxInt
    Bound,            \* the saved expiry ranges over -Bound..Bound-1, as an
                      \* i64 ranges over -2^63..2^63-1
    Skew,             \* the one-minute margin on that scale
    Margins,          \* the skews an MCP login saves, within MinInt..MaxInt
    Now,              \* the clock on that scale, after the epoch
    ClearAtTake,      \* design: the rotated token leaves the reply when it is
                      \* taken. FALSE is fx before, which cleared it only after
                      \* the lifetime check.
    Saturating,       \* design: the margin is subtracted saturating. FALSE is
                      \* fx before, a checked subtraction.
    SignOutBadReply,  \* design: a refresh that fails deletes the saved login.
                      \* FALSE plants a bug.
    SaveRotated,      \* design: a refresh saves the rotated refresh token.
                      \* FALSE plants a bug.
    SendAdd           \* how an MCP request adds the saved skew to the clock:
                      \* "saturate" is the design. "plain" is fx before, whose
                      \* checked add aborts on overflow. "wrap" plants a bug.

MinInt == -Bound
MaxInt == Bound - 1

ASSUME Skew > 0 /\ Bound > Skew /\ Expiries \subseteq MinInt..MaxInt /\ Now \in 0..MaxInt
ASSUME Margins \subseteq MinInt..MaxInt
ASSUME SendAdd \in {"saturate", "plain", "wrap"}

AllExpiries == MinInt..MaxInt
AllMargins == MinInt..MaxInt

Commands == {"status", "ask", "send"}
Lifetimes == {"ok", "missing", "overflow"}
Replies == [rotated: BOOLEAN, lifetime: Lifetimes, account: {"same", "changed"}, save: {"ok", "fail"}]
NoReply == [rotated |-> FALSE, lifetime |-> "none", account |-> "none", save |-> "none"]
Buffers == {"rotated", "copy"}
Holders == {"reply", "local", "replacement", "session"}
Phases == {"deadline", "reply", "account", "take", "lifetime", "build", "save",
           "fail", "retire", "unwind", "release", "send", "done"}
Outcomes == {"none", "expired", "live", "due", "sent", "answered", "signed_out",
             "account_changed", "save_failed", "abort", "crash"}

VARIABLES
    cmd,       \* the command fx runs
    provider,  \* whose login it is
    stored,    \* the saved expiry
    margin,    \* the saved skew: Skew for a subscription login, skew_ms for MCP
    reply,     \* the issuer's refresh reply, or NoReply
    phase,     \* where fx is
    made,      \* the refresh-token buffers fx has allocated
    holders,   \* [Buffers -> SUBSET Holders]
    frees,     \* [Buffers -> Nat]: how many times each buffer was freed
    err,       \* the error refreshSession is returning
    file,      \* the saved login: "saved", "rotated" (the new token), or "deleted"
    outcome    \* how the command ended

vars == <<cmd, provider, stored, margin, reply, phase, made, holders, frees, err, file, outcome>>

\* refreshDeadlineMs: @max(expires_at_ms - expiry_skew_ms, 0). The checked
\* subtraction of fx before panics below MinInt + Skew; the saturating one
\* reaches the same 0 as the clamp.
Overflows(e) == ~Saturating /\ e - Skew < MinInt
Deadline(e) == IF e - Skew < 0 THEN 0 ELSE e - Skew
Expired(e) == Deadline(e) <= Now

\* beforeSend in src/mcp/auth/client.zig: `a.now() + a.skew_ms >= at`. fx before
\* added with a checked `+`, which panics when the sum leaves i64. The design
\* adds with `+|`, which stops at the limit. "wrap" is `+%`, which comes back
\* round from the other end.
Sum == Now + margin
OutOfRange(x) == x > MaxInt \/ x < MinInt
Clamp(x) == IF x > MaxInt THEN MaxInt ELSE IF x < MinInt THEN MinInt ELSE x
Wrap(x) == IF x > MaxInt THEN x - 2 * Bound ELSE IF x < MinInt THEN x + 2 * Bound ELSE x
SendAborts == SendAdd = "plain" /\ OutOfRange(Sum)
SendDue ==
    CASE SendAdd = "saturate" -> Clamp(Sum) >= stored
      [] SendAdd = "wrap" -> Wrap(Sum) >= stored
      [] SendAdd = "plain" -> Sum >= stored

\* The saved skew of a login: the one-minute margin, or MCP's own.
CommandsOf(p) == IF p = "mcp" THEN {"send"} ELSE {"status", "ask"}
MarginsOf(p) == IF p = "mcp" THEN Margins ELSE {Skew}

InitWith(c, p, e, m) ==
    /\ cmd = c
    /\ provider = p
    /\ stored = e
    /\ margin = m
    /\ reply = NoReply
    /\ phase = "deadline"
    /\ made = {}
    /\ holders = [b \in Buffers |-> {}]
    /\ frees = [b \in Buffers |-> 0]
    /\ err = "none"
    /\ file = "saved"
    /\ outcome = "none"

\* The same state, entered as the next run starts (for the trace checker).
Begin(c, p, e, m) ==
    /\ cmd' = c
    /\ provider' = p
    /\ stored' = e
    /\ margin' = m
    /\ reply' = NoReply
    /\ phase' = "deadline"
    /\ made' = {}
    /\ holders' = [b \in Buffers |-> {}]
    /\ frees' = [b \in Buffers |-> 0]
    /\ err' = "none"
    /\ file' = "saved"
    /\ outcome' = "none"

Init ==
    \E p \in Providers :
        \E c \in CommandsOf(p), e \in Expiries, m \in MarginsOf(p) : InitWith(c, p, e, m)

\* Session.expired (status) and takeAccess (ask) both compute the deadline. An
\* MCP request (send) asks beforeSend: a login that is due is refreshed and
\* saved before the request goes, and one that is not goes out as saved.
CheckDeadline ==
    /\ phase = "deadline"
    /\ IF provider = "mcp"
       THEN IF SendAborts
            THEN phase' = "done" /\ outcome' = "abort" /\ file' = file   \* panic: integer overflow
            ELSE /\ phase' = "done"
                 /\ outcome' = IF SendDue THEN "due" ELSE "sent"
                 /\ file' = IF SendDue THEN "rotated" ELSE "saved"
       ELSE /\ file' = file
            /\ IF Overflows(stored)
               THEN phase' = "done" /\ outcome' = "abort"   \* panic: integer overflow
               ELSE IF cmd = "status"
                    THEN phase' = "done" /\ outcome' = IF Expired(stored) THEN "expired" ELSE "live"
                    ELSE phase' = (IF Expired(stored) THEN "reply" ELSE "send") /\ UNCHANGED outcome
    /\ UNCHANGED <<cmd, provider, stored, margin, reply, made, holders, frees, err>>

\* requestRefreshToken returns the issuer's reply, which owns a rotated token.
Reply(r) ==
    /\ phase = "reply"
    /\ reply' = r
    /\ made' = IF r.rotated THEN {"rotated"} ELSE {}
    /\ holders' = [holders EXCEPT !["rotated"] = IF r.rotated THEN {"reply"} ELSE {}]
    /\ phase' = "account"
    /\ UNCHANGED <<cmd, provider, stored, margin, frees, err, file, outcome>>

\* refreshReplacement asks xAI (Grok) or reads the token (Codex) for the
\* account before it takes the refresh token.
CheckAccount ==
    /\ phase = "account"
    /\ IF reply.account = "changed"
       THEN err' = "account_changed" /\ phase' = "fail"
       ELSE phase' = "take" /\ UNCHANGED err
    /\ UNCHANGED <<cmd, provider, stored, margin, reply, made, holders, frees, file, outcome>>

\* The rotated token, or a copy of the saved one, under an errdefer.
Take ==
    /\ phase = "take"
    /\ IF reply.rotated
       THEN /\ holders' = [holders EXCEPT !["rotated"] =
                              IF ClearAtTake THEN {"local"} ELSE {"reply", "local"}]
            /\ UNCHANGED made
       ELSE /\ holders' = [holders EXCEPT !["copy"] = {"local"}]
            /\ made' = made \cup {"copy"}
    /\ phase' = "lifetime"
    /\ UNCHANGED <<cmd, provider, stored, margin, reply, frees, err, file, outcome>>

\* A missing expires_in fails for Grok, and for Codex when the access token
\* has no exp claim, as the driver's tokens do not. An expires_in whose
\* milliseconds, or their sum with now, overflow an i64 fails for both.
CheckLifetime ==
    /\ phase = "lifetime"
    /\ IF reply.lifetime = "ok"
       THEN phase' = "build" /\ UNCHANGED err
       ELSE err' = "bad_lifetime" /\ phase' = "fail"
    /\ UNCHANGED <<cmd, provider, stored, margin, reply, made, holders, frees, file, outcome>>

\* The replacement takes the local's buffer. fx before also cleared the
\* reply's field here, at the end of refreshReplacement.
Build ==
    /\ phase = "build"
    /\ holders' = [b \in Buffers |->
                     IF "local" \in holders[b]
                     THEN (holders[b] \ {"local", "reply"}) \cup {"replacement"}
                     ELSE holders[b]]
    /\ phase' = "save"
    /\ UNCHANGED <<cmd, provider, stored, margin, reply, made, frees, err, file, outcome>>

\* mutation.save writes the replacement. On success the session takes it.
Save ==
    /\ phase = "save"
    /\ IF reply.save = "ok"
       THEN /\ holders' = [b \in Buffers |->
                              IF "replacement" \in holders[b]
                              THEN (holders[b] \ {"replacement"}) \cup {"session"}
                              ELSE holders[b]]
            /\ file' = IF reply.rotated /\ SaveRotated THEN "rotated" ELSE "saved"
            /\ phase' = "release"
            /\ UNCHANGED err
       ELSE /\ err' = "save_failed"
            /\ phase' = "retire"
            /\ UNCHANGED <<holders, file>>
    /\ UNCHANGED <<cmd, provider, stored, margin, reply, made, frees, outcome>>

\* Every buffer `h` holds is freed once more, and `h` lets go of it. A free
\* of a buffer that was freed already crashes fx.
FreeBy(h, next, done) ==
    LET held == {b \in Buffers : h \in holders[b]}
    IN  /\ frees' = [b \in Buffers |-> IF b \in held THEN frees[b] + 1 ELSE frees[b]]
        /\ holders' = [b \in Buffers |-> holders[b] \ {h}]
        /\ IF \E b \in held : frees[b] >= 1
           THEN phase' = "done" /\ outcome' = "crash"
           ELSE phase' = next /\ outcome' = done

\* refreshReplacement returns an error: its errdefer frees the local's buffer.
UnwindLocal ==
    /\ phase = "fail"
    /\ FreeBy("local", "retire", outcome)
    /\ UNCHANGED <<cmd, provider, stored, margin, reply, made, err, file>>

\* retireRefreshSession deletes the saved login before refreshSession
\* returns the error.
Retire ==
    /\ phase = "retire"
    /\ file' = IF SignOutBadReply THEN "deleted" ELSE file
    /\ phase' = IF err = "save_failed" THEN "unwind" ELSE "release"
    /\ UNCHANGED <<cmd, provider, stored, margin, reply, made, holders, frees, err, outcome>>

\* A failed save returns: the errdefer frees the replacement.
UnwindReplacement ==
    /\ phase = "unwind"
    /\ FreeBy("replacement", "release", outcome)
    /\ UNCHANGED <<cmd, provider, stored, margin, reply, made, err, file>>

ErrOutcome(e) ==
    CASE e = "account_changed" -> "account_changed"
      [] e = "bad_lifetime" -> "signed_out"
      [] e = "save_failed" -> "save_failed"

\* refreshSession's `defer token.deinit` frees what the reply still holds.
ReleaseReply ==
    /\ phase = "release"
    /\ IF err = "none"
       THEN FreeBy("reply", "send", outcome)
       ELSE FreeBy("reply", "done", ErrOutcome(err))
    /\ UNCHANGED <<cmd, provider, stored, margin, reply, made, err, file>>

\* The prompt goes out and the provider answers it.
Send ==
    /\ phase = "send"
    /\ phase' = "done"
    /\ outcome' = "answered"
    /\ UNCHANGED <<cmd, provider, stored, margin, reply, made, holders, frees, err, file>>

NextWith(R) ==
    \/ CheckDeadline
    \/ \E r \in R : Reply(r)
    \/ CheckAccount
    \/ Take
    \/ CheckLifetime
    \/ Build
    \/ Save
    \/ UnwindLocal
    \/ Retire
    \/ UnwindReplacement
    \/ ReleaseReply
    \/ Send

Next == NextWith(Replies)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
TypeOK ==
    /\ cmd \in Commands
    /\ provider \in Providers
    /\ stored \in MinInt..MaxInt
    /\ margin \in MinInt..MaxInt
    /\ reply \in Replies \cup {NoReply}
    /\ phase \in Phases
    /\ made \subseteq Buffers
    /\ holders \in [Buffers -> SUBSET Holders]
    /\ frees \in [Buffers -> 0..2]
    /\ err \in {"none", "account_changed", "bad_lifetime", "save_failed"}
    /\ file \in {"saved", "rotated", "deleted"}
    /\ outcome \in Outcomes

\* No refresh-token buffer is freed twice.
NoDoubleFree == \A b \in Buffers : frees[b] <= 1

\* Each refresh-token buffer has at most one holder at any time.
OneHolder == \A b \in Buffers : Cardinality(holders[b]) <= 1

\* Reading the saved expiry never aborts fx.
NoAbort == outcome # "abort"

\* When fx finishes normally, every buffer it allocated was freed once or is
\* held by the saved session.
NoLeak ==
    (phase = "done" /\ outcome \notin {"crash", "abort"}) =>
        \A b \in made : \/ frees[b] = 1 /\ holders[b] = {}
                        \/ frees[b] = 0 /\ holders[b] = {"session"}

\* `fx status` reads an expiry in the past as expired, and one more than the
\* margin ahead as live, whatever the saved integer.
StatusReadsExpiry ==
    (phase = "done" /\ cmd = "status" /\ outcome \in {"expired", "live"}) =>
        /\ stored <= Now => outcome = "expired"
        /\ stored - Skew > Now => outcome = "live"

\* An MCP request never aborts, and reads the saved expiry and skew at any
\* integer: a skew at the largest reaches every expiry, an expiry at the
\* smallest is always passed, and with a skew of zero or more an expiry in the
\* past is due and one more than the skew ahead is not. A negative skew is no
\* window before the expiry, so the sum alone decides it.
SendReadsExpiry ==
    (phase = "done" /\ cmd = "send" /\ outcome \in {"due", "sent"}) =>
        /\ margin = MaxInt => outcome = "due"
        /\ stored = MinInt => outcome = "due"
        /\ (margin >= 0 /\ stored <= Now) => outcome = "due"
        /\ (margin >= 0 /\ stored - margin > Now) => outcome = "sent"

\* A refresh that fails deletes the saved login, so fx asks to sign in again.
BadReplySignsOut ==
    (phase = "done" /\ outcome \in {"signed_out", "account_changed", "save_failed"}) =>
        file = "deleted"

\* A refresh that rotated the token saves the new one.
RotatedTokenSaved ==
    (phase = "done" /\ outcome = "answered" /\ reply.rotated) => file = "rotated"
=============================================================================
