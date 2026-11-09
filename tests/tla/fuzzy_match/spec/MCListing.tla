----------------------------- MODULE MCListing -----------------------------
(***************************************************************************)
(* The listing laws of design/GOAL.md, L8, L9, and L11, over every query   *)
(* every list of items the configured alphabet can build. Each item has a  *)
(* name field and a text field, so ties on tier are broken by field.       *)
(***************************************************************************)
EXTENDS FuzzyMatch, FiniteSets

CONSTANTS Alphabet, MaxQuery, MaxField, NumItems

Strings(n) == UNION {[1..k -> Alphabet] : k \in 0..n}
Items == {<<[text |-> name, kind |-> "name"], [text |-> text, kind |-> "text"]>> :
            name \in Strings(MaxField), text \in Strings(MaxField)}

VARIABLES q, items
vars == <<q, items>>

Init == q \in Strings(MaxQuery) /\ items \in [1..NumItems -> Items]
Next == UNCHANGED vars
Spec == Init /\ [][Next]_vars

Rk(i) == TierRank[Match(q, items[i]).tier]
Fd(i) == Match(q, items[i]).field
MatchSet == {i \in 1..NumItems : Rk(i) > 0}
Ranked == Listing(items, q, "ranked")
Filtered == Listing(items, q, "filtered")
Shows(l) == {l[k] : k \in 1..Len(l)}

TypeOK == Ranked \in Seq(1..NumItems) /\ Filtered \in Seq(1..NumItems)

\* L8: the matches, each once, best tier first, then lowest field, then base
\* order.
ListingSortedStable ==
    /\ Shows(Ranked) = MatchSet
    /\ Len(Ranked) = Cardinality(MatchSet)
    /\ \A a, b \in 1..Len(Ranked) :
         a < b =>
           \/ Rk(Ranked[a]) > Rk(Ranked[b])
           \/ /\ Rk(Ranked[a]) = Rk(Ranked[b])
              /\ \/ Fd(Ranked[a]) < Fd(Ranked[b])
                 \/ Fd(Ranked[a]) = Fd(Ranked[b]) /\ Ranked[a] < Ranked[b]

\* L8: what matches today, as substring or better, is listed before any
\* match the engine adds.
LegacyRowsFirst ==
    \A a, b \in 1..Len(Ranked) :
        (a < b /\ Rk(Ranked[b]) >= TierRank["substring"]) => Rk(Ranked[a]) >= TierRank["substring"]

AsTypedSet == {i \in MatchSet : Rk(i) >= TierRank["substring"]}

\* L9: a filtered listing shows only matches, each once, in base order.
FilteredKeepsOrder ==
    /\ Shows(Filtered) \subseteq MatchSet
    /\ \A a, b \in 1..Len(Filtered) : a < b => Filtered[a] < Filtered[b]

\* L11: it shows exactly the as-typed matches when there are any, and
\* otherwise every match, so it is never empty while something matches.
FilteredPrefersAsTyped ==
    Shows(Filtered) = (IF AsTypedSet # {} THEN AsTypedSet ELSE MatchSet)

=============================================================================
