------------------------- MODULE MCAcpForkRewind -------------------------
(* Bounds for AcpForkRewind: at most three unread messages per connection. *)
EXTENDS AcpForkRewind

ChanBound == \A c \in Conns : Len(chan[c]) <= 3
=============================================================================
