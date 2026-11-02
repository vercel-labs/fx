---- MODULE SnapshotSources ----
\* A saved workspace listing and the sources that decide whether
\* `sub/api.secret` is listed: the user's ~/.gitconfig, a link to one of two
\* dotfiles whose content may name an excludes file ignoring *.secret; the
\* git config location (HOME versus GIT_CONFIG_GLOBAL pointing at a file
\* without excludes); and a root .gitignore that may ignore *.secret.
\*
\* Current() mirrors tree.isCurrent: recorded sources must be unchanged
\* (followed through the link when FollowLinks), a root .gitignore is a
\* source only if it existed at commit, and folder stamps are checked for the
\* whole tree, or for a subfolder search only at and below the subfolder
\* unless SubtreeChecksAncestors. KeyEnv keys the snapshot on the config
\* location, as file_index.snapshotPath does.
EXTENDS Naturals, Sequences

CONSTANTS SubtreeChecksAncestors, FollowLinks, KeyEnv, MaxSteps

Targets == {"t1", "t2"}
Envs == {"home", "alt"}
Keys == IF KeyEnv THEN Envs ELSE {"one"}
KeyOf(e) == IF KeyEnv THEN e ELSE "one"
NoSnap == [exists |-> FALSE, secretListed |-> FALSE, envAt |-> "home", gStamp |-> <<"none", 0>>,
           rootRec |-> FALSE, rootStamp |-> 0, rootFolder |-> 0]

VARIABLES link, linkGen, content, contentGen, env, rootIgnore, rootGen, rootFolderGen,
          snap, answer, stale, history
vars == <<link, linkGen, content, contentGen, env, rootIgnore, rootGen, rootFolderGen, snap, answer, stale, history>>

\* Whether git lists sub/api.secret right now.
Truth == ~((env = "home" /\ content[link] = "ex") \/ rootIgnore = "secret")

GStampFor(e) ==
    IF e = "alt" THEN <<"alt", 0>>
    ELSE IF FollowLinks THEN <<link, contentGen[link]>> ELSE <<"link", linkGen>>

Init ==
    /\ link = "t1" /\ linkGen = 0
    /\ content = [t \in Targets |-> IF t = "t1" THEN "ex" ELSE "none"]
    /\ contentGen = [t \in Targets |-> 0]
    /\ env = "home" /\ rootIgnore = "absent" /\ rootGen = 0 /\ rootFolderGen = 0
    /\ snap = [k \in Keys |-> NoSnap]
    /\ answer = "none" /\ stale = FALSE /\ history = <<>>

Step(name) == /\ Len(history) < MaxSteps /\ history' = Append(history, name)

Retarget ==
    /\ Step("Retarget")
    /\ link' = (IF link = "t1" THEN "t2" ELSE "t1")
    /\ linkGen' = linkGen + 1
    /\ answer' = "none"
    /\ UNCHANGED <<content, contentGen, env, rootIgnore, rootGen, rootFolderGen, snap, stale>>

EditTarget ==
    /\ Step("EditTarget")
    /\ content' = [content EXCEPT ![link] = IF @ = "ex" THEN "none" ELSE "ex"]
    /\ contentGen' = [contentGen EXCEPT ![link] = @ + 1]
    /\ answer' = "none"
    /\ UNCHANGED <<link, linkGen, env, rootIgnore, rootGen, rootFolderGen, snap, stale>>

ChangeEnv ==
    /\ Step("ChangeEnv")
    /\ env' = (IF env = "home" THEN "alt" ELSE "home")
    /\ answer' = "none"
    /\ UNCHANGED <<link, linkGen, content, contentGen, rootIgnore, rootGen, rootFolderGen, snap, stale>>

ToggleRootIgnore ==
    /\ Step("ToggleRootIgnore")
    /\ rootIgnore' = (IF rootIgnore = "absent" THEN "secret" ELSE "absent")
    /\ rootGen' = rootGen + 1 /\ rootFolderGen' = rootFolderGen + 1
    /\ answer' = "none"
    /\ UNCHANGED <<link, linkGen, content, contentGen, env, snap, stale>>

Commit ==
    /\ Step("Commit")
    /\ snap' = [snap EXCEPT ![KeyOf(env)] = [exists |-> TRUE, secretListed |-> Truth, envAt |-> env,
                gStamp |-> GStampFor(env), rootRec |-> rootIgnore = "secret", rootStamp |-> rootGen,
                rootFolder |-> rootFolderGen]]
    /\ answer' = "none"
    /\ UNCHANGED <<link, linkGen, content, contentGen, env, rootIgnore, rootGen, rootFolderGen, stale>>

Current(rec, whole) ==
    /\ rec.exists
    /\ rec.gStamp = GStampFor(rec.envAt)
    /\ (rec.rootRec => (rootIgnore = "secret" /\ rec.rootStamp = rootGen))
    /\ ((whole \/ SubtreeChecksAncestors) => rec.rootFolder = rootFolderGen)

Reuse(whole) ==
    LET rec == snap[KeyOf(env)] IN
    /\ Step(IF whole THEN "ReuseWhole" ELSE "ReuseSub")
    /\ IF Current(rec, whole)
       THEN /\ answer' = IF rec.secretListed THEN "listed" ELSE "hidden"
            /\ stale' = (stale \/ rec.secretListed # Truth)
       ELSE /\ answer' = "scan" /\ stale' = stale
    /\ UNCHANGED <<link, linkGen, content, contentGen, env, rootIgnore, rootGen, rootFolderGen, snap>>

Next == Retarget \/ EditTarget \/ ChangeEnv \/ ToggleRootIgnore \/ Commit \/ Reuse(TRUE) \/ Reuse(FALSE)
Spec == Init /\ [][Next]_vars

\* A reused listing always equals what a fresh scan (git) lists now.
NoStaleReuse == ~stale
====
