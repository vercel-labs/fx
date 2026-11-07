----------------------------- MODULE SignInTeams -----------------------------
(***************************************************************************)
(* What a Vercel sign-in does with the team list it reads after the token  *)
(* arrives (src/core/auth/login_flow.zig): `fx login` in a shell           *)
(* (runLogin), and the in-app /login (SignInRuntime.completeToken with     *)
(* completeSignIn, then collectSignInFacts in                              *)
(* src/core/app/app_auth_runtime.zig).                                     *)
(*                                                                         *)
(* /v2/teams answers with one of:                                          *)
(*   status "error"    a non-2xx status, a transport failure, or a body    *)
(*                     past the size limit                                 *)
(*   status "garbage"  a 2xx body that is not a team list                  *)
(*   status "ok"       a list of entries, each one of:                     *)
(*     "plain"       a readable team with a printable name                 *)
(*     "ctl_name"    a readable team whose name mixes control characters   *)
(*                   with text, such as "Example\x1b[2J Team"              *)
(*     "ctl_only"    a readable team whose name has nothing printable      *)
(*     "ctl_slug"    a team whose slug holds a control character           *)
(*     "unreadable"  not an object, or no string id or slug                *)
(*                                                                         *)
(* A team is usable when its id and slug can be used and shown: "plain",   *)
(* "ctl_name", and "ctl_only" (whose name falls back to the slug).         *)
(*                                                                         *)
(* saved is what the session store holds: "none", "teamed" (the session    *)
(* from before this sign-in), "new_teamless" (the new token with no team), *)
(* or "new_teamed". prior is what it held at the start. The in-app sign-in *)
(* saves the new session before its team picker opens, and the picker's    *)
(* choice adds the team; `fx login` picks the team first and saves once.   *)
(*                                                                         *)
(* Rule picks the code: "design" is the fix, "today" is fx before it, and  *)
(* each "mut_*" plants one defect; check.sh names the rule that catches    *)
(* it. SignInTeamsTrace.tla replays runs of the built fx against this      *)
(* model; tests/tla/drivers/auth/driver.ts makes them.                     *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Surfaces, Priors, MaxEntries, Rule

Entries == {"plain", "ctl_name", "ctl_only", "ctl_slug", "unreadable"}
Lists == UNION {[1..n -> Entries] : n \in 0..MaxEntries}
Responses ==
    {[status |-> s, entries |-> <<>>] : s \in {"error", "garbage"}}
        \cup {[status |-> "ok", entries |-> l] : l \in Lists}
NoResponse == [status |-> "none", entries |-> <<>>]

Outcomes == {"none", "signed_in", "picking", "picker_closed", "teams_unavailable",
             "no_teams", "gateway_missing", "notice_saved", "crashed", "killed", "cancelled"}
Saves == {"none", "teamed", "new_teamless", "new_teamed"}

VARIABLES
    surface,  \* "cli" (fx login) or "app" (the in-app /login)
    prior,    \* what the session store held before the sign-in
    phase,    \* "waiting" for the token, "fetching" the teams, "picking", "done"
    resp,     \* what /v2/teams answered
    saved,    \* what the session store holds
    outcome,  \* what the person was told, or how fx ended
    offered,  \* how many teams the picker offered
    rawOut,   \* fx wrote a team's control characters to the terminal
    alive     \* the fx process is still running

vars == <<surface, prior, phase, resp, saved, outcome, offered, rawOut, alive>>

-----------------------------------------------------------------------------
(* What the response is, whatever the code makes of it. *)

Usable(e) == e \in {"plain", "ctl_name", "ctl_only"}
Count(s, P(_)) == Cardinality({i \in DOMAIN s : P(s[i])})
UsableCount(r) == Count(r.entries, Usable)

Truth(r) ==
    IF r.status # "ok" THEN "unavailable"
    ELSE IF Len(r.entries) = 0 THEN "empty"
    ELSE IF UsableCount(r) = 0 THEN "unavailable"
    ELSE "teams"

(* What the code makes of it under Rule. *)

\* parseTeams keeps an entry.
Keeps(e) ==
    CASE Rule \in {"today", "mut_slug"} -> e # "unreadable"
      [] Rule = "mut_strict" -> e = "plain"
      [] OTHER -> Usable(e)

\* A kept entry's name still holds its control characters. The driver's
\* "ctl_name" names carry a CSI sequence (ESC [2J), which moves the cursor
\* out of the in-app picker's band; its "ctl_only" names hold BEL, CR, LF,
\* and a lone ESC, which only fx login writes out raw.
RawName(e) == Rule \in {"today", "mut_name"} /\ e \in {"ctl_name", "ctl_only"}
BreaksBand(e) == RawName(e) /\ e = "ctl_name"
\* A kept entry's slug holds a CSI sequence: fx login lists it, and the
\* in-app notice "Changed Vercel team to <name> (<slug>)" draws it.
RawSlug(e) == e = "ctl_slug"

Kept(r) == SelectSeq(r.entries, Keeps)

\* What the sign-in gets from fetchTeams and parseTeams.
Result(r) ==
    IF r.status # "ok"
        THEN IF Rule \in {"today", "mut_swallow"} THEN "empty" ELSE "unavailable"
    ELSE IF Len(r.entries) = 0 THEN "empty"
    ELSE IF Len(Kept(r)) = 0
        THEN IF Rule \in {"today", "mut_unreadable"} THEN "empty" ELSE "unavailable"
    ELSE "teams"

-----------------------------------------------------------------------------

InitWith(s, p) ==
    /\ surface = s
    /\ prior = p
    /\ phase = "waiting"
    /\ resp = NoResponse
    /\ saved = p
    /\ outcome = "none"
    /\ offered = 0
    /\ rawOut = FALSE
    /\ alive = TRUE

Init == \E s \in Surfaces, p \in Priors : InitWith(s, p)

\* A fresh sign-in, for trace validation of several runs in a row.
Reset(s, p) ==
    /\ surface' = s
    /\ prior' = p
    /\ phase' = "waiting"
    /\ resp' = NoResponse
    /\ saved' = p
    /\ outcome' = "none"
    /\ offered' = 0
    /\ rawOut' = FALSE
    /\ alive' = TRUE

\* The issuer grants the token; fx asks for the teams.
Token ==
    /\ phase = "waiting"
    /\ phase' = "fetching"
    /\ UNCHANGED <<surface, prior, resp, saved, outcome, offered, rawOut, alive>>

\* The sign-in ends without a team and says why.
Fail(o) ==
    /\ phase' = "done"
    /\ outcome' = o
    /\ saved' = IF Rule = "mut_save" THEN "new_teamless" ELSE saved
    /\ UNCHANGED <<offered, rawOut, alive>>

\* fx before the change: an empty list saved the session with no team.
SaveTeamless ==
    /\ phase' = "done"
    /\ saved' = "new_teamless"
    /\ outcome' = IF surface = "cli" THEN "gateway_missing" ELSE "notice_saved"
    /\ UNCHANGED <<offered, rawOut, alive>>

\* fx login lists the teams when there are two or more, takes the default
\* (the first), and saves the session with it.
CliTeams(k) ==
    /\ offered' = Len(k)
    /\ rawOut' = (Len(k) >= 2 /\ \E i \in DOMAIN k : RawName(k[i]) \/ RawSlug(k[i]))
    /\ saved' = "new_teamed"
    /\ outcome' = "signed_in"
    /\ phase' = "done"
    /\ UNCHANGED alive

\* The in-app sign-in saves the session, then draws every team's name in the
\* picker; a name that moves the cursor ends fx (ansi band overflow).
AppTeams(k) ==
    /\ offered' = Len(k)
    /\ saved' = "new_teamless"
    /\ UNCHANGED rawOut
    /\ IF \E i \in DOMAIN k : BreaksBand(k[i])
         THEN /\ alive' = FALSE
              /\ outcome' = "crashed"
              /\ phase' = "done"
         ELSE /\ UNCHANGED alive
              /\ outcome' = "picking"
              /\ phase' = "picking"

Answer(r) ==
    /\ phase = "fetching"
    /\ resp' = r
    /\ UNCHANGED <<surface, prior>>
    /\ CASE Result(r) = "unavailable" -> Fail("teams_unavailable")
         [] Result(r) = "empty" -> IF Rule = "today" THEN SaveTeamless ELSE Fail("no_teams")
         [] Result(r) = "teams" -> IF surface = "cli" THEN CliTeams(Kept(r)) ELSE AppTeams(Kept(r))

\* The person takes the picker's first team, the default. fx saves it, then
\* says so with the team's name and slug.
Pick ==
    /\ phase = "picking"
    /\ phase' = "done"
    /\ saved' = "new_teamed"
    /\ IF RawSlug(Kept(resp)[1])
         THEN /\ alive' = FALSE
              /\ outcome' = "crashed"
         ELSE /\ UNCHANGED alive
              /\ outcome' = "signed_in"
    /\ UNCHANGED <<surface, prior, resp, offered, rawOut>>

\* The person closes the in-app picker; the new session keeps no team.
ClosePicker ==
    /\ phase = "picking"
    /\ phase' = "done"
    /\ outcome' = "picker_closed"
    /\ UNCHANGED <<surface, prior, resp, saved, offered, rawOut, alive>>

\* The in-app sign-in is cancelled before it saves anything.
Cancel ==
    /\ surface = "app"
    /\ phase \in {"waiting", "fetching"}
    /\ phase' = "done"
    /\ outcome' = "cancelled"
    /\ UNCHANGED <<surface, prior, resp, saved, offered, rawOut, alive>>

\* fx is killed at any point; a kill saves nothing.
Kill ==
    /\ phase # "done"
    /\ phase' = "done"
    /\ alive' = FALSE
    /\ outcome' = "killed"
    /\ UNCHANGED <<surface, prior, resp, saved, offered, rawOut>>

Ended == phase = "done" /\ UNCHANGED vars

Next ==
    \/ Token
    \/ \E r \in Responses : Answer(r)
    \/ Pick
    \/ ClosePicker
    \/ Cancel
    \/ Kill
    \/ Ended

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------

TypeOK ==
    /\ surface \in {"cli", "app"}
    /\ prior \in {"none", "teamed"}
    /\ phase \in {"waiting", "fetching", "picking", "done"}
    /\ resp \in Responses \cup {NoResponse}
    /\ saved \in Saves
    /\ outcome \in Outcomes
    /\ offered \in 0..MaxEntries
    /\ rawOut \in BOOLEAN
    /\ alive \in BOOLEAN

Answered == resp # NoResponse

\* A team name never ends fx (I1579).
NoCrash == outcome # "crashed"

\* fx login never writes a team's control characters to the terminal (I1579).
NoRawControls == ~rawOut

\* A failed, unreadable, or empty team list leaves the session store as it
\* was before the sign-in (I476).
KeepsPriorSession == Answered /\ Truth(resp) \in {"unavailable", "empty"} => saved = prior

\* The person is told what happened: a list that failed or could not be read
\* is not an account with no teams, and neither is a successful sign-in (I476).
TellsTheTruth ==
    (Answered /\ phase = "done" /\ outcome \notin {"killed", "cancelled"}) =>
        CASE Truth(resp) = "unavailable" -> outcome = "teams_unavailable"
          [] Truth(resp) = "empty" -> outcome = "no_teams"
          [] OTHER -> outcome \notin {"teams_unavailable", "no_teams", "gateway_missing", "notice_saved"}

\* Every usable team is offered, control characters in its name or not.
OffersEveryTeam ==
    outcome \in {"signed_in", "picking", "picker_closed"} => offered = UsableCount(resp)
=============================================================================
