#!/usr/bin/env python3
"""Prepare and apply a pinned upstream refresh across attached worktrees."""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


class RefreshError(RuntimeError):
    pass


def git(cwd: Path, *args: str, check: bool = True) -> str:
    result = subprocess.run(["git", *args], cwd=cwd, text=True, capture_output=True)
    if check and result.returncode:
        raise RefreshError(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result.stdout.strip()


def git_ok(cwd: Path, *args: str) -> bool:
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True).returncode == 0


def common_git_dir(root: Path) -> Path:
    value = Path(git(root, "rev-parse", "--git-common-dir"))
    return (root / value).resolve() if not value.is_absolute() else value.resolve()


def state_root(root: Path) -> Path:
    path = common_git_dir(root) / "omifx-upstream-refresh"
    path.mkdir(exist_ok=True)
    return path


def write_json(path: Path, value: Any) -> None:
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def acquire_lock(path: Path) -> None:
    try:
        path.mkdir()
    except FileExistsError as exc:
        raise RefreshError(f"another refresh is active: {path}") from exc
    (path / "pid").write_text(f"{os.getpid()}\n")


def release_lock(path: Path) -> None:
    (path / "pid").unlink(missing_ok=True)
    path.rmdir()


def worktrees(root: Path) -> list[dict[str, str]]:
    entries: list[dict[str, str]] = []
    current: dict[str, str] = {}
    for line in git(root, "worktree", "list", "--porcelain").splitlines() + [""]:
        if line.startswith("worktree "):
            current = {"path": line[9:]}
        elif line.startswith("branch "):
            current["branch"] = line.removeprefix("branch refs/heads/")
        elif line == "" and current:
            entries.append(current)
            current = {}
    return entries


def marker_paths(path: Path) -> list[Path]:
    return [
        Path(git(path, "rev-parse", "--git-path", marker))
        for marker in ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "AUTO_MERGE", "rebase-merge", "rebase-apply")
    ]


def operation_in_progress(path: Path) -> bool:
    return any(marker.exists() for marker in marker_paths(path))


def branch_entry(root: Path, base: str, item: dict[str, str], excluded: set[str]) -> dict[str, Any]:
    path = Path(item["path"])
    data: dict[str, Any] = {"branch": item.get("branch"), "worktree": str(path)}
    if path.resolve() == root.resolve():
        data["status"] = "skipped-root"
        return data
    if "branch" not in item:
        data["status"] = "skipped-detached"
        return data
    branch = item["branch"]
    if not path.exists():
        data["status"] = "skipped-missing-worktree"
        return data
    old = git(path, "rev-parse", "HEAD")
    data["old"] = old
    if branch in excluded:
        data["status"] = "excluded"
    elif operation_in_progress(path):
        data["status"] = "skipped-operation-in-progress"
    elif git(path, "status", "--porcelain"):
        data["status"] = "skipped-dirty"
    else:
        data["fork"] = git(root, "merge-base", branch, base)
        data["status"] = "noop" if git_ok(root, "merge-base", "--is-ancestor", base, branch) else "planned"
    return data


def find_plan(states: Path, requested: str | None) -> Path:
    if requested:
        return Path(requested).resolve()
    plans = sorted(states.glob("*.json"), key=lambda p: p.stat().st_mtime)
    if not plans:
        raise RefreshError("no refresh plan exists")
    return plans[-1]


def prepare(args: argparse.Namespace) -> int:
    root = Path(args.root).resolve()
    states = state_root(root)
    lock_path = states / "lock"
    acquire_lock(lock_path)
    integration: Path | None = None
    try:
        if not args.no_fetch:
            git(root, "fetch", "--prune", args.remote, args.upstream_branch)
            if git_ok(root, "rev-parse", "origin/main"):
                git(root, "fetch", "--prune", "origin", "main")
        source = git(root, "rev-parse", f"{args.remote}/{args.upstream_branch}")
        base_ref = "origin/main" if git_ok(root, "rev-parse", "origin/main") else "main"
        base = git(root, "rev-parse", base_ref)
        session = f"{time.time_ns()}-{source[:12]}"
        integration = states / f"integration-{session}"
        git(root, "worktree", "add", "--detach", str(integration), base)
        merge = subprocess.run(["git", "merge", "--no-ff", "--no-edit", source], cwd=integration, text=True, capture_output=True)
        phase = "integration-conflict" if merge.returncode else "ready"
        integration_oid = git(integration, "rev-parse", "HEAD")
        entries = [branch_entry(root, base, item, set(args.exclude)) for item in worktrees(root)]
        payload = {"version": 3, "session": session, "phase": phase, "root": str(root), "remote": args.remote, "upstream_branch": args.upstream_branch, "source": source, "base": base, "integration": integration_oid, "integration_worktree": str(integration), "entries": entries}
        path = states / f"{session}.json"
        write_json(path, payload)
        print(f"plan: {path}")
        print(json.dumps(payload, indent=2, sort_keys=True))
        if merge.returncode:
            print(merge.stderr, file=sys.stderr)
        return 2 if merge.returncode else 0
    except Exception:
        if integration and integration.exists() and not (integration / ".git").exists():
            subprocess.run(["git", "worktree", "remove", "--force", str(integration)], cwd=root, check=False)
        raise
    finally:
        release_lock(lock_path)

def apply(args: argparse.Namespace) -> int:
    root = Path(args.root).resolve()
    plan_path = find_plan(state_root(root), args.plan)
    payload = json.loads(plan_path.read_text())
    if payload.get("root") != str(root) or payload.get("version") != 3:
        raise RefreshError("plan does not belong to this repository or is unsupported")
    if payload["phase"] == "integration-conflict":
        raise RefreshError("resolve the integration worktree, then run resume")
    integration = str(payload["integration"])
    if not git_ok(root, "cat-file", "-e", f"{integration}^{{commit}}"):
        raise RefreshError("integration commit is unavailable")
    lock_path = state_root(root) / "lock"
    acquire_lock(lock_path)
    try:
        backup_prefix = f"refs/backup/omifx-upstream-refresh/{payload['session']}"
        for data in payload["entries"]:
            if data.get("status") != "planned":
                continue
            branch = str(data["branch"])
            path = Path(str(data["worktree"]))
            if git(path, "rev-parse", branch) != data["old"] or git(path, "status", "--porcelain") or operation_in_progress(path):
                data["status"] = "refused-drift"
                continue
            backup = f"{backup_prefix}/{branch.replace('/', '%2F')}"
            git(root, "update-ref", backup, str(data["old"]))
            result = subprocess.run(["git", "rebase", "--rebase-merges", "--onto", integration, str(data["fork"]), branch], cwd=path, text=True, capture_output=True)
            data["backup"] = backup
            if result.returncode:
                data["status"] = "conflict"
                data["error"] = result.stderr.strip()
                write_json(plan_path, payload)
                print(json.dumps(payload, indent=2, sort_keys=True))
                return 2
            data["status"] = "updated"
            data["new"] = git(path, "rev-parse", branch)
        payload["phase"] = "complete"
        write_json(plan_path, payload)
        print(json.dumps(payload, indent=2, sort_keys=True))
        return 0
    finally:
        release_lock(lock_path)


def status(args: argparse.Namespace) -> int:
    root = Path(args.root).resolve()
    path = find_plan(state_root(root), args.plan)
    payload = json.loads(path.read_text())
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("prepare", "plan"):
        command = sub.add_parser(name)
        command.add_argument("--root", default=".")
        command.add_argument("--remote", default="upstream")
        command.add_argument("--upstream-branch", default="main")
        command.add_argument("--exclude", action="append", default=[])
        command.add_argument("--no-fetch", action="store_true")
    for name, function in (("apply", apply), ("status", status)):
        command = sub.add_parser(name)
        command.add_argument("--root", default=".")
        command.add_argument("--plan")
    args = parser.parse_args()
    return prepare(args) if args.command in ("prepare", "plan") else apply(args) if args.command == "apply" else status(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RefreshError, json.JSONDecodeError) as exc:
        print(f"upstream-refresh: {exc}", file=sys.stderr)
        raise SystemExit(3)
