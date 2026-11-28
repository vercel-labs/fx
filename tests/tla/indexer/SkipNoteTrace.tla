---- MODULE SkipNoteTrace ----
\* Replays what tests/tla/drivers/indexer/skip_note.ts saw the built fx do.
\* Each observation is one glob_files or grep_files result: the folder as it
\* was, whether it is a repository, which snapshot was on disk, whether fx
\* reused it (from its trace log), the search root, whether hidden folders
\* were kept, and the files and note fx returned. An observation matches when
\* SkipNoteRules gives the same files and note from the same tree: the saved
\* workspace tree when fx reused the snapshot, which needs a current one and
\* a root the walk entered, or a scan of the root otherwise. A listing the
\* tool cut short is compared by its note alone. AllMatched is violated once
\* every observation has matched; an observation that cannot match stops the
\* trace first.
EXTENDS SkipNoteRules, SkipNoteObserved

VARIABLE i

TreeOf(o) ==
    LET whole == Scan(o.repo, o.fs, o.files, o.folders, <<>>)
    IN IF ~o.reused THEN Scan(o.repo, o.fs, o.files, o.folders, o.root)
       ELSE IF o.snapshot = "v3" THEN SavedOld(whole)
       ELSE Saved(whole)

Matches(o) ==
    LET tree == TreeOf(o)
        a == Answer(o.repo, tree, o.root, o.keep)
    IN /\ o.reused => (o.snapshot = "v4" \/ (o.snapshot = "v3" /\ Bug = "old_format"))
       /\ o.reused => (o.root = <<>> \/ o.root \in tree.folders)
       /\ (o.truncated \/ a.files = o.listed)
       /\ a.note = o.note

TraceInit == i = 0
TraceNext == i < Len(Observed) /\ Matches(Observed[i + 1]) /\ i' = i + 1
TraceSpec == TraceInit /\ [][TraceNext]_i

AllMatched == i < Len(Observed)
====
