"""Resolve the immutable preparation artifact consumed by the final approval job."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re

from scripts.release_delivery import NATIVE_REPO, github
from scripts.release_candidate import sha256_file, verify_candidate
from scripts.release_publication import PublicationTargets, verify_ready
from scripts.release_preparation import inspect_release_pr


def select_preparation(run: dict, artifacts: list[dict], run_id: int) -> dict | None:
    if run.get("id") != run_id or run.get("path") != ".github/workflows/release.yml":
        raise ValueError("candidate must come from the release preparation workflow")
    if run.get("head_repository", {}).get("full_name") != NATIVE_REPO or run.get("head_branch") != "main":
        raise ValueError("candidate preparation must run from the trusted main workflow")
    if not re.fullmatch(r"[0-9a-f]{40}", str(run.get("head_sha", ""))):
        raise ValueError("preparation workflow SHA is invalid")
    if run.get("event") not in ("push", "workflow_dispatch") or run.get("status") != "completed" or run.get("conclusion") != "success":
        raise ValueError("candidate preparation did not complete successfully")
    matching = [artifact for artifact in artifacts if artifact.get("name") == "fx-release-ready"]
    if not matching:
        return None
    if len(matching) != 1 or matching[0].get("expired"):
        raise ValueError("prepared release artifact is ambiguous or expired")
    artifact = matching[0]
    if type(artifact.get("id")) is not int or artifact["id"] <= 0:
        raise ValueError("prepared release artifact ID is invalid")
    return {"artifact_id": artifact["id"], "run_id": run_id, "workflow_sha": run["head_sha"]}


def hydrate(artifacts: pathlib.Path, run_id: int, workflow_sha: str) -> dict:
    candidate_path = artifacts / "candidate.json"
    candidate = json.loads(candidate_path.read_text())
    ready = json.loads((artifacts / "ready.json").read_text())
    if ready.get("publication_allowed") is False:
        return {"eligible": "false"}
    require_current_preparation(run_id)
    if candidate.get("prepared_run_id") != run_id:
        raise ValueError("candidate belongs to a different preparation run")
    verify_candidate(candidate, artifacts, candidate["source_sha"])
    report = json.loads((artifacts / "website-evidence/report.json").read_text())
    verify_ready(ready, candidate, sha256_file(candidate_path), report)
    if ready.get("native_pr"):
        inspect_release_pr(ready["native_pr"], candidate["source_sha"], pathlib.Path.cwd())
    elif candidate["source_sha"] != workflow_sha:
        raise ValueError("unqualified source differs from the trusted preparation workflow")
    PublicationTargets(artifacts).preflight(candidate, ready)
    return {"eligible": "true", "version": candidate["version"], "source_sha": candidate["source_sha"], "website_sha": ready["website"]["source_sha"]}


def require_current_preparation(run_id: int) -> None:
    """Reject an older approval without racing cancellation against public writes."""
    for page in range(1, 21):
        result = github(f"repos/{NATIVE_REPO}/actions/workflows/release.yml/runs?branch=main&status=success&per_page=100&page={page}")
        runs = result["workflow_runs"]
        for run in runs:
            if run["id"] <= run_id:
                return
            if run.get("display_title", "").startswith("Prepare rehearsal "):
                continue
            # Ordinary main pushes with an existing tag do not prepare artifacts.
            listed = github(f"repos/{NATIVE_REPO}/actions/runs/{run['id']}/artifacts?per_page=100")
            if listed["total_count"] > 100:
                raise ValueError("cannot establish freshness from an incomplete artifact listing")
            if any(item.get("name") == "fx-release-ready" for item in listed["artifacts"]):
                raise ValueError(f"approval superseded by preparation run {run['id']}; review its preview instead")
        if len(runs) < 100:
            return
    raise ValueError("cannot establish release freshness within the workflow history limit")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", type=int, required=True)
    parser.add_argument("--artifacts", type=pathlib.Path)
    parser.add_argument("--workflow-sha")
    parser.add_argument("--assert-current", action="store_true")
    args = parser.parse_args()
    try:
        if args.run_id <= 0:
            raise ValueError("prepared run ID must be positive")
        if args.assert_current:
            require_current_preparation(args.run_id)
            values = {}
        elif args.artifacts:
            values = hydrate(args.artifacts, args.run_id, args.workflow_sha)
        else:
            run = github(f"repos/{NATIVE_REPO}/actions/runs/{args.run_id}")
            artifacts = []
            for page in range(1, 21):
                result = github(f"repos/{NATIVE_REPO}/actions/runs/{args.run_id}/artifacts?per_page=100&page={page}")
                artifacts.extend(result["artifacts"])
                if len(artifacts) >= result["total_count"]:
                    break
            else:
                raise ValueError("candidate artifact listing is incomplete")
            selected = select_preparation(run, artifacts, args.run_id)
            values = {"available": "true" if selected else "false", **(selected or {})}
        destination = os.environ.get("GITHUB_OUTPUT")
        lines = "".join(f"{key}={value}\n" for key, value in values.items())
        if destination:
            with pathlib.Path(destination).open("a") as stream:
                stream.write(lines)
        print("Verified release preparation inputs")
    except (ValueError, RuntimeError, OSError) as error:
        parser.exit(1, f"Release input rejected: {error}\n")


if __name__ == "__main__":
    main()
