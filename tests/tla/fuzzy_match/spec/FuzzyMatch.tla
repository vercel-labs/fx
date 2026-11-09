----------------------------- MODULE FuzzyMatch -----------------------------
(***************************************************************************)
(* The fuzzy match engine, `match(query, fields)` in                       *)
(* src/core/shared/fuzzy_match.zig, step by step as the code runs it, and  *)
(* the listings that ranked and filtered menus build from its answers      *)
(* (`Ranking` and `Filter` in the same file).                              *)
(*                                                                         *)
(* A string is a sequence of character atoms, as the drivers encode them:  *)
(*   - an ASCII letter or digit is itself, such as "a", "Q", or "7";       *)
(*   - every other ASCII byte is "s+" and its two lowercase hex digits,    *)
(*     such as "s+20" for a space and "s+2d" for a hyphen;                 *)
(*   - a valid non-ASCII UTF-8 sequence is "u+" and its code point in      *)
(*     lowercase hex, such as "u+e9";                                      *)
(*   - a byte that starts no valid UTF-8 sequence is "b+" and its two      *)
(*     lowercase hex digits.                                               *)
(* So one atom is one character the code never splits (R8).               *)
(*                                                                         *)
(* A field is [text |-> string, kind |-> "name" or "text"]. Field indexes  *)
(* here start at 1; the code's start at 0. A match is                      *)
(* [tier |-> tier, field |-> index], with field 0 for no match.            *)
(*                                                                         *)
(* MCFuzzyMatch.tla and MCListing.tla state the rules again declaratively  *)
(* and check that these definitions agree with them, so a wrong step here  *)
(* breaks a law instead of moving it. Rule numbers are design/GOAL.md's.   *)
(***************************************************************************)
EXTENDS Naturals, Sequences, TLC

Tiers == {"none", "fuzzy", "words", "substring", "prefix", "exact"}

\* R1.
TierRank == [none |-> 0, fuzzy |-> 1, words |-> 2, substring |-> 3, prefix |-> 4, exact |-> 5]

UpperLetters == <<"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
                  "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z">>
LowerLetters == <<"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
                  "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z">>
Digits == {"0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}
HexDigits == Digits \cup {"a", "b", "c", "d", "e", "f"}

\* R8: every ASCII byte that is not a letter or digit.
Separators == {"s+" \o hi \o lo : hi \in HexDigits, lo \in HexDigits}

\* R2: space, tab, line feed, carriage return.
Whitespace == {"s+20", "s+09", "s+0a", "s+0d"}

FoldMap == [c \in {UpperLetters[i] : i \in 1..26} |->
              LowerLetters[CHOOSE i \in 1..26 : UpperLetters[i] = c]]

\* R8: ASCII letters compare without case; everything else exactly.
Fold(c) == IF c \in DOMAIN FoldMap THEN FoldMap[c] ELSE c
Same(a, b) == Fold(a) = Fold(b)

IsSep(c) == c \in Separators
IsWordChar(c) == ~IsSep(c)
IsDigit(c) == c \in Digits

SameSeq(a, b) == Len(a) = Len(b) /\ \A i \in 1..Len(a) : Same(a[i], b[i])
StartsWith(s, p) == Len(p) <= Len(s) /\ SameSeq(SubSeq(s, 1, Len(p)), p)

\* The code scans start positions left to right and stops at the first hit.
RECURSIVE ContainsFrom(_, _, _)
ContainsFrom(s, n, i) ==
    IF i + Len(n) - 1 > Len(s) THEN FALSE
    ELSE IF SameSeq(SubSeq(s, i, i + Len(n) - 1), n) THEN TRUE
    ELSE ContainsFrom(s, n, i + 1)
Contains(s, n) == ContainsFrom(s, n, 1)

\* R2.
RECURSIVE TrimStart(_)
TrimStart(s) == IF s # <<>> /\ Head(s) \in Whitespace THEN TrimStart(Tail(s)) ELSE s
RECURSIVE TrimEnd(_)
TrimEnd(s) == IF s # <<>> /\ s[Len(s)] \in Whitespace THEN TrimEnd(SubSeq(s, 1, Len(s) - 1)) ELSE s
Trim(s) == TrimEnd(TrimStart(s))

\* R4: the query's words, split at whitespace, in order.
RECURSIVE WordsFrom(_, _)
WordsFrom(s, current) ==
    IF s = <<>> THEN (IF current = <<>> THEN <<>> ELSE <<current>>)
    ELSE IF Head(s) \in Whitespace
         THEN (IF current = <<>> THEN WordsFrom(Tail(s), <<>>)
               ELSE <<current>> \o WordsFrom(Tail(s), <<>>))
         ELSE WordsFrom(Tail(s), Append(current, Head(s)))
Words(s) == WordsFrom(s, <<>>)

HasWordChar(s) == \E i \in 1..Len(s) : IsWordChar(s[i])

\* The word characters of `s`, in order.
Compact(s) == SelectSeq(s, IsWordChar)

\* R9.
WordStart(f, i) ==
    /\ IsWordChar(f[i])
    /\ \/ i = 1
       \/ IsSep(f[i - 1])
       \/ IsDigit(f[i - 1]) # IsDigit(f[i])

\* R4 on a name field: the word's word characters form a run among the
\* field's word characters.
RunIn(f, w) == Compact(w) # <<>> /\ Contains(Compact(f), Compact(w))

\* R5, as the code finds it: the first word start whose character matches
\* the word's first word character, then each later word character at its
\* first occurrence after the one before. MCFuzzyMatch!GreedyIsComplete
\* checks that this finds every match that exists.
RECURSIVE AnchorFrom(_, _, _)
AnchorFrom(f, c, i) ==
    IF i > Len(f) THEN 0
    ELSE IF WordStart(f, i) /\ Same(f[i], c) THEN i
    ELSE AnchorFrom(f, c, i + 1)

RECURSIVE GreedyFrom(_, _, _)
GreedyFrom(f, w, i) ==
    IF w = <<>> THEN TRUE
    ELSE IF i > Len(f) THEN FALSE
    ELSE IF Same(f[i], Head(w)) THEN GreedyFrom(f, Tail(w), i + 1)
    ELSE GreedyFrom(f, w, i + 1)

FuzzyIn(f, w) ==
    LET cw == Compact(w)
    IN /\ cw # <<>>
       /\ LET anchor == AnchorFrom(f, Head(cw), 1)
          IN anchor > 0 /\ GreedyFrom(f, Tail(cw), anchor + 1)

\* R3: the tier the whole trimmed query gets from one field.
WholeTier(fd, t) ==
    IF fd.kind = "name" /\ SameSeq(fd.text, t) THEN "exact"
    ELSE IF fd.kind = "name" /\ StartsWith(fd.text, t) THEN "prefix"
    ELSE IF Contains(fd.text, t) THEN "substring"
    ELSE "none"

\* R4 and R5: the tier one query word gets from one field.
WordTier(fd, w) ==
    IF fd.kind = "name"
    THEN (IF RunIn(fd.text, w) THEN "words"
          ELSE IF FuzzyIn(fd.text, w) THEN "fuzzy"
          ELSE "none")
    ELSE (IF Contains(fd.text, w) THEN "words" ELSE "none")

Range(s) == {s[i] : i \in DOMAIN s}
MaxTier(ts) == CHOOSE t \in Range(ts) : \A u \in Range(ts) : TierRank[t] >= TierRank[u]
MinTier(ts) == CHOOSE t \in Range(ts) : \A u \in Range(ts) : TierRank[t] <= TierRank[u]
\* The lowest index holding `t`.
FirstWith(ts, t) == CHOOSE i \in DOMAIN ts : ts[i] = t /\ \A j \in 1..(i - 1) : ts[j] # t
MinOf(S) == CHOOSE x \in S : \A y \in S : x <= y

NoMatch == [tier |-> "none", field |-> 0]

\* R12: the most characters a query can have and still match by words or
\* letters in order. A longer query matches only as typed.
MaxFuzzyChars == 64

\* R1 to R7 and R12. `fs` is never empty. R6: a query with no word characters
\* that no field holds as typed matches nothing, and R12: neither does a query
\* longer than MaxFuzzyChars.
Match(q, fs) ==
    LET t == Trim(q)
    IN IF t = <<>> THEN [tier |-> "exact", field |-> 1]
       ELSE
         LET whole == [i \in 1..Len(fs) |-> WholeTier(fs[i], t)]
             best == MaxTier(whole)
         IN IF TierRank[best] >= TierRank["substring"]
            THEN [tier |-> best, field |-> FirstWith(whole, best)]
            ELSE IF Len(t) > MaxFuzzyChars THEN NoMatch
            ELSE
              LET ws == SelectSeq(Words(t), HasWordChar)
              IN IF ws = <<>> THEN NoMatch
                 ELSE
                   LET per == [j \in 1..Len(ws) |-> [i \in 1..Len(fs) |-> WordTier(fs[i], ws[j])]]
                       level == [j \in 1..Len(ws) |-> MaxTier(per[j])]
                   IN IF \E j \in 1..Len(ws) : level[j] = "none" THEN NoMatch
                      ELSE [tier |-> MinTier(level),
                            field |-> MinOf({FirstWith(per[j], level[j]) : j \in 1..Len(ws)})]

Matches(q, fs) == Match(q, fs).tier # "none"

\* R10. `items` is a sequence of field sequences in the surface's base order.
\* A listing is the indexes of the items it shows, in the order it shows them.
Better(items, q, i, j) ==
    LET a == Match(q, items[i])
        b == Match(q, items[j])
    IN \/ TierRank[a.tier] > TierRank[b.tier]
       \/ /\ TierRank[a.tier] = TierRank[b.tier]
          /\ \/ a.field < b.field
             \/ a.field = b.field /\ i < j

MatchingIndexes(items, q) ==
    SelectSeq([i \in 1..Len(items) |-> i], LAMBDA i : Matches(q, items[i]))

\* R11: a filtered surface lists, in base order, the items that match as
\* typed, substring or better, when any does, and otherwise every match.
AsTyped(items, q, i) == TierRank[Match(q, items[i]).tier] >= TierRank["substring"]
FilteredIndexes(items, q) ==
    IF \E i \in 1..Len(items) : AsTyped(items, q, i)
    THEN SelectSeq([i \in 1..Len(items) |-> i], LAMBDA i : AsTyped(items, q, i))
    ELSE MatchingIndexes(items, q)

Listing(items, q, mode) ==
    IF mode = "filtered" THEN FilteredIndexes(items, q)
    ELSE SortSeq(MatchingIndexes(items, q), LAMBDA i, j : Better(items, q, i, j))

=============================================================================
