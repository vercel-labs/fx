--------------------------- MODULE FetchAdmission ---------------------------
(***************************************************************************)
(* Which addresses one web_fetch hop may dial (src/tools/web/http_fetch.zig *)
(* fetch, and isPublicAddress in src/tools/web/url_policy.zig).            *)
(*                                                                         *)
(* A hop gets its addresses from DNS, or one address from an IP literal in *)
(* the URL. fx checks every address and refuses the whole hop when any one *)
(* is not public, so a public A record cannot carry a private answer past  *)
(* the check. Only then does it dial, and only the addresses it checked. A *)
(* redirect to the same host starts a new hop with a new lookup.           *)
(*                                                                         *)
(* An address is a record [form, v4]. form is one of:                      *)
(*   "ipv4"         an IPv4 address: an A record or a literal              *)
(*   "nat64"        64:ff9b::/96, the RFC 6052 well-known prefix: a NAT64  *)
(*                  gateway forwards it to the IPv4 address in its last    *)
(*                  32 bits, which DNS64 puts there                        *)
(*   "nat64_local"  64:ff9b:1::/48, RFC 8215 local use: the network        *)
(*                  chooses where it translates                            *)
(*   "compat"       ::/96, the deprecated IPv4-compatible form (RFC 4291)  *)
(*   "mapped"       ::ffff:0:0/96, IPv4-mapped (RFC 4291)                  *)
(*   "global6"      global unicast IPv6 in 2000::/3                        *)
(*   "special6"     special ranges inside 2000::/3: Teredo, 6to4,          *)
(*                  documentation                                          *)
(*   "local6"       every other IPv6 address outside 2000::/3: loopback,   *)
(*                  unspecified, unique local, link-local, multicast, and  *)
(*                  the rest of 64:ff9b::/32                               *)
(* v4 is the class of the IPv4 address the form carries: "public" or a     *)
(* non-public class from V4Classes; "none" for the IPv6-only forms.        *)
(*                                                                         *)
(* Rule picks fx's rule for one address. "fixed" is fx with 64:ff9b::/96   *)
(* judged by its embedded IPv4 address; "today" is fx before it, which     *)
(* refused every NAT64 address (issue #1184). Each other value plants one  *)
(* defect, and check.sh names the property that must catch it:             *)
(*   no_embedded_check  every 64:ff9b::/96 address admitted                *)
(*   loose_prefix       64:ff9b::/32 matched, so 64:ff9b:1::/48 judged     *)
(*                      by its tail too                                    *)
(*   compat             every IPv4-embedding form judged by its tail       *)
(*   any_answer         a hop admitted when one answer is public           *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, Sequences

CONSTANTS V4Classes, MaxAnswers, MaxHops, Rule

ASSUME "public" \in V4Classes

V4Forms == {"ipv4", "nat64", "nat64_local", "compat", "mapped"}
V6Forms == {"global6", "special6", "local6"}
Addresses == [form : V4Forms, v4 : V4Classes] \cup [form : V6Forms, v4 : {"none"}]

\* Where a packet to a ends up, from the RFCs alone, apart from fx's rule.
Destination(a) ==
    CASE a.form \in {"ipv4", "nat64", "mapped"} -> a.v4
      [] a.form = "global6" -> "public"
      [] a.form = "special6" -> "special"
      [] a.form = "local6" -> "local"
      [] a.form \in {"nat64_local", "compat"} -> "unknown"

\* Safe to dial: the packet provably reaches a public address.
Safe(a) == Destination(a) = "public"

\* An answer DNS gives for a public host: an A record, a global AAAA
\* record, or a DNS64 AAAA record, each of a public address.
PublicAnswer(a) == a.form \in {"ipv4", "nat64", "global6"} /\ Safe(a)

\* fx's rule for one address (isPublicAddress).
Admit(a) ==
    CASE a.form = "ipv4" -> a.v4 = "public"
      [] a.form = "global6" -> TRUE
      [] a.form = "nat64" ->
            IF Rule = "today" THEN FALSE
            ELSE IF Rule = "no_embedded_check" THEN TRUE
            ELSE a.v4 = "public"
      [] a.form = "nat64_local" -> Rule = "loose_prefix" /\ a.v4 = "public"
      [] a.form \in {"compat", "mapped"} -> Rule = "compat" /\ a.v4 = "public"
      [] a.form \in {"special6", "local6"} -> FALSE

\* The hop's check (http_fetch.zig fetch): every answer, or for any_answer
\* only one.
AdmitHop(S) ==
    IF Rule = "any_answer" THEN \E a \in S : Admit(a) ELSE \A a \in S : Admit(a)

VARIABLES
    phase,    \* "resolve", "check", "admitted", or "refused"
    hops,     \* the hop number, 1 for the first request
    answers,  \* the addresses this hop got
    dialed    \* the addresses this hop dialed

vars == <<phase, hops, answers, dialed>>

Init ==
    /\ phase = "resolve"
    /\ hops = 1
    /\ answers = {}
    /\ dialed = {}

\* DNS, or an IP literal, gives the hop its addresses: any non-empty set of
\* at most MaxAnswers.
Resolve(S) ==
    /\ phase = "resolve"
    /\ S # {}
    /\ Cardinality(S) <= MaxAnswers
    /\ answers' = S
    /\ phase' = "check"
    /\ UNCHANGED <<hops, dialed>>

Check ==
    /\ phase = "check"
    /\ phase' = IF AdmitHop(answers) THEN "admitted" ELSE "refused"
    /\ UNCHANGED <<hops, answers, dialed>>

\* The connector tries the pinned addresses, in any order.
Dial(a) ==
    /\ phase = "admitted"
    /\ a \in answers
    /\ dialed' = dialed \cup {a}
    /\ UNCHANGED <<phase, hops, answers>>

\* The server redirects to the same host: a new hop with a new lookup.
Redirect ==
    /\ phase = "admitted"
    /\ hops < MaxHops
    /\ hops' = hops + 1
    /\ phase' = "resolve"
    /\ answers' = {}
    /\ dialed' = {}

Finished == phase \in {"admitted", "refused"} /\ UNCHANGED vars

\* Answer sets as the ranges of short sequences, so TLC never enumerates
\* SUBSET Addresses.
AnswerSets == UNION {{{f[i] : i \in 1..n} : f \in [1..n -> Addresses]} : n \in 1..MaxAnswers}

Next ==
    \/ \E S \in AnswerSets : Resolve(S)
    \/ Check
    \/ \E a \in Addresses : Dial(a)
    \/ Redirect
    \/ Finished

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------

TypeOK ==
    /\ phase \in {"resolve", "check", "admitted", "refused"}
    /\ hops \in 1..MaxHops
    /\ answers \subseteq Addresses
    /\ dialed \subseteq answers

\* fx never dials an address it cannot show is public.
NoUnsafeDial == \A a \in dialed : Safe(a)

\* An admitted hop holds only safe answers, so no dial order can reach an
\* unsafe one.
EveryAnswerSafe == phase = "admitted" => \A a \in answers : Safe(a)

\* fx refuses a hop only when some answer is not a public answer, so a
\* public host on a DNS64 network is fetched (issue #1184).
PublicHostAdmitted == phase = "refused" => \E a \in answers : ~PublicAnswer(a)

\* The change admits one new form, 64:ff9b::/96; IPv4-mapped, IPv4-compatible,
\* and local-use NAT64 addresses stay refused.
AdmittedForms == phase = "admitted" => \A a \in answers : a.form \in {"ipv4", "nat64", "global6"}
=============================================================================
