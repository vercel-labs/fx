---- MODULE AuthFlow ----
\* U09 signing in, client side, for one MCP server: discovery, registration,
\* the authorization request and its response, and redeeming the code.
\* Rules: AUTH-03..AUTH-17, AUTH-23 (rules.md). The token on requests is
\* AuthGate.tla.
\*
\*   - Discovery finds the authorization server the resource metadata names.
\*     Its metadata is used only when its issuer is the one the URL was built
\*     from and it lists S256 (AUTH-06, AUTH-07); otherwise the sign-in fails.
\*   - Registrations are kept per issuer: one is presented only to the issuer
\*     that issued it, and a new issuer gets a new one (AUTH-08). The token held
\*     is dropped when the metadata names another issuer.
\*   - The issuer is recorded with the flow's verifier and state before the
\*     authorization request (AUTH-13). The response is checked for state and
\*     iss before anything else, and an error in a response that fails the
\*     checks is never shown (AUTH-14, AUTH-15). Each verifier is redeemed once.
\*   - A sign-in asks for the scopes the token held was asked with plus those of
\*     the latest challenge (AUTH-23), also when both come from a login an
\*     earlier run saved. At most MaxAuthorizations authorization requests go
\*     out since the server last accepted a request.
\*
\* Issuers, scopes, and flows are small sets; their strings are data.
EXTENDS Naturals

CONSTANTS
    Issuers,
    None,                \* no issuer
    Scopes,
    MaxFlows,            \* sign-ins per run
    MaxAuthorizations    \* authorization requests per sign-in; fx allows 3

ASSUME MaxFlows \in Nat \ {0} /\ MaxAuthorizations \in Nat \ {0} /\ None \notin Issuers

Flows == {"idle", "discovering", "registering", "authorizing", "redeeming"}

VARIABLES
    flow,
    flows,        \* sign-ins started; each has its own verifier and state
    flowIssuer,   \* the issuer recorded with the flow's verifier and state
    flowScopes,   \* the scopes the flow asks for
    regs,         \* issuers the client holds a registration with
    tokenIssuer,  \* issuer of the token held, None for none
    granted,      \* the scopes the token held was asked with
    challenge,    \* the scopes the latest challenge named
    auths,        \* authorization requests since the server last accepted one
    \* Environment.
    asIssuer,     \* the authorization server the resource metadata names
    migrated,
    \* Ghosts.
    known,        \* issuer of the last metadata the client validated
    validated,    \* this flow's metadata passed the issuer and PKCE checks
    checked,      \* this flow's response passed the state and iss checks
    asked,        \* granted \cup challenge when this flow started
    shown,        \* an error from an unchecked response was shown
    redemptions,  \* [1..MaxFlows -> codes redeemed]
    used          \* <<registration's issuer, issuer it was presented to>>

vars == <<flow, flows, flowIssuer, flowScopes, regs, tokenIssuer, granted, challenge, auths,
          asIssuer, migrated, known, validated, checked, asked, shown, redemptions, used>>

Init ==
    /\ flow = "idle"
    /\ flows = 0
    /\ flowIssuer = None
    /\ flowScopes = {}
    /\ regs = {}
    /\ tokenIssuer = None
    \* A run starts with no login, or from one an earlier run saved: the
    \* scopes its token was asked with and a step-up it still owes, so the
    \* next sign-in asks for both. The core records no issuer for a saved
    \* token, so tokenIssuer stays None.
    /\ granted \in SUBSET Scopes
    /\ challenge \in SUBSET Scopes
    /\ auths = 0
    /\ asIssuer \in Issuers
    /\ migrated = FALSE
    /\ known = None
    /\ validated = FALSE
    /\ checked = FALSE
    /\ asked = {}
    /\ shown = FALSE
    /\ redemptions = [f \in 1..MaxFlows |-> 0]
    /\ used = {}

\* ---- Client ----

\* The host asks to sign in: after a challenge, or to step up (AUTH-23).
SignIn ==
    /\ flow = "idle"
    /\ flows < MaxFlows
    /\ auths < MaxAuthorizations
    /\ flow' = "discovering"
    /\ flows' = flows + 1
    /\ flowScopes' = granted \cup challenge
    /\ asked' = granted \cup challenge
    /\ validated' = FALSE
    /\ checked' = FALSE
    /\ UNCHANGED <<flowIssuer, regs, tokenIssuer, granted, challenge, auths, asIssuer, migrated, known, shown, redemptions, used>>

\* The authorization request goes out, presenting registration `reg` to `i`.
Authorize(reg, i) ==
    /\ flow' = "authorizing"
    /\ auths' = auths + 1
    /\ used' = used \cup {<<reg, i>>}

\* Discovery ends: whether the metadata's issuer is the one the URL was built
\* from, whether it lists S256, and the resource metadata's scopes_supported,
\* asked for when nothing else names scopes (AUTH-12). Usable metadata names
\* the issuer the flow records.
Discovered(metaOk, pkceOk, defaults) ==
    /\ flow = "discovering"
    /\ LET usable == metaOk /\ pkceOk IN
       IF usable
       THEN /\ flowIssuer' = asIssuer
            /\ known' = asIssuer
            /\ validated' = (metaOk /\ pkceOk)
            /\ flowScopes' = IF flowScopes = {} THEN defaults ELSE flowScopes
            /\ IF tokenIssuer \notin {None, asIssuer}
               THEN tokenIssuer' = None /\ granted' = {}
               ELSE UNCHANGED <<tokenIssuer, granted>>
            /\ IF asIssuer \in regs
               THEN Authorize(asIssuer, asIssuer) /\ UNCHANGED regs
               ELSE flow' = "registering" /\ UNCHANGED <<regs, auths, used>>
       ELSE /\ flow' = "idle"
            /\ UNCHANGED <<flowIssuer, flowScopes, known, validated, tokenIssuer, granted, regs, auths, used>>
    /\ UNCHANGED <<flows, challenge, asIssuer, migrated, checked, asked, shown, redemptions>>

\* Registration with the flow's issuer ends.
Registered(ok) ==
    /\ flow = "registering"
    /\ IF ok
       THEN regs' = regs \cup {flowIssuer} /\ Authorize(flowIssuer, flowIssuer)
       ELSE flow' = "idle" /\ UNCHANGED <<regs, auths, used>>
    /\ UNCHANGED <<flows, flowIssuer, flowScopes, tokenIssuer, granted, challenge, asIssuer, migrated, known, validated, checked, asked, shown, redemptions>>

\* The host passes back the authorization response: whether its state matches,
\* its iss ("none", "match", "wrong"), whether the metadata advertised iss, and
\* whether it carries an error rather than a code (AUTH-14, AUTH-15).
Responded(stateOk, iss, advertised, err) ==
    /\ flow = "authorizing"
    /\ LET \* What RFC 9207 and the state check say about the response.
           passes == stateOk /\ (iss = "match" \/ (iss = "none" /\ ~advertised))
           \* The client's decision, and whether it shows the error.
           accept == stateOk /\ CASE iss = "match" -> TRUE
                                    [] iss = "wrong" -> FALSE
                                    [] iss = "none" -> ~advertised
           display == err /\ accept
       IN /\ checked' = passes
          /\ shown' = (shown \/ (display /\ ~passes))
          /\ flow' = IF accept /\ ~err THEN "redeeming" ELSE "idle"
    /\ UNCHANGED <<flows, flowIssuer, flowScopes, regs, tokenIssuer, granted, challenge, auths, asIssuer, migrated, known, validated, asked, redemptions, used>>

\* The token request with the flow's verifier ends.
Redeemed(ok) ==
    /\ flow = "redeeming"
    /\ redemptions' = [redemptions EXCEPT ![flows] = @ + 1]
    /\ flow' = "idle"
    /\ IF ok
       THEN tokenIssuer' = flowIssuer /\ granted' = flowScopes
       ELSE UNCHANGED <<tokenIssuer, granted>>
    /\ UNCHANGED <<flows, flowIssuer, flowScopes, regs, challenge, auths, asIssuer, migrated, known, validated, checked, asked, shown, used>>

\* The host gives up waiting, or the sign-in is cancelled.
Cancel ==
    /\ flow # "idle"
    /\ flow' = "idle"
    /\ UNCHANGED <<flows, flowIssuer, flowScopes, regs, tokenIssuer, granted, challenge, auths, asIssuer, migrated, known, validated, checked, asked, shown, redemptions, used>>

SignOut ==
    /\ tokenIssuer' = None
    /\ granted' = {}
    /\ UNCHANGED <<flow, flows, flowIssuer, flowScopes, regs, challenge, auths, asIssuer, migrated, known, validated, checked, asked, shown, redemptions, used>>

\* ---- Environment ----

\* A request is rejected with a challenge naming these scopes.
Challenged(sc) ==
    /\ challenge' = sc
    /\ UNCHANGED <<flow, flows, flowIssuer, flowScopes, regs, tokenIssuer, granted, auths, asIssuer, migrated, known, validated, checked, asked, shown, redemptions, used>>

\* The server accepts a request.
Accepted ==
    /\ tokenIssuer # None
    /\ auths' = 0
    /\ UNCHANGED <<flow, flows, flowIssuer, flowScopes, regs, tokenIssuer, granted, challenge, asIssuer, migrated, known, validated, checked, asked, shown, redemptions, used>>

\* The resource metadata starts naming another authorization server.
Migrate ==
    /\ ~migrated
    /\ \E i \in Issuers \ {asIssuer} : asIssuer' = i
    /\ migrated' = TRUE
    /\ UNCHANGED <<flow, flows, flowIssuer, flowScopes, regs, tokenIssuer, granted, challenge, auths, known, validated, checked, asked, shown, redemptions, used>>

Progress ==
    \/ \E m, p \in BOOLEAN, d \in SUBSET Scopes : Discovered(m, p, d)
    \/ \E ok \in BOOLEAN : Registered(ok)
    \/ \E s, a, e \in BOOLEAN, i \in {"none", "match", "wrong"} : Responded(s, i, a, e)
    \/ \E ok \in BOOLEAN : Redeemed(ok)
    \/ Cancel

Next ==
    \/ SignIn
    \/ Progress
    \/ SignOut
    \/ \E sc \in SUBSET Scopes : Challenged(sc)
    \/ Accepted
    \/ Migrate

\* Every step of a sign-in gets an answer, or the host cancels it.
Spec == Init /\ [][Next]_vars /\ WF_vars(Progress)

\* ---- Properties ----

TypeOK ==
    /\ flow \in Flows
    /\ flows \in 0..MaxFlows
    /\ regs \subseteq Issuers
    /\ tokenIssuer \in Issuers \cup {None}
    /\ granted \subseteq Scopes /\ challenge \subseteq Scopes /\ flowScopes \subseteq Scopes
    /\ auths \in Nat

\* AUTH-06, AUTH-07: nothing goes to an authorization server whose metadata
\* failed the issuer or PKCE check.
MetaValidated == flow \in {"registering", "authorizing", "redeeming"} => validated

\* AUTH-14, AUTH-15: a code is redeemed only from a response that passed the
\* state and iss checks.
RedeemGuard == flow = "redeeming" => checked

\* Each flow's verifier is redeemed at most once.
VerifierOnce == \A f \in 1..MaxFlows : redemptions[f] <= 1

\* AUTH-14: no error from a response that failed the checks is shown.
ErrSuppress == ~shown

\* AUTH-08: a registration is presented only to the issuer that issued it.
CredIsolation == \A p \in used : p[1] = p[2]

\* AUTH-20: the token held is always from the issuer the validated metadata
\* names, once the client has seen one.
TokenAudience == tokenIssuer \in {None, known}

\* AUTH-23: a sign-in asks for at least the scopes held and those challenged.
ScopeUnion == flow # "idle" => asked \subseteq flowScopes

\* Authorization requests are bounded.
StepUpBound == auths <= MaxAuthorizations

\* Every sign-in ends.
EverySignInEnds == flow # "idle" ~> flow = "idle"
====
