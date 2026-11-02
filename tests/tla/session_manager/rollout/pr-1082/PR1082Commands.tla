-------------------------- MODULE PR1082Commands ---------------------------
EXTENDS Naturals, FiniteSets
CONSTANT Sessions, Children, MaxTurns
VARIABLES live, indexed, deleted, counts, torn, listed, recovered, origin,
          copied, sourceBefore, lastRead, readBefore, orphanFolders, cleaned
vars == <<live, indexed, deleted, counts, torn, listed, recovered, origin,
          copied, sourceBefore, lastRead, readBefore, orphanFolders, cleaned>>
TypeOK == /\ live \subseteq Sessions /\ indexed \subseteq Sessions /\ deleted \subseteq Sessions
          /\ counts \in [Sessions -> 0..MaxTurns] /\ torn \in [Sessions -> BOOLEAN]
          /\ listed \subseteq Sessions /\ recovered \in Sessions \cup {"none"}
          /\ origin \in Sessions \cup {"none"} /\ copied \in 0..MaxTurns
          /\ sourceBefore \in 0..MaxTurns /\ lastRead \in Sessions \cup {"none"}
          /\ readBefore \in 0..MaxTurns /\ orphanFolders \subseteq Sessions /\ cleaned \subseteq Sessions
Init == /\ live \in SUBSET Sessions /\ indexed = live /\ deleted = {}
        /\ counts \in [Sessions -> 0..MaxTurns] /\ torn \in [Sessions -> BOOLEAN]
        /\ listed = {} /\ recovered = "none" /\ origin = "none" /\ copied = 0 /\ sourceBefore = 0
        /\ lastRead = "none" /\ readBefore = 0 /\ orphanFolders = Sessions \ live /\ cleaned = {}
List == /\ listed' = (indexed \cap live) \ (Children \cup deleted)
        /\ UNCHANGED <<live, indexed, deleted, counts, torn, recovered, origin, copied, sourceBefore, lastRead, readBefore, orphanFolders, cleaned>>
Read(s) == /\ s \in live \ Children /\ lastRead' = s /\ readBefore' = counts[s]
           /\ UNCHANGED <<live, indexed, deleted, counts, torn, listed, recovered, origin, copied, sourceBefore, orphanFolders, cleaned>>
Recover(s,t) == /\ recovered = "none" /\ s \in live \ Children /\ counts[s] > 0
                /\ t \in Sessions \ (live \cup deleted \cup Children \cup cleaned) /\ t # s
                /\ recovered' = t /\ origin' = s /\ copied' = counts[s] /\ sourceBefore' = counts[s]
                /\ counts' = [counts EXCEPT ![t] = counts[s]] /\ torn' = [torn EXCEPT ![t] = FALSE]
                /\ live' = live \cup {t} /\ indexed' = indexed \cup {t}
                /\ lastRead' = "none" /\ orphanFolders' = orphanFolders \ {t}
                /\ UNCHANGED <<deleted, listed, readBefore, cleaned>>
Delete(s) == /\ s \in live /\ recovered = "none"
             /\ live' = live \ {s} /\ deleted' = deleted \cup {s} /\ listed' = listed \ {s}
             /\ orphanFolders' = orphanFolders \cup {s} /\ lastRead' = "none"
             /\ UNCHANGED <<indexed, counts, torn, recovered, origin, copied, sourceBefore, readBefore, cleaned>>
Doctor(s) == /\ s \in orphanFolders /\ s \notin live
             /\ orphanFolders' = orphanFolders \ {s} /\ cleaned' = cleaned \cup {s}
             /\ UNCHANGED <<live, indexed, deleted, counts, torn, listed, recovered, origin, copied, sourceBefore, lastRead, readBefore>>
Next == List \/ (\E s \in Sessions : Read(s) \/ Delete(s) \/ Doctor(s))
        \/ (\E s,t \in Sessions : Recover(s,t)) \/ UNCHANGED vars
Spec == Init /\ [][Next]_vars
ListedRootsExist == listed \subseteq live \ Children
NoResurrection == listed \cap deleted = {}
ReadOnlyCounts == lastRead # "none" => counts[lastRead] = readBefore
RecoveryKeepsSource == recovered # "none" => counts[origin] = sourceBefore /\ copied = sourceBefore /\ ~torn[recovered]
DoctorNeverCleansLive == cleaned \cap live = {}
=============================================================================
