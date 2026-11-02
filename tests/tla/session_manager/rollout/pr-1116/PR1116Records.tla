--------------------------- MODULE PR1116Records ---------------------------
EXTENDS Naturals, FiniteSets
CONSTANT Records, Keys
VARIABLES up, live, bodies, index, acknowledged, memorySettings, diskSettings,
          loaded, forked, forkIndex, forkBodies
vars == <<up, live, bodies, index, acknowledged, memorySettings, diskSettings,
          loaded, forked, forkIndex, forkBodies>>
TypeOK == /\ up \in BOOLEAN /\ live \in BOOLEAN /\ bodies \subseteq Records /\ index \subseteq Records
          /\ acknowledged \subseteq Records /\ memorySettings \in [Keys -> 0..1]
          /\ diskSettings \in [Keys -> 0..1] /\ loaded \in BOOLEAN /\ forked \in BOOLEAN
          /\ forkIndex \subseteq Records /\ forkBodies \subseteq Records
Init == /\ up = TRUE /\ live = TRUE /\ bodies = {} /\ index = {} /\ acknowledged = {}
        /\ memorySettings = [k \in Keys |-> 0] /\ diskSettings = memorySettings /\ loaded = FALSE
        /\ forked = FALSE /\ forkIndex = {} /\ forkBodies = {}
PutRecord(r) == /\ up /\ live /\ bodies' = bodies \cup {r}
                /\ UNCHANGED <<up, live, index, acknowledged, memorySettings, diskSettings, loaded, forked, forkIndex, forkBodies>>
PublishIndex(r) == /\ up /\ live /\ r \in bodies /\ index' = index \cup {r}
                   /\ acknowledged' = acknowledged \cup {r}
                   /\ UNCHANGED <<up, live, bodies, memorySettings, diskSettings, loaded, forked, forkIndex, forkBodies>>
SetClient(k,v) == /\ up /\ live /\ memorySettings' = [memorySettings EXCEPT ![k] = v]
                  /\ diskSettings' = [diskSettings EXCEPT ![k] = v]
                  /\ UNCHANGED <<up, live, bodies, index, acknowledged, loaded, forked, forkIndex, forkBodies>>
Fork == /\ up /\ live /\ ~forked /\ forked' = TRUE /\ forkIndex' = index /\ forkBodies' = bodies
        /\ UNCHANGED <<up, live, bodies, index, acknowledged, memorySettings, diskSettings, loaded>>
DeleteSource == /\ forked /\ live /\ live' = FALSE /\ bodies' = {} /\ index' = {}
                /\ UNCHANGED <<up, acknowledged, memorySettings, diskSettings, loaded, forked, forkIndex, forkBodies>>
Crash == /\ up /\ up' = FALSE /\ loaded' = FALSE /\ memorySettings' = [k \in Keys |-> 0]
         /\ UNCHANGED <<live, bodies, index, acknowledged, diskSettings, forked, forkIndex, forkBodies>>
Resume == /\ ~up /\ up' = TRUE /\ loaded' = TRUE /\ memorySettings' = diskSettings
          /\ UNCHANGED <<live, bodies, index, acknowledged, diskSettings, forked, forkIndex, forkBodies>>
Next == (\E r \in Records : PutRecord(r) \/ PublishIndex(r))
        \/ (\E k \in Keys, v \in 0..1 : SetClient(k,v)) \/ Fork \/ DeleteSource \/ Crash \/ Resume \/ UNCHANGED vars
Spec == Init /\ [][Next]_vars
RecordIndexHasBodies == live => index \subseteq bodies
AcknowledgedRecordsReadable == live => acknowledged \subseteq index \cap bodies
ClientSettingsRestored == loaded => memorySettings = diskSettings
ForkRecordsIndependent == forkIndex \subseteq forkBodies
=============================================================================
