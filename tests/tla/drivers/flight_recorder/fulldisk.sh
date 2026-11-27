#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../../../.." && pwd)
LAB_BIN=${FX_FLIGHT_RECORDER_LAB:-"$REPO_ROOT/zig-out/bin/flight-recorder-lab"}

if [ ! -x "$LAB_BIN" ]; then
  echo "missing executable: $LAB_BIN (run: zig build flight-recorder-lab)" >&2
  exit 1
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fx-fr-fulldisk.XXXXXX")
ATTACHED_DEV=""
MOUNTED_DIR=""
LAB_PID=""

cleanup() {
  if [ -n "$LAB_PID" ]; then
    kill -9 "$LAB_PID" 2>/dev/null || true
    wait "$LAB_PID" 2>/dev/null || true
    LAB_PID=""
  fi
  if [ -n "$MOUNTED_DIR" ]; then
    if [ -n "${SUDO:-}" ]; then
      $SUDO umount "$MOUNTED_DIR" 2>/dev/null || true
    else
      umount "$MOUNTED_DIR" 2>/dev/null || true
    fi
    MOUNTED_DIR=""
  fi
  if [ -n "$ATTACHED_DEV" ]; then
    hdiutil detach "$ATTACHED_DEV" >/dev/null 2>&1 || hdiutil detach -force "$ATTACHED_DEV" >/dev/null 2>&1 || true
    ATTACHED_DEV=""
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

fill_disk() {
  target_mnt=$1
  dd if=/dev/zero of="$target_mnt/filler.bin" bs=65536 2>/dev/null || true
  dd if=/dev/zero of="$target_mnt/filler_tail.bin" bs=512 2>/dev/null || true
}

run_case_a() {
  fs_name=$1
  mnt=$2
  dir_a="$mnt/case-a"
  mkdir -p "$dir_a"
  chmod 0700 "$dir_a"

  emit_out="$TMP_ROOT/emit_a_${fs_name}.json"
  emit_err="$TMP_ROOT/emit_a_${fs_name}.err"
  "$LAB_BIN" emit "$dir_a" 2 1500 --segment-bytes 1048576 --sync-ms 50 --payload-bytes 16384 --delay-us 400 >"$emit_out" 2>"$emit_err" &
  LAB_PID=$!

  i=0
  while [ "$i" -lt 300 ]; do
    if ls "$dir_a"/*.open >/dev/null 2>&1; then
      break
    fi
    i=$((i + 1))
    sleep 0.01 2>/dev/null || sleep 1
  done

  fill_disk "$mnt"

  set +e
  wait "$LAB_PID"
  emit_rc=$?
  set -e
  LAB_PID=""

  if [ "$emit_rc" -ne 0 ]; then
    echo "FAIL [$fs_name] case (a): lab emit exited $emit_rc (stderr: $(cat "$emit_err"))" >&2
    exit 1
  fi

  read_json=$("$LAB_BIN" read "$dir_a")
  bun -e '
    const [fsName, raw] = process.argv.slice(1);
    const r = JSON.parse(raw);
    const total = r.frames + r.dropped;
    if (total !== 3000 || r.dropped <= 0 || r.torn !== 0 || r.missing !== 0 || r.newer !== 0) {
      console.error(`FAIL [${fsName}] case (a): unexpected summary ${raw}`);
      process.exit(1);
    }
    console.log(`PASS [${fsName}] case (a): exit=0 frames=${r.frames} dropped=${r.dropped} total=${total}`);
  ' "$fs_name" "$read_json"
}

run_case_b() {
  fs_name=$1
  mnt=$2
  dir_b="$mnt/case-b"
  mkdir -p "$dir_b"
  chmod 0700 "$dir_b"

  fill_disk "$mnt"

  emit_out="$TMP_ROOT/emit_b_${fs_name}.json"
  emit_err="$TMP_ROOT/emit_b_${fs_name}.err"
  set +e
  "$LAB_BIN" emit "$dir_b" 2 500 --segment-bytes 1048576 --sync-ms 50 --payload-bytes 16384 >"$emit_out" 2>"$emit_err"
  emit_rc=$?
  set -e

  if [ "$emit_rc" -ne 0 ]; then
    echo "FAIL [$fs_name] case (b): lab emit exited $emit_rc (stderr: $(cat "$emit_err"))" >&2
    exit 1
  fi

  read_json=$("$LAB_BIN" read "$dir_b")
  emit_json=$(cat "$emit_out")
  bun -e '
    const [fsName, rawEmit, rawRead] = process.argv.slice(1);
    const e = JSON.parse(rawEmit);
    const r = JSON.parse(rawRead);
    const droppedTotal = e.startup_buffered + e.startup_dropped;
    if (e.segments !== 0 || r.frames !== 0 || r.torn !== 0 || r.holes !== 0 || r.missing !== 0 || droppedTotal !== 1000) {
      console.error(`FAIL [${fsName}] case (b): emit=${rawEmit} read=${rawRead}`);
      process.exit(1);
    }
    console.log(`PASS [${fsName}] case (b): exit=0 segments=${e.segments} dropped_total=${droppedTotal} (startup_buffered=${e.startup_buffered}, startup_dropped=${e.startup_dropped})`);
  ' "$fs_name" "$emit_json" "$read_json"
}

run_macos_apfs() {
  case_name=$1
  dmg="$TMP_ROOT/apfs_${case_name}.dmg"
  mnt="$TMP_ROOT/mnt_apfs_${case_name}"
  mkdir -p "$mnt"

  hdiutil create -size 40m -fs APFS -volname "fx-fr-${case_name}-$$" "$dmg" >/dev/null
  attach_out=$(hdiutil attach -nobrowse -mountpoint "$mnt" "$dmg")
  ATTACHED_DEV=$(printf '%s\n' "$attach_out" | awk 'NR==1 { print $1 }')
  if [ -z "$ATTACHED_DEV" ]; then
    echo "FAIL: could not determine attached device from hdiutil attach" >&2
    exit 1
  fi

  if [ "$case_name" = "a" ]; then
    run_case_a "APFS" "$mnt"
  else
    run_case_b "APFS" "$mnt"
  fi

  hdiutil detach "$ATTACHED_DEV" >/dev/null
  ATTACHED_DEV=""
  rm -f "$dmg"
}

run_linux_tmpfs() {
  case_name=$1
  mnt="$TMP_ROOT/mnt_tmpfs_${case_name}"
  mkdir -p "$mnt"
  $SUDO mount -t tmpfs -o size=40M tmpfs "$mnt"
  MOUNTED_DIR="$mnt"
  $SUDO chmod 0777 "$mnt"

  if [ "$case_name" = "a" ]; then
    run_case_a "tmpfs" "$mnt"
  else
    run_case_b "tmpfs" "$mnt"
  fi

  $SUDO umount "$mnt"
  MOUNTED_DIR=""
}

run_linux_ext4() {
  case_name=$1
  img="$TMP_ROOT/ext4_${case_name}.img"
  mnt="$TMP_ROOT/mnt_ext4_${case_name}"
  mkdir -p "$mnt"
  dd if=/dev/zero of="$img" bs=1048576 count=40 2>/dev/null
  mkfs.ext4 -q -F "$img"
  $SUDO mount -o loop "$img" "$mnt"
  MOUNTED_DIR="$mnt"
  $SUDO chmod 0777 "$mnt"

  if [ "$case_name" = "a" ]; then
    run_case_a "ext4" "$mnt"
  else
    run_case_b "ext4" "$mnt"
  fi

  $SUDO umount "$mnt"
  MOUNTED_DIR=""
  rm -f "$img"
}

OS=$(uname -s)
case "$OS" in
  Darwin)
    run_macos_apfs a
    run_macos_apfs b
    ;;
  Linux)
    SUDO=""
    if [ "$(id -u)" -eq 0 ]; then
      SUDO=""
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      SUDO="sudo -n"
    else
      echo "SKIP: Linux fulldisk.sh requires root or passwordless sudo for tmpfs and ext4 loop mounts"
      exit 0
    fi
    run_linux_tmpfs a
    run_linux_tmpfs b
    run_linux_ext4 a
    run_linux_ext4 b
    ;;
  *)
    echo "SKIP: unsupported OS $OS"
    exit 0
    ;;
esac
