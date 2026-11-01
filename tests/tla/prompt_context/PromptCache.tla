---------------------------- MODULE PromptCache ----------------------------
(***************************************************************************)
(* How fx lays out a model request and how an explicit-caching provider    *)
(* (Anthropic through AI Gateway with providerOptions.gateway.caching =    *)
(* "auto") reuses it across steps, turns, sessions, worktrees and repos.   *)
(*                                                                         *)
(* fx side: src/core/agent/runtime/orchestrator.zig appendStablePromptContext *)
(* builds the stable instructions, the per-step overlay follows them, and  *)
(* src/core/agent/runtime/prompt_context.zig buildProviderPrompt puts the  *)
(* history after both. src/gateway/vercel_protocol.zig sends the request.  *)
(*                                                                         *)
(* Provider side, as AI Gateway documents automatic caching and as live    *)
(* measurements through it confirmed:                                      *)
(*   - the cached prefix is tools, then system, then messages;             *)
(*   - an entry is written only at a breakpoint, covering the prefix up to *)
(*     and including that block;                                           *)
(*   - a request reads the longest written entry that is a prefix of it    *)
(*     and ends at or before one of its breakpoints;                       *)
(*   - with caching "auto" the Gateway marks the last message and the      *)
(*     message before the last user message (the last system message on a  *)
(*     first request);                                                     *)
(*   - at most Limit blocks may carry a marker (Anthropic: 4).             *)
(*                                                                         *)
(* Design = "proposed" is fx: one marker after the repo-independent        *)
(* instructions (MarkProfile) and one at the end of the stable             *)
(* instructions, before the per-step overlay (MarkStable). Design =        *)
(* "current" is fx before those markers. Mutation plants known-bad         *)
(* designs:                                                                *)
(*   "mark_every_system"   the design fx had before a0b393743: a marker on *)
(*                         every stable system message;                    *)
(*   "fence_after_context" the stable marker placed after the turn context;*)
(*   "no_auto"             the manual markers without caching "auto".      *)
(*                                                                         *)
(* Family = "openai" models OpenAI GPT-5.6 and later instead, as OpenAI's  *)
(* prompt caching guide documents and live measurements through AI Gateway *)
(* confirmed:                                                              *)
(*   - implicit mode writes at the latest eligible message (a user message *)
(*     or the last tool result of a step), and the request's explicit      *)
(*     breakpoints write too;                                              *)
(*   - the end of the leading developer block is reused with no marker, so *)
(*     the model writes an entry there too; of the two rules that fit the  *)
(*     measurements, this one never grants a read the other would deny;    *)
(*   - a read needs an entry ending exactly at a lookup candidate: an      *)
(*     explicit or the implicit breakpoint, an earlier eligible message    *)
(*     ending, or the end of the leading developer block;                  *)
(*   - Mutation "no_auto" there is explicit-only mode: no implicit or      *)
(*     developer-block write, and only explicit breakpoints are looked up; *)
(*   - at most Limit breakpoints per request, the implicit one included    *)
(*     (OpenAI: 4).                                                        *)
(*                                                                         *)
(* Design = "current" with Family = "openai" also models the families fx   *)
(* sends no markers to, whose provider caches prefixes by itself: Grok,    *)
(* GLM, Kimi, Gemini, DeepSeek and MiniMax.                               *)
(*                                                                         *)
(* PathScoped = FALSE is fx: the skill catalog and the project rules name  *)
(* workspace paths relative to the workspace root, so worktrees of one     *)
(* repository send the same bytes there. TRUE models absolute paths, fx    *)
(* before that change; mutant-absolute-paths.cfg keeps it failing.         *)
(*                                                                         *)
(* Events lists the mid-session events a behavior may contain: "switch"    *)
(* (the agent switches branches during a tool step), "deliver" (a tool     *)
(* step reaches a folder with its own AGENTS.md, so fx delivers its scoped *)
(* rules) and "skill" (a user turn names a skill). Notes = FALSE is fx     *)
(* before P6: delivered rules are appended to the stable instructions for  *)
(* that turn and move into them on the next turn, a named skill sits in    *)
(* the overlay for its turn only, and a branch switch rewrites the turn    *)
(* context. With Notes = TRUE the instructions stay as the session         *)
(* started, and Carrier says where a change goes:                          *)
(*   "message"  on the message that caused it: the tool result of the step *)
(*              that reached the rules or switched the branch, or the user *)
(*              message that named the skill. The fixed instructions say   *)
(*              what such a block is. This is fx for delivered rules       *)
(*              (src/core/agent/stream_provider.zig carryContextNotes).    *)
(*   "note"     a system message of its own after the latest message, the  *)
(*              design fx had before. Two measured provider facts make it  *)
(*              fail: through AI Gateway, Claude reads no further than the *)
(*              instructions when a note sits right before a user message, *)
(*              and on OpenAI a note is not an eligible message, so it is  *)
(*              cached only after the next one.                            *)
(* At the end of a skill turn the skill text is swapped for a short note.  *)
(* Event "remind" is a tool step in a later turn that reaches a folder      *)
(* whose rules an earlier turn delivered: fx appends a one-line reminder   *)
(* to that step's tool result (src/builtins/context.zig                    *)
(* renderRuleReminders), at most once per folder per turn.                 *)
(* Mutation "note_not_saved" drops each change at the next user turn, as   *)
(* if it were not saved with the session. Mutation "contract_late" adds    *)
(* the fixed contract to the instructions only once rules arrive.          *)
(* Mutation "remind_old_result" adds the reminder to the tool result that  *)
(* carried the rules instead of the step's own result.                     *)
(* Event "resume" is the first user turn after fx restarted, when the      *)
(* restored history names shell handles the new process does not own: fx  *)
(* tells the model once, on that turn's user message                       *)
(* (src/core/agent/runtime/orchestrator.zig, session.zig                   *)
(* stale_shell_handles_note). Mutation "stale_in_instructions" is fx       *)
(* before that: the notice joins the runtime block of the instructions     *)
(* and stays there.                                                        *)
(* Event "outside" is a user turn after the runtime context changed        *)
(* outside the session's own tool steps: the date rolled over, the branch  *)
(* was switched outside fx, or the permission mode or workspace            *)
(* directories changed. With Notes the turn context and runtime block stay *)
(* as the session started, saved with the session, and a change the model  *)
(* has not seen rides on the message where fx noticed it: that turn's user *)
(* message, or the tool result of a step that switched the branch          *)
(* (src/core/agent/runtime/orchestrator.zig runtime context update).       *)
(* Mutation "overlay_rebuilt" is fx before that: the turn context and      *)
(* runtime block follow the current values on every request. Mutation      *)
(* "overlay_not_saved" freezes them but recaptures them when fx restarts.  *)
(*                                                                         *)
(* Abstraction: a block is a [k, v] record; equal v means equal bytes.     *)
(* Tokens, cache lifetime, eviction and the provider's 20-block lookback   *)
(* window are not modeled: every modeled request is shorter than the       *)
(* window and every request happens inside the cache lifetime.             *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
  Design,       \* "current" | "proposed"
  Mutation,     \* "none" | "mark_every_system" | "fence_after_context" | "no_auto"
  Worktrees,    \* worktree ids
  RepoOf,       \* [Worktrees -> repository ids]
  MaxSessions,  \* sessions started in one behavior
  MaxSteps,     \* model requests after the first in one session
  Limit,        \* blocks per request that may carry a cache marker
  PathScoped,   \* skill catalog and project rules embed the worktree path
  Family,       \* "anthropic" | "openai": the provider's cache rules
  Events,       \* mid-session events: a subset of {"switch", "deliver", "skill", "remind", "resume", "outside"}
  Notes,        \* mid-session changes join the conversation, not the instructions
  Carrier       \* "message" | "note": where such a change goes

ASSUME Design \in {"current", "proposed"}
ASSUME Family \in {"anthropic", "openai"}
ASSUME Mutation \in {"none", "mark_every_system", "fence_after_context", "no_auto",
                     "note_not_saved", "contract_late", "remind_old_result",
                     "stale_in_instructions", "overlay_rebuilt", "overlay_not_saved"}
ASSUME Carrier \in {"message", "note"}
ASSUME MaxSessions \in Nat /\ MaxSteps \in Nat /\ Limit \in Nat
ASSUME PathScoped \in BOOLEAN
ASSUME Events \subseteq {"switch", "deliver", "skill", "remind", "resume", "outside"} /\ Notes \in BOOLEAN

Block(k, v) == [k |-> k, v |-> v]

(* Provider prefix order for one request. Every value is a string so TLC   *)
(* compares like with like.                                                *)
(*   tools    tool schemas: the same for one profile and fx version        *)
(*   base     system prompt and custom tool guidance                       *)
(*   skills   skill catalog: lists each root by absolute path              *)
(*   project  AGENTS.md project context, tagged with the file's path       *)
(*   mcp      MCP catalog                                                  *)
(*   ctx      <fx-turn-context>: worktree path, date, branch               *)
(*   rt       permission, verification and response-language notes         *)
(*   scoped   rules from a subfolder AGENTS.md, delivered at tool time     *)
(*   skill    a named skill's text for its turn                            *)
(*   note     a mid-session change after the conversation (Carrier note)   *)
(* A message that carries a change has kind "userc" or "asstc" (Carrier    *)
(* message); the change is part of its bytes.                              *)
Scoped(w) == IF PathScoped THEN w ELSE RepoOf[w]

Stable(w) ==
  << Block("tools", "p"), Block("base", "p"), Block("skills", Scoped(w)),
     Block("project", Scoped(w)), Block("mcp", "p") >>

Overlay(w, br) == << Block("ctx", w \o "@" \o br), Block("rt", "p") >>

Instructions(w, br) == Stable(w) \o Overlay(w, br)

PosProfile == 2   \* last repo-independent block: base
PosStable  == 5   \* last stable block of a session's first request: mcp

(* Where a block kind sits in req. Every request has one of each           *)
(* instruction kind, so positions follow today's mid-session insertions.   *)
PosOf(req, kind) == CHOOSE i \in 1..Len(req) : req[i].k = kind
NInstr(req) == PosOf(req, "rt")

Max(S) == CHOOSE x \in S : \A y \in S : y <= x

UserKinds == {"user", "userc"}
MessageKinds == UserKinds \cup {"asst", "asstc"}

LastUser(req) == Max({i \in 1..Len(req) : req[i].k \in UserKinds})

Manual(req) ==
  CASE Mutation = "mark_every_system" -> {2, 3, 4, PosOf(req, "mcp")}
    [] Design = "current" -> {}
    [] Mutation = "fence_after_context" -> {PosProfile, PosOf(req, "ctx")}
    [] OTHER -> {PosProfile, PosOf(req, "mcp")}

(* OpenAI eligible message endings after the instructions.                 *)
Eligible(req) == {j \in (NInstr(req) + 1)..Len(req) : req[j].k \in MessageKinds}

(* The provider's own breakpoints: Gateway caching "auto" for Anthropic,   *)
(* the implicit breakpoint for OpenAI, at the latest eligible message.     *)
Auto(req) ==
  CASE Mutation = "no_auto" -> {}
    [] Family = "anthropic" -> {Len(req), LastUser(req) - 1}
    [] OTHER -> {Max(Eligible(req) \cup {NInstr(req)})}

(* Breakpoints of req when its manual markers are man.                     *)
BpsWith(req, man) == man \cup Auto(req)

Breakpoints(req) == BpsWith(req, Manual(req))

(* Positions where req leaves a cache entry.                               *)
WritesWith(req, man) ==
  IF Family = "openai" /\ Mutation # "no_auto"
  THEN BpsWith(req, man) \cup {NInstr(req)}
  ELSE BpsWith(req, man)

(* Anthropic: the longest written entry that is a prefix of req and ends at *)
(* or before one of its breakpoints.                                        *)
Hit(req, bps, c) ==
  IF bps = {} THEN 0 ELSE
    LET found == {n \in 1..Max(bps) : SubSeq(req, 1, n) \in c}
    IN IF found = {} THEN 0 ELSE Max(found)

(* OpenAI: the longest written entry that ends exactly at a lookup          *)
(* candidate of req.                                                        *)
Candidates(req, man) ==
  IF Mutation = "no_auto" THEN man
  ELSE BpsWith(req, man) \cup Eligible(req) \cup {NInstr(req)}

Lookup(req, man, c) ==
  LET found == {n \in Candidates(req, man) : SubSeq(req, 1, n) \in c}
  IN IF found = {} THEN 0 ELSE Max(found)

(* Measured through AI Gateway: when a note sits right before a user       *)
(* message, Claude reads no further than the instructions.                  *)
NoteBeforeUser(req) ==
  \E i \in 1..(Len(req) - 1) : req[i].k = "note" /\ req[i + 1].k \in UserKinds

(* How much of req the provider reads from cache c.                        *)
ReadWith(req, man, c) ==
  IF Family = "anthropic"
  THEN LET h == Hit(req, BpsWith(req, man), c)
       IN IF NoteBeforeUser(req) /\ h > NInstr(req) THEN NInstr(req) ELSE h
  ELSE Lookup(req, man, c)

VARIABLES cache, sessions, active, log, branchOf
vars == <<cache, sessions, active, log, branchOf>>

NoSession == [on |-> FALSE, w |-> "none", s |-> 0, n |-> 0, br |-> "b1", br0 |-> "b1",
              hist |-> <<>>, last |-> <<>>, switched |-> FALSE, delivered |-> FALSE,
              skilled |-> FALSE, scopedTurn |-> FALSE, scopedStable |-> FALSE,
              skill |-> FALSE, skillUser |-> 0, skillText |-> 0,
              carrierAt |-> 0, remindable |-> FALSE, reminded |-> FALSE,
              resumed |-> FALSE, stale |-> FALSE, out |-> FALSE, out0 |-> FALSE]

(* Whether the request's turn context and runtime block show the outside  *)
(* change, and which branch they show.                                    *)
OutInLead(a) == IF ~Notes \/ Mutation = "overlay_rebuilt" THEN a.out ELSE a.out0
LeadBranch(a) == IF ~Notes \/ Mutation = "overlay_rebuilt" THEN a.br ELSE a.br0

(* The runtime block: the stale-shell notice where fx had it, and the      *)
(* outside change when the block shows it.                                *)
WithRt(a, lead) ==
  IF a.stale \/ OutInLead(a)
  THEN [lead EXCEPT ![PosOf(lead, "rt")] =
          Block("rt", "p" \o (IF a.stale THEN "+stale" ELSE "")
                          \o (IF OutInLead(a) THEN "+out" ELSE ""))]
  ELSE lead

LeadBlocks(a) ==
  IF Notes THEN
    IF Mutation = "contract_late" /\ a.delivered
    THEN [Instructions(a.w, LeadBranch(a)) EXCEPT ![2] = Block("base", "p+contract")]
    ELSE Instructions(a.w, LeadBranch(a))
  ELSE SubSeq(Stable(a.w), 1, 4)
         \o (IF a.scopedStable THEN << Block("scoped", Scoped(a.w)) >> ELSE << >>)
         \o << Block("mcp", "p") >>
         \o (IF a.scopedTurn THEN << Block("scoped", Scoped(a.w)) >> ELSE << >>)
         \o (IF a.skill THEN << Block("skill", "k") >> ELSE << >>)
         \o Overlay(a.w, LeadBranch(a))

(* The instructions of session a's next request. With Notes they stay as   *)
(* the session started; otherwise they carry today's mid-session           *)
(* insertions.                                                             *)
Lead(a) == WithRt(a, LeadBlocks(a))

(* The end of prev without the notes after its last message: what the next *)
(* request must read. A trailing note is cheap, and OpenAI caches it only  *)
(* after the next eligible message.                                        *)
LastKept(prev) ==
  Max({i \in 1..Len(prev) : prev[i].k \notin {"note", "skilltext"}} \cup {0})

Init ==
  /\ cache = {}
  /\ sessions = 0
  /\ active = NoSession
  /\ log = <<>>
  /\ branchOf = [w \in Worktrees |-> "b1"]

(* Send one request and record what the provider read.                     *)
Send(w, s, req, first, prev, changed, keep) ==
  LET bps == Breakpoints(req)
  IN /\ cache' = cache \cup {SubSeq(req, 1, n) : n \in WritesWith(req, Manual(req))}
     /\ log' = Append(log, [w |-> w, s |-> s, first |-> first, req |-> req, bps |-> bps,
                            read |-> ReadWith(req, Manual(req), cache), prev |-> prev, changed |-> changed,
                            keep |-> keep,
                            repoSeen |-> \E i \in 1..Len(log) : RepoOf[log[i].w] = RepoOf[w],
                            worktreeSeen |-> \E i \in 1..Len(log) : log[i].w = w,
                            anySeen |-> Len(log) > 0])

(* A session starts on the branch its worktree was left on.                 *)
Start(w) ==
  LET s == sessions + 1
      br == branchOf[w]
      hist == << Block("user", ToString(s) \o ".0") >>
      a == [NoSession EXCEPT !.on = TRUE, !.w = w, !.s = s, !.br = br, !.br0 = br,
                             !.hist = hist]
      req == Lead(a) \o hist
  IN /\ ~active.on
     /\ sessions < MaxSessions
     /\ sessions' = s
     /\ active' = [a EXCEPT !.last = req]
     /\ Send(w, s, req, TRUE, <<>>, FALSE, 0)
     /\ UNCHANGED branchOf

(* A message without the change it carried.                               *)
Uncarried(b) ==
  CASE b.k = "asstc" -> Block("asst", b.v)
    [] b.k = "userc" -> Block("user", b.v)
    [] OTHER -> b

(* The next request of the session. "step" is a tool step and "turn" a new *)
(* user turn; "switch", "deliver", "skill", "remind", "resume" and         *)
(* "outside" are the events in Events, described above. Each event happens *)
(* at most once per session, and "remind" only after a user turn that      *)
(* followed the delivery. Before P6 (Notes = FALSE) the rules sit in the   *)
(* instructions and "remind" is a plain step; there, as with mutation      *)
(* "stale_in_instructions", "resume" puts the notice in the instructions,  *)
(* and as with mutation "overlay_rebuilt", "switch" and "outside" change   *)
(* the turn context or runtime block ahead of the history.                 *)
Continue(kind) ==
  LET a == active
      n == a.n + 1
      isTurn == kind \in {"turn", "skill", "resume", "outside"}
      staleInLead == kind = "resume" /\ (~Notes \/ Mutation = "stale_in_instructions")
      \* The change shows up ahead of the history instead of on a message.
      inLead == staleInLead \/ (kind \in {"switch", "outside"} /\ (~Notes \/ Mutation = "overlay_rebuilt"))
      event == kind \in {"switch", "deliver", "skill", "resume", "outside"} \/ (kind = "remind" /\ Notes)
      carried == Notes /\ Carrier = "message"
      recapture == kind = "resume" /\ Mutation = "overlay_not_saved"
      misplaced == kind = "remind" /\ carried /\ Mutation = "remind_old_result"
      br == IF kind = "switch" THEN "b2" ELSE a.br
      swapped == IF isTurn /\ Notes /\ a.skillText > 0
                 THEN [a.hist EXCEPT ![a.skillText] =
                         IF carried THEN Block("userc", @.v \o "short")
                         ELSE Block("skillnote", "k")]
                 ELSE a.hist
      kept == IF isTurn /\ Notes /\ Mutation = "note_not_saved"
              THEN IF carried THEN [i \in 1..Len(swapped) |-> Uncarried(swapped[i])]
                   ELSE SelectSeq(swapped, LAMBDA b : b.k # "note")
              ELSE swapped
      reminded == IF misplaced
                  THEN [kept EXCEPT ![a.carrierAt] = Block(@.k, @.v \o "+remind")]
                  ELSE kept
      msgKind == CASE isTurn /\ carried /\ event /\ ~inLead -> "userc"
                   [] isTurn -> "user"
                   [] carried /\ event /\ ~misplaced /\ ~inLead -> "asstc"
                   [] OTHER -> "asst"
      withMsg == Append(reminded, Block(msgKind, ToString(a.s) \o "." \o ToString(n)))
      hist == CASE ~Notes \/ carried -> withMsg
                [] kind = "switch" /\ ~inLead -> Append(withMsg, Block("note", "branch"))
                [] kind = "deliver" -> Append(withMsg, Block("note", "scoped"))
                [] kind = "skill" -> Append(withMsg, Block("skilltext", "k"))
                [] kind = "remind" -> Append(withMsg, Block("note", "remind"))
                [] kind = "resume" /\ ~staleInLead -> Append(withMsg, Block("note", "stale"))
                [] kind = "outside" /\ ~inLead -> Append(withMsg, Block("note", "outside"))
                [] OTHER -> withMsg
      next == [a EXCEPT !.n = n, !.br = br, !.hist = hist,
                        !.switched = a.switched \/ kind = "switch",
                        !.delivered = a.delivered \/ kind = "deliver",
                        !.skilled = a.skilled \/ kind = "skill",
                        !.scopedStable = a.scopedStable \/ (isTurn /\ a.scopedTurn),
                        !.scopedTurn = (IF isTurn THEN FALSE
                                        ELSE a.scopedTurn \/ (~Notes /\ kind = "deliver")),
                        !.skill = (IF isTurn THEN ~Notes /\ kind = "skill" ELSE a.skill),
                        !.skillUser = (IF kind = "skill" THEN Len(withMsg)
                                       ELSE IF isTurn THEN 0 ELSE a.skillUser),
                        !.skillText = (IF Notes /\ kind = "skill" THEN Len(hist)
                                       ELSE IF isTurn THEN 0 ELSE a.skillText),
                        !.carrierAt = (IF kind = "deliver" /\ carried THEN Len(withMsg)
                                       ELSE a.carrierAt),
                        !.remindable = a.remindable \/ (isTurn /\ a.delivered),
                        !.reminded = a.reminded \/ kind = "remind",
                        !.resumed = a.resumed \/ kind = "resume",
                        !.stale = a.stale \/ staleInLead,
                        !.out = a.out \/ kind = "outside",
                        !.br0 = IF recapture THEN a.br ELSE a.br0,
                        !.out0 = IF recapture THEN a.out ELSE a.out0]
      req == Lead(next) \o hist
      \* On the turn after a named skill, only the history before that turn's
      \* user message must be read.
      keep == IF isTurn /\ a.skillUser > 0
              THEN Len(a.last) - Len(a.hist) + a.skillUser - 1
              ELSE LastKept(a.last)
  IN /\ a.on
     /\ a.n < MaxSteps
     /\ kind \in {"switch", "deliver", "skill", "remind", "resume", "outside"} => kind \in Events
     /\ kind = "switch" => ~a.switched
     /\ kind = "deliver" => ~a.delivered
     /\ kind = "skill" => ~a.skilled
     /\ kind = "remind" => a.remindable /\ ~a.reminded
     /\ kind = "resume" => ~a.resumed
     /\ kind = "outside" => ~a.out
     /\ active' = [next EXCEPT !.last = req]
     /\ Send(a.w, a.s, req, FALSE, a.last, event, keep)
     /\ branchOf' = [branchOf EXCEPT ![a.w] = br]
     /\ UNCHANGED sessions

End ==
  /\ active.on
  /\ active' = NoSession
  /\ UNCHANGED <<cache, sessions, log, branchOf>>

(* The user switches a worktree's branch outside fx between sessions: the  *)
(* next session's turn context differs with no request in between.         *)
ExternalSwitch(w) ==
  /\ ~active.on
  /\ branchOf[w] = "b1"
  /\ branchOf' = [branchOf EXCEPT ![w] = "b2"]
  /\ UNCHANGED <<cache, sessions, active, log>>

Next ==
  \/ \E w \in Worktrees : Start(w)
  \/ \E kind \in {"step", "turn", "switch", "deliver", "skill", "remind", "resume", "outside"} : Continue(kind)
  \/ End
  \/ \E w \in Worktrees : ExternalSwitch(w)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------
(* Properties. Each is an invariant over the request log.                   *)

TypeOK ==
  /\ sessions \in 0..MaxSessions
  /\ \A i \in 1..Len(log) : log[i].read \in 0..Len(log[i].req)

(* Never more markers than the provider accepts.                           *)
Budget == \A i \in 1..Len(log) : Cardinality(log[i].bps) <= Limit

(* A new session in a worktree that already ran reads at least the stable  *)
(* instructions, even when the worktree is now on another branch.          *)
SameWorktreeReuse ==
  \A i \in 1..Len(log) : log[i].first /\ log[i].worktreeSeen => log[i].read >= PosStable

(* A new session in a worktree of a repository that already ran reads at    *)
(* least the stable instructions. Needs PathScoped = FALSE.                 *)
WorktreeReuse ==
  \A i \in 1..Len(log) : log[i].first /\ log[i].repoSeen => log[i].read >= PosStable

(* A new session in any repository reads at least the repo-independent part *)
(* once anything has run.                                                   *)
CrossRepoReuse ==
  \A i \in 1..Len(log) : log[i].first /\ log[i].anySeen => log[i].read >= PosProfile

(* Within a session, a request whose instructions did not change reads all  *)
(* of the previous request.                                                 *)
SessionReuse ==
  \A i \in 1..Len(log) : ~log[i].first /\ ~log[i].changed => log[i].read >= Len(log[i].prev)

(* When the turn context changes mid-session, the stable instructions are   *)
(* still read.                                                              *)
ContextChangeKeepsStable ==
  \A i \in 1..Len(log) : log[i].changed => log[i].read >= PosStable

(* When the turn context changes mid-session, the history is still read,   *)
(* except on the turn after a named skill, whose text is swapped for a     *)
(* short note (the exception MidSessionKeepsHistory and PreviousFully-     *)
(* Reused make too; "resume" is the change that can land on that turn).    *)
(* Only the notes design has it; elsewhere the turn context sits ahead of  *)
(* the history, and gap-history.cfg keeps that gap visible.                *)
ContextChangeKeepsHistory ==
  \A i \in 1..Len(log) :
    log[i].changed /\ log[i].keep = LastKept(log[i].prev) => log[i].read >= Len(log[i].prev)

(* Within a session, each request reads all of the previous one except the *)
(* notes at its end, and on the turn after a named skill, all history      *)
(* before that turn's user message. fx today misses it: mid-session        *)
(* changes sit ahead of the history.                                       *)
MidSessionKeepsHistory ==
  \A i \in 1..Len(log) : ~log[i].first => log[i].read >= log[i].keep

(* Within a session, each request reads all of the previous one, changes   *)
(* included, except on the turn after a named skill. The message carrier   *)
(* has it on both families; a note is not an eligible OpenAI message.      *)
PreviousFullyReused ==
  \A i \in 1..Len(log) :
    ~log[i].first /\ log[i].keep = LastKept(log[i].prev) => log[i].read >= Len(log[i].prev)
=============================================================================
