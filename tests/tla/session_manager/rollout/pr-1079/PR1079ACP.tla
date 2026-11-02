----------------------------- MODULE PR1079ACP -----------------------------
EXTENDS Naturals, Sequences
CONSTANT MaxTurns, Keys
VARIABLES phase, exists, full, context, replay, workspace, savedWorkspace,
          settings, savedSettings, loaded, backend
vars == <<phase, exists, full, context, replay, workspace, savedWorkspace,
          settings, savedSettings, loaded, backend>>
TypeOK == /\ phase \in {"lazy", "active", "down"} /\ exists \in BOOLEAN
          /\ full \in Seq(1..MaxTurns) /\ context \in Seq(1..MaxTurns)
          /\ replay \in Seq(1..MaxTurns) /\ workspace \in {"a", "b"}
          /\ savedWorkspace \in {"a", "b"} /\ settings \in [Keys -> 0..2]
          /\ savedSettings \in [Keys -> 0..2] /\ loaded \in BOOLEAN /\ backend \in {"v1", "v2"}
Init == /\ phase = "lazy" /\ exists = FALSE /\ full = <<>> /\ context = <<>> /\ replay = <<>>
        /\ workspace = "a" /\ savedWorkspace = "a" /\ settings = [k \in Keys |-> 0]
        /\ savedSettings = settings /\ loaded = FALSE /\ backend \in {"v1", "v2"}
SetPreference(k,v) == /\ phase # "down" /\ settings' = [settings EXCEPT ![k] = v]
                      /\ savedSettings' = IF exists THEN [savedSettings EXCEPT ![k] = v] ELSE savedSettings
                      /\ UNCHANGED <<phase, exists, full, context, replay, workspace, savedWorkspace, loaded, backend>>
Prompt == /\ phase # "down" /\ Len(full) < MaxTurns /\ phase' = "active" /\ exists' = TRUE
          /\ full' = Append(full, Len(full) + 1) /\ context' = Append(context, Len(full) + 1)
          /\ savedWorkspace' = workspace /\ savedSettings' = settings /\ loaded' = FALSE
          /\ UNCHANGED <<replay, workspace, settings, backend>>
Compact == /\ phase = "active" /\ Len(context) > 1
           /\ context' = SubSeq(context, Len(context), Len(context))
           /\ UNCHANGED <<phase, exists, full, replay, workspace, savedWorkspace, settings, savedSettings, loaded, backend>>
Crash == /\ phase # "down" /\ phase' = "down" /\ loaded' = FALSE /\ replay' = <<>>
         /\ settings' = [k \in Keys |-> 0]
         /\ UNCHANGED <<exists, full, context, workspace, savedWorkspace, savedSettings, backend>>
Load(w) == /\ exists /\ phase = "down" /\ phase' = "active" /\ loaded' = TRUE
           /\ replay' = full /\ settings' = savedSettings
           /\ workspace' = w /\ savedWorkspace' = w
           /\ UNCHANGED <<exists, full, context, savedSettings, backend>>
Next == (\E k \in Keys, v \in 0..2 : SetPreference(k,v)) \/ Prompt \/ Compact \/ Crash
        \/ (\E w \in {"a", "b"} : Load(w)) \/ UNCHANGED vars
Spec == Init /\ [][Next]_vars
LazyMeansNoSession == ~exists => full = <<>>
ReplayWholeHistory == loaded => replay = full
LoadRestoresSettings == loaded => settings = savedSettings
WorkspaceImmediatelyIndexed == exists /\ phase # "down" => workspace = savedWorkspace
=============================================================================
