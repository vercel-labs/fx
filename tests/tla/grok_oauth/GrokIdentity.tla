---------------------------- MODULE GrokIdentity ----------------------------
(***************************************************************************)
(* Which account a Grok sign-in saves, and whether a refresh keeps it      *)
(* (src/core/auth/grok_oauth.zig: completeSignIn, fetchAccountId,          *)
(* refreshSession, refreshReplacement).                                    *)
(*                                                                         *)
(* The issuer follows what the reporters of #461 describe of xAI, which    *)
(* this repository cannot check without a Team account: a Team access      *)
(* token names the Team in its principal_type and principal_id claims,     *)
(* /oauth2/userinfo refuses a Team token, and a refresh that sends no      *)
(* principal fields gets a token for the person's own account. A personal  *)
(* token's own principal_id claim (u_claim) differs from its userinfo sub  *)
(* (u1) here, so a fx that names a personal account from the claim is      *)
(* caught.                                                                 *)
(*                                                                         *)
(* One run is one of these commands, for one kind of principal that the    *)
(* browser authorization picked:                                           *)
(*                                                                         *)
(*   login           fx login grok                                         *)
(*   login_refresh   fx login grok, then fx ask, which refreshes the login *)
(*                   after a 401 and resends the request                   *)
(*   refresh         fx ask on a saved login inside its one-minute margin  *)
(*   refresh_killed  the same, but the first fx is killed while the issuer *)
(*                   holds the refresh reply, and a second fx runs         *)
(*   fresh           fx ask on a saved login outside the margin            *)
(*                                                                         *)
(*   user            a JWT whose principal_type is User                    *)
(*   opaque          a token without principal claims: not a JWT, or a     *)
(*                   JWT without them                                      *)
(*   team            principal_type Team with a usable principal_id        *)
(*   team_bad_id     principal_type Team with a missing or unsafe id       *)
(*                                                                         *)
(* The constants choose fx's rules. The design is TeamClaim, RefreshFields *)
(* "team", ValidateTeamId, and not UserFromClaim; fx before the fix is     *)
(* neither TeamClaim nor any refresh fields.                               *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Cmds,
    Kinds,
    TeamClaim,       \* fetchAccountId reads a Team principal from the token
    RefreshFields,   \* "none", "team" (a Team's fields), or "always" (any principal's)
    ValidateTeamId,  \* a Team principal_id must be a valid account id
    UserFromClaim    \* a personal account is named from its claim, not userinfo

ASSUME Cmds \subseteq {"login", "login_refresh", "refresh", "refresh_killed", "fresh"}
ASSUME Kinds \subseteq {"user", "opaque", "team", "team_bad_id"}
ASSUME RefreshFields \in {"none", "team", "always"}
ASSUME {TeamClaim, ValidateTeamId, UserFromClaim} \subseteq BOOLEAN

Types == {"User", "Team", "none"}
Ids == {"u_claim", "t1", "bad", "none"}
Accounts == {"u1", "t1", "u_claim", "bad", "none"}
Absent == [type |-> "absent", id |-> "none"]
Tokens == [type : Types, id : Ids] \cup {Absent}

\* A seeded login of a Team whose token names no usable id is only refreshed.
RunOK(c, k) == ~(c \in {"refresh_killed", "fresh"} /\ k = "team_bad_id")

\* The access token the browser authorization returns.
Issued(k) ==
    CASE k = "user" -> [type |-> "User", id |-> "u_claim"]
      [] k = "opaque" -> [type |-> "none", id |-> "none"]
      [] k = "team" -> [type |-> "Team", id |-> "t1"]
      [] k = "team_bad_id" -> [type |-> "Team", id |-> "bad"]

\* The account each kind must be saved under.
Account(k) ==
    CASE k = "team" -> "t1"
      [] k = "team_bad_id" -> "none"
      [] OTHER -> "u1"

\* The account a seeded login is saved under. A team_bad_id one holds a
\* usable account id beside a token whose claims name none.
SeededAccount(k) == IF k = "team_bad_id" THEN "t1" ELSE Account(k)

\* The issuer. userinfo refuses a Team token.
UserinfoSub(t) == IF t.type = "Team" THEN "refused" ELSE "u1"

\* The issuer's refresh: Team fields keep that Team; no fields, or a User's,
\* give the person's own account.
Refreshed(t, f) ==
    IF f = "team" THEN [type |-> "Team", id |-> t.id]
    ELSE IF t.type = "none" THEN t
    ELSE [type |-> "User", id |-> "u_claim"]

\* fx: the principal fields refreshSession adds to the refresh form.
Fields(t) ==
    CASE RefreshFields = "none" -> "none"
      [] RefreshFields = "team" -> IF t.type = "Team" THEN "team" ELSE "none"
      [] RefreshFields = "always" ->
            IF t.type = "Team" THEN "team"
            ELSE IF t.type = "User" THEN "user" ELSE "none"

\* fx: how fetchAccountId names a token's account.
Identify(t) ==
    IF TeamClaim /\ t.type = "Team"
    THEN IF ValidateTeamId /\ t.id = "bad"
         THEN [via |-> "claim", ok |-> FALSE, acct |-> "none"]
         ELSE [via |-> "claim", ok |-> TRUE, acct |-> t.id]
    ELSE IF UserFromClaim /\ t.type = "User"
    THEN [via |-> "claim", ok |-> TRUE, acct |-> t.id]
    ELSE IF UserinfoSub(t) = "refused"
    THEN [via |-> "userinfo", ok |-> FALSE, acct |-> "none"]
    ELSE [via |-> "userinfo", ok |-> TRUE, acct |-> UserinfoSub(t)]

AskedBy(t, r) == IF r.via = "userinfo" THEN {t.type} ELSE {}

VARIABLES
    cmd, kind,
    phase,      \* "sign_in", "refresh", "use", "done"
    saved,      \* the account grok-auth.json holds, or "none"
    savedTok,   \* the access token it holds, or Absent
    signedAs,   \* the account fx login saved, or "none"
    login,      \* "not_run", "signed_in", "failed"
    asked,      \* the token types fx sent to userinfo
    named,      \* how fx named accounts: "claim", "userinfo"
    form,       \* the principal fields of the refresh: "no_refresh", "none", "team", "user"
    ask,        \* how fx ask ended: "not_run", "answered", "account_changed", "signed_out"
    afterKill   \* the saved login after the killed fx: "none" (no kill), "kept", "lost"

vars == <<cmd, kind, phase, saved, savedTok, signedAs, login, asked, named, form, ask, afterKill>>

Seeded(c) == c \in {"refresh", "refresh_killed", "fresh"}

InitWith(c, k) ==
    /\ cmd = c
    /\ kind = k
    /\ phase = CASE c \in {"login", "login_refresh"} -> "sign_in"
                 [] c = "fresh" -> "use"
                 [] OTHER -> "refresh"
    /\ saved = IF Seeded(c) THEN SeededAccount(k) ELSE "none"
    /\ savedTok = IF Seeded(c) THEN Issued(k) ELSE Absent
    /\ signedAs = "none"
    /\ login = "not_run"
    /\ asked = {}
    /\ named = {}
    /\ form = "no_refresh"
    /\ ask = "not_run"
    /\ afterKill = "none"

\* InitWith for the next state, for the trace spec.
Begin(c, k) ==
    /\ cmd' = c
    /\ kind' = k
    /\ phase' = CASE c \in {"login", "login_refresh"} -> "sign_in"
                  [] c = "fresh" -> "use"
                  [] OTHER -> "refresh"
    /\ saved' = IF Seeded(c) THEN SeededAccount(k) ELSE "none"
    /\ savedTok' = IF Seeded(c) THEN Issued(k) ELSE Absent
    /\ signedAs' = "none"
    /\ login' = "not_run"
    /\ asked' = {}
    /\ named' = {}
    /\ form' = "no_refresh"
    /\ ask' = "not_run"
    /\ afterKill' = "none"

Init == \E c \in Cmds, k \in Kinds : RunOK(c, k) /\ InitWith(c, k)

\* completeSignIn: name the account of the exchanged token, then save.
SignIn ==
    /\ phase = "sign_in"
    /\ LET t == Issued(kind)
           r == Identify(t)
       IN /\ asked' = asked \cup AskedBy(t, r)
          /\ named' = named \cup {r.via}
          /\ IF r.ok
             THEN /\ login' = "signed_in"
                  /\ saved' = r.acct
                  /\ savedTok' = t
                  /\ signedAs' = r.acct
                  /\ phase' = IF cmd = "login_refresh" THEN "refresh" ELSE "done"
             ELSE /\ login' = "failed"
                  /\ phase' = "done"
                  /\ UNCHANGED <<saved, savedTok, signedAs>>
    /\ UNCHANGED <<cmd, kind, form, ask, afterKill>>

\* The first fx dies while the issuer holds the refresh reply. refreshSession
\* saves only a checked replacement, so the saved login is as it was.
Kill ==
    /\ phase = "refresh"
    /\ cmd = "refresh_killed"
    /\ afterKill = "none"
    /\ afterKill' = IF saved = SeededAccount(kind) THEN "kept" ELSE "lost"
    /\ UNCHANGED <<cmd, kind, phase, saved, savedTok, signedAs, login, asked, named, form, ask>>

\* refreshSession and refreshReplacement: send the form, name the new token's
\* account, and keep it only when it is the saved one; otherwise the saved
\* login is retired. A saved Team token that names no usable id is retired
\* before anything is sent, since no refresh can name its Team.
Refresh ==
    /\ phase = "refresh"
    /\ cmd = "refresh_killed" => afterKill # "none"
    /\ IF TeamClaim /\ ValidateTeamId /\ savedTok.type = "Team" /\ savedTok.id = "bad"
       THEN /\ ask' = "signed_out"
            /\ saved' = "none"
            /\ savedTok' = Absent
            /\ UNCHANGED <<form, asked, named>>
       ELSE LET f == Fields(savedTok)
                t == Refreshed(savedTok, f)
                r == Identify(t)
            IN /\ form' = f
               /\ asked' = asked \cup AskedBy(t, r)
               /\ named' = named \cup {r.via}
               /\ IF r.ok /\ r.acct = saved
                  THEN /\ ask' = "answered"
                       /\ savedTok' = t
                       /\ UNCHANGED saved
                  ELSE /\ ask' = IF r.ok THEN "account_changed" ELSE "signed_out"
                       /\ saved' = "none"
                       /\ savedTok' = Absent
    /\ phase' = "done"
    /\ UNCHANGED <<cmd, kind, signedAs, login, afterKill>>

\* A saved login outside the margin is used as it is.
Use ==
    /\ phase = "use"
    /\ ask' = "answered"
    /\ phase' = "done"
    /\ UNCHANGED <<cmd, kind, saved, savedTok, signedAs, login, asked, named, form, afterKill>>

Next == SignIn \/ Kill \/ Refresh \/ Use

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
Done == phase = "done"
Personal == kind \in {"user", "opaque"}

TypeOK ==
    /\ cmd \in Cmds
    /\ kind \in Kinds
    /\ phase \in {"sign_in", "refresh", "use", "done"}
    /\ saved \in Accounts
    /\ savedTok \in Tokens
    /\ signedAs \in Accounts
    /\ login \in {"not_run", "signed_in", "failed"}
    /\ asked \subseteq Types
    /\ named \subseteq {"claim", "userinfo"}
    /\ form \in {"no_refresh", "none", "team", "user"}
    /\ ask \in {"not_run", "answered", "account_changed", "signed_out"}
    /\ afterKill \in {"none", "kept", "lost"}

\* A personal account keeps the userinfo path.
PersonalUsesUserinfo == Personal => "claim" \notin named

\* A sign-in of a usable principal completes (#461: a Team one ended in
\* GrokUserInfoRequestFailed).
UsableSignInCompletes ==
    (Done /\ cmd \in {"login", "login_refresh"} /\ kind # "team_bad_id") => login = "signed_in"

\* Nothing unsafe is saved as an account: it goes into HTTP headers.
SavedAccountValid == saved # "bad" /\ signedAs # "bad"

\* A sign-in saves the principal the authorization picked: the Team's
\* principal_id, or the person's userinfo sub.
SignInNamesPrincipal == login = "signed_in" => signedAs = Account(kind)

\* A Team principal with no usable id is refused, never saved.
BadTeamIdRefused ==
    (Done /\ cmd \in {"login", "login_refresh"} /\ kind = "team_bad_id") => login = "failed" /\ saved = "none"

\* fx never sends a Team token to userinfo, which refuses it.
NoTeamTokenToUserinfo == "Team" \notin asked

\* A refresh keeps the account it refreshed: fx ask is answered under the
\* same account, a Team's included.
RefreshKeepsAccount ==
    (Done /\ form # "no_refresh" /\ kind # "team_bad_id") =>
        /\ ask = "answered"
        /\ saved = Account(kind)

\* A personal login's refresh sends no principal fields.
PersonalRefreshOmitsFields == Personal => form \in {"no_refresh", "none"}

\* A killed refresh leaves the saved login as it was.
KillKeepsLogin == afterKill # "lost"

\* A saved Team login whose token names no usable id is retired without a
\* refresh request.
UnusableSavedTeamRetired ==
    (Done /\ Seeded(cmd) /\ kind = "team_bad_id") => saved = "none" /\ form = "no_refresh"
=============================================================================
