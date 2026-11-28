----------------------- MODULE MCAcpSharedSession -----------------------
(* Bounds for AcpSharedSession: at most three unread messages per          *)
(* connection.                                                              *)
EXTENDS AcpSharedSession

ChanBound == \A c \in Conns : Len(chan[c]) <= 3
=============================================================================
