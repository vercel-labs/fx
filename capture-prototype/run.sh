#!/usr/bin/env bash
# Prototype tests for the workspace capture design in WORKSPACE_CAPTURE_PLAN.md.
# Throwaway evidence, not fx code. Every repository it writes lives in a
# temporary folder that is removed on exit. The optional performance case
# (PERF_REPO=/abs/path) only reads that repository and writes its capture
# store in the temporary folder.
#
# Usage: [LIST_MODE=indexer|git] [PERF_REPO=/abs/path] bash capture-prototype/run.sh
# MUTATION=no_tracked, no_stale, no_skip, keep_flags, stale_sparse, shared_index, fresh_copy,
# shared_temporaries, link_any or late_touch plants a known bug; the run must fail.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
FX_SRC=${FX_SRC:-$HERE/../src}
WORK=$(mktemp -d /tmp/fx-capture-proto.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home" GIT_CONFIG_GLOBAL="$WORK/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0 LC_ALL=C PATH=/usr/bin:/bin:$(dirname "$(command -v zig)")
mkdir -p "$HOME"
printf '[user]\n\tname = fixture\n\temail = fixture@example.invalid\n[init]\n\tdefaultBranch = main\n[protocol "file"]\n\tallow = always\n' > "$GIT_CONFIG_GLOBAL"

GIT=/usr/bin/git
SAFE=(-c core.fsmonitor=false -c core.hooksPath=/dev/null -c gc.auto=0 -c core.logAllRefUpdates=false)
# Capture commits never depend on the user having a git identity.
FX_IDENTITY=(-c user.name=fx -c user.email=fx@localhost)
PASS=0
FAIL=0
LIST_MODE=${LIST_MODE:-indexer}
UNTRACKED_MAX_BYTES=$((2 * 1024 * 1024))

ok() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s  %s\n' "$1" "${2:-}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected=[$3] got=[$2]"; fi; }
now() { python3 -c 'import time;print(time.time())'; }

# Build the indexer listing tool against a copy of fx's source.
mkdir -p "$WORK/src"
cp -R "$FX_SRC/." "$WORK/src/"
cp "$HERE/list_indexer.zig" "$WORK/src/list_indexer.zig"
(cd "$WORK/src" && zig build-exe -O ReleaseFast -lc list_indexer.zig -femit-bin="$WORK/list_indexer") || { echo "cannot build indexer tool"; exit 2; }
LIST="$WORK/list_indexer"

# ---------------------------------------------------------------------------
# The prototype capture: tree of tracked files plus admitted untracked files,
# written into a separate fx store that reads the user's objects through
# alternates. Each worktree has its own persistent capture index, which starts
# from a copy of that worktree's index.
#   capture WORKSPACE STORE REF -> tree id; intermediates under wt_dir/last.*
#   returns 0 on success or a reported status, 1 on error, 3 when another
#   capture of the same worktree is running.
# ---------------------------------------------------------------------------

# Folder of one worktree's capture state inside a store: index and lock.
wt_dir() {
    local gitdir key
    gitdir=$($GIT "${SAFE[@]}" -C "$1" rev-parse --absolute-git-dir) || return 1
    key=$(printf '%s' "$gitdir" | shasum | cut -c1-16)
    # MUTATION=shared_index plants a bug: every worktree shares one capture index.
    [ "${MUTATION:-}" = shared_index ] && key=shared
    printf '%s/fx-worktrees/%s\n' "$2" "$key"
}

capture() {
    local ws=$1 store=$2 ref=$3
    local common dir rc
    common=$($GIT "${SAFE[@]}" -C "$ws" rev-parse --path-format=absolute --git-common-dir) || return 1
    if [ ! -d "$store" ]; then
        $GIT init -q --bare --template= "$store" || return 1
        mkdir -p "$store/objects/info"
        printf '%s\n' "$common/objects" > "$store/objects/info/alternates"
    fi
    dir=$(wt_dir "$ws" "$store") || return 1
    mkdir -p "$dir"
    # One capture at a time per worktree, held for the whole capture. The
    # kernel drops a flock when its process dies, so it cannot go stale.
    exec 9> "$dir/capture.lock"
    if ! python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)' 2> /dev/null; then
        exec 9>&-
        return 3
    fi
    # While this process holds the capture lock, a git index.lock left in the
    # folder can only belong to a capture that was killed.
    rm -f "$dir/index.lock"
    capture_locked "$ws" "$store" "$ref" "$dir"
    rc=$?
    exec 9>&-
    return $rc
}

capture_locked() {
    local ws=$1 store=$2 ref=$3 dir=$4
    local gitdir idx
    gitdir=$($GIT "${SAFE[@]}" -C "$ws" rev-parse --absolute-git-dir) || return 1
    idx="$dir/index"
    local scratch="$dir"
    # All intermediates are isolated under the whole-worktree capture lock.
    [ "${MUTATION:-}" = shared_temporaries ] && scratch="$store"
    echo complete > "$scratch/last.status"
    # A sparse index holds folder entries the capture cannot expand safely:
    # report it instead of writing a wrong tree (fx's indexer refuses it too).
    if [ "$($GIT "${SAFE[@]}" -C "$ws" config --bool index.sparse 2>/dev/null)" = true ]; then
        echo "unavailable:index_sparse" > "$scratch/last.status"
        return 0
    fi
    if [ ! -f "$idx" ]; then
        # A split index keeps entries in a sharedindex file the copy would
        # not have, so the capture index is rebuilt from HEAD instead.
        if [ "$($GIT "${SAFE[@]}" -C "$ws" config --bool core.splitIndex 2>/dev/null)" = true ] || compgen -G "$gitdir/sharedindex.*" > /dev/null; then
            local head_tree
            head_tree=$($GIT "${SAFE[@]}" -C "$ws" rev-parse -q --verify 'HEAD^{tree}' 2>/dev/null || true)
            if [ -n "$head_tree" ]; then GIT_INDEX_FILE="$idx" $GIT "${SAFE[@]}" --git-dir="$store" read-tree "$head_tree" || return 1; fi
            echo "complete:index_rebuilt" > "$scratch/last.status"
        elif [ -f "$gitdir/index" ]; then
            # git trusts a file's size and time unless the file is as new as
            # the index itself; then it compares content. A plain copy gets a
            # new time and silently turns that check off, so the copy keeps
            # the time of the user's index.
            # MUTATION=fresh_copy plants a bug: the copy gets a new time.
            if [ "${MUTATION:-}" = fresh_copy ]; then cp "$gitdir/index" "$idx"; else cp -p "$gitdir/index" "$idx"; fi
            # The copy brings the user's assume-unchanged and skip-worktree
            # bits. Either one makes git skip reading the file, so the capture
            # index drops both: it must always describe what is on disk.
            # MUTATION=keep_flags plants a bug: the bits stay.
            if [ "${MUTATION:-}" != keep_flags ]; then
                GIT_INDEX_FILE="$idx" $GIT "${SAFE[@]}" --git-dir="$store" ls-files -z -v > "$scratch/last.flags" || return 1
                python3 - "$scratch" <<'PY' || return 1
import os, sys
store = sys.argv[1]
entries = [e for e in open(os.path.join(store, 'last.flags'), 'rb').read().split(b'\0') if e]
lists = {'last.valid': [e[2:] for e in entries if e[:1].islower()],
         'last.skip': [e[2:] for e in entries if e[:1] in (b'S', b's')]}
for name, paths in lists.items():
    open(os.path.join(store, name), 'wb').write(b''.join(path + b'\0' for path in paths))
PY
                if [ -s "$scratch/last.valid" ]; then
                    GIT_INDEX_FILE="$idx" $GIT "${SAFE[@]}" --git-dir="$store" --work-tree="$ws" update-index -z --no-assume-unchanged --stdin < "$scratch/last.valid" || return 1
                fi
                if [ -s "$scratch/last.skip" ]; then
                    GIT_INDEX_FILE="$idx" $GIT "${SAFE[@]}" --git-dir="$store" --work-tree="$ws" update-index -z --no-skip-worktree --stdin < "$scratch/last.skip" || return 1
                fi
            fi
        fi
    fi

    # Tracked entries come from the user's index on every capture, with their
    # tag, mode and object id: deleted paths included, and skip-worktree
    # entries with the value the user's index has now.
    $GIT "${SAFE[@]}" --no-optional-locks -C "$ws" ls-files -z -t -s --cached > "$scratch/last.tracked" || return 1
    # Untracked candidates come from the indexer (or git, for comparison).
    if [ "$LIST_MODE" = indexer ]; then
        # The indexer refuses index formats it cannot read (split or sparse
        # index); the read-only git listing is the fallback, not an option.
        if ! "$LIST" "$ws" > "$scratch/last.listed" 2>/dev/null; then
            $GIT "${SAFE[@]}" --no-optional-locks -C "$ws" ls-files -z --cached --others --exclude-standard > "$scratch/last.listed" || return 1
            printf '%s,git_listing\n' "$(cat "$scratch/last.status")" > "$scratch/last.status"
        fi
    else
        $GIT "${SAFE[@]}" --no-optional-locks -C "$ws" ls-files -z --cached --others --exclude-standard > "$scratch/last.listed" || return 1
    fi
    GIT_INDEX_FILE="$idx" $GIT "${SAFE[@]}" --git-dir="$store" ls-files -z > "$scratch/last.previous" 2>/dev/null || : > "$scratch/last.previous"

    python3 - "$ws" "$scratch" "$UNTRACKED_MAX_BYTES" <<'PY' || return 1
import fnmatch, os, sys
ws, store, max_bytes = sys.argv[1], sys.argv[2], int(sys.argv[3])
mutation = os.environ.get('MUTATION')
read = lambda name: [p for p in open(os.path.join(store, name), 'rb').read().split(b'\0') if p]
tagged, listed, previous = read('last.tracked'), read('last.listed'), read('last.previous')
# A skip-worktree entry that is absent from disk is absent on purpose (sparse
# checkout): it keeps the mode and object id the user's index has now. One
# that is on disk is read from disk like any tracked file.
# MUTATION=no_skip plants a bug: absent skip-worktree entries count as deleted.
keep, tracked, seen = {}, [], set()
for entry in tagged:
    meta, path = entry.split(b'\t', 1)
    tag, mode, oid, _stage = meta.split(b' ')
    absent = not os.path.lexists(os.path.join(ws.encode(), path))
    if tag in (b'S', b's') and absent and mutation != 'no_skip':
        keep[path] = (mode, oid)
    elif path not in seen:  # an unmerged path is listed once per stage
        seen.add(path)
        tracked.append(path)
tracked_set = seen | set(keep)
sensitive = ['.env', '.env.*', '.envrc', '*.pem', '*.key', '*.p12', 'id_rsa*', 'id_ed25519*', '.netrc', '.npmrc']
# MUTATION=no_tracked plants a bug: tracked paths come only from the listing.
add, excluded = ([] if mutation == 'no_tracked' else list(tracked)), []
for path in listed:
    if path in tracked_set:
        continue
    name = os.path.basename(path.decode('utf-8', 'surrogateescape'))
    full = os.path.join(ws.encode(), path)
    if any(fnmatch.fnmatch(name, pattern) for pattern in sensitive):
        excluded.append((path, b'sensitive'))
    elif not os.path.islink(full) and os.path.isfile(full) and os.path.getsize(full) > max_bytes:
        excluded.append((path, b'too_large'))
    else:
        add.append(path)
add_set = set(add)
out = lambda name, data: open(os.path.join(store, name), 'wb').write(data)
out('last.add', b''.join(path + b'\0' for path in add))
out('last.stale', b''.join(path + b'\0' for path in previous if path not in add_set and path not in keep))
# MUTATION=stale_sparse plants a bug: kept entries are never refreshed.
out('last.keep', b'' if mutation == 'stale_sparse' else b''.join(mode + b' ' + oid + b'\t' + path + b'\0' for path, (mode, oid) in keep.items()))
out('last.excluded', b''.join(path + b'\t' + reason + b'\n' for path, reason in excluded))
PY

    # MUTATION=no_stale plants a bug: paths that left the capture are kept.
    if [ -s "$scratch/last.stale" ] && [ "${MUTATION:-}" != no_stale ]; then
        GIT_INDEX_FILE="$idx" $GIT "${SAFE[@]}" --git-dir="$store" --work-tree="$ws" update-index -z --force-remove --stdin < "$scratch/last.stale" || return 1
    fi
    if [ -s "$scratch/last.keep" ]; then
        GIT_INDEX_FILE="$idx" $GIT "${SAFE[@]}" --git-dir="$store" update-index -z --index-info < "$scratch/last.keep" || return 1
    fi
    GIT_INDEX_FILE="$idx" $GIT "${SAFE[@]}" --git-dir="$store" --work-tree="$ws" update-index -z --add --remove --stdin < "$scratch/last.add" || return 1
    local tree parent commit
    tree=$(GIT_INDEX_FILE="$idx" $GIT "${SAFE[@]}" --git-dir="$store" write-tree) || return 1
    parent=$($GIT "${SAFE[@]}" --git-dir="$store" rev-parse -q --verify "$ref" 2>/dev/null || true)
    if [ -n "$parent" ]; then
        commit=$($GIT "${SAFE[@]}" "${FX_IDENTITY[@]}" --git-dir="$store" commit-tree "$tree" -p "$parent" -m capture) || return 1
    else
        commit=$($GIT "${SAFE[@]}" "${FX_IDENTITY[@]}" --git-dir="$store" commit-tree "$tree" -m capture) || return 1
    fi
    $GIT "${SAFE[@]}" --git-dir="$store" update-ref "$ref" "$commit" "${parent:-0000000000000000000000000000000000000000}" || return 1
    printf '%s\n' "$tree"
}

# What the user's own git would record for the same state, minus the paths
# the capture excludes on purpose. Uses a throwaway index; scratch repos only.
expected_tree() {
    local ws=$1 store=$2
    local scratch; scratch=$(wt_dir "$ws" "$store")
    local gitdir ref_idx
    gitdir=$($GIT -C "$ws" rev-parse --absolute-git-dir)
    ref_idx="$WORK/expected.$RANDOM.idx"
    if [ -f "$gitdir/index" ]; then cp -p "$gitdir/index" "$ref_idx"; else rm -f "$ref_idx"; fi
    GIT_INDEX_FILE="$ref_idx" $GIT -C "$ws" add -A
    if [ -s "$scratch/last.excluded" ]; then
        cut -f1 "$scratch/last.excluded" | while IFS= read -r p; do
            GIT_INDEX_FILE="$ref_idx" $GIT -C "$ws" rm -q --cached --ignore-unmatch -- "$p"
        done
    fi
    GIT_INDEX_FILE="$ref_idx" $GIT -C "$ws" write-tree
    rm -f "$ref_idx"
}

# Restores TREE from STORE into a new folder and compares it with the
# workspace: file set, bytes, executable bit and symlink targets.
restore_matches() {
    local store=$1 tree=$2 ws=$3
    local out="$WORK/restore.$RANDOM"
    mkdir -p "$out"
    GIT_INDEX_FILE="$out.idx" $GIT "${SAFE[@]}" --git-dir="$store" --work-tree="$out" read-tree "$tree" || return 1
    GIT_INDEX_FILE="$out.idx" $GIT "${SAFE[@]}" --git-dir="$store" --work-tree="$out" checkout-index -a -f || return 1
    python3 - "$ws" "$out" "$(wt_dir "$ws" "$store")" <<'PY'
import os, stat, sys
ws, out, store = sys.argv[1:]
add = [p for p in open(os.path.join(store, 'last.add'), 'rb').read().split(b'\0') if p]
problems = []
expected = set()
for rel in add:
    src = os.path.join(ws.encode(), rel)
    if not os.path.lexists(src):
        continue
    if os.path.isdir(src) and not os.path.islink(src):
        continue  # submodule: recorded as a gitlink, not restored as files
    expected.add(rel)
    dst = os.path.join(out.encode(), rel)
    if not os.path.lexists(dst):
        problems.append(b'missing ' + rel); continue
    if os.path.islink(src) != os.path.islink(dst):
        problems.append(b'type ' + rel); continue
    if os.path.islink(src):
        if os.readlink(src) != os.readlink(dst): problems.append(b'link ' + rel)
        continue
    if open(src, 'rb').read() != open(dst, 'rb').read(): problems.append(b'bytes ' + rel)
    if bool(os.stat(src).st_mode & stat.S_IXUSR) != bool(os.stat(dst).st_mode & stat.S_IXUSR): problems.append(b'mode ' + rel)
for root, dirs, files in os.walk(out.encode()):
    for name in files + [d for d in dirs if os.path.islink(os.path.join(root, d))]:
        rel = os.path.relpath(os.path.join(root, name), out.encode())
        if rel not in expected: problems.append(b'extra ' + rel)
print(b'; '.join(problems[:5]).decode('utf-8', 'replace') if problems else 'ok')
PY
    rm -rf "$out" "$out.idx"
}

# A repository with every shape the capture must handle.
make_repo() {
    local r=$1
    mkdir -p "$r" && cd "$r" || return 1
    $GIT init -q
    printf 'one\n' > a.txt
    mkdir -p dir nested
    printf 'b\n' > dir/b.txt
    printf '#!/bin/sh\necho hi\n' > exec.sh && chmod +x exec.sh
    ln -s a.txt link
    head -c 4096 /dev/urandom > bin.dat
    printf 'space\n' > 'space name.txt'
    printf 'unicode\n' > 'ñandú.txt'
    printf 'tmp/\n' > nested/.gitignore
    printf 'c\n' > nested/c.txt
    printf 'delete me\n' > todelete.txt
    printf 'rename me\n' > torename.txt
    printf '*.log\n' > .gitignore
    printf 'tracked but ignored\n' > keep.log
    $GIT add -A && $GIT add -f keep.log && $GIT commit -q -m base
    cd - > /dev/null || return 1
}

dirty_repo() {
    local r=$1
    cd "$r" || return 1
    printf 'two\n' >> a.txt                                # modified
    printf 'staged\n' >> dir/b.txt && $GIT add dir/b.txt  # staged ...
    printf 'unstaged\n' >> dir/b.txt                      # ... then changed again
    chmod -x exec.sh                                      # mode change
    rm todelete.txt                                       # tracked deleted
    mv torename.txt renamed.txt                           # rename
    rm link && ln -s dir/b.txt link                       # symlink retargeted
    printf 'new\n' > new.txt                              # untracked
    mkdir -p newdir && printf 'x\n' > newdir/x.txt         # untracked in new folder
    printf 'ignored\n' > debug.log                        # ignored untracked
    mkdir -p nested/tmp && printf 't\n' > nested/tmp/t.txt # ignored by nested rule
    printf 'local\n' > local.txt && echo local.txt >> .git/info/exclude
    printf 'SECRET=1\n' > .env                             # sensitive untracked
    head -c $((3 * 1024 * 1024)) /dev/urandom > big.bin    # too large untracked
    printf 'more tracked-ignored\n' >> keep.log            # tracked file matching .gitignore
    cd - > /dev/null || return 1
}

# Read without refreshing the index, so the probe itself cannot change it.
user_state() { (cd "$1" && export GIT_OPTIONAL_LOCKS=0 && $GIT status --porcelain=v1 -uall && $GIT diff --cached --stat && $GIT rev-parse -q --verify HEAD; shasum < .git/index) 2>/dev/null; }

echo "== list mode: $LIST_MODE"

# 1. Correctness against the user's git, restore, user state untouched -------
R="$WORK/repo"; S="$WORK/store1"
make_repo "$R"; dirty_repo "$R"
before=$(user_state "$R")
t1=$(capture "$R" "$S" refs/fx/sessions/one) || bad "capture runs" "capture failed"
check "1a dirty capture equals the user's git (minus exclusions)" "$t1" "$(expected_tree "$R" "$S")"
check "1b excluded .env and big.bin with reasons" "$(sort "$(wt_dir "$R" "$S")/last.excluded" | tr '\t\n' ':,')" ".env:sensitive,big.bin:too_large,"
check "1c restore is byte-exact, modes and symlinks included" "$(restore_matches "$S" "$t1" "$R")" "ok"
after=$(user_state "$R")
check "1d user's status, staged changes and index file unchanged" "$after" "$before"
check "1e keep.log (tracked, matches .gitignore) captured" "$($GIT --git-dir="$S" ls-tree --name-only "$t1" keep.log)" "keep.log"
check "1f local.txt (info/exclude) not captured" "$($GIT --git-dir="$S" ls-tree --name-only "$t1" local.txt)" ""
check "1g todelete.txt (deleted tracked) not captured" "$($GIT --git-dir="$S" ls-tree --name-only "$t1" todelete.txt)" ""

# 2. Second capture: previous untracked deleted, another newly ignored -------
cd "$R" && rm new.txt && echo 'newdir/' >> .gitignore && printf 'later\n' > later.txt && cd - > /dev/null
t2=$(capture "$R" "$S" refs/fx/sessions/one) || bad "second capture runs" "capture failed"
check "2a second capture equals the user's git" "$t2" "$(expected_tree "$R" "$S")"
check "2b session ref keeps a two-capture chain" "$($GIT --git-dir="$S" rev-list --count refs/fx/sessions/one)" "2"
check "2c newly ignored newdir/x.txt dropped" "$($GIT --git-dir="$S" ls-tree -r --name-only "$t2" newdir)" ""

# 3. Commit linking: the user commits the same state -------------------------
cd "$R" && rm -f .env big.bin && $GIT add -A && $GIT commit -q -m work && cd - > /dev/null
t3=$(capture "$R" "$S" refs/fx/sessions/one)
check "3a capture of a clean tree equals the new commit's tree" "$t3" "$($GIT -C "$R" rev-parse 'HEAD^{tree}')"

# 4. GC keeps captures reachable from the session ref ------------------------
$GIT --git-dir="$S" gc -q --prune=now 2>/dev/null
check "4a captures survive gc in the fx store" "$($GIT --git-dir="$S" cat-file -t "$t1")" "tree"
check "4b restore still byte-exact after gc" "$(restore_matches "$S" "$t3" "$R")" "ok"

# 5. Repository with no commits -----------------------------------------------
U="$WORK/unborn"; mkdir -p "$U" && (cd "$U" && $GIT init -q && printf 'u\n' > u.txt && mkdir d && printf 'v\n' > d/v.txt)
tu=$(capture "$U" "$WORK/store-unborn" refs/fx/sessions/u) || bad "5 unborn capture runs"
check "5a unborn repository captures untracked files" "$tu" "$(expected_tree "$U" "$WORK/store-unborn")"
check "5b unborn HEAD is detected" "$($GIT -C "$U" rev-parse -q --verify HEAD || echo unborn)" "unborn"

# 6. Linked worktree ----------------------------------------------------------
W="$WORK/linked"
$GIT -C "$R" worktree add -q "$W" -b side 2>/dev/null
(cd "$W" && printf 'wt change\n' >> a.txt && printf 'wt new\n' > wt.txt)
tw=$(capture "$W" "$WORK/store-wt" refs/fx/sessions/w) || bad "6 worktree capture runs"
check "6a linked worktree capture equals the user's git" "$tw" "$(expected_tree "$W" "$WORK/store-wt")"
check "6b alternates point at the common object store" "$(cat "$WORK/store-wt/objects/info/alternates")" "$($GIT -C "$W" rev-parse --path-format=absolute --git-common-dir)/objects"

# 7. Submodule whose HEAD moved ------------------------------------------------
SUBSRC="$WORK/subsrc"; mkdir -p "$SUBSRC" && (cd "$SUBSRC" && $GIT init -q && printf 's1\n' > s.txt && $GIT add -A && $GIT commit -q -m s1)
M="$WORK/withsub"; mkdir -p "$M" && (cd "$M" && $GIT init -q && printf 'm\n' > m.txt && $GIT submodule -q add "$SUBSRC" sub 2>/dev/null && $GIT commit -q -m with-sub)
(cd "$M/sub" && printf 's2\n' >> s.txt && $GIT commit -q -am s2 && printf 'dirty inside\n' >> s.txt)
tm=$(capture "$M" "$WORK/store-sub" refs/fx/sessions/m) || bad "7 submodule capture runs"
check "7a submodule recorded as gitlink at its new HEAD, like the user's git" "$tm" "$(expected_tree "$M" "$WORK/store-sub")"
check "7b gitlink points at the submodule's HEAD" "$($GIT --git-dir="$WORK/store-sub" ls-tree "$tm" sub | awk '{print $1, $3}')" "160000 $($GIT -C "$M/sub" rev-parse HEAD)"

# 8. Concurrent captures on one store -----------------------------------------
C="$WORK/conc"; make_repo "$C"; dirty_repo "$C"
capture "$C" "$WORK/store-c" refs/fx/sessions/c1 > /dev/null
printf 'race\n' >> "$C/a.txt"
( capture "$C" "$WORK/store-c" refs/fx/sessions/c1 > "$WORK/c1.out" 2>&1; echo $? > "$WORK/c1.rc" ) &
( capture "$C" "$WORK/store-c" refs/fx/sessions/c2 > "$WORK/c2.out" 2>&1; echo $? > "$WORK/c2.rc" ) &
wait
rcs="$(cat "$WORK/c1.rc")$(cat "$WORK/c2.rc")"
if [ "$rcs" = "00" ] || [ "$rcs" = "03" ] || [ "$rcs" = "30" ]; then ok "8a concurrent captures: each one succeeds or reports locked, never an error (rc=$rcs)"; else bad "8a concurrent captures" "rc=$rcs"; fi
check "8b store passes fsck after the race" "$($GIT --git-dir="$WORK/store-c" fsck --no-dangling 2>&1 | grep -c -E 'error|missing|broken')" "0"

# 9. Locks: a killed capture cannot block the next one ---------------------------
CD=$(wt_dir "$C" "$WORK/store-c")
: > "$CD/index.lock"                                      # what a killed git process leaves behind
if capture "$C" "$WORK/store-c" refs/fx/sessions/c1 > /dev/null 2>&1; then ok "9a a git index.lock left by a killed capture is cleared under the capture lock"; else bad "9a leftover index.lock"; fi
python3 -c 'import fcntl, sys, time
f = open(sys.argv[1], "w"); fcntl.flock(f, fcntl.LOCK_EX); open(sys.argv[2], "w").close(); time.sleep(60)' "$CD/capture.lock" "$WORK/holder.ready" &
holder=$!
while [ ! -e "$WORK/holder.ready" ]; do sleep 0.05; done
capture "$C" "$WORK/store-c" refs/fx/sessions/c1 > /dev/null 2>&1
check "9b while another process captures this worktree, a capture reports locked at once" "$?" "3"
kill "$holder" 2> /dev/null; wait "$holder" 2> /dev/null
if capture "$C" "$WORK/store-c" refs/fx/sessions/c1 > /dev/null 2>&1; then ok "9c the lock goes away with the process that held it"; else bad "9c capture after the holder died"; fi

# 10. Lost user objects are detected ------------------------------------------
L="$WORK/lost"; mkdir -p "$L" && (cd "$L" && $GIT init -q && printf 'base\n' > f.txt && $GIT add -A && $GIT commit -q -m base && printf 'only in a dropped commit\n' > f.txt && $GIT commit -q -am dropped)
tl=$(capture "$L" "$WORK/store-lost" refs/fx/sessions/l)
check "10a store wrote no copy of committed content (alternates)" "$(find "$WORK/store-lost/objects" -type f -path '*/objects/??/*' | wc -l | tr -d ' ')" "1"
(cd "$L" && $GIT reset -q --hard HEAD~1 && $GIT reflog expire --expire=now --all && $GIT gc -q --prune=now)
if $GIT --git-dir="$WORK/store-lost" fsck --connectivity-only --no-dangling > /dev/null 2>&1; then bad "10b missing base is detected"; else ok "10b fsck reports the capture broken after the user pruned its objects (base no disponible)"; fi

# 11. Line-ending conversion makes trees incomparable -------------------------
E="$WORK/eol"; mkdir -p "$E" && (cd "$E" && $GIT init -q && $GIT config core.autocrlf input && printf 'a\r\nb\r\n' > crlf.txt)
te=$(capture "$E" "$WORK/store-eol" refs/fx/sessions/e)
if [ "$te" != "$(expected_tree "$E" "$WORK/store-eol")" ]; then ok "11a repo-scope core.autocrlf changes the tree, so comparable must be false"; else bad "11a eol mismatch" "trees matched unexpectedly"; fi
check "11b repo-scope core.autocrlf is visible in the repository config" "$($GIT -C "$E" config --local --get core.autocrlf)" "input"

# 12. Repository-controlled programs never run ---------------------------------
X="$WORK/trap"; make_repo "$X"; dirty_repo "$X"
SENT="$WORK/sentinel.sh"; SLOG="$WORK/sentinel.log"
printf '#!/bin/sh\necho ran >> %s\ncat\n' "$SLOG" > "$SENT" && chmod +x "$SENT"
(cd "$X" && printf '*.txt filter=evil\n' >> .gitattributes && $GIT config filter.evil.clean "$SENT" && $GIT config filter.evil.process "$SENT" && $GIT config core.fsmonitor "$SENT" && mkdir -p .git/hooks && for h in post-index-change reference-transaction pre-commit; do ln -sf "$SENT" ".git/hooks/$h"; done)
capture "$X" "$WORK/store-trap" refs/fx/sessions/x > /dev/null || bad "12 trap capture runs"
check "12a no planted filter, fsmonitor or hook ran during capture" "$( [ -f "$SLOG" ] && grep -c ran "$SLOG" || echo 0)" "0"
(cd "$X" && $GIT add -A > /dev/null 2>&1; $GIT reset -q > /dev/null 2>&1)
if [ -f "$SLOG" ] && [ "$(grep -c ran "$SLOG")" -gt 0 ]; then ok "12b control: plain git in the same repo runs them ($(grep -c ran "$SLOG") times)"; else bad "12b control did not exercise the trap"; fi

# 16. Sparse checkout: tracked files absent on purpose stay in the capture -----
SP="$WORK/sparse"; mkdir -p "$SP/in" "$SP/out" && (cd "$SP" && $GIT init -q && echo i > in/a && echo o > out/b && $GIT add -A && $GIT commit -q -m base && $GIT sparse-checkout set --cone in > /dev/null 2>&1)
check "16a sparse checkout left out/b off disk (fixture)" "$([ -e "$SP/out/b" ] && echo yes || echo no)" "no"
tsp=$(capture "$SP" "$WORK/store-sparse" refs/fx/sessions/sp) || bad "16 sparse capture runs"
check "16b clean sparse checkout captures HEAD's tree, out/b included" "$tsp" "$($GIT -C "$SP" rev-parse 'HEAD^{tree}')"
printf 'edited\n' >> "$SP/in/a"
tsp2=$(capture "$SP" "$WORK/store-sparse" refs/fx/sessions/sp)
check "16c sparse checkout with an edit equals the user's git" "$tsp2" "$(expected_tree "$SP" "$WORK/store-sparse")"

# 17. Split index: the store's index is rebuilt instead of copied ---------------
SI="$WORK/split"; mkdir -p "$SI" && (cd "$SI" && $GIT init -q && $GIT config core.splitIndex true && echo x > x && mkdir d && echo y > d/y && $GIT add -A && $GIT commit -q -m base && echo more >> x && echo new > n.txt)
check "17a split index writes a sharedindex file (fixture)" "$(compgen -G "$SI/.git/sharedindex.*" > /dev/null && echo yes || echo no)" "yes"
tsi=$(capture "$SI" "$WORK/store-split" refs/fx/sessions/si) || bad "17 split capture runs"
check "17b split index capture equals the user's git" "$tsi" "$(expected_tree "$SI" "$WORK/store-split")"
expected_status="complete:index_rebuilt"; [ "$LIST_MODE" = indexer ] && expected_status="complete:index_rebuilt,git_listing"
check "17c split index is recorded as rebuilt, with the git listing fallback" "$(cat "$(wt_dir "$SI" "$WORK/store-split")/last.status")" "$expected_status"

# 18. Sparse index: reported as unavailable, never a wrong tree ----------------
SX="$WORK/sparseidx"; mkdir -p "$SX/in" "$SX/out" && (cd "$SX" && $GIT init -q && echo i > in/a && echo o > out/b && $GIT add -A && $GIT commit -q -m base && $GIT sparse-checkout set --cone --sparse-index in > /dev/null 2>&1)
tsx=$(capture "$SX" "$WORK/store-sparseidx" refs/fx/sessions/sx)
check "18a sparse index capture reports unavailable with a reason" "$(cat "$(wt_dir "$SX" "$WORK/store-sparseidx")/last.status")" "unavailable:index_sparse"
check "18b sparse index capture writes no tree" "$tsx" ""

# 27. A file changed in the same second as the index, with the same size -------
RC="$WORK/racy"; mkdir -p "$RC" && cd "$RC" && $GIT init -q
python3 -c 'import time; time.sleep(1 - time.time() % 1 + 0.02)'            # start right after a second boundary
echo one > f && $GIT add f && $GIT commit -q -m base && echo two > f           # same size, same second as the index write
cd - > /dev/null; sleep 1.2                                                     # the capture runs in a later second
check "27a the user's own git sees the change, without refreshing its index (fixture)" "$($GIT --no-optional-locks -C "$RC" status --porcelain | tr -d '\n')" " M f"
trc=$(capture "$RC" "$WORK/store-racy" refs/fx/sessions/rc)
check "27b a same-size change made in the index's own second is captured" "$($GIT --git-dir="$WORK/store-racy" show "$trc:f" 2>&1)" "two"
check "27c and it restores byte for byte" "$(restore_matches "$WORK/store-racy" "$trc" "$RC")" "ok"

# 21. Index flags must not hide what is on disk --------------------------------
FL="$WORK/flags"; mkdir -p "$FL" && (cd "$FL" && $GIT init -q && echo one > au.txt && echo one > sw.txt && echo one > plain.txt && $GIT add -A && $GIT commit -q -m base \
    && $GIT update-index --assume-unchanged au.txt && $GIT update-index --skip-worktree sw.txt && echo two > au.txt && echo two > sw.txt)
tfl=$(capture "$FL" "$WORK/store-flags" refs/fx/sessions/fl) || bad "21 flags capture runs"
check "21a an assume-unchanged file is captured as it is on disk" "$($GIT --git-dir="$WORK/store-flags" show "$tfl:au.txt" 2>&1)" "two"
check "21b a skip-worktree file present on disk is captured as it is on disk" "$($GIT --git-dir="$WORK/store-flags" show "$tfl:sw.txt" 2>&1)" "two"
check "21c restore reproduces the flagged files byte for byte" "$(restore_matches "$WORK/store-flags" "$tfl" "$FL")" "ok"
check "21d the user's own index flags are untouched" "$($GIT -C "$FL" ls-files -v au.txt sw.txt | tr '\n' ' ')" "h au.txt S sw.txt "

# 22. Sparse checkout that changes between captures ---------------------------
SL="$WORK/sparse-later"; mkdir -p "$SL/in" "$SL/out" && (cd "$SL" && $GIT init -q && echo i > in/a && echo old > out/b && $GIT add -A && $GIT commit -q -m base && $GIT sparse-checkout set --cone in > /dev/null 2>&1)
capture "$SL" "$WORK/store-sl" refs/fx/sessions/sl > /dev/null || bad "22 first sparse capture runs"
(cd "$SL" && $GIT sparse-checkout disable && echo new > out/b && $GIT commit -q -am upd && $GIT sparse-checkout set --cone in) > /dev/null 2>&1
tsl=$(capture "$SL" "$WORK/store-sl" refs/fx/sessions/sl)
check "22a a file outside the cone that changed in HEAD is captured at its current version" "$tsl" "$($GIT -C "$SL" rev-parse 'HEAD^{tree}')"
(cd "$SL" && $GIT sparse-checkout disable > /dev/null 2>&1 && echo edited > out/b)
tsl=$(capture "$SL" "$WORK/store-sl" refs/fx/sessions/sl)
check "22b a file that came back on disk and was edited is captured from disk" "$tsl" "$(expected_tree "$SL" "$WORK/store-sl")"

# 23. Two worktrees of one repository share objects, never the capture index ---
WM="$WORK/wt-main"; mkdir -p "$WM/in" "$WM/out" && (cd "$WM" && $GIT init -q && echo i > in/a && echo main > out/b && $GIT add -A && $GIT commit -q -m base \
    && $GIT worktree add -q -b side "$WORK/wt-side" && cd "$WORK/wt-side" && echo side > out/b && $GIT commit -q -am side && $GIT sparse-checkout set --cone in) > /dev/null 2>&1
(cd "$WM" && $GIT sparse-checkout set --cone in > /dev/null 2>&1)
twm=$(capture "$WM" "$WORK/store-wt2" refs/fx/sessions/wm)
tws=$(capture "$WORK/wt-side" "$WORK/store-wt2" refs/fx/sessions/ws)
twm2=$(capture "$WM" "$WORK/store-wt2" refs/fx/sessions/wm)
check "23a the main worktree captures its own branch" "$twm" "$($GIT -C "$WM" rev-parse 'HEAD^{tree}')"
check "23b the side worktree captures its own branch through the same store" "$tws" "$($GIT -C "$WORK/wt-side" rev-parse 'HEAD^{tree}')"
check "23c the main worktree is still right after the side capture" "$twm2" "$($GIT -C "$WM" rev-parse 'HEAD^{tree}')"

# 23d-e. With core.checkStat=minimal git compares only size and time, so a
# capture index shared by two worktrees cannot tell their files apart.
printf '[user]\n\tname = fixture\n\temail = fixture@example.invalid\n[core]\n\tcheckStat = minimal\n' > "$WORK/minimal.gitconfig"
CM="$WORK/cs-main"; mkdir -p "$CM" && (cd "$CM" && $GIT init -q && echo main > f && $GIT add -A && $GIT commit -q -m base && $GIT worktree add -q -b side "$WORK/cs-side" && cd "$WORK/cs-side" && echo side > f && $GIT commit -q -am side) > /dev/null 2>&1
touch -t 202001010000 "$CM/f" "$WORK/cs-side/f"            # same size, same time, different content
tcm=$(export GIT_CONFIG_GLOBAL="$WORK/minimal.gitconfig"; capture "$CM" "$WORK/store-cs" refs/fx/sessions/cm)
tcs=$(export GIT_CONFIG_GLOBAL="$WORK/minimal.gitconfig"; capture "$WORK/cs-side" "$WORK/store-cs" refs/fx/sessions/cs)
check "23d with minimal stat checks the main worktree captures its own file" "$($GIT --git-dir="$WORK/store-cs" show "$tcm:f" 2>&1)" "main"
check "23e with minimal stat the side worktree captures its own file, not main's" "$($GIT --git-dir="$WORK/store-cs" show "$tcs:f" 2>&1)" "side"

# 28. Interleaved worktrees must not share capture intermediates.
# Pause main after it writes its tracked entries. Complete side, then resume
# main: no timing guesses and both trees must match their own HEAD.
REAL_LIST="$LIST"
cat > "$WORK/barrier-list" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "$PAUSE_REPO" ]; then
    touch "$BARRIER/ready"
    for i in {1..500}; do
        [ -e "$BARRIER/go" ] && break
        sleep 0.02
    done
    [ -e "$BARRIER/go" ] || exit 1
fi
exec "$REAL_LIST" "$@"
SH
chmod +x "$WORK/barrier-list"
mkdir -p "$WORK/barrier"
(export PAUSE_REPO="$WM" BARRIER="$WORK/barrier" REAL_LIST; LIST="$WORK/barrier-list"; LIST_MODE=indexer; capture "$WM" "$WORK/store-wt2" refs/fx/sessions/wm > "$WORK/barrier-main.tree"; echo $? > "$WORK/barrier-main.rc") & paused=$!
for i in {1..500}; do [ -e "$WORK/barrier/ready" ] && break; sleep 0.02; done
capture "$WORK/wt-side" "$WORK/store-wt2" refs/fx/sessions/ws > "$WORK/barrier-side.tree"; side_rc=$?
touch "$WORK/barrier/go"; wait "$paused"
check "28a both interleaved captures succeed" "$(cat "$WORK/barrier-main.rc") $side_rc" "0 0"
check "28b paused main captures main, not side" "$(cat "$WORK/barrier-main.tree")" "$($GIT -C "$WM" rev-parse 'HEAD^{tree}')"
check "28c side captures its own state" "$(cat "$WORK/barrier-side.tree")" "$($GIT -C "$WORK/wt-side" rev-parse 'HEAD^{tree}')"

# 24. Branch switch between captures -------------------------------------------
BS="$WORK/switch"; mkdir -p "$BS" && (cd "$BS" && $GIT init -q && echo a > f && echo keep > k && $GIT add -A && $GIT commit -q -m base && $GIT checkout -q -b other && echo b > f && echo extra > g && $GIT add -A && $GIT commit -q -m other && $GIT checkout -q main && echo dirty >> k)
capture "$BS" "$WORK/store-switch" refs/fx/sessions/bs > /dev/null
(cd "$BS" && $GIT checkout -q -- k && $GIT checkout -q other && echo wip > h.txt)
tbs=$(capture "$BS" "$WORK/store-switch" refs/fx/sessions/bs)
check "24a after a branch switch the persistent capture index follows the new state" "$tbs" "$(expected_tree "$BS" "$WORK/store-switch")"

# 25. Retention: evicting a whole session frees its data and nothing else ------
# The budget evicts the oldest sessions whole: their ref is deleted and a gc
# with a grace period drops what only they held. The grace period, git's own
# protection, keeps objects a running capture wrote but has not referenced yet.
RT="$WORK/retain"; RS="$WORK/store-retain"
mkdir -p "$RT" && (cd "$RT" && $GIT init -q && echo base > f && $GIT add -A && $GIT commit -q -m base)
head -c 300000 /dev/urandom > "$RT/old-session.bin"
t_old=$(capture "$RT" "$RS" refs/fx/sessions/old)
t_old2=$(echo more >> "$RT/f"; capture "$RT" "$RS" refs/fx/sessions/old)      # a second capture in the same chain
rm "$RT/old-session.bin"; head -c 300000 /dev/urandom > "$RT/new-session.bin"
t_new=$(capture "$RT" "$RS" refs/fx/sessions/new)
old_blob=$($GIT --git-dir="$RS" rev-parse "$t_old:old-session.bin")
kib_before=$(du -sk "$RS/objects" | awk '{print $1}')
$GIT "${SAFE[@]}" --git-dir="$RS" gc -q --prune=1.hour.ago 2> /dev/null
check "25a while its session ref exists, every capture of the chain survives cleanup" "$($GIT --git-dir="$RS" cat-file -t "$t_old" 2>&1) $($GIT --git-dir="$RS" cat-file -t "$t_old2" 2>&1)" "tree tree"
$GIT "${SAFE[@]}" --git-dir="$RS" update-ref -d refs/fx/sessions/old                # evict the oldest session, whole
find "$RS/objects" -type f \( -path '*/objects/??/*' -o -name '*.pack' -o -name '*.idx' -o -name '*.mtimes' \) -exec touch -t 202001010000 {} +   # its data is old
inflight=$(echo "written by a capture that is still running" | $GIT --git-dir="$RS" hash-object -w --stdin)
$GIT "${SAFE[@]}" --git-dir="$RS" gc -q --prune=1.hour.ago 2> /dev/null
kib_after=$(du -sk "$RS/objects" | awk '{print $1}')
check "25b the evicted session's own content is gone" "$($GIT --git-dir="$RS" cat-file -e "$old_blob" 2> /dev/null && echo present || echo gone)" "gone"
check "25c the store shrank by about the evicted content" "$([ $((kib_before - kib_after)) -ge 250 ] && echo yes || echo "no: $kib_before -> $kib_after KiB")" "yes"
check "25d the retained session still restores byte for byte" "$(restore_matches "$RS" "$t_new" "$RT")" "ok"
check "25e an object a running capture just wrote survives the cleanup" "$($GIT --git-dir="$RS" cat-file -e "$inflight" 2> /dev/null && echo present || echo gone)" "present"
check "25f the store keeps no reflog that would hold evicted captures" "$(find "$RS" -path '*/logs/*' -type f | wc -l | tr -d ' ')" "0"

# 26. The user's global git config cannot break or bloat the store -------------
# No identity, reflogs for every ref and commit signing are all things a
# trusted global config may set; the capture must not depend on any of them.
printf '#!/bin/sh\necho ran >> %s\nexit 1\n' "$WORK/gpg.log" > "$WORK/fakegpg" && chmod +x "$WORK/fakegpg"
printf '[core]\n\tlogAllRefUpdates = always\n[commit]\n\tgpgsign = true\n[gpg]\n\tprogram = %s\n[user]\n\tsigningkey = ABC\n' "$WORK/fakegpg" > "$WORK/hostile.gitconfig"
HG="$WORK/hostile"; mkdir -p "$HG" && (cd "$HG" && $GIT init -q && echo x > f && $GIT add -A && $GIT commit -q -m base && echo y >> f)
thg=$(export GIT_CONFIG_GLOBAL="$WORK/hostile.gitconfig"; capture "$HG" "$WORK/store-hostile" refs/fx/sessions/hg 2> "$WORK/hostile.err"); hrc=$?
check "26a capture works with no git identity configured" "$hrc $($GIT --git-dir="$WORK/store-hostile" show "$thg:f" 2>&1 | tr '\n' ' ')" "0 x y "
check "26b the capture commit carries fx's fixed identity" "$($GIT --git-dir="$WORK/store-hostile" log -1 --format='%an <%ae>' refs/fx/sessions/hg 2>&1)" "fx <fx@localhost>"
check "26c a global logAllRefUpdates=always creates no reflog in the store" "$(find "$WORK/store-hostile" -path '*/logs/*' -type f | wc -l | tr -d ' ')" "0"
check "26d a global commit.gpgsign never runs the signing program" "$([ -f "$WORK/gpg.log" ] && echo ran || echo never)" "never"

# 14. Workspace without git: only files fx's edit tools touch -----------------
# Simulates fx's file mutation handoff, which already carries each file's
# preimage (absent or its bytes) and after-content. Nothing walks the folder.
#   touched_capture STORE REF ROOT MANIFEST PATH... -> prints the tree id
touched_capture() {
    local store=$1 ref=$2 root=$3 manifest=$4; shift 4
    [ -d "$store" ] || $GIT init -q --bare --template= "$store" || return 1
    local idx="$store/touched.$RANDOM.idx" p sha parent commit tree
    rm -f "$idx"; : > "$manifest"
    for p in "$@"; do
        if [ -L "$root/$p" ] || [ -f "$root/$p" ]; then
            sha=$($GIT "${SAFE[@]}" --git-dir="$store" hash-object -w --no-filters -- "$root/$p") || return 1
            mode=100644; [ -x "$root/$p" ] && mode=100755
            GIT_INDEX_FILE="$idx" $GIT "${SAFE[@]}" --git-dir="$store" update-index --add --cacheinfo "$mode,$sha,$p" || return 1
            printf 'present\t%s\n' "$p" >> "$manifest"
        else
            printf 'absent\t%s\n' "$p" >> "$manifest"
        fi
    done
    if [ -f "$idx" ]; then tree=$(GIT_INDEX_FILE="$idx" $GIT --git-dir="$store" write-tree); else tree=$($GIT --git-dir="$store" mktree < /dev/null); fi
    rm -f "$idx"
    parent=$($GIT --git-dir="$store" rev-parse -q --verify "$ref" 2>/dev/null || true)
    commit=$($GIT --git-dir="$store" commit-tree "$tree" ${parent:+-p "$parent"} -m touched) || return 1
    $GIT --git-dir="$store" update-ref "$ref" "$commit" "${parent:-0000000000000000000000000000000000000000}" || return 1
    printf '%s\n' "$tree"
}
N="$WORK/notgit"; NS="$WORK/store-notgit"
mkdir -p "$N/notes" && printf 'original\n' > "$N/notes/a.md" && printf 'untouched secret\n' > "$N/private.txt"
# Turn start: the agent is about to edit notes/a.md and create notes/new.md.
ts=$(touched_capture "$NS" refs/fx/sessions/n "$N" "$WORK/start.manifest" notes/a.md notes/new.md)
printf 'edited\n' > "$N/notes/a.md"; printf 'created\n' > "$N/notes/new.md"
te=$(touched_capture "$NS" refs/fx/sessions/n "$N" "$WORK/end.manifest" notes/a.md notes/new.md)
check "14a start capture keeps the preimage of the edited file" "$($GIT --git-dir="$NS" show "$ts":notes/a.md)" "original"
check "14b start manifest records the created file as absent" "$(grep notes/new.md "$WORK/start.manifest" | cut -f1)" "absent"
check "14c end capture has both files' new content" "$($GIT --git-dir="$NS" show "$te":notes/a.md)|$($GIT --git-dir="$NS" show "$te":notes/new.md)" "edited|created"
check "14d untouched files are never stored" "$($GIT --git-dir="$NS" ls-tree -r --name-only "$te" | tr '\n' ' ')" "notes/a.md notes/new.md "
check "14e the folder was not turned into a repository" "$([ -e "$N/.git" ] && echo yes || echo no)" "no"

# 15. Linking later commits to the session's end captures --------------------
# A user commit links to the session when its tree equals an end capture's
# tree. Only first-parent commits since the HEAD recorded at capture count.
#   link_commits WORKSPACE STORE REF SINCE_HEAD -> prints linked commit ids
link_commits() {
    local ws=$1 store=$2 ref=$3 since=$4
    $GIT "${SAFE[@]}" --git-dir="$store" log --format=%T "$ref" | sort -u > "$WORK/capture.trees"
    $GIT "${SAFE[@]}" --no-optional-locks -C "$ws" rev-list --first-parent --max-count=50 --format='%T %H' HEAD "^$since" |
        grep -v '^commit ' | sort > "$WORK/commit.trees"
    # MUTATION=link_any plants a bug: every later commit is linked.
    if [ "${MUTATION:-}" = link_any ]; then awk '{print $2}' "$WORK/commit.trees" | sort; return; fi
    join "$WORK/capture.trees" "$WORK/commit.trees" | awk '{print $2}' | sort
}
K="$WORK/link"; KS="$WORK/store-link"
mkdir -p "$K" && (cd "$K" && $GIT init -q && printf 'base\n' > f.txt && printf 'g\n' > g.txt && $GIT add -A && $GIT commit -q -m base)
base=$($GIT -C "$K" rev-parse HEAD)
(cd "$K" && printf 'turn edit\n' >> f.txt && printf 'turn edit\n' >> g.txt)
capture "$K" "$KS" refs/fx/sessions/k > /dev/null                  # end of the agent's turn
(cd "$K" && $GIT add f.txt && $GIT commit -q -m partial)            # user commits only part
check "15a a partial commit is not an exact link" "$(link_commits "$K" "$KS" refs/fx/sessions/k "$base")" ""
(cd "$K" && $GIT add g.txt && $GIT commit -q -m rest)               # the rest: same tree as the capture
rest=$($GIT -C "$K" rev-parse HEAD)
check "15b the commit whose tree equals the end capture links" "$(link_commits "$K" "$KS" refs/fx/sessions/k "$base")" "$rest"
(cd "$K" && $GIT commit -q --amend -m 'reworded')                   # same tree, new commit id
amended=$($GIT -C "$K" rev-parse HEAD)
check "15c rewording keeps the link through the tree" "$(link_commits "$K" "$KS" refs/fx/sessions/k "$base")" "$amended"
(cd "$K" && printf 'later\n' > h.txt && $GIT add h.txt && $GIT commit -q -m later)
check "15d a later unrelated commit does not link" "$(link_commits "$K" "$KS" refs/fx/sessions/k "$base")" "$amended"
# Alternates let the store read user objects; it must not own or reference them.
check "15e the store keeps no copy of user commits and no refs outside refs/fx" "$([ -e "$KS/objects/${amended:0:2}/${amended:2}" ] && echo copied || echo none) $($GIT --git-dir="$KS" for-each-ref --format='%(refname)' | grep -vc '^refs/fx/')" "none 0"

# 19. Why links need both moments: next turn start and export -----------------
# Export-time linking compares capture trees with every commit still in the
# repository.
export_links() {
    local ws=$1 store=$2 ref=$3
    $GIT "${SAFE[@]}" --git-dir="$store" log --format=%T "$ref" | sort -u > "$WORK/capture.trees"
    $GIT "${SAFE[@]}" --no-optional-locks -C "$ws" log --all --format='%T %H' | sort > "$WORK/all.trees"
    join "$WORK/capture.trees" "$WORK/all.trees" | awk '{print $2}' | sort
}
Q="$WORK/squash"; QS="$WORK/store-squash"
mkdir -p "$Q" && (cd "$Q" && $GIT init -q && echo a > a && echo b > b && $GIT add -A && $GIT commit -q -m base && $GIT checkout -q -b feat && echo "agent change" >> a)
qbase=$($GIT -C "$Q" rev-parse main)
capture "$Q" "$QS" refs/fx/sessions/q > /dev/null                     # end of the agent's turn
(cd "$Q" && $GIT commit -q -am "agent work"); qc=$($GIT -C "$Q" rev-parse HEAD)
next_turn=$(link_commits "$Q" "$QS" refs/fx/sessions/q "$qbase")         # recorded at the next turn start
(cd "$Q" && $GIT checkout -q main && echo other >> b && $GIT commit -q -am other && $GIT merge -q --squash feat > /dev/null 2>&1 && $GIT commit -q -m squash \
    && $GIT branch -q -D feat && $GIT reflog expire --expire=now --all && $GIT gc -q --prune=now)
check "19a next-turn linking recorded the commit before it was squashed away" "$next_turn" "$qc"
check "19b export-time linking finds nothing once the commit is pruned" "$(export_links "$Q" "$QS" refs/fx/sessions/q)" ""
(cd "$Q" && $GIT checkout -q -b late && echo late >> a)
capture "$Q" "$QS" refs/fx/sessions/q > /dev/null                     # the session's last turn
(cd "$Q" && $GIT commit -q -am late); ql=$($GIT -C "$Q" rev-parse HEAD) # no further turn runs
check "19c export-time linking finds a commit made after the last turn" "$(export_links "$Q" "$QS" refs/fx/sessions/q)" "$ql"

# 20. Capture per repository touched (D14) ------------------------------------
# The session starts in a folder without git and works on repositories below
# it. A repository is captured right before the first action that targets it:
# an edit tool's file, or a command whose working directory is inside it.
# fx would find the repository with its indexer's discovery, without git.
repo_top() { $GIT "${SAFE[@]}" -C "$1" rev-parse --show-toplevel 2>/dev/null; }
TURN_TOUCHED=()
touch_repo() { # touch_repo PATH TRIGGER: captures PATH's repository if new this turn
    local dir=$1 trigger=$2 top
    [ -d "$dir" ] || dir=$(dirname "$dir")
    top=$(repo_top "$dir") || { echo "not_git" >> "$WORK/touch.log"; return 0; }
    case " ${TURN_TOUCHED[*]-} " in *" $top "*) return 0 ;; esac
    TURN_TOUCHED+=("$top")
    # MUTATION=late_touch plants a bug: the start capture happens after the action.
    if [ "${MUTATION:-}" != late_touch ]; then
        capture "$top" "$WORK/store-$(basename "$top")" refs/fx/sessions/home > "$WORK/start-$(basename "$top").tree"
    fi
    printf '%s\t%s\n' "$(basename "$top")" "$trigger" >> "$WORK/touch.log"
}
end_turn() { local top; for top in "${TURN_TOUCHED[@]}"; do
    if [ "${MUTATION:-}" = late_touch ]; then capture "$top" "$WORK/store-$(basename "$top")" refs/fx/sessions/home > "$WORK/start-$(basename "$top").tree"; fi
    capture "$top" "$WORK/store-$(basename "$top")" refs/fx/sessions/home > "$WORK/end-$(basename "$top").tree"; done; }
H="$WORK/homelike"; mkdir -p "$H"; : > "$WORK/touch.log"
for name in alpha beta gamma; do mkdir -p "$H/$name" && (cd "$H/$name" && $GIT init -q && echo "$name v1" > f.txt && $GIT add -A && $GIT commit -q -m base); done
printf 'pre-existing local edit\n' >> "$H/beta/f.txt"                  # the user's dirty work in beta
alpha_before=$(expected_tree "$H/alpha" "$WORK/none"); beta_before=$(expected_tree "$H/beta" "$WORK/none")
gamma_head=$($GIT -C "$H/gamma" rev-parse HEAD)
check "20a the session folder itself is not a repository" "$(repo_top "$H" || echo none)" "none"
touch_repo "$H/alpha/f.txt" edit_tool; printf 'agent edit\n' >> "$H/alpha/f.txt"   # edit tool targets alpha
touch_repo "$H/alpha/new.txt" edit_tool; printf 'new\n' > "$H/alpha/new.txt"       # second touch: no new capture
touch_repo "$H/beta" command_cwd; (cd "$H/beta" && printf 'generated\n' > out.txt)  # command runs inside beta
end_turn
check "20b alpha's start capture is its state before the agent's first edit" "$(cat "$WORK/start-alpha.tree")" "$alpha_before"
check "20c beta's start capture keeps the user's dirty work, before the command ran" "$(cat "$WORK/start-beta.tree")" "$beta_before"
check "20d each touched repository is captured once at start, with its trigger" "$(sort "$WORK/touch.log" | tr '\t\n' ':,')" "alpha:edit_tool,beta:command_cwd,"
check "20e alpha's end capture has both agent changes" "$(cat "$WORK/end-alpha.tree")" "$(expected_tree "$H/alpha" "$WORK/store-alpha")"
check "20f beta's end capture has the command's output" "$($GIT --git-dir="$WORK/store-beta" ls-tree --name-only "$(cat "$WORK/end-beta.tree")" out.txt)" "out.txt"
check "20g an untouched repository gets no store and no capture" "$([ -e "$WORK/store-gamma" ] && echo captured || echo none) $($GIT -C "$H/gamma" rev-parse HEAD)" "none $gamma_head"

# 13. Optional end-to-end timing on a real repository (read-only) -------------
if [ -n "${PERF_REPO:-}" ]; then
    P="$WORK/store-perf"
    a=$(now); capture "$PERF_REPO" "$P" refs/fx/sessions/p > /dev/null || bad "13 perf capture runs"; b=$(now)
    c=$(now); capture "$PERF_REPO" "$P" refs/fx/sessions/p > /dev/null; d=$(now)
    python3 -c "print('INFO  13 %s: first=%.2fs repeat=%.2fs objects=%.1fMiB index=%.1fMiB prototype_lists=%.1fMiB' % ('$(basename "$PERF_REPO")', $b-$a, $d-$c, $(du -sk "$P/objects" | awk '{print $1}')/1024, $(du -sk "$(wt_dir "$PERF_REPO" "$P")/index" | awk '{print $1}')/1024, $(cat "$(wt_dir "$PERF_REPO" "$P")"/last.* | wc -c)/1048576))"
fi

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
