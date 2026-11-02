---------------------------- MODULE PR1099FIFO -----------------------------
EXTENDS Naturals
CONSTANT MaxYields
VARIABLES reader, opened, writer, joined, yields
vars == <<reader, opened, writer, joined, yields>>
TypeOK == /\ reader \in BOOLEAN /\ opened \in BOOLEAN /\ writer \in {"blocked", "running", "finished"}
          /\ joined \in BOOLEAN /\ yields \in 0..MaxYields
Init == /\ reader = FALSE /\ opened = FALSE /\ writer \in {"blocked", "finished"}
        /\ joined = FALSE /\ yields = 0
OpenReader == /\ ~opened /\ ~joined /\ writer # "finished"
              /\ reader' = TRUE /\ opened' = TRUE /\ UNCHANGED <<writer, joined, yields>>
WriterOpen == /\ writer = "blocked" /\ reader /\ writer' = "running"
              /\ UNCHANGED <<reader, opened, joined, yields>>
WriterFinish == /\ writer = "running" /\ writer' = "finished"
                /\ UNCHANGED <<reader, opened, joined, yields>>
Join == /\ writer = "finished" /\ ~joined /\ joined' = TRUE
        /\ UNCHANGED <<reader, opened, writer, yields>>
CloseReader == /\ reader /\ joined /\ reader' = FALSE
               /\ UNCHANGED <<opened, writer, joined, yields>>
Yield == /\ ~joined /\ yields < MaxYields /\ yields' = yields + 1
         /\ UNCHANGED <<reader, opened, writer, joined>>
Next == OpenReader \/ WriterOpen \/ WriterFinish \/ Join \/ CloseReader \/ Yield \/ UNCHANGED vars
Spec == Init /\ [][Next]_vars /\ WF_vars(OpenReader) /\ WF_vars(WriterOpen)
        /\ WF_vars(WriterFinish) /\ WF_vars(Join)
ReaderHeldUntilJoin == opened /\ ~joined => reader
JoinAfterFinish == joined => writer = "finished"
EventuallyJoined == <>joined
=============================================================================
