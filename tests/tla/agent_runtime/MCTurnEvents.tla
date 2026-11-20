---------------------------- MODULE MCTurnEvents ----------------------------
(* TurnEvents for TLC: a turn whose loop emits each kind of event, with text *)
(* first and last. A config file can't give Script a sequence, so the        *)
(* turn-events*.cfg configs take it from here.                               *)
EXTENDS TurnEvents

MCScript == <<"text", "tool", "worker", "diff", "notice", "text">>
=============================================================================
