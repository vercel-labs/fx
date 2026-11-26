---- MODULE SessionToggles ----
\* Session-local MCP admission and access gates.
\*
\* Code: src/core/agents/mcp_overrides.zig, src/core/app/app_mcp_runtime.zig,
\* and src/core/mcp_host/model.zig.
\*
\* Each root owns optional per-server enabled overrides. An absent override
\* follows the saved config, including after a reload. A child keeps its
\* captured access and profile but intersects them with its root's live gate.
\* Two roots share one runtime, whose admission is the OR of their effective
\* enabled values. RefreshRuntime loads that union; admission may lag a toggle,
\* so an admitted server alone never authorizes discovery or a new call.
\*
\* Project trust and each call's permission approval are independent gates.
\* A saved disabled server may be temporarily enabled, but never trusted or
\* approved by its toggle. ResetRoot stands for reset, new, and resume after
\* the old root tree stops: only that root's overrides are dropped. Captured
\* views here are gate inputs, not live child processes or persisted state.
\*
\* This pure gate model leaves process lifetimes and config reload progress
\* to HostLifecycle.tla. It models admission and the next call, not cancellation
\* of a call already dispatched, retries, or asynchronous command completion.
EXTENDS Naturals, FiniteSets

CONSTANTS Roots, Servers, Project, MaxViews, NoOverride

ASSUME /\ Cardinality(Roots) = 2
       /\ Project \subseteq Servers
       /\ MaxViews \in Nat

None == NoOverride
OverrideValues == BOOLEAN \cup {None}
EmptyOverrides == [s \in Servers |-> None]
Views == [root : Roots, access : SUBSET Servers, profile : SUBSET Servers]
TrustValues == {"pending", "approved", "rejected"}

VARIABLES saved, overrides, trust, views, admitted, current
vars == <<saved, overrides, trust, views, admitted, current>>

GateWith(values, defaults, r, s) ==
    IF values[r][s] = None THEN defaults[s] ELSE values[r][s]

Effective(r, s) == GateWith(overrides, saved, r, s)
Trusted(s) == s \notin Project \/ trust[s] = "approved"
RuntimeNeeds(s) == \E r \in Roots : Effective(r, s)
RuntimeUnion == {s \in Servers : RuntimeNeeds(s)}

RootMayUse(r, s) == Effective(r, s) /\ Trusted(s) /\ s \in admitted
ChildMayUse(v, s) ==
    /\ s \in v.access
    /\ s \in v.profile
    /\ RootMayUse(v.root, s)

RootCallAllowed(r, s, approved) == RootMayUse(r, s) /\ approved
ChildCallAllowed(v, s, approved) == ChildMayUse(v, s) /\ approved

Init ==
    /\ saved \in [Servers -> BOOLEAN]
    /\ overrides = [r \in Roots |-> EmptyOverrides]
    /\ trust = [s \in Servers |-> IF s \in Project THEN "pending" ELSE "approved"]
    /\ views = {}
    /\ admitted = RuntimeUnion
    /\ current = TRUE

SetOverride(r, s, value) ==
    /\ overrides' = [overrides EXCEPT ![r][s] = value]
    /\ current' = FALSE
    /\ UNCHANGED <<saved, trust, views, admitted>>

ReloadConfig(s, value) ==
    /\ saved' = [saved EXCEPT ![s] = value]
    /\ current' = FALSE
    /\ UNCHANGED <<overrides, trust, views, admitted>>

DecideTrust(s, decision) ==
    /\ s \in Project
    /\ trust' = [trust EXCEPT ![s] = decision]
    /\ UNCHANGED <<saved, overrides, views, admitted, current>>

Capture(r, access, profile) ==
    /\ Cardinality(views) < MaxViews
    /\ access \subseteq {s \in Servers : RootMayUse(r, s)}
    /\ views' = views \cup {[root |-> r, access |-> access, profile |-> profile]}
    /\ UNCHANGED <<saved, overrides, trust, admitted, current>>

ResetRoot(r) ==
    /\ overrides' = [overrides EXCEPT ![r] = EmptyOverrides]
    /\ current' = FALSE
    /\ UNCHANGED <<saved, trust, views, admitted>>

RefreshRuntime ==
    /\ admitted' = RuntimeUnion
    /\ current' = TRUE
    /\ UNCHANGED <<saved, overrides, trust, views>>

Next ==
    \/ \E r \in Roots, s \in Servers, value \in OverrideValues : SetOverride(r, s, value)
    \/ \E s \in Servers, value \in BOOLEAN : ReloadConfig(s, value)
    \/ \E s \in Project, decision \in TrustValues : DecideTrust(s, decision)
    \/ \E r \in Roots, access \in SUBSET Servers, profile \in SUBSET Servers : Capture(r, access, profile)
    \/ \E r \in Roots : ResetRoot(r)
    \/ RefreshRuntime

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ saved \in [Servers -> BOOLEAN]
    /\ overrides \in [Roots -> [Servers -> OverrideValues]]
    /\ trust \in [Servers -> TrustValues]
    /\ views \subseteq Views
    /\ Cardinality(views) <= MaxViews
    /\ admitted \subseteq Servers
    /\ current \in BOOLEAN

DefaultFollowsSaved ==
    \A r \in Roots, s \in Servers : overrides[r][s] = None => Effective(r, s) = saved[s]

OverrideWins ==
    \A r \in Roots, s \in Servers : overrides[r][s] # None => Effective(r, s) = overrides[r][s]

\* Changing one root's override cannot change another root's effective gate,
\* even when both use the same runtime and the same saved config.
OtherRootUnaffected ==
    \A r, other \in Roots, s, t \in Servers, value \in OverrideValues : r # other =>
        GateWith([overrides EXCEPT ![r][s] = value], saved, other, t) = Effective(other, t)

RuntimeUnionWhenCurrent ==
    current => admitted = {s \in Servers : \E r \in Roots :
        overrides[r][s] = TRUE \/ (overrides[r][s] = None /\ saved[s])}

\* Raw config enabled=FALSE does not veto an explicit session enabled=TRUE.
RawDisabledCanEnable ==
    \A r \in Roots, s \in Servers : ~saved[s] /\ overrides[r][s] = TRUE =>
        Effective(r, s) /\ (current /\ Trusted(s) => RootMayUse(r, s))

RootGateHolds ==
    \A r \in Roots, s \in Servers : RootMayUse(r, s) => Effective(r, s)

ProjectTrustHolds ==
    \A r \in Roots, s \in Project : RootMayUse(r, s) => trust[s] = "approved"

ChildWithinCapturedAccess == \A v \in views, s \in Servers : ChildMayUse(v, s) => s \in v.access
ChildWithinProfile == \A v \in views, s \in Servers : ChildMayUse(v, s) => s \in v.profile
ChildWithinRoot == \A v \in views, s \in Servers : ChildMayUse(v, s) => RootMayUse(v.root, s)
ChildIntersectionComplete ==
    \A v \in views, s \in Servers :
        s \in v.access /\ s \in v.profile /\ RootMayUse(v.root, s) => ChildMayUse(v, s)

NoApprovalBypass ==
    /\ \A r \in Roots, s \in Servers : ~RootCallAllowed(r, s, FALSE)
    /\ \A v \in views, s \in Servers : ~ChildCallAllowed(v, s, FALSE)
ApprovedCallsAllowed ==
    /\ \A r \in Roots, s \in Servers : RootMayUse(r, s) => RootCallAllowed(r, s, TRUE)
    /\ \A v \in views, s \in Servers : ChildMayUse(v, s) => ChildCallAllowed(v, s, TRUE)

\* These step properties compare mutation effects with a separate contract,
\* rather than accepting a toggle that rewrites config or another root's map.
ToggleIsRootLocal ==
    [][\A r \in Roots, s \in Servers, value \in OverrideValues : SetOverride(r, s, value) =>
        /\ overrides'[r][s] = value
        /\ \A other \in Roots \ {r} : overrides'[other] = overrides[other]
        /\ \A t \in Servers \ {s} : overrides'[r][t] = overrides[r][t]
        /\ UNCHANGED <<saved, trust, views, admitted>>]_vars

RootResetIsLocal ==
    [][\A r \in Roots : ResetRoot(r) =>
        /\ overrides'[r] = EmptyOverrides
        /\ \A other \in Roots \ {r} : overrides'[other] = overrides[other]
        /\ UNCHANGED <<saved, trust, views, admitted>>]_vars

ReloadPreservesOverrides ==
    [][\A s \in Servers, value \in BOOLEAN : ReloadConfig(s, value) =>
        UNCHANGED <<overrides, trust, views, admitted>>]_vars
====
