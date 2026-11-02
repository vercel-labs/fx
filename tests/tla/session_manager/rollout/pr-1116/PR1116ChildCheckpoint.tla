---------------------- MODULE PR1116ChildCheckpoint ------------------------
EXTENDS Naturals
CONSTANT MaxWork
VARIABLES up, work, parentRecord, childTurn, effectStarted, ended, outcome
vars == <<up, work, parentRecord, childTurn, effectStarted, ended, outcome>>
TypeOK == /\ up \in BOOLEAN /\ work \in 0..MaxWork /\ parentRecord \in BOOLEAN
          /\ childTurn \in BOOLEAN /\ effectStarted \in BOOLEAN /\ ended \in BOOLEAN
          /\ outcome \in {"none", "ok", "interrupted", "lost"}
Init == /\ up = TRUE /\ work = 0 /\ parentRecord = FALSE /\ childTurn = FALSE
        /\ effectStarted = FALSE /\ ended = FALSE /\ outcome = "none"
Spawn == /\ up /\ ~parentRecord /\ work < MaxWork /\ work' = work + 1 /\ parentRecord' = TRUE
         /\ childTurn' = FALSE /\ effectStarted' = FALSE /\ ended' = FALSE /\ outcome' = "none"
         /\ UNCHANGED up
SaveTurn == /\ up /\ parentRecord /\ ~ended /\ childTurn' = TRUE
            /\ UNCHANGED <<up, work, parentRecord, effectStarted, ended, outcome>>
Execute == /\ up /\ parentRecord /\ childTurn /\ ~ended /\ effectStarted' = TRUE
           /\ UNCHANGED <<up, work, parentRecord, childTurn, ended, outcome>>
Finish == /\ up /\ parentRecord /\ childTurn /\ effectStarted /\ ~ended
          /\ ended' = TRUE /\ outcome' = "ok"
          /\ UNCHANGED <<up, work, parentRecord, childTurn, effectStarted>>
Crash == /\ up /\ up' = FALSE
         /\ UNCHANGED <<work, parentRecord, childTurn, effectStarted, ended, outcome>>
Resume == /\ ~up /\ up' = TRUE
          /\ ended' = IF parentRecord THEN TRUE ELSE ended
          /\ outcome' = IF parentRecord /\ ~ended THEN IF childTurn THEN "interrupted" ELSE "lost" ELSE outcome
          /\ UNCHANGED <<work, parentRecord, childTurn, effectStarted>>
NextWork == /\ up /\ parentRecord /\ ended /\ parentRecord' = FALSE /\ childTurn' = FALSE
            /\ effectStarted' = FALSE /\ ended' = FALSE /\ outcome' = "none"
            /\ UNCHANGED <<up, work>>
Next == Spawn \/ SaveTurn \/ Execute \/ Finish \/ Crash \/ Resume \/ NextWork \/ UNCHANGED vars
Spec == Init /\ [][Next]_vars
CheckpointBeforeEffects == effectStarted => childTurn
ExecutedWorkNeverLost == effectStarted => outcome # "lost"
LostOnlyBeforeTurn == outcome = "lost" => ~childTurn
=============================================================================
