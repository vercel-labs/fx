---- MODULE MCAgentsMenu ----
\* Small constants for TLC. agents-menu.cfg: two instances, the first with
\* two subagents and the second with one, one subagent open at the start.
\* agents-menu-three.cfg: three instances, so a closed instance gives way to
\* the next one in launch order, wrapping. agents-menu-drive.cfg: the world
\* tests/tla/drivers/agents_menu/spec-to-binary.ts starts, two instances and
\* the first's subagents alpha and beta, with only the person's steps, whose
\* state graph the driver walks on the binary.
EXTENDS AgentsMenu

MCInstanceOrder == <<"i1", "i2">>
MCSubs == {"s1", "s2", "s3"}
MCParent == [s \in MCSubs |-> IF s = "s3" THEN "i2" ELSE "i1"]
MCInitOrder == <<"i1", "s1", "i2">>

MC3InstanceOrder == <<"i1", "i2", "i3">>
MC3Subs == {"s1", "s2"}
MC3Parent == [s \in MC3Subs |-> IF s = "s1" THEN "i1" ELSE "i3"]
MC3InitOrder == <<"i1", "s1", "i2", "i3", "s2">>

MCDriveInstanceOrder == <<"i1", "i2">>
MCDriveSubs == {"alpha", "beta"}
MCDriveParent == [s \in MCDriveSubs |-> "i1"]
MCDriveInitOrder == <<"i1", "alpha", "beta", "i2">>
====
