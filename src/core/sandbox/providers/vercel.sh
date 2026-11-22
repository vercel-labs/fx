#!/bin/bash
# fx sandbox provider for Vercel Sandbox, over the standalone `sandbox` CLI
# (4.x: `npm i -g sandbox`). fx runs it for every shell call that a rule in
# ~/.fx/sandbox/config.json places in a sandbox, and once at startup to sweep.
#
#   vercel.sh [provider options] run --mode workspace|isolated --root DIR
#             --cwd DIR --state DIR [--profile NAME] [--env NAME]...
#             [sandbox create flags...] -- COMMAND
#   vercel.sh [provider options] sweep --state DIR
#
# Provider options: --cli PATH (default `sandbox`), --scope TEAM,
# --project NAME, --token TOKEN, --command-timeout DURATION (default 30m),
# and --remote-base DIR, which puts sandbox paths under DIR/<sandbox> instead
# of at the same path as here (tests use it with a fake CLI).
#
# The command's output streams to stdout and stderr. Lines that start with
# "fx: " on stderr say where it ran and which files moved. The exit status is
# the command's, or 125 when the command did not run. On SIGTERM the command
# is killed in the sandbox and the exit status is 143.
#
# The rules this script keeps are model-checked in
# tests/tla/sandbox/SandboxProvider.tla.
# The single-quoted scripts run in the sandbox, and the trap handlers run
# from traps.
# shellcheck disable=SC2016,SC2329
set -u

CLI=sandbox
COMMON=()
RBASE=""
CTIMEOUT=30m
MAX_BACK=500

note() { printf 'fx: %s\n' "$*" >&2; }
did_not_run() { note "the command did not run: $*"; exit 125; }
last_line() { printf '%s\n' "$1" | sed '/^[[:space:]]*$/d' | tail -n 1; }
hash_hex() { printf '%s' "$1" | { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-"$2"; }

# The CLI takes its own options after the subcommand words.
sb() { "$CLI" "$1" ${COMMON[@]+"${COMMON[@]}"} "${@:2}"; }
sb2() { "$CLI" "$1" "$2" ${COMMON[@]+"${COMMON[@]}"} "${@:3}"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --cli) CLI=$2; shift 2 ;;
        --scope | --project | --token) COMMON+=("$1" "$2"); shift 2 ;;
        --command-timeout) CTIMEOUT=$2; shift 2 ;;
        --remote-base) RBASE=$2; shift 2 ;;
        run | sweep) break ;;
        *) did_not_run "unknown provider option $1" ;;
    esac
done
[ $# -gt 0 ] || did_not_run "no subcommand"
SUB=$1
shift

MODE=""
ROOT=""
CWD=""
STATE=""
PROFILE=default
ENVS=()
CREATE=()
while [ $# -gt 0 ]; do
    case "$1" in
        --mode) MODE=$2; shift 2 ;;
        --root) ROOT=$2; shift 2 ;;
        --cwd) CWD=$2; shift 2 ;;
        --state) STATE=$2; shift 2 ;;
        --profile) PROFILE=$2; shift 2 ;;
        --env) ENVS+=("$2"); shift 2 ;;
        --) shift; break ;;
        *) CREATE+=("$1"); shift ;;
    esac
done
[ -n "$STATE" ] || did_not_run "no --state folder"
command -v "$CLI" >/dev/null 2>&1 || did_not_run "the sandbox CLI ($CLI) is not installed; run: npm i -g sandbox"

HOST_ID=$(hash_hex "$(hostname)" 8)
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/fx-sandbox.XXXXXX") || did_not_run "no temp folder"
trap 'rm -rf "$TMPD"' EXIT

# --- sweep -------------------------------------------------------------------

if [ "$SUB" = sweep ]; then
    # Isolated sandboxes are named fx-iso-<host>-<pid>-<n>; remove the ones
    # this machine made for a provider that is gone.
    sb ls --name-prefix "fx-iso-$HOST_ID-" --all 2>/dev/null | awk 'NR > 1 { print $1 }' |
        while read -r name; do
            pid=${name#"fx-iso-$HOST_ID-"}
            pid=${pid%%-*}
            case "$pid" in '' | *[!0-9]*) continue ;; esac
            kill -0 "$pid" 2>/dev/null && continue
            sb rm "$name" >/dev/null 2>&1 && note "removed the isolated sandbox $name"
        done
    exit 0
fi

[ "$SUB" = run ] || did_not_run "unknown subcommand $SUB"
[ $# -eq 1 ] || did_not_run "expected one command after --"
COMMAND=$1
case "$MODE" in workspace | isolated) ;; *) did_not_run "unknown mode '$MODE'" ;; esac
[ -d "$ROOT" ] || did_not_run "no root folder $ROOT"
[ -d "$CWD" ] || did_not_run "no folder $CWD"
case "$CWD/" in "$ROOT"/*) ;; *) did_not_run "$CWD is outside $ROOT" ;; esac
if ! mkdir -p "$STATE" || ! chmod 700 "$STATE"; then did_not_run "cannot use $STATE"; fi

IS_GIT=0
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 && IS_GIT=1
TAR_FLAGS=()
tar --version 2>/dev/null | grep -q bsdtar && TAR_FLAGS=(--no-mac-metadata --no-xattrs)
export COPYFILE_DISABLE=1

RUN_ID=""
NAME=""
RROOT=""

remote_path() { printf '%s%s' "$RROOT" "${1#"$ROOT"}"; }

# Make the root path in the sandbox, owned by the sandbox user.
make_remote_root() {
    local owner
    owner=$(sb exec "$NAME" -- sh -c 'printf %s:%s "$(id -u)" "$(id -g)"' 2>/dev/null) || return 1
    sb exec --sudo "$NAME" -- sh -c 'mkdir -p "$1" && chown "$2" "$1"' _ "$RROOT" "$owner" >/dev/null 2>&1
}

# NUL-separated paths under $1 that git does not ignore, relative to $1.
list_files() {
    if [ "$IS_GIT" = 1 ]; then
        git -C "$1" ls-files -z --cached --others --exclude-standard -- . 2>/dev/null
    else
        (cd "$1" && find . \( -name .git -prune \) -o \( -type f -o -type l \) -print0)
    fi
}

# Send files (NUL list in $2, relative to $1) into the sandbox folder $3.
push_files() {
    [ -s "$2" ] || return 0
    tar -C "$1" ${TAR_FLAGS[@]+"${TAR_FLAGS[@]}"} -czf - --null -T "$2" 2>"$TMPD/tar.err" |
        sb exec --stdin "$NAME" -- sh -c 'mkdir -p "$1" && cd "$1" && tar -xmzf -' _ "$3" >/dev/null 2>"$TMPD/push.err"
}

# Start the command detached, stream its output, and wait for its status.
run_remote() {
    local envflags=() n value rstamp
    if [ "$MODE" = workspace ]; then
        for n in ${ENVS[@]+"${ENVS[@]}"}; do
            case "$n" in '' | [0-9]* | *[!A-Za-z0-9_]*) note "skipped env name '$n'"; continue ;; esac
            if eval "[ -n \"\${$n+x}\" ]"; then
                eval "value=\${$n}"
                envflags+=(--env "$n=$value")
            else
                note "env $n is not set here, so the sandbox does not get it"
            fi
        done
    fi
    rstamp="/tmp/fx-run-$$-$RANDOM"
    RSTAMP=$rstamp
    # The command starts one clock tick after the stamp, so every file it writes
    # is newer than the stamp, while the files pushed before it are not. 50 ms
    # covers the coarsest Linux file clock (10 ms).
    RUN_ID=$(sb exec --detach --timeout "$CTIMEOUT" --workdir "$(remote_path "$CWD")" \
        ${envflags[@]+"${envflags[@]}"} "$NAME" -- sh -c 'touch "$1" && sleep 0.05; exec sh -c "$2"' _ "$rstamp" "$COMMAND" 2>"$TMPD/start.err")
    [ -n "$RUN_ID" ] || did_not_run "the sandbox did not start it: $(last_line "$(cat "$TMPD/start.err")")"
    sb2 commands logs "$NAME" "$RUN_ID" &
    LOGS=$!
    sb2 commands wait "$NAME" "$RUN_ID" >/dev/null 2>&1 &
    WAITER=$!
    wait "$WAITER"
    STATUS=$?
    wait "$LOGS" 2>/dev/null
}

on_term() {
    trap '' TERM INT
    if [ -n "$RUN_ID" ]; then
        if sb2 commands kill "$NAME" "$RUN_ID" >/dev/null 2>&1; then
            note "stopped the command in the sandbox $NAME"
        else
            note "could not stop the command in the sandbox $NAME; it ends by its timeout ($CTIMEOUT)"
        fi
    else
        note "stopped before the command started"
    fi
    exit 143
}
trap on_term TERM INT

# Names of files the command made or changed, relative to the sandbox folder
# $1, one per line, without ignored files.
remote_changes() {
    sb exec "$NAME" -- sh -c 'cd "$1" && find . -newer "$2" \( -type f -o -type l \) ! -path "./.git/*" -print' _ "$1" "$RSTAMP" 2>/dev/null |
        sed 's#^\./##' >"$TMPD/changed"
    if [ "$IS_GIT" = 1 ] && [ -s "$TMPD/changed" ]; then
        git -C "$ROOT" check-ignore --stdin <"$TMPD/changed" >"$TMPD/ignored" 2>/dev/null
        grep -vxF -f "$TMPD/ignored" "$TMPD/changed" >"$TMPD/changed.kept" || true
        mv "$TMPD/changed.kept" "$TMPD/changed"
    fi
}

# Copy the files named in $3 from sandbox folder $1 into local folder $2.
fetch_files() {
    [ -s "$3" ] || return 0
    mkdir -p "$2"
    # Command output is text, so the archive travels as base64.
    tr '\n' '\0' <"$3" | sb exec --stdin "$NAME" -- sh -c 'cd "$1" && tar -czf - --null -T - | base64' _ "$1" 2>/dev/null |
        base64 --decode 2>/dev/null | tar -xzf - -C "$2"
}

name_list() { awk -v max=20 'NR <= max { printf "%s%s", (NR > 1 ? ", " : ""), $0 } END { if (NR > max) printf " and %d more", NR - max }' "$1"; }

# --- workspace ----------------------------------------------------------------

if [ "$MODE" = workspace ]; then
    NAME="fx-ws-$(hash_hex "$ROOT" 16)"
    RROOT=$ROOT
    [ -n "$RBASE" ] && RROOT="$RBASE/$NAME$ROOT"
    SDIR="$STATE/$NAME"
    mkdir -p "$SDIR"

    if [ ! -f "$SDIR/ready" ]; then
        out=$(sb create --name "$NAME" --tag fx=workspace --timeout "$CTIMEOUT" 2>&1) ||
            case "$out" in *"already exists"*) ;; *) did_not_run "sandbox create failed: $(last_line "$out")" ;; esac
        make_remote_root || did_not_run "could not make $RROOT in the sandbox $NAME"
        rm -f "$SDIR/manifest"
        : >"$SDIR/ready"
    fi

    # Files changed here after this moment are kept here when the command ends.
    : >"$SDIR/sent-at"
    list_files "$ROOT" >"$TMPD/all"
    if [ "$IS_GIT" = 1 ]; then
        # Blob ids from a scratch index, so the user's index never changes.
        idx="$TMPD/index"
        cp "$(git -C "$ROOT" rev-parse --absolute-git-dir)/index" "$idx" 2>/dev/null || rm -f "$idx"
        GIT_INDEX_FILE=$idx git -C "$ROOT" add -A -- . >/dev/null 2>&1
        GIT_INDEX_FILE=$idx git -C "$ROOT" ls-files -s -- . 2>/dev/null |
            awk -F'\t' '$1 !~ /^160000/ { split($1, a, " "); print a[2] "\t" $2 }' >"$TMPD/manifest"
    else
        tr '\0' '\n' <"$TMPD/all" | awk '{ print "-\t" $0 }' >"$TMPD/manifest"
        rm -f "$SDIR/manifest"
    fi
    touch "$SDIR/manifest"
    awk -F'\t' -v del="$TMPD/deleted" '
        FILENAME == ARGV[1] { old[$2] = $1; next }
        { seen[$2] = 1; if (!($2 in old) || old[$2] != $1 || $1 == "-") print $2 }
        END { for (p in old) if (!(p in seen)) print p > del }
    ' "$SDIR/manifest" "$TMPD/manifest" | tr '\n' '\0' >"$TMPD/send"
    sent=$(tr -cd '\0' <"$TMPD/send" | wc -c | tr -d ' ')
    if ! push_files "$ROOT" "$TMPD/send" "$RROOT"; then
        rm -f "$SDIR/manifest" "$SDIR/ready"
        did_not_run "could not send files to the sandbox $NAME: $(last_line "$(cat "$TMPD/push.err" "$TMPD/tar.err" 2>/dev/null)")"
    fi
    if [ -s "$TMPD/deleted" ]; then
        tr '\n' '\0' <"$TMPD/deleted" | sb exec --stdin "$NAME" -- sh -c 'cd "$1" && xargs -0 rm -f --' _ "$RROOT" >/dev/null 2>&1
    fi
    cp "$TMPD/manifest" "$SDIR/manifest"

    run_remote
    if [ "$sent" -gt 0 ]; then
        note "ran in the workspace sandbox $NAME (sent $sent changed files)"
    else
        note "ran in the workspace sandbox $NAME"
    fi

    remote_changes "$RROOT"
    count=$(wc -l <"$TMPD/changed" | tr -d ' ')
    if [ "$count" -gt "$MAX_BACK" ]; then
        note "$count files changed in the sandbox, more than $MAX_BACK, so none came back"
    elif [ "$count" -gt 0 ]; then
        : >"$TMPD/take"
        : >"$TMPD/kept"
        while IFS= read -r f; do
            if [ -e "$ROOT/$f" ] && [ "$ROOT/$f" -nt "$SDIR/sent-at" ]; then
                printf '%s\n' "$f" >>"$TMPD/kept"
            else
                printf '%s\n' "$f" >>"$TMPD/take"
            fi
        done <"$TMPD/changed"
        fetch_files "$RROOT" "$ROOT" "$TMPD/take" && [ -s "$TMPD/take" ] && note "brought back: $(name_list "$TMPD/take")"
        [ -s "$TMPD/kept" ] && note "kept your version of: $(name_list "$TMPD/kept") (it changed here during the run)"
    fi
    [ "$STATUS" = 137 ] && note "exit 137: killed, maybe by the sandbox timeout ($CTIMEOUT)"
    exit "$STATUS"
fi

# --- isolated -----------------------------------------------------------------

NAME="fx-iso-$HOST_ID-$$-$RANDOM$RANDOM"
RROOT=$CWD
[ -n "$RBASE" ] && RROOT="$RBASE/$NAME$CWD"
remove_isolated() { sb rm "$NAME" >/dev/null 2>&1; }
trap 'remove_isolated; rm -rf "$TMPD"' EXIT

network=none
for flag in ${CREATE[@]+"${CREATE[@]}"}; do
    case "$flag" in --network-policy | --allowed-domain | --allowed-cidr) network=custom ;; esac
done
[ "$network" = none ] && CREATE+=(--network-policy deny-all)
out=$(sb create --name "$NAME" --non-persistent --timeout "$CTIMEOUT" --tag fx=isolated ${CREATE[@]+"${CREATE[@]}"} 2>&1) ||
    did_not_run "sandbox create failed: $(last_line "$out")"
make_remote_root || did_not_run "could not make $RROOT in the sandbox $NAME"
list_files "$CWD" >"$TMPD/send"
push_files "$CWD" "$TMPD/send" "$RROOT" ||
    did_not_run "could not send files to the sandbox $NAME: $(last_line "$(cat "$TMPD/push.err" "$TMPD/tar.err" 2>/dev/null)")"

run_remote
note "ran in a new isolated sandbox (profile $PROFILE, no keys, network: $network)"

remote_changes "$RROOT"
if [ -s "$TMPD/changed" ]; then
    count=$(wc -l <"$TMPD/changed" | tr -d ' ')
    if [ "$count" -gt "$MAX_BACK" ]; then
        note "$count files changed in the sandbox, more than $MAX_BACK, so none were kept"
    else
        RUNS="$STATE/runs/$(date +%Y%m%dT%H%M%S)-$$"
        fetch_files "$RROOT" "$RUNS" "$TMPD/changed" && note "new and changed files: $RUNS"
    fi
fi
[ "$STATUS" = 137 ] && note "exit 137: killed, maybe by the sandbox timeout ($CTIMEOUT)"
exit "$STATUS"
