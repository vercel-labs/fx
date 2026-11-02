------------------------- MODULE PR1116Migration ---------------------------
EXTENDS Naturals, FiniteSets
CONSTANT Handles
VARIABLES up, copying, side, blobs, map, settings, terminal, removed, targetBusy
vars == <<up, copying, side, blobs, map, settings, terminal, removed, targetBusy>>
TypeOK == /\ up \in BOOLEAN /\ copying \in BOOLEAN /\ side \subseteq Handles /\ blobs \subseteq Handles
          /\ map \subseteq Handles /\ settings \in BOOLEAN /\ terminal \in {"side", "new"}
          /\ removed \in BOOLEAN /\ targetBusy \in BOOLEAN
Init == /\ up = TRUE /\ copying = FALSE /\ side = Handles /\ blobs = {} /\ map = {}
        /\ settings = FALSE /\ terminal = "side" /\ removed = FALSE /\ targetBusy \in BOOLEAN
Open == /\ up /\ ~removed /\ copying' = TRUE
        /\ UNCHANGED <<up, side, blobs, map, settings, terminal, removed, targetBusy>>
Put(h) == /\ up /\ copying /\ h \in side /\ blobs' = blobs \cup {h}
          /\ UNCHANGED <<up, copying, side, map, settings, terminal, removed, targetBusy>>
PublishMapAndSettings == /\ up /\ copying /\ blobs = Handles /\ ~settings
                        /\ map' = Handles /\ settings' = TRUE
                        /\ UNCHANGED <<up, copying, side, blobs, terminal, removed, targetBusy>>
MoveTerminal == /\ up /\ copying /\ settings /\ terminal = "side" /\ ~targetBusy
                /\ terminal' = "new"
                /\ UNCHANGED <<up, copying, side, blobs, map, settings, removed, targetBusy>>
RemoveSide == /\ up /\ copying /\ settings /\ terminal = "new"
              /\ side' = {} /\ removed' = TRUE /\ copying' = FALSE
              /\ UNCHANGED <<up, blobs, map, settings, terminal, targetBusy>>
ClearConflict == /\ targetBusy /\ targetBusy' = FALSE
                 /\ UNCHANGED <<up, copying, side, blobs, map, settings, terminal, removed>>
Crash == /\ up /\ up' = FALSE /\ copying' = FALSE
         /\ UNCHANGED <<side, blobs, map, settings, terminal, removed, targetBusy>>
Resume == /\ ~up /\ up' = TRUE
          /\ UNCHANGED <<copying, side, blobs, map, settings, terminal, removed, targetBusy>>
Next == Open \/ (\E h \in Handles : Put(h)) \/ PublishMapAndSettings \/ MoveTerminal
        \/ RemoveSide \/ ClearConflict \/ Crash \/ Resume \/ UNCHANGED vars
Spec == Init /\ [][Next]_vars
EveryOldHandleResolvable == \A h \in Handles : h \in side \/ (h \in map /\ h \in blobs)
MapReferencesDurableBlobs == map \subseteq blobs
SettingsTogether == settings => map = Handles
TerminalNeverLost == removed => terminal = "new"
=============================================================================
