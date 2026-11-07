------------------------- MODULE MCAcpSubagents -------------------------
(* Bounds for AcpSubagents: at most four unread messages.                   *)
EXTENDS AcpSubagents

ChanBound == Len(chan) <= 4
=============================================================================
