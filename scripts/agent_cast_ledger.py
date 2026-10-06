#!/usr/bin/env python3
"""Validate and inspect the agent-cast task ledger without changing it."""

import argparse
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_LEDGER = ROOT / "docs" / "agent-cast" / "tasks.json"
STATUSES = {
    "planned", "in_progress", "implemented", "verified_local",
    "ci_pending", "done", "blocked",
}
AVAILABLE = {"done", "verified_local"}


def strings(value):
    return isinstance(value, list) and all(isinstance(item, str) and item.strip() for item in value)


def acyclic(items, label, errors):
    valid_items = [item for item in items if isinstance(item, dict)]
    ids = {item["id"] for item in valid_items if isinstance(item.get("id"), str) and item["id"].strip()}
    graph = {
        item["id"]: item["depends_on"]
        for item in valid_items
        if isinstance(item.get("id"), str) and item["id"].strip()
        and strings(item.get("depends_on"))
    }
    visiting, visited = set(), set()

    def visit(node):
        if node in visiting:
            errors.append(f"{label} dependency cycle includes {node!r}")
            return
        if node in visited:
            return
        visiting.add(node)
        for dep in graph.get(node, []):
            if dep in ids:
                visit(dep)
        visiting.remove(node)
        visited.add(node)

    for node in ids:
        visit(node)


def validate(data):
    errors = []
    if not isinstance(data, dict):
        return ["ledger root must be an object"]
    if type(data.get("schema_version")) is not int or data["schema_version"] != 1:
        errors.append("schema_version must be 1")
    project = data.get("project")
    if not isinstance(project, dict) or not all(isinstance(project.get(k), str) and project[k].strip() for k in ("name", "objective")):
        errors.append("project must contain nonempty name and objective")
    milestones, tasks = data.get("milestones"), data.get("tasks")
    if not isinstance(milestones, list) or not isinstance(tasks, list):
        return errors + ["milestones and tasks must be arrays"]

    def check_ids(items, label):
        ids = []
        for i, item in enumerate(items):
            if not isinstance(item, dict):
                errors.append(f"{label}[{i}] must be an object")
                continue
            ident = item.get("id")
            if not isinstance(ident, str) or not ident.strip():
                errors.append(f"{label}[{i}] needs a nonempty id")
            else:
                ids.append(ident)
        if len(ids) != len(set(ids)):
            errors.append(f"{label} IDs must be unique")
        return set(ids)

    milestone_ids = check_ids(milestones, "milestones")
    task_ids = check_ids(tasks, "tasks")
    for i, item in enumerate(milestones):
        if not isinstance(item, dict):
            continue
        if not isinstance(item.get("title"), str) or not item["title"].strip():
            errors.append(f"milestones[{i}] needs a nonempty title")
        if not strings(item.get("acceptance")) or not item["acceptance"]:
            errors.append(f"milestones[{i}].acceptance must be a nonempty array of nonempty strings")
        deps = item.get("depends_on")
        if not strings(deps):
            errors.append(f"milestones[{i}].depends_on must be an array of nonempty strings")
        else:
            for dep in deps:
                if dep not in milestone_ids:
                    errors.append(f"milestones[{i}] has unknown dependency {dep!r}")
    acyclic(milestones, "milestone", errors)

    by_id = {item.get("id"): item for item in tasks if isinstance(item, dict) and isinstance(item.get("id"), str)}
    for i, task in enumerate(tasks):
        if not isinstance(task, dict):
            continue
        prefix = f"tasks[{i}]"
        if not isinstance(task.get("milestone"), str) or task["milestone"] not in milestone_ids:
            errors.append(f"{prefix} references unknown milestone {task.get('milestone')!r}")
        if not isinstance(task.get("title"), str) or not task["title"].strip():
            errors.append(f"{prefix} needs a nonempty title")
        if not isinstance(task.get("status"), str) or task["status"] not in STATUSES:
            errors.append(f"{prefix} has invalid status {task.get('status')!r}")
        for key in ("scope", "acceptance"):
            if not strings(task.get(key)) or not task[key]:
                errors.append(f"{prefix}.{key} must be a nonempty array of nonempty strings")
        deps = task.get("depends_on")
        if not strings(deps):
            errors.append(f"{prefix}.depends_on must be an array of nonempty strings")
        else:
            for dep in deps:
                if dep not in task_ids:
                    errors.append(f"{prefix} has unknown dependency {dep!r}")
        owner = task.get("owner")
        if not isinstance(owner, dict) or not all(isinstance(owner.get(k), str) and owner[k].strip() for k in ("role", "model", "reasoning_effort")):
            errors.append(f"{prefix}.owner needs nonempty role, model, and reasoning_effort")
        usage = task.get("usage")
        if not isinstance(usage, dict) or any(usage.get(k) is not None and (not isinstance(usage[k], int) or isinstance(usage[k], bool) or usage[k] < 0) for k in ("input_tokens", "output_tokens")):
            errors.append(f"{prefix}.usage token counts must be nonnegative integers or null")
        if isinstance(usage, dict) and usage.get("source") is not None and not isinstance(usage["source"], str):
            errors.append(f"{prefix}.usage.source must be a string or null")
        if isinstance(usage, dict) and any(usage.get(k) is not None for k in ("input_tokens", "output_tokens")) and not (isinstance(usage.get("source"), str) and usage["source"].strip()):
            errors.append(f"{prefix}.usage.source must be nonempty when token counts are provided")
        evidence = task.get("evidence")
        if not strings(evidence):
            errors.append(f"{prefix}.evidence must be an array of nonempty strings")
        elif task.get("status") in ("done", "verified_local") and not evidence:
            errors.append(f"{prefix} status {task['status']} requires evidence")
    acyclic(tasks, "task", errors)
    for task in tasks:
        if not isinstance(task, dict) or task.get("status") != "done":
            continue
        deps = task.get("depends_on")
        if not strings(deps):
            continue
        for dep in deps:
            dependency = by_id.get(dep)
            if dependency and dependency.get("status") != "done":
                errors.append(f"done task {task.get('id')!r} requires dependency {dep!r} to be done")
    return errors


def report(data, command):
    tasks = data.get("tasks", [])
    if command == "next":
        selected = [t for t in tasks if t.get("status") == "planned" and all(
            isinstance(next((d for d in tasks if d.get("id") == dep), None), dict)
            and next(d for d in tasks if d.get("id") == dep).get("status") in AVAILABLE
            for dep in t.get("depends_on", []))]
    elif command == "show":
        selected = tasks
    else:
        selected = []
    return {"ok": True, "command": command, "project": data.get("project"), "tasks": selected,
            "done_task_ids": [t.get("id") for t in tasks if t.get("status") == "done"],
            "ci_pending": [t.get("id") for t in tasks if t.get("status") == "ci_pending"],
            "verification_note": "This checker validates ledger consistency, not live CI results or the truth of receipt content."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", nargs="?", choices=("validate", "next", "show"), default="validate")
    parser.add_argument("--ledger", type=Path, default=DEFAULT_LEDGER)
    parser.add_argument("--json", action="store_true", help="write structured JSON")
    args = parser.parse_args()
    try:
        data = json.loads(args.ledger.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        errors = [f"cannot read ledger {args.ledger}: {exc}"]
        result = {"ok": False, "errors": errors}
    else:
        errors = validate(data)
        result = {"ok": not errors, "errors": errors} if errors else report(data, args.command)
    if args.json:
        print(json.dumps(result, indent=2))
    elif result["ok"]:
        if args.command == "validate":
            print("Ledger valid")
        elif args.command == "next":
            for task in result["tasks"]:
                print(f"{task['id']} [{task['status']}] {task['title']}")
            if not result["tasks"]:
                print("No planned tasks are currently unblocked")
            if result["ci_pending"]:
                print("CI pending: " + ", ".join(result["ci_pending"]))
        else:
            for task in result["tasks"]:
                print(f"{task['id']} [{task['status']}] {task['title']}")
    else:
        for error in result["errors"]:
            print(error, file=sys.stderr)
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
