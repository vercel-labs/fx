-------------------------- MODULE ResponseLanguage --------------------------
(***************************************************************************)
(* The response language guard of one root fx turn                         *)
(* (src/core/agent/runtime/response_language.zig, used by the step loop in *)
(* src/core/agent/runtime/orchestrator.zig).                               *)
(*                                                                         *)
(* When a turn starts, fx infers from the prompt the script it expects the *)
(* reply in: Latin, or nothing. After each completed reply it decides. A   *)
(* reply in the expected script, or one whose script is unclear, is kept.  *)
(* A reply in another script with tool calls keeps the calls and drops its *)
(* prose. Any other reply in another script is dropped and replaced once   *)
(* with a correction request; a second one ends the turn without saving    *)
(* it.                                                                     *)
(*                                                                         *)
(* A prompt is a record of what fx can see in it:                          *)
(*   lang    "english" or "other": the language the person wrote in        *)
(*   script  "latin", "nonlatin", or "none" when there is too little text  *)
(*   word    it has an English word the guard trusts, such as "the"        *)
(*   switch  it names a language or asks for a translation in English      *)
(*   accent  it has a Latin letter outside ASCII, such as "ị" or "é"       *)
(*   mark    it has a combining accent after a Latin letter: "ị" stored as *)
(*           "i" and U+0323, which Unicode allows for Vietnamese           *)
(*   cut     it has a UTF-8 lead byte that claims more bytes than remain,  *)
(*           ahead of every accented letter                                *)
(*   bare    it has a clause of three or more words, outside code spans,   *)
(*           with no English function word                                 *)
(*   shared  a bare clause uses a word that English also has, such as      *)
(*           Dutch "we" or Polish "to"                                     *)
(*   stem    a bare clause has an English contraction stem before an       *)
(*           ending that English does not use, such as Turkish "Can'a"     *)
(*           ("can" is English only in "can't")                            *)
(*   space   a bare clause has its words split by a Unicode space, such    *)
(*           as U+00A0, U+202F, or U+3000, not by an ASCII one             *)
(*                                                                         *)
(* Prompts holds what a person can write. A request in another Latin-      *)
(* script language either names its language in English, has an accented   *)
(* letter (with its accent in the letter or stored apart), or has a bare   *)
(* clause: its own words are not English. A request that runs its words    *)
(* into the English with no punctuation between them, whose clauses all    *)
(* have fewer than three words, whose bare clause sits after a stray       *)
(* backtick that makes the rest a code span, or whose only English         *)
(* function words are "the", "that", or a capital "I", breaks that;        *)
(* AllowUnmarked = TRUE adds it, and response-language-limit.cfg shows the *)
(* guard still rejects the reply then.                                     *)
(*                                                                         *)
(* The law is RequestedLanguageAccepted: the expectation follows the       *)
(* request's language, so a request in another language never gets the     *)
(* English expectation, however many English words or shared words it has. *)
(*                                                                         *)
(* Rule picks the inference: "fixed" for fx now, "today" for fx before the *)
(* fix of #809, and "accent_only" for the accented-letter rule alone. Bug  *)
(* plants one defect; check.sh names the rule that must catch each. The    *)
(* defects cut_hides, marks_ignored, and shared_hides are the three flaws  *)
(* of the first fix of #809, and first_cut has all three. The defects      *)
(* stem_hides and space_hides are the two flaws of the second fix, and     *)
(* second_cut has both.                                                    *)
(***************************************************************************)
EXTENDS Naturals, Sequences

CONSTANTS Rule, Bug, MaxRequests, AllowUnmarked

Langs == {"english", "other"}
PromptScripts == {"latin", "nonlatin", "none"}
AllPrompts == [lang : Langs, script : PromptScripts, word : BOOLEAN,
               switch : BOOLEAN, accent : BOOLEAN, mark : BOOLEAN,
               cut : BOOLEAN, bare : BOOLEAN, shared : BOOLEAN,
               stem : BOOLEAN, space : BOOLEAN]
Prompts == {p \in AllPrompts :
              /\ p.cut => (p.accent \/ p.mark)
              /\ p.shared => (p.lang = "other" /\ p.bare)
              /\ p.stem => (p.lang = "other" /\ p.bare)
              /\ p.space => (p.lang = "other" /\ p.bare)
              /\ (p.lang = "other" /\ p.script = "latin" /\ ~p.switch)
                     => (p.accent \/ p.mark \/ p.bare \/ AllowUnmarked)}

\* A reply: the script of its prose, and whether it has tool calls.
Replies == [script : {"latin", "nonlatin", "unclear"}, tools : BOOLEAN]
\* What each request carries: the prompt, tool results, or the correction.
Carries == {"prompt", "tools", "correction"}
\* What fx kept of each reply.
Kept == {"prose", "calls_only", "dropped"}
Outcomes == {"none", "answered", "failed_language"}

VARIABLES
    prompt,     \* the turn's prompt
    expected,   \* the inferred script, "latin" or "none"
    corrected,  \* the turn's one correction was sent
    sent,       \* what each request carried, in order
    replies,    \* each reply, in order; replies[i] answers sent[i]
    kept,       \* what fx kept of each reply
    phase,      \* "waiting" for a reply, or "done"
    outcome     \* how the turn ended

vars == <<prompt, expected, corrected, sent, replies, kept, phase, outcome>>

\* The three flaws of the first fix of #809.
\* cut_hides: the letter scan stopped at a lead byte that claims too many bytes.
CutHides == Bug \in {"cut_hides", "first_cut"}
\* marks_ignored: the letter scan did not count a combining accent.
MarksIgnored == Bug \in {"marks_ignored", "first_cut"}
\* shared_hides: the English word list held words that other languages use.
SharedHides == Bug \in {"shared_hides", "first_cut"}

\* The two flaws of the second fix of #809.
\* stem_hides: a contraction stem counted as English before any ending.
StemHides == Bug \in {"stem_hides", "second_cut"}
\* space_hides: the clause splitter knew only ASCII white space.
SpaceHides == Bug \in {"space_hides", "second_cut"}

\* has_non_ascii_latin_letter: the scan finds an accented letter.
AccentSeen(p) ==
    /\ ~(CutHides /\ p.cut)
    /\ (p.accent \/ (p.mark /\ ~MarksIgnored))

\* has_clause_without_english: some clause is judged to have no English word.
BareSeen(p) ==
    /\ p.bare
    /\ ~(SharedHides /\ p.shared)
    /\ ~(StemHides /\ p.stem)
    /\ ~(SpaceHides /\ p.space)

\* infer_expectation: Latin only for a prompt that reads as English.
Expect(p) ==
    IF /\ Bug # "abstain_all"
       /\ ~p.switch
       /\ p.script = "latin"
       /\ p.word
       /\ (Rule \in {"accent_only", "fixed"} => ~AccentSeen(p))
       /\ (Rule = "fixed" => ~BareSeen(p))
    THEN "latin" ELSE "none"

InitWith(p) ==
    /\ prompt = p
    /\ expected = Expect(p)
    /\ corrected = FALSE
    /\ sent = <<"prompt">>
    /\ replies = <<>>
    /\ kept = <<>>
    /\ phase = "waiting"
    /\ outcome = "none"

Init == \E p \in Prompts : InitWith(p)

\* A fresh turn, for trace validation of several runs in a row.
Reset(p) ==
    /\ prompt' = p
    /\ expected' = Expect(p)
    /\ corrected' = FALSE
    /\ sent' = <<"prompt">>
    /\ replies' = <<>>
    /\ kept' = <<>>
    /\ phase' = "waiting"
    /\ outcome' = "none"

Continue(carry) == /\ sent' = Append(sent, carry)
                   /\ phase' = "waiting"
                   /\ UNCHANGED outcome

Finish(o) == /\ phase' = "done"
             /\ outcome' = o
             /\ UNCHANGED sent

\* decide: a clear reply in a script other than the expected one.
Mismatch(r) == expected = "latin" /\ r.script = "nonlatin"

Reply(r) ==
    /\ phase = "waiting"
    /\ replies' = Append(replies, r)
    /\ UNCHANGED <<prompt, expected>>
    /\ IF ~Mismatch(r)
         THEN /\ kept' = Append(kept, "prose")
              /\ UNCHANGED corrected
              /\ IF r.tools THEN Continue("tools") ELSE Finish("answered")
       \* tools_reject: a reply with tool calls is replaced like one without.
       ELSE IF r.tools /\ Bug # "tools_reject"
         THEN /\ kept' = Append(kept, "calls_only")
              /\ UNCHANGED corrected
              /\ Continue("tools")
       \* retry_twice: the correction is not capped at one per turn.
       ELSE IF ~corrected \/ Bug = "retry_twice"
         THEN /\ kept' = Append(kept, "dropped")
              /\ corrected' = TRUE
              /\ Continue("correction")
       ELSE /\ kept' = Append(kept, "dropped")
            /\ UNCHANGED corrected
            /\ Finish("failed_language")

Ended == phase = "done" /\ UNCHANGED vars

Next == (\E r \in Replies : Reply(r)) \/ Ended

Spec == Init /\ [][Next]_vars

Bounded == Len(sent) <= MaxRequests

-----------------------------------------------------------------------------

TypeOK ==
    /\ prompt \in AllPrompts
    /\ expected \in {"latin", "none"}
    /\ corrected \in BOOLEAN
    /\ sent \in Seq(Carries)
    /\ replies \in Seq(Replies)
    /\ kept \in Seq(Kept)
    /\ Len(kept) = Len(replies)
    /\ phase \in {"waiting", "done"}
    /\ outcome \in Outcomes

\* A prompt that reads as English throughout.
ClearEnglish(p) ==
    /\ p.lang = "english"
    /\ ~p.switch
    /\ p.script = "latin"
    /\ p.word
    /\ ~p.accent
    /\ ~p.mark
    /\ ~p.bare

\* #809: the expectation follows the request's language. fx never expects a
\* script for, and so never rejects the reply to, a request written in another
\* language that shows it, with an accented letter or a bare clause, whatever
\* English it quotes and whichever words it shares with it.
RequestedLanguageAccepted ==
    prompt.lang = "other" =>
        /\ expected = "none"
        /\ outcome # "failed_language"
        /\ \A i \in 1..Len(sent) : sent[i] # "correction"

\* Plain English keeps the guard: fx never keeps prose in another script.
EnglishGuardKept ==
    ClearEnglish(prompt) =>
        \A i \in 1..Len(replies) :
            replies[i].script = "nonlatin" => kept[i] # "prose"

\* At most one correction per turn.
OneCorrection ==
    \A i, j \in 1..Len(sent) :
        (sent[i] = "correction" /\ sent[j] = "correction") => i = j

\* The tool calls of a reply are never thrown away.
CallsKept ==
    \A i \in 1..Len(replies) : replies[i].tools => kept[i] # "dropped"

\* A turn fails for its language only after its one correction.
FailOnlyAfterCorrection ==
    outcome = "failed_language" => \E i \in 1..Len(sent) : sent[i] = "correction"
=============================================================================
