"""Publish a retained candidate after the workflow's final human approval."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import time

from scripts.release_candidate import PLATFORMS, sha256_file, verify_candidate
from scripts.release_delivery import BlobConflictError, BlobStore, NATIVE_REPO, WEB_PROJECT, WEB_REPO, TransientDeliveryError, command, etag_value, github, put_immutable, vercel, website_check_snapshot, website_checks_pass
from scripts.release_examples import preflight_examples, promote_examples, validate_records

CHANNEL_POLLS = 16


def verify_ready(ready: dict, candidate: dict, digest: str, report: dict) -> None:
    if ready.get("schema_version") != 1 or ready.get("publication_allowed") is not True:
        raise ValueError("this candidate is preparation-only and cannot be published")
    if ready.get("candidate_sha256") != digest:
        raise ValueError("approved candidate identity changed")
    if type(ready.get("native_pr", 0)) is not int or ready.get("native_pr", 0) < 0:
        raise ValueError("invalid native preparation PR")
    validate_records(ready.get("examples", []))
    if any(example["source_sha"] != candidate["source_sha"] for example in ready["examples"]):
        raise ValueError("examples were prepared from another source")
    website = ready.get("website", {})
    for field in ("base_sha", "source_sha"):
        if not re.fullmatch(r"[0-9a-f]{40}", str(website.get(field, ""))):
            raise ValueError(f"invalid website {field}")
    if type(website.get("pr")) is not int or website["pr"] <= 0:
        raise ValueError("invalid website PR")
    if not re.fullmatch(r"dpl_[A-Za-z0-9]+", str(website.get("deployment_id", ""))):
        raise ValueError("invalid prepared website deployment")
    if not re.fullmatch(r"https://[a-zA-Z0-9.-]+\.(?:vercel\.app|vercel\.dev)", str(website.get("url", ""))):
        raise ValueError("invalid prepared website URL")
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", str(ready.get("previous_version", ""))):
        raise ValueError("previous public version was not captured")
    if report.get("passed") is not True or report.get("errors") != []:
        raise ValueError("website verification did not pass")
    expected = {"candidate_sha256": digest, "source_sha": candidate["source_sha"], "version": candidate["version"], "target_origin": website["url"]}
    if any(report.get(key) != value for key, value in expected.items()):
        raise ValueError("website verification belongs to another candidate")
    checks = report.get("checks", [])
    expected_checks = {(route, width) for route in ("/", "/try", "/changelog") for width in (375, 1440)}
    if len(checks) != len(expected_checks) or {(check.get("route"), check.get("width")) for check in checks} != expected_checks:
        raise ValueError("website verification is incomplete")
    for check in checks:
        if check.get("horizontal_overflow") is not False:
            raise ValueError("website layout verification failed")
        if check["route"] != "/changelog" and (check.get("terminal_version") != f"v{candidate['version']}" or check.get("help_open_close") is not True):
            raise ValueError("running terminal verification failed")
        if check["route"] == "/try" and check["width"] == 1440 and check.get("synthetic_gateway") is not True:
            raise ValueError("SDK Gateway compatibility was not verified")


class PublicationTargets:
    def __init__(self, artifacts: pathlib.Path):
        self.artifacts = artifacts
        self.blob = BlobStore()
        self.channel_etag = None

    def preflight(self, candidate: dict, ready: dict) -> None:
        preflight_examples(ready["examples"])
        ref = github(f"repos/{NATIVE_REPO}/git/ref/tags/v{candidate['version']}", missing_ok=True)
        if ref is not None and ref["object"]["sha"] != candidate["source_sha"]:
            raise ValueError("release tag already identifies another source")
        if ready.get("native_pr"):
            pr = github(f"repos/{NATIVE_REPO}/pulls/{ready['native_pr']}")
            if pr["head"]["sha"] != candidate["source_sha"] or pr["base"]["ref"] != "main" or pr["head"]["repo"]["full_name"] != NATIVE_REPO:
                raise ValueError("native preparation PR changed after verification")
            if not pr.get("merged") and (pr["state"] != "open" or pr.get("mergeable") is not True or pr.get("mergeable_state") in ("blocked", "dirty", "behind", "draft")):
                raise ValueError("native preparation PR is not eligible for the approved merge")
        elif ref is None and github(f"repos/{NATIVE_REPO}/commits/main")["sha"] != candidate["source_sha"]:
            raise ValueError("native source advanced; prepare the current release before approval")
        website = ready["website"]
        pr = github(f"repos/{WEB_REPO}/pulls/{website['pr']}", web=True)
        if pr["head"]["sha"] != website["source_sha"] or pr["base"]["ref"] != "main":
            raise ValueError("prepared website PR changed")
        if pr.get("merged"):
            self.verify_website_tree(website, pr["merge_commit_sha"])
        else:
            if pr["state"] != "open" or pr.get("draft") or pr.get("mergeable") is not True or pr.get("mergeable_state") != "clean":
                raise ValueError("website preparation PR is not eligible for the approved merge")
            if not website_checks_pass(website_check_snapshot(website["pr"]), website["source_sha"]):
                raise ValueError("website required checks have not passed")
        expected = pr["merge_commit_sha"] if pr.get("merged") else website["base_sha"]
        if github(f"repos/{WEB_REPO}/commits/main", web=True)["sha"] != expected:
            raise ValueError("website main advanced; refusing to promote a stale release")
        deployed = vercel(f"/v13/deployments/{website['deployment_id']}")
        if deployed.get("projectId") != WEB_PROJECT or deployed.get("readyState") != "READY" or deployed.get("url") != website["url"].removeprefix("https://"):
            raise ValueError("prepared website deployment changed or is unavailable")
        active = vercel(f"/v9/projects/{WEB_PROJECT}").get("targets", {}).get("production", {}).get("id")
        if active not in (website.get("previous_deployment_id"), website["deployment_id"]):
            raise ValueError("another website deployment is now live")
        current = (self.blob.read("cli/latest.txt") or b"").decode().strip()
        if current not in (ready["previous_version"], f"v{candidate['version']}"):
            raise ValueError("public download channel changed")

    def native_assets(self, candidate: dict) -> None:
        version = f"v{candidate['version']}"
        ref = github(f"repos/{NATIVE_REPO}/git/ref/tags/{version}", missing_ok=True)
        if ref is None:
            github(f"repos/{NATIVE_REPO}/git/refs", method="POST", body={"ref": f"refs/tags/{version}", "sha": candidate["source_sha"]})
        elif ref["object"]["sha"] != candidate["source_sha"]:
            raise ValueError("release tag changed")
        release = github(f"repos/{NATIVE_REPO}/releases/tags/{version}", missing_ok=True)
        if release is None:
            release = github(f"repos/{NATIVE_REPO}/releases", method="POST", body={"tag_name": version, "target_commitish": candidate["source_sha"], "name": version, "body": candidate["changelog"], "draft": True})
        elif (release.get("body") or "").strip() != candidate["changelog"].strip():
            raise ValueError("published release notes differ from approved notes")
        existing = {asset["name"]: asset for asset in release.get("assets", [])}
        for platform in PLATFORMS:
            archive = candidate["binaries"][platform]["archive"]
            for name in (archive, archive + ".sha256"):
                data = (self.artifacts / name).read_bytes()
                if name in existing:
                    asset = existing[name]
                    digest = asset.get("digest")
                    if digest != "sha256:" + hashlib.sha256(data).hexdigest():
                        raise ValueError(f"existing GitHub release asset differs or lacks a digest: {name}")
                else:
                    command(["gh", "release", "upload", version, str((self.artifacts / name).resolve()), "--repo", NATIVE_REPO])
                put_immutable(self.blob, f"cli/{version}/{name}", data)
        if release.get("draft"):
            github(f"repos/{NATIVE_REPO}/releases/{release['id']}", method="PATCH", body={"draft": False})

    def merge_native(self, candidate: dict, ready: dict) -> None:
        if not ready.get("native_pr"):
            return
        pr = github(f"repos/{NATIVE_REPO}/pulls/{ready['native_pr']}")
        if pr["head"]["sha"] != candidate["source_sha"]:
            raise ValueError("native PR changed after approval")
        if not pr.get("merged"):
            merged = github(f"repos/{NATIVE_REPO}/pulls/{ready['native_pr']}/merge", method="PUT",
                            body={"sha": candidate["source_sha"], "merge_method": "merge"})
            if not merged.get("merged"):
                raise ValueError("native release preparation merge did not complete")

    def merge_website(self, ready: dict) -> str:
        website = ready["website"]
        pr = github(f"repos/{WEB_REPO}/pulls/{website['pr']}", web=True)
        if pr["head"]["sha"] != website["source_sha"]:
            raise ValueError("website PR changed after approval")
        if not pr.get("merged"):
            if github(f"repos/{WEB_REPO}/commits/main", web=True)["sha"] != website["base_sha"]:
                raise ValueError("website main changed after approval")
            merged = github(f"repos/{WEB_REPO}/pulls/{website['pr']}/merge", method="PUT", web=True,
                            body={"sha": website["source_sha"], "merge_method": "squash"})
            if not merged.get("merged"):
                raise ValueError("website merge did not complete")
            merge_sha = merged["sha"]
        else:
            merge_sha = pr["merge_commit_sha"]
        self.verify_website_tree(website, merge_sha)
        return merge_sha

    def verify_website_tree(self, website: dict, merge_sha: str) -> None:
        approved = github(f"repos/{WEB_REPO}/git/commits/{website['source_sha']}", web=True)
        merged = github(f"repos/{WEB_REPO}/git/commits/{merge_sha}", web=True)
        tree = approved.get("tree", {}).get("sha", "")
        if not re.fullmatch(r"[0-9a-f]{40}", tree) or merged.get("tree", {}).get("sha") != tree:
            raise ValueError("merged website tree differs from the approved deployment; prepare a new candidate")

    def advance_channel(self, candidate: dict, ready: dict) -> None:
        version = f"v{candidate['version']}"
        self.channel_etag = self.replace_channel(ready["previous_version"], version)
        self.wait_channel(version, ready["previous_version"])

    def channel_snapshot(self) -> tuple[str, str]:
        data, etag = self.blob.snapshot("cli/latest.txt")
        if data is None or etag is None:
            raise TransientDeliveryError("release channel is not visible")
        if etag_value(etag) != etag_value(self.blob.origin_etag()):
            raise TransientDeliveryError("release channel cache has not converged with storage")
        return data.decode().strip(), etag

    def replace_channel(self, previous: str, version: str) -> str:
        for attempt in range(CHANNEL_POLLS):
            try:
                current, etag = self.channel_snapshot()
                if current == version:
                    return etag
                if current != previous:
                    raise ValueError("download channel advanced to another release")
                return self.blob.write("cli/latest.txt", version.encode(), mutable=True, if_match=etag)
            except (BlobConflictError, TransientDeliveryError):
                if attempt + 1 == CHANNEL_POLLS:
                    raise TransientDeliveryError("release channel write is unresolved; retry the same candidate") from None
                time.sleep(5)
        raise AssertionError("unreachable channel write")

    def wait_channel(self, version: str, previous: str) -> None:
        for attempt in range(CHANNEL_POLLS):
            try:
                current, _ = self.channel_snapshot()
                if current == version:
                    return
                if current != previous:
                    raise ValueError("download channel advanced to another release")
            except TransientDeliveryError:
                pass
            if attempt + 1 < CHANNEL_POLLS:
                time.sleep(5)
        raise TransientDeliveryError("release channel cache did not converge; retry the same candidate")

    def promote_website(self, ready: dict, merge_sha: str) -> None:
        if github(f"repos/{WEB_REPO}/commits/main", web=True)["sha"] != merge_sha:
            raise ValueError("website changed after the approved merge")
        website = ready["website"]
        active = vercel(f"/v9/projects/{WEB_PROJECT}").get("targets", {}).get("production", {}).get("id")
        if active == website["deployment_id"]:
            return
        if active != website.get("previous_deployment_id"):
            raise ValueError("refusing to replace a newer website deployment")
        command(["vercel", "promote", website["deployment_id"], "--yes", "--scope", "vercel-labs"])

    def promote_examples(self, ready: dict) -> None:
        promote_examples(ready["examples"])

    def restore_channel(self, candidate: dict, ready: dict) -> None:
        version = f"v{candidate['version']}"
        if self.channel_etag is not None:
            try:
                self.blob.write("cli/latest.txt", ready["previous_version"].encode(), mutable=True, if_match=self.channel_etag)
            except TransientDeliveryError:
                # A lost response cannot establish whether rollback reached storage.
                self.replace_channel(version, ready["previous_version"])
        else:
            self.replace_channel(version, ready["previous_version"])
        self.wait_channel(ready["previous_version"], version)
        self.channel_etag = None

    def verify(self, candidate: dict, ready: dict) -> None:
        self.wait_channel(f"v{candidate['version']}", ready["previous_version"])
        active = vercel(f"/v9/projects/{WEB_PROJECT}").get("targets", {}).get("production", {}).get("id")
        if active != ready["website"]["deployment_id"]:
            raise ValueError("prepared website is not the production deployment")
        release = github(f"repos/{NATIVE_REPO}/releases/tags/v{candidate['version']}")
        if release.get("draft"):
            raise ValueError("GitHub release is not public")


def publish_release_once(candidate: dict, ready: dict, digest: str, report: dict, targets: PublicationTargets) -> None:
    verify_ready(ready, candidate, digest, report)
    targets.preflight(candidate, ready)
    targets.merge_native(candidate, ready)
    targets.native_assets(candidate)
    merge_sha = targets.merge_website(ready)
    targets.advance_channel(candidate, ready)
    try:
        targets.promote_examples(ready)
        targets.promote_website(ready, merge_sha)
    except (ValueError, RuntimeError, OSError):
        targets.restore_channel(candidate, ready)
        raise
    targets.verify(candidate, ready)


def publish_release(candidate: dict, ready: dict, digest: str, report: dict, targets: PublicationTargets) -> None:
    for attempt in range(3):
        try:
            publish_release_once(candidate, ready, digest, report, targets)
            return
        except TransientDeliveryError:
            if attempt == 2:
                raise
            print("Rechecking completed publication steps after a temporary transport failure", flush=True)
            time.sleep(2 ** attempt)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("verify", "publish"))
    parser.add_argument("--artifacts", type=pathlib.Path, required=True)
    parser.add_argument("--source-sha", required=True)
    args = parser.parse_args()
    try:
        candidate_path = args.artifacts / "candidate.json"
        candidate = json.loads(candidate_path.read_text())
        ready = json.loads((args.artifacts / "ready.json").read_text())
        report = json.loads((args.artifacts / "website-evidence/report.json").read_text())
        verify_candidate(candidate, args.artifacts, args.source_sha)
        verify_ready(ready, candidate, sha256_file(candidate_path), report)
        targets = PublicationTargets(args.artifacts)
        if args.action == "verify":
            targets.preflight(candidate, ready)
            print(f"Verified prepared fx {candidate['version']} publication inputs")
        else:
            publish_release(candidate, ready, sha256_file(candidate_path), report, targets)
            print(f"Published prepared fx {candidate['version']}")
    except (ValueError, RuntimeError, OSError) as error:
        parser.exit(1, f"Release publication stopped: {error}\n")


if __name__ == "__main__":
    main()
