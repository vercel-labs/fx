---------------------------- MODULE MCFuzzyMatch ----------------------------
(***************************************************************************)
(* Every law of design/GOAL.md that is about one item, over every query    *)
(* and every tuple of fields the configured alphabet can build.            *)
(*                                                                         *)
(* The rules are restated here declaratively, with their own copies of the *)
(* character classes and of case folding, so a wrong step in               *)
(* FuzzyMatch.tla shows up as a disagreement instead of being copied into  *)
(* the law. Each state is one query and one field tuple; nothing moves.    *)
(***************************************************************************)
EXTENDS FuzzyMatch, FiniteSets

CONSTANTS
    Alphabet,   \* the character atoms queries and fields are built from
    MaxQuery,   \* the longest query
    MaxField,   \* the longest field text
    Kinds       \* the kind of each field, such as <<"name", "text">>

\* The field kinds a config can bind to Kinds with `<-`.
OneName == <<"name">>
OneText == <<"text">>
NameAndText == <<"name", "text">>
TwoNames == <<"name", "name">>

Strings(n) == UNION {[1..k -> Alphabet] : k \in 0..n}

FieldTuples ==
    {[i \in 1..Len(Kinds) |-> [text |-> texts[i], kind |-> Kinds[i]]] :
        texts \in [1..Len(Kinds) -> Strings(MaxField)]}

VARIABLES q, fs
vars == <<q, fs>>

Init == q \in Strings(MaxQuery) /\ fs \in FieldTuples
Next == UNCHANGED vars
Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
\* The declarative rules.

DHex == {"0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"}
DSeparators == {"s+" \o hi \o lo : hi \in DHex, lo \in DHex}
DWhitespace == {"s+20", "s+09", "s+0a", "s+0d"}
DDigits == {"0", "1", "2", "3", "4", "5", "6", "7", "8", "9"}
DIsWord(c) == c \notin DSeparators
DFold(c) == IF \E i \in 1..26 : UpperLetters[i] = c
            THEN LowerLetters[CHOOSE i \in 1..26 : UpperLetters[i] = c]
            ELSE c
DSame(a, b) == DFold(a) = DFold(b)

DMin(S) == CHOOSE x \in S : \A y \in S : x <= y
DMax(S) == CHOOSE x \in S : \A y \in S : x >= y

DTrim(s) ==
    LET keep == {i \in 1..Len(s) : s[i] \notin DWhitespace}
    IN IF keep = {} THEN <<>> ELSE SubSeq(s, DMin(keep), DMax(keep))

\* R4: the maximal runs of non-whitespace.
DWords(t) ==
    {SubSeq(t, ab[1], ab[2]) :
        ab \in {ab \in (1..Len(t)) \X (1..Len(t)) :
                  /\ ab[1] <= ab[2]
                  /\ \A k \in ab[1]..ab[2] : t[k] \notin DWhitespace
                  /\ ab[1] = 1 \/ t[ab[1] - 1] \in DWhitespace
                  /\ ab[2] = Len(t) \/ t[ab[2] + 1] \in DWhitespace}}

IncSeqs(n, k) == {p \in [1..k -> 1..n] : \A j \in 1..(k - 1) : p[j] < p[j + 1]}

\* The positions of the word characters of `w`, in order.
WordPositions(w) ==
    LET at == {i \in 1..Len(w) : DIsWord(w[i])}
    IN CHOOSE p \in IncSeqs(Len(w), Cardinality(at)) : {p[j] : j \in 1..Cardinality(at)} = at

DContains(s, n) == \E i \in 0..(Len(s) - Len(n)) : \A j \in 1..Len(n) : DSame(s[i + j], n[j])
DStarts(s, n) == Len(n) <= Len(s) /\ \A j \in 1..Len(n) : DSame(s[j], n[j])
DEqual(s, n) == Len(s) = Len(n) /\ DStarts(s, n)

\* R9.
DWordStart(f, i) ==
    DIsWord(f[i]) /\ (i = 1 \/ ~DIsWord(f[i - 1]) \/ ((f[i - 1] \in DDigits) # (f[i] \in DDigits)))

\* R4 on a name field: the word characters of `w` land on word characters
\* of `f` with no word character of `f` between consecutive ones.
DRun(f, w) ==
    LET wp == WordPositions(w)
        k == Len(wp)
    IN /\ k > 0
       /\ \E p \in IncSeqs(Len(f), k) :
            /\ \A j \in 1..k : DIsWord(f[p[j]]) /\ DSame(f[p[j]], w[wp[j]])
            /\ \A j \in 1..(k - 1) : \A x \in (p[j] + 1)..(p[j + 1] - 1) : ~DIsWord(f[x])

\* R5: the word characters of `w` appear in order in `f`, the first at a
\* word start.
DFuzzy(f, w) ==
    LET wp == WordPositions(w)
        k == Len(wp)
    IN /\ k > 0
       /\ \E p \in IncSeqs(Len(f), k) :
            /\ DWordStart(f, p[1])
            /\ \A j \in 1..k : DSame(f[p[j]], w[wp[j]])

\* Ranks as numbers: 0 none, 1 fuzzy, 2 words, 3 substring, 4 prefix, 5 exact.
DRankName == <<"fuzzy", "words", "substring", "prefix", "exact">>
DName(n) == IF n = 0 THEN "none" ELSE DRankName[n]

DWhole(fd, t) ==
    IF fd.kind = "name" /\ DEqual(fd.text, t) THEN 5
    ELSE IF fd.kind = "name" /\ DStarts(fd.text, t) THEN 4
    ELSE IF DContains(fd.text, t) THEN 3
    ELSE 0

DWordLevel(fd, w) ==
    IF fd.kind = "name"
    THEN (IF DRun(fd.text, w) THEN 2 ELSE IF DFuzzy(fd.text, w) THEN 1 ELSE 0)
    ELSE (IF DContains(fd.text, w) THEN 2 ELSE 0)

\* R1 to R7 and R12.
DMatch(query, fields) ==
    LET t == DTrim(query)
        I == 1..Len(fields)
    IN IF t = <<>> THEN [tier |-> "exact", field |-> 1]
       ELSE
         LET best == DMax({DWhole(fields[i], t) : i \in I})
         IN IF best >= 3
            THEN [tier |-> DName(best), field |-> DMin({i \in I : DWhole(fields[i], t) = best})]
            ELSE IF Len(t) > MaxFuzzyChars THEN [tier |-> "none", field |-> 0]
            ELSE
              LET ws == {w \in DWords(t) : \E i \in 1..Len(w) : DIsWord(w[i])}
                  level(w) == DMax({DWordLevel(fields[i], w) : i \in I})
              IN IF ws = {} THEN [tier |-> "none", field |-> 0]
                 ELSE IF \E w \in ws : level(w) = 0 THEN [tier |-> "none", field |-> 0]
                 ELSE [tier |-> DName(DMin({level(w) : w \in ws})),
                       field |-> DMin({DMin({i \in I : DWordLevel(fields[i], w) = level(w)}) : w \in ws})]

-----------------------------------------------------------------------------
\* The laws.

TypeOK ==
    /\ q \in Seq(Alphabet)
    /\ Match(q, fs) \in [tier : Tiers, field : 0..Len(fs)]
    /\ (Match(q, fs).tier = "none") <=> (Match(q, fs).field = 0)

\* L1.
MatchIsDeclarative == Match(q, fs) = DMatch(q, fs)

\* L7, and its partner for R4.
GreedyIsComplete == \A i \in 1..Len(fs) : FuzzyIn(fs[i].text, q) = DFuzzy(fs[i].text, q)
RunIsDeclarative == \A i \in 1..Len(fs) : RunIn(fs[i].text, q) = DRun(fs[i].text, q)

\* L2: once the query has a word character, or while it is blank, typing one
\* more character never adds a match. By induction every prefix of a
\* matching query that has a word character, or is blank, matches. A prefix
\* of only punctuation matches only as typed (L10), so `-` can hide an item
\* that `-a` then shows.
DHasWord(s) == \E i \in 1..Len(s) : DIsWord(s[i])
Narrowing ==
    (DTrim(q) = <<>> \/ DHasWord(q)) => \A c \in Alphabet : Matches(Append(q, c), fs) => Matches(q, fs)

\* L3.
KeepsSubstringMatches ==
    (\E i \in 1..Len(fs) : DContains(fs[i].text, DTrim(q)))
        => TierRank[Match(q, fs).tier] >= TierRank["substring"]

\* A query of only punctuation matches only as typed (L10), and so does one
\* longer than MaxFuzzyChars (L12), so the token half holds once the query has
\* a word character and is no longer than that.
KeepsTokenMatches ==
    (DHasWord(q) /\ Len(DTrim(q)) <= MaxFuzzyChars /\ \A w \in DWords(DTrim(q)) : \E i \in 1..Len(fs) : DContains(fs[i].text, w))
        => Matches(q, fs)

\* L10: a query of only punctuation matches exactly the items with a field
\* that holds it as typed.
PunctuationMatchesAsTyped ==
    (DTrim(q) # <<>> /\ ~DHasWord(q))
        => (Matches(q, fs) <=> \E i \in 1..Len(fs) : DContains(fs[i].text, DTrim(q)))

\* L12: a query longer than MaxFuzzyChars matches exactly the items with a
\* field that holds it as typed.
LongQueriesMatchAsTyped ==
    Len(DTrim(q)) > MaxFuzzyChars
        => (Matches(q, fs) <=> \E i \in 1..Len(fs) : DContains(fs[i].text, DTrim(q)))

\* A limit small enough for a config's short queries to cross (R12), bound
\* with `MaxFuzzyChars <- SmallFuzzyLimit`.
SmallFuzzyLimit == 2

\* L4.
FoldAll(s) == [i \in DOMAIN s |-> DFold(s[i])]
UpperAll(s) == [i \in DOMAIN s |->
                  IF \E k \in 1..26 : LowerLetters[k] = s[i]
                  THEN UpperLetters[CHOOSE k \in 1..26 : LowerLetters[k] = s[i]]
                  ELSE s[i]]
CaseInsensitive ==
    /\ Match(FoldAll(q), fs) = Match(q, fs)
    /\ Match(UpperAll(q), fs) = Match(q, fs)
    /\ Match(q, [i \in 1..Len(fs) |-> [fs[i] EXCEPT !.text = UpperAll(@)]]) = Match(q, fs)

\* L5.
TextNeverFuzzy ==
    (\A i \in 1..Len(fs) : fs[i].kind = "text") /\ (\E i \in 1..Len(DTrim(q)) : DIsWord(DTrim(q)[i]))
        => Match(q, fs).tier \in {"substring", "words", "none"}

\* L6.
Without(s, i) == SubSeq(s, 1, i - 1) \o SubSeq(s, i + 1, Len(s))
MoreFieldsNeverWorse ==
    Len(fs) > 1 => \A i \in 1..Len(fs) : TierRank[Match(q, Without(fs, i)).tier] <= TierRank[Match(q, fs).tier]

FieldOrderOnlyMovesIndex ==
    (Len(fs) = 2 /\ fs[1].kind = fs[2].kind) => Match(q, <<fs[2], fs[1]>>).tier = Match(q, fs).tier

=============================================================================
