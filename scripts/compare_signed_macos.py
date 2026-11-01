"""Measure two notarized copies of one macOS arm64 payload."""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import pathlib
import platform
import re
import shutil
import struct
import subprocess

from scripts.pgso.qualify import MeasurementResult, measure_startup


def measurement_record(result: MeasurementResult) -> dict:
    record = dataclasses.asdict(result)
    record.pop("passed")
    if record["comparison"] is not None:
        record["comparison"].pop("passed", None)
    return record


def signature_layout(data: bytes) -> tuple[int, int, int, list[tuple[int, int]]]:
    if len(data) < 32:
        raise ValueError("truncated Mach-O header")
    magic, cpu, _, kind, count, size = struct.unpack_from("<6I", data)
    if (magic, cpu, kind) != (0xFEEDFACF, 0x0100000C, 2):
        raise ValueError("expected a thin arm64 Mach-O executable")
    end = 32 + size
    if end > len(data):
        raise ValueError("truncated load commands")
    command_offset = 32
    fields: list[tuple[int, int]] = []
    signature = None
    for _ in range(count):
        if command_offset + 8 > end:
            raise ValueError("truncated load command")
        command, length = struct.unpack_from("<2I", data, command_offset)
        if length < 8 or command_offset + length > end:
            raise ValueError("invalid load command length")
        if command == 0x19:
            if length < 72:
                raise ValueError("truncated segment")
            if data[command_offset + 8:command_offset + 24].rstrip(b"\0") == b"__LINKEDIT":
                if fields:
                    raise ValueError("ambiguous link-edit segment")
                fields.extend(((command_offset + 32, 8), (command_offset + 48, 8)))
        elif command == 0x1D:
            if signature is not None or length != 16:
                raise ValueError("ambiguous code signature")
            signature = struct.unpack_from("<2I", data, command_offset + 8)
            fields.append((command_offset + 12, 4))
        command_offset += length
    if command_offset != end or signature is None or len(fields) != 3:
        raise ValueError("missing signature or link-edit segment")
    offset, length = signature
    if offset < end or offset + length > len(data):
        raise ValueError("invalid code signature extent")
    return end, offset, length, fields


def compare_payloads(control: bytes, candidate: bytes) -> dict:
    old_end, old_offset, old_size, old_fields = signature_layout(control)
    new_end, new_offset, new_size, new_fields = signature_layout(candidate)
    if (old_end, old_offset, old_fields) != (new_end, new_offset, new_fields):
        raise ValueError("binary layouts differ")
    old_header = bytearray(control[:old_end])
    new_header = bytearray(candidate[:new_end])
    for offset, length in old_fields:
        old_header[offset:offset + length] = bytes(length)
        new_header[offset:offset + length] = bytes(length)
    if old_header != new_header or control[old_end:old_offset] != candidate[new_end:new_offset]:
        raise ValueError("application header or payload changed")
    if control[old_offset + old_size:] != candidate[new_offset + new_size:]:
        raise ValueError("trailing data changed")
    return {
        "payload_range": [old_end, old_offset],
        "payload_sha256": hashlib.sha256(control[old_end:old_offset]).hexdigest(),
        "saving_bytes": len(control) - len(candidate),
        "control_bytes": len(control), "candidate_bytes": len(candidate),
        "control_sha256": hashlib.sha256(control).hexdigest(),
        "candidate_sha256": hashlib.sha256(candidate).hexdigest(),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--control", type=pathlib.Path, required=True)
    parser.add_argument("--candidate", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--source-sha", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.source_sha):
        parser.error("source SHA must be a full commit hash")
    repo = pathlib.Path(__file__).resolve().parents[1]
    samples = 5_000
    binaries = {"control": args.control.resolve(), "candidate": args.candidate.resolve()}
    for label, path in binaries.items():
        if not path.is_file() or path.stat().st_size > 16 * 1024 * 1024:
            raise ValueError(f"invalid {label} binary")
        subprocess.run(["codesign", "--verify", "--strict", "--check-notarization", "-R=notarized", str(path)], check=True, timeout=60)
        details = subprocess.run(["codesign", "--display", "--verbose=4", str(path)], capture_output=True, text=True, check=True, timeout=30).stderr
        page = 4096 if label == "control" else 16384
        for required in ("Identifier=com.vercel.fx", "TeamIdentifier=JW6Y669B67", f"Page size={page}", "flags=0x10000(runtime)", "Timestamp="):
            if required not in details:
                raise ValueError(f"unexpected {label} signature: missing {required}")
    manifest = compare_payloads(binaries["control"].read_bytes(), binaries["candidate"].read_bytes())
    args.output.mkdir(parents=True, exist_ok=False)
    manifest.update({
        "artifact_source_sha": args.source_sha,
        "driver_sha": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
        "platform": platform.platform(),
        "cpu": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
        "hyperfine": subprocess.check_output(["hyperfine", "--version"], text=True).strip(),
        "samples_per_binary_per_command_per_cohort": samples, "cohorts": 2,
        "calibration": {"cohort": 2, "commands": ["status"], "pair": "control versus identical control"},
        "order": "alternating rounds; equal-length paths; reversed lanes in cohort 1",
        "boundary": "warm process launch to exit; not first-use Gatekeeper assessment",
        "qualification": "measurement only; inspect latency and memory evidence before shipping",
    })
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    hyperfine = pathlib.Path(shutil.which("hyperfine") or "hyperfine")
    for cohort in (0, 1, 2):
        paths = {}
        for label, lane in (("control", cohort % 2), ("candidate", 1 - cohort % 2)):
            directory = args.output / f"cohort-{cohort}" / f"lane-{lane}"
            directory.mkdir(parents=True)
            paths[label] = directory / "fx"
            shutil.copy2(binaries["control" if cohort == 2 else label], paths[label])
        results = measure_startup(
            repo_root=repo, control_binary=paths["control"], candidate_binary=paths["candidate"],
            hyperfine_binary=hyperfine, output_dir=args.output / f"startup-{cohort}",
            samples=samples, timeout_s=30, command_names=("status",) if cohort == 2 else None,
            retry_speed_failures=False,
        )
        records = [measurement_record(result) for result in results]
        for record in records:
            record["pair"] = "control-versus-control" if cohort == 2 else "control-versus-candidate"
        (args.output / f"startup-{cohort}.json").write_text(json.dumps(records, indent=2) + "\n")
        for result in results:
            print(f"cohort {cohort} {result.name}: p50 {result.comparison.p50_change:+.3%}, p95 {result.comparison.p95_change:+.3%}", flush=True)


if __name__ == "__main__":
    main()
