------------------------ MODULE MCAcpPermissionModes ------------------------
(* Exhaustive model: every starting profile, the three modes plus unknown *)
(* values a client might still send (the old "code" mode and the CLI's    *)
(* internal "yolo" name).                                                  *)
EXTENDS AcpPermissionModes

MCProfiles == {"unset", "auto", "ask", "full-access"}
MCValues == {"auto", "ask", "full-access", "code", "yolo"}
=============================================================================
