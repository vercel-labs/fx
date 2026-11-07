---------------------------- MODULE MCAcpFollow ----------------------------
(* Exhaustive model of AcpFollow: two connections, two folders, up to three *)
(* turns and one compaction, in every order of joins, closes, turns and    *)
(* saves. Rules is TRUE for the sh.fx rules; the AcpFollowToday configs    *)
(* set it to FALSE.                                                         *)
EXTENDS AcpFollow

MCConns == {"c1", "c2"}
MCFolders == {"w1", "w2"}
=============================================================================
