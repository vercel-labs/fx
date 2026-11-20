--------------------------- MODULE MCAcpSessions ---------------------------
(* Exhaustive model of AcpSessions: two sessions, two workspaces, two       *)
(* prompts per session and two load or resume requests, in every order of *)
(* opens, prompts, updates, tool writes, cancels, closes and loads. Rules  *)
(* is TRUE for many sessions; the AcpSessionsToday configs set it to FALSE.*)
EXTENDS AcpSessions
=============================================================================
