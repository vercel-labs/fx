----------------------------- MODULE PR1072Ask -----------------------------
EXTENDS Naturals, Sequences, FiniteSets
CONSTANT MaxPieces
VARIABLES phase, backend, saving, disk, durable, acknowledged, turn, marker,
          charged, persisted, writes, recovered
vars == <<phase, backend, saving, disk, durable, acknowledged, turn, marker,
          charged, persisted, writes, recovered>>
TypeOK == /\ phase \in {"new", "idle", "turn", "down", "closed"}
          /\ backend \in {"v1", "v2"} /\ saving \in BOOLEAN
          /\ disk \in Seq(1..MaxPieces) /\ durable \in 0..Len(disk)
          /\ acknowledged \in 0..durable /\ turn \in {"none", "open", "interrupted", "committed"}
          /\ marker \in BOOLEAN /\ charged \in 0..MaxPieces
          /\ persisted \in 0..charged /\ writes \subseteq {"v1", "v2"}
          /\ recovered \in BOOLEAN
Init == /\ phase = "new" /\ backend = "v1" /\ saving = TRUE
        /\ disk = <<>> /\ durable = 0 /\ acknowledged = 0 /\ turn = "none"
        /\ marker = FALSE /\ charged = 0 /\ persisted = 0 /\ writes = {} /\ recovered = FALSE
Start(b, save) == /\ phase = "new" /\ phase' = "idle" /\ backend' = b /\ saving' = save
                  /\ UNCHANGED <<disk, durable, acknowledged, turn, marker, charged, persisted, writes, recovered>>
Begin == /\ phase = "idle" /\ phase' = "turn" /\ turn' = "open" /\ recovered' = FALSE
         /\ UNCHANGED <<backend, saving, disk, durable, acknowledged, marker, charged, persisted, writes>>
AppendPiece == /\ phase = "turn" /\ saving /\ Len(disk) < MaxPieces
               /\ disk' = Append(disk, Len(disk) + 1) /\ writes' = writes \cup {backend}
               /\ UNCHANGED <<phase, backend, saving, durable, acknowledged, turn, marker, charged, persisted, recovered>>
Sync == /\ phase = "turn" /\ durable' = Len(disk) /\ acknowledged' = Len(disk)
        /\ UNCHANGED <<phase, backend, saving, disk, turn, marker, charged, persisted, writes, recovered>>
Mark == /\ phase = "turn" /\ marker' = TRUE
        /\ UNCHANGED <<phase, backend, saving, disk, durable, acknowledged, turn, charged, persisted, writes, recovered>>
Charge == /\ phase = "turn" /\ marker /\ charged < MaxPieces /\ charged' = charged + 1
          /\ UNCHANGED <<phase, backend, saving, disk, durable, acknowledged, turn, marker, persisted, writes, recovered>>
Checkpoint == /\ phase = "turn" /\ persisted' = charged
              /\ UNCHANGED <<phase, backend, saving, disk, durable, acknowledged, turn, marker, charged, writes, recovered>>
ClearMarker == /\ persisted = charged /\ marker' = FALSE
               /\ UNCHANGED <<phase, backend, saving, disk, durable, acknowledged, turn, charged, persisted, writes, recovered>>
Commit == /\ phase = "turn" /\ phase' = "closed" /\ turn' = "committed"
          /\ durable' = Len(disk) /\ acknowledged' = Len(disk) /\ persisted' = charged
          /\ UNCHANGED <<backend, saving, disk, marker, charged, writes, recovered>>
Crash == /\ phase \in {"idle", "turn"} /\ phase' = "down" /\ recovered' = FALSE
         /\ disk' = SubSeq(disk, 1, durable)
         /\ UNCHANGED <<backend, saving, durable, acknowledged, turn, marker, charged, persisted, writes>>
Resume == /\ phase = "down" /\ phase' = "idle" /\ recovered' = TRUE
          /\ turn' = IF turn = "open" THEN "interrupted" ELSE turn
          /\ persisted' = charged /\ marker' = FALSE
          /\ UNCHANGED <<backend, saving, disk, durable, acknowledged, charged, writes>>
Next == (\E b \in {"v1", "v2"}, s \in BOOLEAN : Start(b, s)) \/ Begin \/ AppendPiece
        \/ Sync \/ Mark \/ Charge \/ Checkpoint \/ ClearMarker \/ Commit \/ Crash \/ Resume
        \/ UNCHANGED vars
Spec == Init /\ [][Next]_vars
NoSaveNoDisk == ~saving => disk = <<>>
OneBackend == writes \subseteq {backend}
AcknowledgedSurvive == acknowledged <= Len(disk)
NoSilentUsageGap == charged > persisted => marker
RecoveredTurnClosed == recovered => turn # "open"
=============================================================================
