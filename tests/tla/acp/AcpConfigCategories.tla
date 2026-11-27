-------------------------- MODULE AcpConfigCategories --------------------------
(***************************************************************************)
(* The session config options fx acp lists in session/new, session/load   *)
(* and session/set_config_option responses (src/acp/sessions.zig and      *)
(* src/acp/server.zig), as ids and categories in list order.               *)
(*                                                                         *)
(*  - The list is provider (native builds), model, mode, then effort,     *)
(*    fast and ultrafast when the model offers them.                       *)
(*  - ACP clients find the model picker as the first option with category *)
(*    `model` and break ties by list order, so only the model option has   *)
(*    that category. Provider, fast and ultrafast are model settings, with *)
(*    category `model_config`.                                             *)
(*                                                                         *)
(* Fixed = FALSE is fx before the fix, where provider, fast and ultrafast  *)
(* also had category `model`.                                              *)
(***************************************************************************)
EXTENDS Sequences, TLC

CONSTANT Fixed

Ops == {"new", "load", "set"}

Option(id, category) == [id |-> id, category |-> category]

SettingCategory == IF Fixed THEN "model_config" ELSE "model"

OptionList(native, effort, fast, ultra) ==
    (IF native THEN <<Option("provider", SettingCategory)>> ELSE <<>>)
    \o <<Option("model", "model"), Option("mode", "mode")>>
    \o (IF effort THEN <<Option("effort", "thought_level")>> ELSE <<>>)
    \o (IF fast THEN <<Option("fast", SettingCategory)>> ELSE <<>>)
    \o (IF ultra THEN <<Option("ultrafast", SettingCategory)>> ELSE <<>>)

VARIABLES op, options

vars == <<op, options>>

Init == /\ op = "none"
        /\ options = <<>>

(* fx answers a request of kind k with the options its session has. *)
Advertise(k) ==
    /\ op' = k
    /\ \E native, effort, fast, ultra \in BOOLEAN :
           options' = OptionList(native, effort, fast, ultra)

Next == \E k \in Ops : Advertise(k)

Spec == Init /\ [][Next]_vars

-----------------------------------------------------------------------------

IsModelCategory(o) == o.category = "model"

ModelCategory == SelectSeq(options, IsModelCategory)

TypeOK == /\ op \in Ops \cup {"none"}
          /\ \A n \in DOMAIN options : options[n].id \in {"provider", "model", "mode", "effort", "fast", "ultrafast"}

(* The first option with category `model` is the model picker. *)
ModelPickerFirst == options # <<>> => Head(ModelCategory).id = "model"

(* No other option shares the model picker's category. *)
OneModelOption == options # <<>> => Len(ModelCategory) = 1
=============================================================================
