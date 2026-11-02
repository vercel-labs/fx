--------------------------- MODULE PR1116Blobs -----------------------------
EXTENDS Naturals, FiniteSets
CONSTANT Bodies, MaxChunks
VARIABLES up, temporary, chunks, sealed, blobs, blobSize, refs, expectedSize, readonly, external, side
vars == <<up, temporary, chunks, sealed, blobs, blobSize, refs, expectedSize, readonly, external, side>>
TypeOK == /\ up \in BOOLEAN /\ temporary \subseteq Bodies /\ chunks \in [Bodies -> 0..MaxChunks]
          /\ sealed \subseteq Bodies /\ blobs \subseteq Bodies /\ blobSize \in [Bodies -> 0..MaxChunks]
          /\ refs \subseteq Bodies /\ expectedSize \in [Bodies -> 0..MaxChunks]
          /\ readonly \subseteq Bodies /\ external \subseteq Bodies /\ side \subseteq Bodies
Init == /\ up = TRUE /\ temporary = {} /\ chunks = [b \in Bodies |-> 0] /\ sealed = {} /\ blobs = {}
        /\ blobSize = [b \in Bodies |-> 0] /\ refs = {} /\ expectedSize = [b \in Bodies |-> 0]
        /\ readonly = {} /\ external = Bodies /\ side = {}
StartBody(b) == /\ up /\ b \notin blobs /\ b \notin temporary /\ temporary' = temporary \cup {b}
                /\ UNCHANGED <<up, chunks, sealed, blobs, blobSize, refs, expectedSize, readonly, external, side>>
Chunk(b) == /\ up /\ b \in temporary /\ b \notin sealed /\ chunks[b] < MaxChunks
            /\ chunks' = [chunks EXCEPT ![b] = @ + 1]
            /\ UNCHANGED <<up, temporary, sealed, blobs, blobSize, refs, expectedSize, readonly, external, side>>
Seal(b) == /\ up /\ b \in temporary /\ chunks[b] > 0 /\ sealed' = sealed \cup {b}
           /\ UNCHANGED <<up, temporary, chunks, blobs, blobSize, refs, expectedSize, readonly, external, side>>
Publish(b) == /\ up /\ b \in sealed /\ b \notin blobs
              /\ blobs' = blobs \cup {b} /\ blobSize' = [blobSize EXCEPT ![b] = chunks[b]]
              /\ readonly' = readonly \cup {b} /\ temporary' = temporary \ {b}
              /\ UNCHANGED <<up, chunks, sealed, refs, expectedSize, external, side>>
Reference(b) == /\ up /\ b \in blobs /\ b \notin refs
                /\ refs' = refs \cup {b} /\ expectedSize' = [expectedSize EXCEPT ![b] = chunks[b]]
                /\ UNCHANGED <<up, temporary, chunks, sealed, blobs, blobSize, readonly, external, side>>
DeleteOriginal(b) == /\ external' = external \ {b}
                     /\ UNCHANGED <<up, temporary, chunks, sealed, blobs, blobSize, refs, expectedSize, readonly, side>>
Crash == /\ up /\ up' = FALSE /\ temporary' = {} /\ sealed' = sealed \cap blobs
         /\ chunks' = [b \in Bodies |-> IF b \in blobs THEN chunks[b] ELSE 0]
         /\ UNCHANGED <<blobs, blobSize, refs, expectedSize, readonly, external, side>>
Resume == /\ ~up /\ up' = TRUE
          /\ UNCHANGED <<temporary, chunks, sealed, blobs, blobSize, refs, expectedSize, readonly, external, side>>
Next == (\E b \in Bodies : StartBody(b) \/ Chunk(b) \/ Seal(b) \/ Publish(b) \/ Reference(b) \/ DeleteOriginal(b))
        \/ Crash \/ Resume \/ UNCHANGED vars
Spec == Init /\ [][Next]_vars
ReferenceAfterBlob == refs \subseteq blobs
WholeBodyKept == \A b \in refs : blobSize[b] = expectedSize[b] /\ blobSize[b] > 0
PublishedReadOnly == blobs \subseteq readonly
NoNewSideFiles == side = {}
=============================================================================
