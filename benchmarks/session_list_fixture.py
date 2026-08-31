#!/usr/bin/env python3
"""Generate projected schema-v3 sessions around large sparse event logs."""

import argparse
import hashlib
import json
import stat
from pathlib import Path


def stat_fingerprint(path: Path, expected_size: int) -> str:
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size != expected_size:
        raise ValueError(f"invalid event log stat for {path}")

    encoded = bytearray([1])
    encoded.extend(info.st_dev.to_bytes(8, "big"))
    encoded.extend(info.st_ino.to_bytes(8, "big"))
    encoded.extend(stat.S_IMODE(info.st_mode).to_bytes(8, "big"))
    encoded.extend(info.st_nlink.to_bytes(8, "big"))
    encoded.extend(info.st_size.to_bytes(8, "big"))
    encoded.extend(info.st_mtime_ns.to_bytes(16, "big", signed=True))
    encoded.extend(info.st_ctime_ns.to_bytes(16, "big", signed=True))
    return hashlib.sha256(b"fx:event-file-stat:v1\0" + encoded).hexdigest()


def write_private_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, separators=(",", ":")) + "\n", encoding="utf-8")
    path.chmod(0o600)


def generate(home: Path, workspace: Path, count: int, log_size: int, deny_event_read: bool) -> None:
    sessions_root = home / ".fx" / "sessions"
    sessions_root.mkdir(parents=True, mode=0o700, exist_ok=True)
    (home / ".fx").chmod(0o700)
    sessions_root.chmod(0o700)

    for index in range(count):
        session_id = f"benchmark-session-{index:02d}"
        authority_id = f"{index + 1:032x}"
        generation = f"{index + 101:032x}"
        event_seq = max(2, index + 1)
        session_dir = sessions_root / session_id
        session_dir.mkdir(mode=0o700)

        for lock_name in ("session.lock", "commit.lock"):
            lock = session_dir / lock_name
            lock.touch(mode=0o600)
            lock.chmod(0o600)

        event_log = session_dir / "events.jsonl"
        with event_log.open("wb") as file:
            file.truncate(log_size)
        event_log.chmod(0o000 if deny_event_read else 0o600)

        write_private_json(
            session_dir / "authority.json",
            {
                "schema_version": 1,
                "session_id": session_id,
                "authority_id": authority_id,
                "storage_format": "event_log_v1",
                "source": "native_create",
            },
        )
        watermark = session_dir / f"commit.{generation}.json"
        write_private_json(
            watermark,
            {
                "schema_version": 1,
                "session_id": session_id,
                "log_generation": generation,
                "through_seq": event_seq,
                "through_event_id": f"{index + 201:032x}",
                "through_event_log_bytes": log_size,
            },
        )
        if deny_event_read:
            watermark.chmod(0o000)
        write_private_json(
            session_dir / "session.json",
            {
                "schema_version": 3,
                "storage_format": "event_log_v1",
                "id": session_id,
                "authority_id": authority_id,
                "log_generation": generation,
                "created_at_ms": 1000 + index,
                "updated_at_ms": 2000 + index,
                "origin_workspace_root": str(workspace),
                "workspace_root": str(workspace),
                "conversation_language": "en",
                "history_len": index,
                "total_input_tokens": 0,
                "total_output_tokens": 0,
                "last_event_seq": event_seq,
                "event_log_bytes": log_size,
                "event_log_stat_fingerprint": stat_fingerprint(event_log, log_size),
                "generation_base_seq": 1,
                "generation_base_bytes": log_size,
                "checkpoint_seq": None,
                "checkpoint_sha256": None,
                "preferences": {
                    "model": "anthropic/claude-opus-4.7",
                    "effort": "auto",
                    "fast_mode": False,
                },
            },
        )
        write_private_json(
            session_dir / "display.json",
            {
                "schema_version": 1,
                "title": f"Benchmark session {index:02d}",
                "preview": f"Benchmark session {index:02d} preview",
                "origin_workspace_root": str(workspace),
            },
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", required=True, type=Path)
    parser.add_argument("--workspace", required=True, type=Path)
    parser.add_argument("--sessions", type=int, default=8)
    parser.add_argument("--log-size", type=int, default=256 * 1024 * 1024)
    parser.add_argument("--deny-event-read", action="store_true")
    args = parser.parse_args()
    generate(
        args.home.resolve(),
        args.workspace.resolve(),
        args.sessions,
        args.log_size,
        args.deny_event_read,
    )


if __name__ == "__main__":
    main()
