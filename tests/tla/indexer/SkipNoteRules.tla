---- MODULE SkipNoteRules ----
\* What glob_files and grep_files list, and what their note says about the
\* entries a scan skipped by name (src/core/indexer/scan.zig listDirectory,
\* src/core/workspace/tool_files.zig collect and Completeness.writeNotes).
\* SkipNote.tla runs these rules across the life of the @-completion
\* snapshot; SkipNoteTrace.tla checks runs of the built fx against them.
\*
\* A path is a sequence of names from the workspace root. Outside a git
\* repository, and below an ignored root, the scan leaves out every entry
\* whose name is in Skip and never reads below a skipped folder. Inside a
\* repository it skips nothing by name. The listing then keeps the search
\* root's subtree and drops files below a hidden folder unless hidden
\* folders are kept.
\*
\* Bug names the behavior: "none" is fx with the note, "today" is fx before
\* it, which notes nothing. The others are planted mistakes: "flag" prints a
\* fixed note whenever names apply, "unsaved" saves no skipped list in the
\* snapshot, "whole_tree" reports skips outside the searched folder,
\* "hidden" reports skips the hidden filter would have dropped anyway, and
\* "old_format" reuses a snapshot an older fx saved without the list.
EXTENDS Integers, Sequences, FiniteSets

CONSTANTS Skip, Hidden, Bug

Last(p) == p[Len(p)]
\* p lies strictly below root.
Under(root, p) == Len(p) > Len(root) /\ SubSeq(p, 1, Len(root)) = root
\* The names of p strictly below root, without p's own name.
Between(root, p) == {p[k] : k \in (Len(root) + 1)..(Len(p) - 1)}
\* The names of p strictly below root, with p's own name.
Below(root, p) == {p[k] : k \in (Len(root) + 1)..Len(p)}
\* The walk from root reaches p: no folder on the way down was skipped.
Reached(repo, root, p) == Under(root, p) /\ (repo \/ Between(root, p) \cap Skip = {})
SkippedAt(repo, root, p) == ~repo /\ Reached(repo, root, p) /\ Last(p) \in Skip
HiddenBelow(root, p) == Between(root, p) \cap Hidden # {}

\* One scan of root over the existing paths fs: the files it lists, the
\* folders it read, and the entries it skipped by name.
Scan(repo, fs, files, folders, root) ==
    [files |-> {f \in fs \cap files : Reached(repo, root, f) /\ (repo \/ Last(f) \notin Skip)},
     folders |-> {d \in fs \cap folders : Reached(repo, root, d) /\ (repo \/ Last(d) \notin Skip)},
     skipped |-> {p \in fs : SkippedAt(repo, root, p)}]

\* tool_files.collect: files in the subtree, then the hidden filter. A
\* skipped entry is reported only where its files would have been listed:
\* not below a hidden folder, and not itself a hidden name, unless hidden
\* folders are kept.
Listed(tree, root, keep) == {f \in tree.files : Under(root, f) /\ (keep \/ ~HiddenBelow(root, f))}
Reported(tree, root, keep) ==
    {p \in tree.skipped :
        /\ (Bug = "whole_tree" \/ Under(root, p))
        /\ (keep \/ Bug = "hidden" \/ (~HiddenBelow(root, p) /\ Last(p) \notin Hidden))}
NoNote == [count |-> 0, names |-> {}]
Note(repo, tree, root, keep) ==
    CASE Bug = "today" -> NoNote
      [] Bug = "flag" -> IF repo THEN NoNote ELSE [count |-> 1, names |-> Skip]
      [] OTHER -> LET r == Reported(tree, root, keep)
                  IN [count |-> Cardinality(r), names |-> {Last(p) : p \in r}]

Answer(repo, tree, root, keep) ==
    [files |-> Listed(tree, root, keep), note |-> Note(repo, tree, root, keep)]

\* The tree a current (v4) snapshot keeps.
Saved(tree) == IF Bug = "unsaved" THEN [tree EXCEPT !.skipped = {}] ELSE tree
\* The tree a v3 snapshot from an older fx keeps: no skipped list.
SavedOld(tree) == [tree EXCEPT !.skipped = {}]

\* What the person should see, read from the folder itself.
TrueFiles(repo, fs, files, root, keep) ==
    {f \in fs \cap files :
        /\ Under(root, f)
        /\ (keep \/ ~HiddenBelow(root, f))
        /\ (repo \/ Below(root, f) \cap Skip = {})}
TrueSkipped(repo, fs, root, keep) ==
    {p \in fs : SkippedAt(repo, root, p) /\ (keep \/ (~HiddenBelow(root, p) /\ Last(p) \notin Hidden))}
TrueNote(repo, fs, root, keep) ==
    LET s == TrueSkipped(repo, fs, root, keep)
    IN [count |-> Cardinality(s), names |-> {Last(p) : p \in s}]
====
