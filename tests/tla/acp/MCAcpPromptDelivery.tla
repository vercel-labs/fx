------------------------ MODULE MCAcpPromptDelivery ------------------------
(* Exhaustive models of AcpPromptDelivery, against a turn that streams,  *)
(* may call one tool, may be stopped once, and a session that may close.  *)
(* MCMsgs, the core: a first prompt, two steers and two queued prompts, in *)
(* every order. MCRefusals: a prompt with no delivery and a steer with an  *)
(* image beside one steer. Rules is TRUE for the sh.fx rules; the          *)
(* AcpPromptDeliveryToday configs set it to FALSE.                         *)
EXTENDS AcpPromptDelivery

MCMsgs == {"P", "S1", "S2", "Q1", "Q2"}
MCRefusals == {"P", "M", "I", "S1"}
=============================================================================
