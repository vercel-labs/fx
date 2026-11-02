-------------------------------- MODULE Refresh --------------------------------
EXTENDS Naturals, Sequences
CONSTANTS MaxSteps, Guarded
Files == {"a.txt", "b.txt"}
VARIABLES fs, tick, stamp, ignoreB, ignoreEpoch, knownStamp, knownIgnore,
          reusable, snapshot, phase, beforeStamp, beforeIgnore, beforeTick,
          listed, published, history
vars == <<fs, tick, stamp, ignoreB, ignoreEpoch, knownStamp, knownIgnore,
          reusable, snapshot, phase, beforeStamp, beforeIgnore, beforeTick,
          listed, published, history>>
Visible == IF ignoreB THEN fs \ {"b.txt"} ELSE fs
Init == /\ fs = {} /\ tick = 0 /\ stamp = 0
        /\ ignoreB = FALSE /\ ignoreEpoch = 0
        /\ knownStamp = 0 /\ knownIgnore = 0 /\ reusable = FALSE
        /\ snapshot = {} /\ phase = "idle" /\ beforeStamp = 0
        /\ beforeIgnore = 0 /\ beforeTick = 0 /\ listed = {}
        /\ published = FALSE /\ history = <<>>
Edit(p) == /\ fs' = IF p \in fs THEN fs \ {p} ELSE fs \cup {p}
           /\ stamp' = tick /\ published' = FALSE
           /\ history' = Append(history, "Edit:" \o p)
           /\ UNCHANGED <<tick, ignoreB, ignoreEpoch, knownStamp, knownIgnore,
                           reusable, snapshot, phase, beforeStamp,
                           beforeIgnore, beforeTick, listed>>
Tick == /\ tick < 2 /\ tick' = tick + 1 /\ published' = FALSE
        /\ history' = Append(history, "Tick")
        /\ UNCHANGED <<fs, stamp, ignoreB, ignoreEpoch, knownStamp, knownIgnore,
                        reusable, snapshot, phase, beforeStamp, beforeIgnore,
                        beforeTick, listed>>
ChangeIgnore == /\ ignoreB' = ~ignoreB /\ ignoreEpoch' = ignoreEpoch + 1
                /\ published' = FALSE
                /\ history' = Append(history, "ChangeIgnore")
                /\ UNCHANGED <<fs, tick, stamp, knownStamp, knownIgnore,
                                reusable, snapshot, phase, beforeStamp,
                                beforeIgnore, beforeTick, listed>>
Reuse == /\ phase = "idle" /\ stamp = knownStamp
         /\ (~Guarded \/ (reusable /\ stamp < tick /\
                          ignoreEpoch = knownIgnore))
         /\ published' = TRUE /\ history' = Append(history, "Reuse")
         /\ UNCHANGED <<fs, tick, stamp, ignoreB, ignoreEpoch, knownStamp,
                         knownIgnore, reusable, snapshot, phase, beforeStamp,
                         beforeIgnore, beforeTick, listed>>
Begin == /\ phase = "idle" /\ phase' = "listing"
         /\ beforeStamp' = stamp /\ beforeIgnore' = ignoreEpoch
         /\ beforeTick' = tick /\ published' = FALSE
         /\ history' = Append(history, "Begin")
         /\ UNCHANGED <<fs, tick, stamp, ignoreB, ignoreEpoch, knownStamp,
                         knownIgnore, reusable, snapshot, listed>>
List == /\ phase = "listing" /\ phase' = "validate" /\ listed' = Visible
        /\ published' = FALSE /\ history' = Append(history, "List")
        /\ UNCHANGED <<fs, tick, stamp, ignoreB, ignoreEpoch, knownStamp,
                        knownIgnore, reusable, snapshot, beforeStamp,
                        beforeIgnore, beforeTick>>
Commit == LET valid == ~Guarded \/ (stamp = beforeStamp /\
                                   ignoreEpoch = beforeIgnore /\
                                   stamp < beforeTick)
          IN /\ phase = "validate" /\ phase' = "idle"
             /\ snapshot' = IF valid THEN listed ELSE snapshot
             /\ knownStamp' = IF valid THEN stamp ELSE knownStamp
             /\ knownIgnore' = IF valid THEN ignoreEpoch ELSE knownIgnore
             /\ reusable' = IF valid THEN TRUE ELSE reusable
             /\ published' = valid /\ history' = Append(history, "Commit")
             /\ UNCHANGED <<fs, tick, stamp, ignoreB, ignoreEpoch, beforeStamp,
                             beforeIgnore, beforeTick, listed>>
Next == /\ Len(history) < MaxSteps
        /\ ((\E p \in Files : Edit(p)) \/ Tick \/ ChangeIgnore \/
             Reuse \/ Begin \/ List \/ Commit)
Spec == Init /\ [][Next]_vars
TypeOK == /\ fs \subseteq Files /\ snapshot \subseteq Files
          /\ listed \subseteq Files /\ tick \in 0..2 /\ stamp \in 0..2
          /\ ignoreB \in BOOLEAN /\ published \in BOOLEAN
          /\ reusable \in BOOLEAN /\ phase \in {"idle", "listing", "validate"}
          /\ ignoreEpoch \in 0..MaxSteps /\ Len(history) <= MaxSteps
NoStalePublication == published => snapshot = Visible
=============================================================================
