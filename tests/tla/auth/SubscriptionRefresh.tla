------------------------- MODULE SubscriptionRefresh -------------------------
(***************************************************************************)
(* A Grok or Codex subscription login (src/core/auth/): how fx reads the   *)
(* saved expiry, and who holds the refresh token while a refresh reply is  *)
(* checked and saved.                                                      *)
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
    Providers,        \* {"codex", "grok"}: both run the same steps
    Expiries,         \* the saved expiries explored, within MinInt..MaxInt
    Bound,            \* the saved expiry ranges over -Bound..Bound-1, as an
                      \* i64 ranges over -2^63..2^63-1
    Skew,             \* the one-minute margin on that scale
    Now,              \* the clock on that scale, after the epoch
    ClearAtTake,      \* design: the rotated token leaves the reply when it is
                      \* taken. FALSE is fx before, which cleared it only after
                      \* the lifetime check.
    Saturating,       \* design: the margin is subtracted saturating. FALSE is
                      \* fx before, a checked subtraction.
    SignOutBadReply,  \* design: a refresh that fails deletes the saved login.
                      \* FALSE plants a bug.
    SaveRotated       \* design: a refresh saves the rotated refresh token.
                      \* FALSE plants a bug.

MinInt == -Bound
MaxInt == Bound - 1

ASSUME Skew > 0 /\ Bound > Skew /\ Expiries \subseteq MinInt..MaxInt /\ Now \in 0..MaxInt

AllExpiries == MinInt..MaxInt

Commands == {"status", "ask"}
Lifetimes == {"ok", "missing", "overflow"}
Replies == [rotated: BOOLEAN, lifetime: Lifetimes, account: {"same", "changed"}, save: {"ok", "fail"}]
NoReply == [rotated |-> FALSE, lifetime |-> "none", account |-> "none", save |-> "none"]
Buffers == {"rotated", "copy"}
Holders == {"reply", "local", "replacement", "session"}
Phases == {"deadline", "reply", "account", "take", "lifetime", "build", "save",
           "fail", "retire", "unwind", "release", "send", "done"}
Outcomes == {"none", "expired", "live", "answered", "signed_out", "account_changed",
             "save_failed", "abort", "crash"}

VARIABLES
    cmd,       \* the command fx runs
    provider,  \* whose login it is
    stored,    \* the saved expiry
    reply,     \* the issuer's refresh reply, or NoReply
    phase,     \* where fx is
    made,      \* the refresh-token buffers fx has allocated
    holders,   \* [Buffers -> SUBSET Holders]
    frees,     \* [Buffers -> Nat]: how many times each buffer was freed
    err,       \* the error refreshSession is returning
    file,      \* the saved login: "saved", "rotated" (the new token), or "deleted"
    outcome    \* how the command ended

vars == <<cmd, provider, stored, reply, phase, made, holders, frees, err, file, outcome>>

\* refreshDeadlineMs: @max(expires_at_ms - expiry_skew_ms, 0). The checked
\* subtraction of fx before panics below MinInt + Skew; the saturating one
\* reaches the same 0 as the clamp.
Overflows(e) == ~Saturating /\ e - Skew < MinInt
Deadline(e) == IF e - Skew < 0 THEN 0 ELSE e - Skew
Expired(e) == Deadline(e) <= Now

InitWith(c, p, e) ==
    /\ cmd = c
    /\ provider = p
    /\ stored = e
    /\ reply = NoReply
    /\ phase = "deadline"
    /\ made = {}
    /\ holders = [b \in Buffers |-> {}]
    /\ frees = [b \in Buffers |-> 0]
    /\ err = "none"
    /\ file = "saved"
    /\ outcome = "none"

\* The same state, entered as the next run starts (for the trace checker).
Begin(c, p, e) ==
    /\ cmd' = c
    /\ provider' = p
    /\ stored' = e
    /\ reply' = NoReply
    /\ phase' = "deadline"
    /\ made' = {}
    /\ holders' = [b \in Buffers |-> {}]
    /\ frees' = [b \in Buffers |-> 0]
    /\ err' = "none"
    /\ file' = "saved"
    /\ outcome' = "none"

Init == \E c \in Commands, p \in Providers, e \in Expiries : InitWith(c, p, e)

\* Session.expired (status) and takeAccess (ask) both compute the deadline.
CheckDeadline ==
    /\ phase = "deadline"
    /\ IF Overflows(stored)
       THEN phase' = "done" /\ outcome' = "abort"   \* panic: integer overflow
       ELSE IF cmd = "status"
            THEN phase' = "done" /\ outcome' = IF Expired(stored) THEN "expired" ELSE "live"
            ELSE phase' = (IF Expired(stored) THEN "reply" ELSE "send") /\ UNCHANGED outcome
    /\ UNCHANGED <<cmd, provider, stored, reply, made, holders, frees, err, file>>

\* requestRefreshToken returns the issuer's reply, which owns a rotated token.
Reply(r) ==
    /\ phase = "reply"
    /\ reply' = r
    /\ made' = IF r.rotated THEN {"rotated"} ELSE {}
    /\ holders' = [holders EXCEPT !["rotated"] = IF r.rotated THEN {"reply"} ELSE {}]
    /\ phase' = "account"
    /\ UNCHANGED <<cmd, provider, stored, frees, err, file, outcome>>

\* refreshReplacement asks xAI (Grok) or reads the token (Codex) for the
\* account before it takes the refresh token.
CheckAccount ==
    /\ phase = "account"
    /\ IF reply.account = "changed"
       THEN err' = "account_changed" /\ phase' = "fail"
       ELSE phase' = "take" /\ UNCHANGED err
    /\ UNCHANGED <<cmd, provider, stored, reply, made, holders, frees, file, outcome>>

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
    /\ UNCHANGED <<cmd, provider, stored, reply, frees, err, file, outcome>>

\* A missing expires_in fails for Grok, and for Codex when the access token
\* has no exp claim, as the driver's tokens do not. An expires_in whose
\* milliseconds, or their sum with now, overflow an i64 fails for both.
CheckLifetime ==
    /\ phase = "lifetime"
    /\ IF reply.lifetime = "ok"
       THEN phase' = "build" /\ UNCHANGED err
       ELSE err' = "bad_lifetime" /\ phase' = "fail"
    /\ UNCHANGED <<cmd, provider, stored, reply, made, holders, frees, file, outcome>>

\* The replacement takes the local's buffer. fx before also cleared the
\* reply's field here, at the end of refreshReplacement.
Build ==
    /\ phase = "build"
    /\ holders' = [b \in Buffers |->
                     IF "local" \in holders[b]
                     THEN (holders[b] \ {"local", "reply"}) \cup {"replacement"}
                     ELSE holders[b]]
    /\ phase' = "save"
    /\ UNCHANGED <<cmd, provider, stored, reply, made, frees, err, file, outcome>>

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
    /\ UNCHANGED <<cmd, provider, stored, reply, made, frees, outcome>>

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
    /\ UNCHANGED <<cmd, provider, stored, reply, made, err, file>>

\* retireRefreshSession deletes the saved login before refreshSession
\* returns the error.
Retire ==
    /\ phase = "retire"
    /\ file' = IF SignOutBadReply THEN "deleted" ELSE file
    /\ phase' = IF err = "save_failed" THEN "unwind" ELSE "release"
    /\ UNCHANGED <<cmd, provider, stored, reply, made, holders, frees, err, outcome>>

\* A failed save returns: the errdefer frees the replacement.
UnwindReplacement ==
    /\ phase = "unwind"
    /\ FreeBy("replacement", "release", outcome)
    /\ UNCHANGED <<cmd, provider, stored, reply, made, err, file>>

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
    /\ UNCHANGED <<cmd, provider, stored, reply, made, err, file>>

\* The prompt goes out and the provider answers it.
Send ==
    /\ phase = "send"
    /\ phase' = "done"
    /\ outcome' = "answered"
    /\ UNCHANGED <<cmd, provider, stored, reply, made, holders, frees, err, file>>

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

\* A refresh that fails deletes the saved login, so fx asks to sign in again.
BadReplySignsOut ==
    (phase = "done" /\ outcome \in {"signed_out", "account_changed", "save_failed"}) =>
        file = "deleted"

\* A refresh that rotated the token saves the new one.
RotatedTokenSaved ==
    (phase = "done" /\ outcome = "answered" /\ reply.rotated) => file = "rotated"
=============================================================================
