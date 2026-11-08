----------------------------- MODULE SignInTeams -----------------------------
(***************************************************************************)
(* What a Vercel sign-in does with the team list it reads after the token  *)
(* arrives (src/core/auth/login_flow.zig): `fx login` in a shell           *)
(* (runLogin), the in-app /login (SignInRuntime.completeToken with         *)
(* completeSignIn, then collectSignInFacts in                              *)
(* src/core/app/app_auth_runtime.zig), and the team column of the in-app   *)
(* /login and /provider picker, which lists the teams with a saved         *)
(* sign-in and asks for no new token (finishTeamsForProviderPicker), and   *)
(* `fx teams`, which lists them the same way in a shell and switches the   *)
(* saved sign-in to one (runTeams, and the catch in src/core/cli/          *)
(* cli_surface.zig).                                                       *)
(*                                                                         *)
(* /v2/teams answers with one of:                                          *)
(*   status "error"    a non-2xx status, a transport failure, or a body    *)
(*                     past the size limit                                 *)
(*   status "garbage"  a 2xx body that is not a team list. The picker and  *)
(*                     `fx teams` read a body that is not even JSON as a   *)
(*                     credential or switch failure, as they did before    *)
(*                     this change; the driver sends them only garbage     *)
(*                     that parses as JSON.                                *)
(*   status "ok"       a list of entries, each one of:                     *)
(*     "plain"       a readable team with a printable name                 *)
(*     "ctl_name"    a readable team whose name mixes control characters   *)
(*                   with text, such as "Example\x1b[2J Team"              *)
(*     "ctl_only"    a readable team whose name has nothing printable      *)
(*     "ctl_slug"    a team whose slug holds a control character           *)
(*     "bad_id"      a team whose id the gateway rejects, such as          *)
(*                   "bad id" or "team/slash" (types.validGatewayTeam)     *)
(*     "unreadable"  not an object, or no string id or slug                *)
(*                                                                         *)
(* A team is usable when its id and slug can be used and shown: "plain",   *)
(* "ctl_name", and "ctl_only" (whose name falls back to the slug).         *)
(*                                                                         *)
(* saved is what the session store holds: "none", "teamed" (the session    *)
(* from before this sign-in), "new_teamless" (the new token with no team), *)
(* "new_teamed", or "reteamed" (the saved session, with the team the       *)
(* picker or `fx teams` chose). prior is what it held at the start. The    *)
(* in-app sign-in saves the new session before its team picker opens, and  *)
(* the picker's choice adds the team; `fx login` picks the team first and  *)
(* saves once; the picker path saves nothing until the person chooses a    *)
(* team; `fx teams` takes the default team, the first of a list that does  *)
(* not hold the saved one, and saves it. team is the kind of entry saved   *)
(* as the team, or "none".                                                 *)
(*                                                                         *)
(* Rule picks the code: "design" is the fix, "today" is fx before it, and  *)
(* each "mut_*" plants one defect; check.sh names the rule that catches    *)
(* it. The picker path and `fx teams` are modeled for the fix only:       *)
(* "today" has no runs of either. SignInTeamsTrace.tla replays runs of the *)
(* built fx against this model; tests/tla/drivers/auth/driver.ts makes     *)
(* them.                                                                   *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS Surfaces, Priors, MaxEntries, Rule

Entries == {"plain", "ctl_name", "ctl_only", "ctl_slug", "bad_id", "unreadable"}
Lists == UNION {[1..n -> Entries] : n \in 0..MaxEntries}
Responses ==
    {[status |-> s, entries |-> <<>>] : s \in {"error", "garbage"}}
        \cup {[status |-> "ok", entries |-> l] : l \in Lists}
NoResponse == [status |-> "none", entries |-> <<>>]

Outcomes == {"none", "signed_in", "picking", "picker_closed", "teams_unavailable",
             "no_teams", "gateway_missing", "notice_saved", "credential_failure",
             "switch_failed", "crashed", "killed", "cancelled"}
Saves == {"none", "teamed", "new_teamless", "new_teamed", "reteamed"}
Teams == {"none"} \cup Entries

VARIABLES
    surface,  \* "cli" (fx login), "app" (the in-app /login), "picker" (its team column),
              \* or "teams" (fx teams)
    prior,    \* what the session store held before the sign-in
    phase,    \* "waiting" for the token, "fetching" the teams, "picking", "done"
    resp,     \* what /v2/teams answered
    saved,    \* what the session store holds
    team,     \* the kind of entry saved as the team, or "none"
    outcome,  \* what the person was told, or how fx ended
    offered,  \* how many teams the picker offered
    rawOut,   \* fx wrote a team's control characters to the terminal
    alive     \* the fx process is still running

vars == <<surface, prior, phase, resp, saved, team, outcome, offered, rawOut, alive>>

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

\* parseTeams keeps an entry. "mut_id" is readTeam without its check of the
\* id: any non-empty id counts, as fx kept one before this change too.
Keeps(e) ==
    CASE Rule \in {"today", "mut_slug"} -> e # "unreadable"
      [] Rule = "mut_strict" -> e = "plain"
      [] Rule = "mut_id" -> Usable(e) \/ e = "bad_id"
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

\* What the picker's team column says when the list is unavailable. A failed
\* request always said so. "mut_picker" is finishTeamsForProviderPicker
\* without its case for InvalidTeamsResponse, which a list that could not be
\* read or held no usable team reaches: it reported a credential problem.
PickerFailure(r) ==
    IF Rule = "mut_picker" /\ r.status # "error"
        THEN "credential_failure"
        ELSE "teams_unavailable"

\* What `fx teams` says when the list is unavailable. A failed request always
\* said so. "mut_teams" is the catch in the teams command without cases for
\* InvalidTeamsResponse and NoTeams: a list that could not be read, held no
\* usable team, or was empty ended in the general failure line.
TeamsFailure(r) ==
    IF Rule = "mut_teams" /\ r.status # "error"
        THEN "switch_failed"
        ELSE "teams_unavailable"

-----------------------------------------------------------------------------

\* The picker path and `fx teams` start from a saved sign-in and ask for the
\* teams at once.
Starts(s, p) ==
    /\ s \in {"picker", "teams"} => (p = "teamed" /\ Rule # "today")
    /\ surface' = s
    /\ prior' = p
    /\ phase' = IF s \in {"picker", "teams"} THEN "fetching" ELSE "waiting"
    /\ resp' = NoResponse
    /\ saved' = p
    /\ team' = "none"
    /\ outcome' = "none"
    /\ offered' = 0
    /\ rawOut' = FALSE
    /\ alive' = TRUE

InitWith(s, p) ==
    /\ s \in {"picker", "teams"} => (p = "teamed" /\ Rule # "today")
    /\ surface = s
    /\ prior = p
    /\ phase = IF s \in {"picker", "teams"} THEN "fetching" ELSE "waiting"
    /\ resp = NoResponse
    /\ saved = p
    /\ team = "none"
    /\ outcome = "none"
    /\ offered = 0
    /\ rawOut = FALSE
    /\ alive = TRUE

Init == \E s \in Surfaces, p \in Priors : InitWith(s, p)

\* A fresh sign-in, for trace validation of several runs in a row.
Reset(s, p) == Starts(s, p)

\* The issuer grants the token; fx asks for the teams.
Token ==
    /\ phase = "waiting"
    /\ phase' = "fetching"
    /\ UNCHANGED <<surface, prior, resp, saved, team, outcome, offered, rawOut, alive>>

\* The sign-in ends without a team and says why.
Fail(o) ==
    /\ phase' = "done"
    /\ outcome' = o
    /\ saved' = IF Rule = "mut_save" THEN "new_teamless" ELSE saved
    /\ UNCHANGED <<offered, rawOut, alive, team>>

\* fx before the change: an empty list saved the session with no team.
SaveTeamless ==
    /\ phase' = "done"
    /\ saved' = "new_teamless"
    /\ outcome' = IF surface = "cli" THEN "gateway_missing" ELSE "notice_saved"
    /\ UNCHANGED <<offered, rawOut, alive, team>>

\* fx login lists the teams when there are two or more, takes the default
\* (the first), and saves the session with it. A team whose id the gateway
\* rejects is saved all the same under "today" and "mut_id", and the next
\* step cannot use it.
CliTeams(k) ==
    /\ offered' = Len(k)
    /\ rawOut' = (Len(k) >= 2 /\ \E i \in DOMAIN k : RawName(k[i]) \/ RawSlug(k[i]))
    /\ saved' = "new_teamed"
    /\ team' = k[1]
    /\ outcome' = IF k[1] = "bad_id" THEN "gateway_missing" ELSE "signed_in"
    /\ phase' = "done"
    /\ UNCHANGED alive

\* The in-app sign-in saves the session, then draws every team's name in the
\* picker; a name that moves the cursor ends fx (ansi band overflow).
AppTeams(k) ==
    /\ offered' = Len(k)
    /\ saved' = "new_teamless"
    /\ UNCHANGED <<rawOut, team>>
    /\ IF \E i \in DOMAIN k : BreaksBand(k[i])
         THEN /\ alive' = FALSE
              /\ outcome' = "crashed"
              /\ phase' = "done"
         ELSE /\ UNCHANGED alive
              /\ outcome' = "picking"
              /\ phase' = "picking"

\* The picker's team column offers the teams and saves nothing yet.
PickerTeams(k) ==
    /\ offered' = Len(k)
    /\ outcome' = "picking"
    /\ phase' = "picking"
    /\ UNCHANGED <<saved, team, rawOut, alive>>

\* `fx teams` takes the default team and saves it on the session it listed
\* the teams with.
TeamsCommand(k) ==
    /\ offered' = Len(k)
    /\ rawOut' = (Len(k) >= 2 /\ \E i \in DOMAIN k : RawName(k[i]) \/ RawSlug(k[i]))
    /\ saved' = "reteamed"
    /\ team' = k[1]
    /\ outcome' = "signed_in"
    /\ phase' = "done"
    /\ UNCHANGED alive

Answer(r) ==
    /\ phase = "fetching"
    /\ resp' = r
    /\ UNCHANGED <<surface, prior>>
    /\ CASE Result(r) = "unavailable" ->
               Fail(IF surface = "picker" THEN PickerFailure(r)
                    ELSE IF surface = "teams" THEN TeamsFailure(r)
                    ELSE "teams_unavailable")
         [] Result(r) = "empty" ->
               IF Rule = "today" THEN SaveTeamless
               ELSE Fail(IF surface = "teams" /\ Rule = "mut_teams" THEN "switch_failed" ELSE "no_teams")
         [] Result(r) = "teams" ->
               IF surface = "cli" THEN CliTeams(Kept(r))
               ELSE IF surface = "app" THEN AppTeams(Kept(r))
               ELSE IF surface = "picker" THEN PickerTeams(Kept(r))
               ELSE TeamsCommand(Kept(r))

\* The person takes the picker's first team, the default. fx saves it, then
\* says so with the team's name and slug.
Pick ==
    /\ phase = "picking"
    /\ phase' = "done"
    /\ saved' = IF surface = "picker" THEN "reteamed" ELSE "new_teamed"
    /\ team' = Kept(resp)[1]
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
    /\ UNCHANGED <<surface, prior, resp, saved, team, offered, rawOut, alive>>

\* The in-app sign-in is cancelled before it saves anything.
Cancel ==
    /\ surface = "app"
    /\ phase \in {"waiting", "fetching"}
    /\ phase' = "done"
    /\ outcome' = "cancelled"
    /\ UNCHANGED <<surface, prior, resp, saved, team, offered, rawOut, alive>>

\* fx is killed at any point; a kill saves nothing.
Kill ==
    /\ phase # "done"
    /\ phase' = "done"
    /\ alive' = FALSE
    /\ outcome' = "killed"
    /\ UNCHANGED <<surface, prior, resp, saved, team, offered, rawOut>>

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
    /\ surface \in {"cli", "app", "picker", "teams"}
    /\ prior \in {"none", "teamed"}
    /\ surface \in {"picker", "teams"} => prior = "teamed"
    /\ phase \in {"waiting", "fetching", "picking", "done"}
    /\ resp \in Responses \cup {NoResponse}
    /\ saved \in Saves
    /\ team \in Teams
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

\* An entry that cannot be used is never saved as the team: a saved sign-in
\* whose team the gateway rejects cannot make a request, and replaces one
\* that could.
SavesOnlyUsableTeam == team = "none" \/ Usable(team)

\* What fx login says for a list, which every path says for the same list.
Said(r) ==
    CASE Truth(r) = "unavailable" -> "teams_unavailable"
      [] Truth(r) = "empty" -> "no_teams"
      [] OTHER -> "teams"

\* What a finished sign-in's outcome tells the person about the list.
Heard(o) ==
    CASE o \in {"teams_unavailable", "no_teams"} -> o
      [] o \in {"signed_in", "picking", "picker_closed"} -> "teams"
      [] OTHER -> "other"

\* fx login, the in-app /login, the picker's team column, and `fx teams` tell
\* the same story for the same list: a list with no usable team is never a
\* credential problem, a failed switch, a sign-in with no team, or an account
\* with no teams, and an empty list is never anything but an account with no
\* teams.
SameOutcomeEverywhere ==
    (Answered /\ outcome \notin {"killed", "cancelled", "crashed"}) => Heard(outcome) = Said(resp)
=============================================================================
