"""Bind release notes and prepared artifacts before asking for publication approval."""

from __future__ import annotations

import argparse
import base64
import datetime
import hashlib
import json
import pathlib
import re
import tarfile

from scripts.pgso.model import sha256_file


PLATFORMS = ("linux-aarch64", "linux-x86_64", "macos-aarch64", "macos-x86_64")
MIRROR_BASE = "https://ugiwefobuo4tac0m.public.blob.vercel-storage.com/release-candidates/sdk"
SEMVER = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
MAX_ARCHIVE_BYTES = 256 * 1024 * 1024


def validate_identity(version: str, source_sha: str, run_id: int, prepared_at: str) -> None:
    if not isinstance(version, str) or not re.fullmatch(SEMVER, version):
        raise ValueError("release version must be stable SemVer")
    if not isinstance(source_sha, str) or not re.fullmatch(r"[0-9a-f]{40}", source_sha):
        raise ValueError("release source must be a full commit SHA")
    if type(run_id) is not int or run_id <= 0:
        raise ValueError("release run ID must be positive")
    try:
        parsed = datetime.datetime.strptime(prepared_at, "%Y-%m-%dT%H:%M:%SZ")
    except (TypeError, ValueError) as error:
        raise ValueError("release preparation time must be UTC ISO seconds") from error
    if parsed.strftime("%Y-%m-%dT%H:%M:%SZ") != prepared_at:
        raise ValueError("release preparation time must be canonical UTC")


def release_notes(path: pathlib.Path, version: str) -> str:
    text = path.read_text(encoding="utf-8")
    start, end = "<!-- release:start -->", "<!-- release:end -->"
    if text.count(start) != 1 or text.count(end) != 1:
        raise ValueError("release notes require one active marker pair")
    before, body = text.split(start)
    if end not in body or end in before:
        raise ValueError("release notes markers are out of order")
    headings = re.findall(r"^## ([^\n]+)$", before, re.MULTILINE)
    if not headings or headings[-1].strip() != version:
        raise ValueError("release notes do not belong to the candidate version")
    notes = body.split(end, 1)[0].strip() + "\n"
    if len(notes.encode()) > 256 * 1024 or not re.search(r"^### .+", notes, re.MULTILINE):
        raise ValueError("release notes are missing or oversized")
    return notes


def checked_archive(root: pathlib.Path, name: str) -> pathlib.Path:
    path = root / name
    checksum = root / (name + ".sha256")
    if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= MAX_ARCHIVE_BYTES:
        raise ValueError(f"release artifact missing or invalid: {name}")
    if checksum.is_symlink() or not checksum.is_file():
        raise ValueError(f"release checksum missing: {name}")
    fields = checksum.read_text().split()
    if len(fields) != 2 or fields[1].lstrip("*") != name or fields[0] != sha256_file(path):
        raise ValueError(f"release checksum mismatch: {name}")
    return path


def archive_files(path: pathlib.Path) -> dict[str, bytes]:
    files: dict[str, bytes] = {}
    total = 0
    with tarfile.open(path, "r:gz") as archive:
        for member in archive:
            name = pathlib.PurePosixPath(member.name)
            if name.is_absolute() or ".." in name.parts or str(name) != member.name:
                raise ValueError(f"unsafe archive path: {member.name}")
            if not member.isfile():
                raise ValueError(f"release archives must contain regular files: {member.name}")
            if member.name in files:
                raise ValueError(f"duplicate archive member: {member.name}")
            total += member.size
            if total > MAX_ARCHIVE_BYTES or len(files) >= 100:
                raise ValueError("release archive exceeds inspection limit")
            stream = archive.extractfile(member)
            if stream is None:
                raise ValueError(f"unreadable archive member: {member.name}")
            files[member.name] = stream.read()
    return files


def inspect_artifacts(root: pathlib.Path, version: str) -> tuple[dict, dict]:
    binaries = {}
    for platform in PLATFORMS:
        name = f"fx-{platform}.tar.gz"
        path = checked_archive(root, name)
        files = archive_files(path)
        binary = files.get("fx")
        if not binary:
            raise ValueError(f"native executable missing: {name}")
        binaries[platform] = {
            "archive": name,
            "archive_bytes": path.stat().st_size,
            "archive_sha256": sha256_file(path),
            "size_bytes": len(binary),
            "sha256": hashlib.sha256(binary).hexdigest(),
        }

    path = checked_archive(root, "libfx-package.tgz")
    files = archive_files(path)
    package = json.loads(files.get("package/package.json", b"{}"))
    if package.get("name") != "libfx" or package.get("version") != version:
        raise ValueError("SDK version must match the stable release version")
    if any(package.get(field) for field in ("dependencies", "optionalDependencies", "peerDependencies")):
        raise ValueError("SDK dependency contract changed; requalify release lockfile generation")
    for name in ("fx-term.wasm", "fx-core.wasm"):
        wasm = files.get(f"package/{name}", b"")
        if not wasm.startswith(b"\0asm") or f"fx/{version}\0".encode() not in wasm:
            raise ValueError(f"SDK WebAssembly version mismatch: {name}")
    digest = sha256_file(path)
    sdk = {
        "version": version,
        "archive": path.name,
        "sha256": digest,
        "integrity": "sha512-" + base64.b64encode(hashlib.sha512(path.read_bytes()).digest()).decode(),
        "tarball_url": f"{MIRROR_BASE}/{digest}/libfx-{version}.tgz",
    }
    return binaries, sdk


def build_candidate(root: pathlib.Path, notes_path: pathlib.Path, version: str, source_sha: str, run_id: int, prepared_at: str) -> dict:
    validate_identity(version, source_sha, run_id, prepared_at)
    notes = release_notes(notes_path, version)
    binaries, sdk = inspect_artifacts(root, version)
    return {
        "schema_version": 1,
        "version": version,
        "source_sha": source_sha,
        "prepared_run_id": run_id,
        "prepared_at": prepared_at,
        "changelog": notes,
        "changelog_sha256": hashlib.sha256(notes.encode()).hexdigest(),
        "binaries": binaries,
        "sdk": sdk,
    }


def verify_candidate(candidate: dict, root: pathlib.Path, expected_source_sha: str) -> None:
    if candidate.get("schema_version") != 1:
        raise ValueError("unsupported release record schema")
    validate_identity(candidate.get("version"), candidate.get("source_sha"), candidate.get("prepared_run_id"), candidate.get("prepared_at"))
    if candidate["source_sha"] != expected_source_sha:
        raise ValueError("release source differs from the prepared candidate")
    notes = candidate.get("changelog")
    if not isinstance(notes, str) or hashlib.sha256(notes.encode()).hexdigest() != candidate.get("changelog_sha256"):
        raise ValueError("release changelog identity mismatch")
    binaries, sdk = inspect_artifacts(root, candidate["version"])
    if candidate.get("binaries") != binaries or candidate.get("sdk") != sdk:
        raise ValueError("release artifact identity changed after preparation")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("create")
    create.add_argument("--artifacts", type=pathlib.Path, required=True)
    create.add_argument("--changelog", type=pathlib.Path, required=True)
    create.add_argument("--version", required=True)
    create.add_argument("--source-sha", required=True)
    create.add_argument("--run-id", type=int, required=True)
    create.add_argument("--prepared-at", required=True)
    create.add_argument("--output", type=pathlib.Path, required=True)
    verify = commands.add_parser("verify")
    verify.add_argument("--record", type=pathlib.Path, required=True)
    verify.add_argument("--artifacts", type=pathlib.Path, required=True)
    verify.add_argument("--source-sha", required=True)
    args = parser.parse_args()
    try:
        if args.command == "create":
            candidate = build_candidate(args.artifacts, args.changelog, args.version, args.source_sha, args.run_id, args.prepared_at)
            args.output.write_text(json.dumps(candidate, sort_keys=True, indent=2) + "\n")
            print(f"Prepared fx {candidate['version']} at {candidate['source_sha']}")
        else:
            candidate = json.loads(args.record.read_text())
            verify_candidate(candidate, args.artifacts, args.source_sha)
            print(f"Verified fx {candidate['version']} prepared artifacts")
    except (ValueError, OSError, tarfile.TarError) as error:
        parser.exit(1, f"Release candidate rejected: {error}\n")


if __name__ == "__main__":
    main()
