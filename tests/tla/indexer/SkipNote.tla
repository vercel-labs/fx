---- MODULE SkipNote ----
\* The skipped-entry note across the life of the @-completion snapshot
\* (src/core/workspace/file_index.zig saves it, src/core/workspace/
\* tool_files.zig listFromSnapshot reuses it). The person edits files, the
\* TUI saves a v4 snapshot, an older fx saves a v3 one, the file is cut
\* short or garbled, and glob_files or grep_files search the workspace or
\* any folder with or without hidden folders. A search reuses the snapshot
\* only when its stamps are unchanged (here: the same files), its format is
\* current, and the root is the workspace or a folder the walk entered;
\* otherwise it scans the root. Every answer must list what the folder holds
\* and note exactly the entries skipped by name, so no file goes missing
\* without its name in the note. See SkipNoteRules.tla for the rules and the
\* Bug values.
EXTENDS SkipNoteRules

CONSTANTS Folders, Files, Mutable

Paths == Folders \cup Files
NoSnapshot == [kind |-> "none"]
NoAnswer == [kind |-> "none"]

VARIABLES repo, fs, snap, out
vars == <<repo, fs, snap, out>>

\* Every path's parent folder exists.
Closed(s) == \A p \in s : Len(p) = 1 \/ SubSeq(p, 1, Len(p) - 1) \in s

Init ==
    /\ repo \in BOOLEAN
    /\ fs = Paths
    /\ snap = NoSnapshot
    /\ out = NoAnswer

Edit(p) ==
    /\ fs' = IF p \in fs THEN fs \ {p} ELSE fs \cup {p}
    /\ Closed(fs')
    /\ UNCHANGED <<repo, snap, out>>

WorkspaceScan == Scan(repo, fs, Files, Folders, <<>>)
\* file_index loadGeneration saves the workspace's tree.
Save ==
    /\ snap' = [kind |-> "tree", version |-> 4, fs |-> fs, tree |-> Saved(WorkspaceScan)]
    /\ UNCHANGED <<repo, fs, out>>
\* An older fx saves its v3 snapshot to the same file.
SaveOld ==
    /\ snap' = [kind |-> "tree", version |-> 3, fs |-> fs, tree |-> SavedOld(WorkspaceScan)]
    /\ UNCHANGED <<repo, fs, out>>
\* The file is cut short, garbled, or readable by others: never admitted.
Corrupt ==
    /\ snap' = [kind |-> "garbage"]
    /\ UNCHANGED <<repo, fs, out>>

Reusable(root) ==
    /\ snap.kind = "tree"
    /\ snap.fs = fs
    /\ (snap.version = 4 \/ Bug = "old_format")
    /\ (root = <<>> \/ root \in snap.tree.folders)

Search(root, keep) ==
    /\ root = <<>> \/ root \in fs \cap Folders
    /\ LET reuse == Reusable(root)
           tree == IF reuse THEN snap.tree ELSE Scan(repo, fs, Files, Folders, root)
           a == Answer(repo, tree, root, keep)
       IN out' = [kind |-> "answer", root |-> root, keep |-> keep, fs |-> fs,
                  reused |-> reuse, files |-> a.files, note |-> a.note]
    /\ UNCHANGED <<repo, fs, snap>>

Next ==
    \/ \E p \in Mutable : Edit(p)
    \/ Save
    \/ SaveOld
    \/ Corrupt
    \/ \E root \in Folders \cup {<<>>}, keep \in BOOLEAN : Search(root, keep)

Spec == Init /\ [][Next]_vars

Answered == out.kind = "answer"

TypeOK ==
    /\ repo \in BOOLEAN
    /\ fs \subseteq Paths /\ Closed(fs)
    /\ snap.kind \in {"none", "tree", "garbage"}
    /\ out.kind \in {"none", "answer"}

\* The listing holds exactly the files a fresh scan of the root lists.
ListingHonest ==
    Answered => out.files = TrueFiles(repo, out.fs, Files, out.root, out.keep)

\* The note counts and names exactly the entries skipped by name below the
\* root that the listing would otherwise have shown.
NoteHonest ==
    Answered => out.note = TrueNote(repo, out.fs, out.root, out.keep)

\* No file under the root goes missing without a name on its way down in
\* the note.
NothingSilent ==
    Answered =>
        \A f \in out.fs \cap Files :
            (Under(out.root, f) /\ (out.keep \/ ~HiddenBelow(out.root, f)) /\ f \notin out.files)
                => Below(out.root, f) \cap out.note.names # {}

\* Inside a repository git's rules decide, so there is never a note.
NoNoteInRepository == (Answered /\ repo) => out.note.count = 0

\* The fixture for the configs. `app/dist` is a file: the names skip files
\* too. `build/dist` sits inside a skipped folder. `.next` is a hidden
\* skipped name and `.cache/dist` a skipped folder below a hidden one.
CheckFolders ==
    {<<"src">>, <<"build">>, <<"build", "dist">>, <<"app">>, <<"app", "build">>,
     <<".next">>, <<".cache">>, <<".cache", "dist">>}
CheckFiles ==
    {<<"src", "a">>, <<"build", "b">>, <<"build", "dist", "c">>, <<"app", "d">>,
     <<"app", "build", "e">>, <<"app", "dist">>, <<".next", "f">>, <<".cache", "dist", "g">>}
CheckMutable == {<<"src", "a">>, <<"build", "b">>, <<"app", "build">>, <<"app", "build", "e">>}
====
