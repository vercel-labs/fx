------------------------ MODULE MCAcpSessionState ------------------------
(* Model values and bounds for AcpSessionState: two connections, two       *)
(* sessions in two folders, two turns, one retitle or delete, and at most  *)
(* three unread messages per connection.                                    *)
EXTENDS AcpSessionState

MCFolderOf == [s \in Sessions |-> IF s = "s1" THEN "A" ELSE "B"]

ChanBound == \A c \in Conns : Len(chan[c]) <= 3
=============================================================================
