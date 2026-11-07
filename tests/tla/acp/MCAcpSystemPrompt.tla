------------------------- MODULE MCAcpSystemPrompt -------------------------
(* Exhaustive model of AcpSystemPrompt: every order of session/new, loads, *)
(* resumes, turns and restarts with each prompt shape. The configs set     *)
(* Fixed: TRUE for ACP v1's rules, FALSE in the AcpSystemPromptBefore      *)
(* configs to show fx before them.                                         *)
EXTENDS AcpSystemPrompt
=============================================================================
