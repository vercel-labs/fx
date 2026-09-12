"""Stage and publish the already-verified release artifacts."""

from __future__ import annotations

import argparse
import base64
import contextlib
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

from scripts.release_candidate import PLATFORMS, sha256_file, verify_candidate
from scripts.release_examples import prepare_examples, vercel_team


NATIVE_REPO = "vercel-labs/fx"
WEB_REPO = "vercel-labs/fx-web"
WEB_PROJECT = "prj_rIMZjpSjEoVhPtOV7y2v35UIDWQK"
PUBLIC_BLOB = "https://ugiwefobuo4tac0m.public.blob.vercel-storage.com/"
RELEASE_PATHS = (
    "apps/marketing/package.json",
    "apps/marketing/pnpm-lock.yaml",
    "apps/marketing/lib/generated/release.json",
    "apps/marketing/lib/examples.generated.json",
)


class TransientDeliveryError(RuntimeError):
    pass


class BlobConflictError(ValueError):
    pass


def etag_value(value: str) -> str:
    if not isinstance(value, str) or not value or len(value) > 256 or value == "*" or value.startswith("W/") or re.search(r"[\x00-\x20\x7f]", value):
        raise ValueError("release channel requires a strong storage ETag")
    normalized = value.removeprefix('"').removesuffix('"')
    if not normalized:
        raise ValueError("release channel requires a nonempty storage ETag")
    return normalized


def command(args: list[str], *, cwd: pathlib.Path | None = None, stdin: str | None = None, web: bool = False) -> str:
    env = dict(os.environ)
    if web:
        if not env.get("FX_WEB_GITHUB_TOKEN"):
            raise ValueError("FX_WEB_GITHUB_TOKEN is required for website preparation")
        env["GH_TOKEN"] = env["FX_WEB_GITHUB_TOKEN"]
    env.pop("GH_DEBUG", None)
    result = subprocess.run(args, cwd=cwd, env=env, input=stdin, capture_output=True, text=True)
    if result.returncode:
        # Provider output can contain credentials or private build configuration.
        if re.search(r"ECONNRESET|ETIMEDOUT|EAI_AGAIN|HTTP (?:429|50[0234])|fetch failed", result.stderr):
            raise TransientDeliveryError(f"{args[0]} {args[1] if len(args) > 1 else ''} encountered a temporary transport failure")
        raise RuntimeError(f"{args[0]} {args[1] if len(args) > 1 else ''} failed (exit {result.returncode})")
    return result.stdout.strip()


def github(path: str, *, method: str = "GET", body: dict | None = None, web: bool = False, missing_ok: bool = False):
    env = dict(os.environ)
    if web:
        if not env.get("FX_WEB_GITHUB_TOKEN"):
            raise ValueError("FX_WEB_GITHUB_TOKEN is required")
        env["GH_TOKEN"] = env["FX_WEB_GITHUB_TOKEN"]
    env.pop("GH_DEBUG", None)
    args = ["gh", "api", "--include", "--method", method, path]
    if body is not None:
        args += ["--input", "-"]
    result = subprocess.run(args, env=env, input=json.dumps(body) if body is not None else None, capture_output=True, text=True)
    headers, _, payload = result.stdout.replace("\r\n", "\n").partition("\n\n")
    matched = re.match(r"HTTP/\S+ (\d{3})", headers)
    status = int(matched[1]) if matched else 0
    if missing_ok and status == 404:
        return None
    if status in (408, 429, 500, 502, 503, 504):
        raise TransientDeliveryError(f"GitHub {method} request temporarily failed (HTTP {status})")
    if result.returncode or not 200 <= status < 300:
        raise RuntimeError(f"GitHub {method} {path.split('?')[0]} failed (HTTP {status or 'unavailable'})")
    return json.loads(payload) if payload.strip() else None


class BlobStore:
    def read(self, path: str) -> bytes | None:
        return self.snapshot(path)[0]

    def snapshot(self, path: str) -> tuple[bytes | None, str | None]:
        try:
            with urllib.request.urlopen(PUBLIC_BLOB + path, timeout=60) as response:
                data = response.read(256 * 1024 * 1024 + 1)
                if len(data) > 256 * 1024 * 1024:
                    raise ValueError("stored release artifact exceeds limit")
                return data, response.headers.get("ETag")
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None, None
            if error.code in (408, 429, 500, 502, 503, 504):
                raise TransientDeliveryError(f"release artifact read temporarily failed (HTTP {error.code})") from None
            raise RuntimeError(f"release artifact read failed (HTTP {error.code})") from None
        except (urllib.error.URLError, TimeoutError):
            raise TransientDeliveryError("release artifact read transport failed") from None

    def origin_etag(self) -> str:
        return self._channel_request()["etag"]

    def _channel_request(self, data: bytes | None = None, if_match: str | None = None) -> dict:
        token = os.environ.get("BLOB_READ_WRITE_TOKEN")
        if not token:
            raise ValueError("BLOB_READ_WRITE_TOKEN is required for release channel state")
        parts = token.split("_")
        if len(parts) < 5 or parts[:3] != ["vercel", "blob", "rw"] or parts[3].lower() != "ugiwefobuo4tac0m":
            raise ValueError("release channel credential does not identify the configured Blob store")
        headers = {"Authorization": f"Bearer {token}", "x-api-version": "12",
                   "x-vercel-blob-store-id": parts[3]}
        if data is None:
            query = urllib.parse.urlencode({"url": PUBLIC_BLOB + "cli/latest.txt"})
        else:
            etag_value(if_match)
            query = urllib.parse.urlencode({"pathname": "cli/latest.txt"})
            headers.update({"x-if-match": if_match, "x-allow-overwrite": "1", "x-add-random-suffix": "0",
                            "x-vercel-blob-access": "public", "x-content-type": "text/plain", "x-cache-control-max-age": "60"})
        request = urllib.request.Request("https://blob.vercel-storage.com/?" + query, data=data,
                                         method="GET" if data is None else "PUT", headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read(8193)
            result = json.loads(raw) if len(raw) <= 8192 else None
            if not isinstance(result, dict) or result.get("pathname") != "cli/latest.txt" or result.get("url") != PUBLIC_BLOB + "cli/latest.txt":
                raise ValueError("release channel metadata identity differs")
            etag_value(result.get("etag"))
            return result
        except urllib.error.HTTPError as error:
            error.close()
            if error.code == 412:
                raise BlobConflictError("release channel changed during a conditional write") from None
            if error.code in (408, 429, 500, 502, 503, 504):
                raise TransientDeliveryError(f"release channel request temporarily failed (HTTP {error.code})") from None
            raise RuntimeError(f"release channel request failed (HTTP {error.code})") from None
        except (urllib.error.URLError, TimeoutError):
            raise TransientDeliveryError("release channel request outcome is unavailable") from None
        except (ValueError, TypeError):
            if data is not None:
                raise TransientDeliveryError("release channel write acknowledgment is invalid; reconcile storage before retrying") from None
            raise ValueError("release channel metadata is invalid") from None

    def write(self, path: str, data: bytes, *, mutable: bool = False, if_match: str | None = None) -> str | None:
        if not re.fullmatch(r"(?:release-candidates/sdk/[0-9a-f]{64}/libfx-[0-9.]+\.tgz|cli/v[0-9.]+/fx-[a-z0-9_-]+\.tar\.gz(?:\.sha256)?|cli/latest\.txt)", path):
            raise ValueError("invalid release storage path")
        if mutable:
            if path != "cli/latest.txt":
                raise ValueError("only the release channel may be overwritten")
            return self._channel_request(data, if_match)["etag"]
        if path == "cli/latest.txt" or if_match is not None:
            raise ValueError("release channel writes must be conditional")
        token = os.environ.get("BLOB_READ_WRITE_TOKEN")
        if not token:
            raise ValueError("BLOB_READ_WRITE_TOKEN is required")
        content_type = "text/plain" if path.endswith((".txt", ".sha256")) else "application/gzip"
        request = urllib.request.Request("https://blob.vercel-storage.com/" + path, data=data, method="PUT", headers={
            "Authorization": f"Bearer {token}", "x-api-version": "7",
            "x-content-type": content_type, "x-add-random-suffix": "0",
            "x-cache-control-max-age": "60" if mutable else "31536000",
        })
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                if not 200 <= response.status < 300:
                    raise RuntimeError("release artifact upload failed")
        except urllib.error.HTTPError as error:
            if error.code in (408, 429, 500, 502, 503, 504):
                raise TransientDeliveryError(f"release artifact upload temporarily failed (HTTP {error.code})") from None
            raise RuntimeError(f"release artifact upload failed (HTTP {error.code})") from None
        except urllib.error.URLError:
            raise TransientDeliveryError("release artifact upload transport failed") from None


def put_immutable(store: BlobStore, path: str, data: bytes) -> None:
    for attempt in range(3):
        try:
            existing = store.read(path)
            if existing is not None:
                if existing != data:
                    raise ValueError(f"existing release artifact differs: {path}")
                return
            store.write(path, data)
            observed = store.read(path)
            if observed is None:
                raise TransientDeliveryError("new release artifact is not visible yet")
            if observed != data:
                raise ValueError(f"uploaded release artifact differs: {path}")
            return
        except TransientDeliveryError:
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)


def stage_sdk(candidate: dict, artifacts: pathlib.Path, store: BlobStore | None = None) -> None:
    verify_candidate(candidate, artifacts, candidate["source_sha"])
    data = (artifacts / candidate["sdk"]["archive"]).read_bytes()
    path = candidate["sdk"]["tarball_url"].removeprefix(PUBLIC_BLOB)
    put_immutable(store or BlobStore(), path, data)


def release_branch(candidate_path: pathlib.Path, candidate: dict, web_base: str = "") -> str:
    suffix = f"-{web_base[:12]}" if web_base else ""
    return f"release/v{candidate['version']}-{sha256_file(candidate_path)[:12]}{suffix}"


def website_commit(web_root: pathlib.Path, candidate_path: pathlib.Path, candidate: dict) -> tuple[str, str, int]:
    base = command(["git", "rev-parse", "HEAD"], cwd=web_root)
    branch = release_branch(candidate_path, candidate, base)
    changed = command(["git", "diff", "--name-only"], cwd=web_root).splitlines()
    changed += command(["git", "ls-files", "--others", "--exclude-standard"], cwd=web_root).splitlines()
    if not changed or not set(changed).issubset(RELEASE_PATHS):
        raise ValueError("website preparation changed unexpected files or produced no release update")
    additions = [{"path": path, "contents": base64.b64encode((web_root / path).read_bytes()).decode()} for path in sorted(set(changed))]
    ref = github(f"repos/{WEB_REPO}/git/ref/heads/{branch}", web=True, missing_ok=True)
    if ref is not None and ref["object"]["sha"] != base:
        head = ref["object"]["sha"]
        for entry in additions:
            remote = github(f"repos/{WEB_REPO}/contents/{entry['path']}?ref={head}", web=True)
            if base64.b64decode(remote.get("content", "")) != base64.b64decode(entry["contents"]):
                raise ValueError("prepared website branch changed; refusing to overwrite it")
    else:
        if ref is None:
            github(f"repos/{WEB_REPO}/git/refs", method="POST", body={"ref": f"refs/heads/{branch}", "sha": base}, web=True)
        response = github("graphql", method="POST", web=True, body={
            "query": "mutation($input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: $input) { commit { oid } } }",
            "variables": {"input": {"branch": {"repositoryNameWithOwner": WEB_REPO, "branchName": branch}, "expectedHeadOid": base,
                "message": {"headline": f"Prepare fx {candidate['version']} website"}, "fileChanges": {"additions": additions}}},
        })
        if response.get("errors") or not response.get("data", {}).get("createCommitOnBranch"):
            raise ValueError("GitHub refused the prepared website commit")
        head = response["data"]["createCommitOnBranch"]["commit"]["oid"]
    commit = github(f"repos/{WEB_REPO}/commits/{head}", web=True)
    if not commit["commit"]["verification"]["verified"]:
        raise ValueError("website preparation commit must be signed")
    prs = github(f"repos/{WEB_REPO}/pulls?state=open&head=vercel-labs:{branch}", web=True)
    if len(prs) > 1:
        raise ValueError("ambiguous prepared website PR")
    pr = prs[0] if prs else github(f"repos/{WEB_REPO}/pulls", method="POST", web=True, body={
        "head": branch, "base": "main", "title": f"Prepare fx {candidate['version']} website", "draft": False,
        "body": f"## Summary\n\n- Update the terminal, release notes and binary size for fx {candidate['version']}.\n\nPublication is controlled by the final approval in the fx release workflow.",
    })
    return base, head, pr["number"]


def website_check_snapshot(number: int) -> dict:
    return json.loads(command(["gh", "pr", "view", str(number), "--repo", WEB_REPO, "--json",
                               "headRefOid,state,isDraft,statusCheckRollup,reviewDecision"], web=True))


def website_checks_pass(pr: dict, head: str) -> bool:
    if pr["headRefOid"] != head:
        raise ValueError("website source changed while checking the release")
    if pr.get("state") != "OPEN" or pr.get("isDraft") is not False:
        raise ValueError("website release PR must remain open and eligible for review")
    if pr.get("reviewDecision") in ("REVIEW_REQUIRED", "CHANGES_REQUESTED"):
        raise ValueError("website branch policy requires separate review; resolve policy before release approval")
    checks = [check for check in pr["statusCheckRollup"] if check.get("name") != "Vercel Agent Review"]
    states = [(check.get("name") or check.get("context"),
               (check.get("conclusion") or check.get("state") or check.get("status") or "PENDING").upper())
              for check in checks]
    if any(state in ("FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED") for _, state in states):
        raise ValueError("website release checks failed")
    required = {"Marketing build", "Installer", "CDN build"}
    return (required.issubset(name for name, _ in states)
            and all(state == "SUCCESS" for name, state in states if name in required)
            and all(state in ("SUCCESS", "SKIPPED", "NEUTRAL") for _, state in states))


def wait_website_checks(number: int, head: str) -> None:
    deadline = time.monotonic() + 30 * 60
    while time.monotonic() < deadline:
        if website_checks_pass(website_check_snapshot(number), head):
            return
        print(f"Waiting for website PR #{number} checks", flush=True)
        time.sleep(20)
    raise TimeoutError("website checks did not complete within the preparation window")


def vercel(path: str):
    return json.loads(command(["vercel", "api", path, "--scope", "vercel-labs", "--raw"]))


def require_website_protection(project: dict) -> None:
    protection = project.get("ssoProtection") or {}
    if protection.get("deploymentType") != "prod_deployment_urls_and_all_previews":
        raise ValueError("configure Vercel protection for preview and production deployment URLs, leaving public domains open")


@contextlib.contextmanager
def linked_website(web_root: pathlib.Path):
    local = web_root / ".vercel"
    if local.exists() or local.is_symlink():
        raise ValueError("website preparation requires a checkout without an existing Vercel link")
    local.mkdir(mode=0o700)
    try:
        (local / "project.json").write_text(json.dumps({"orgId": vercel_team(), "projectId": WEB_PROJECT}))
        yield
    finally:
        shutil.rmtree(local)


def prepare_website(candidate_path: pathlib.Path, artifacts: pathlib.Path, fx_root: pathlib.Path, web_root: pathlib.Path, output: pathlib.Path, *, publication_allowed: bool, native_pr: int = 0) -> dict:
    candidate = json.loads(candidate_path.read_text())
    verify_candidate(candidate, artifacts, command(["git", "rev-parse", "HEAD"], cwd=fx_root))
    project = vercel(f"/v9/projects/{WEB_PROJECT}")
    require_website_protection(project)
    previous_version = (BlobStore().read("cli/latest.txt") or b"").decode().strip()
    examples = prepare_examples(candidate, previous_version, fx_root, output.parent / "example-evidence")
    stage_sdk(candidate, artifacts)
    app = web_root / "apps/marketing"
    command(["pnpm", "install", "--frozen-lockfile"], cwd=app)
    command(["node", "scripts/sync-release.mjs", str(candidate_path.resolve())], cwd=app)
    command(["node", "scripts/sync-examples.mjs", str(fx_root.resolve())], cwd=app)
    base, head, number = website_commit(web_root, candidate_path, candidate)
    command(["git", "fetch", "origin", head], cwd=web_root)
    if command(["git", "diff", "--name-only", head], cwd=web_root):
        raise ValueError("staged website tree differs from the prepared commit")
    command(["git", "add", "--", *RELEASE_PATHS], cwd=web_root)
    if command(["git", "diff", "--cached", "--name-only", head], cwd=web_root):
        raise ValueError("website index differs from the prepared source")
    command(["git", "switch", "--detach", head], cwd=web_root)
    command(["pnpm", "install", "--frozen-lockfile"], cwd=app)
    for test in ("test:release", "test:docs", "test:gateway"):
        command(["pnpm", "run", test], cwd=app)
    previous = project.get("targets", {}).get("production", {}).get("id")
    with linked_website(web_root):
        command(["vercel", "pull", "--yes", "--environment=production", "--scope", "vercel-labs"], cwd=web_root)
        command(["vercel", "build", "--prod", "--yes"], cwd=web_root)
        command(["pnpm", "run", "test:libfx-build"], cwd=app)
        url = command(["vercel", "deploy", "--prebuilt", "--prod", "--skip-domain", "--yes", "--scope", "vercel-labs"], cwd=web_root)
    if not re.fullmatch(r"https://[a-zA-Z0-9.-]+\.(?:vercel\.app|vercel\.dev)", url):
        raise ValueError("unexpected staged website URL")
    deployed = vercel(f"/v13/deployments/{url.removeprefix('https://')}")
    if deployed.get("projectId") != WEB_PROJECT or deployed.get("readyState") != "READY":
        raise ValueError("staged website deployment is not ready on the expected project")
    command(["node", "scripts/verify-release-site.mjs", url, str(candidate_path.resolve()), str((output.parent / "website-evidence").resolve())], cwd=app)
    wait_website_checks(number, head)
    ready = {
        "schema_version": 1, "candidate_sha256": sha256_file(candidate_path),
        "publication_allowed": publication_allowed, "previous_version": previous_version,
        "native_pr": native_pr,
        "examples": examples,
        "website": {"base_sha": base, "source_sha": head, "pr": number, "deployment_id": deployed["id"], "url": url, "previous_deployment_id": previous},
    }
    output.write_text(json.dumps(ready, indent=2, sort_keys=True) + "\n")
    return ready


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=pathlib.Path, required=True)
    parser.add_argument("--artifacts", type=pathlib.Path, required=True)
    parser.add_argument("--fx-root", type=pathlib.Path, required=True)
    parser.add_argument("--web-root", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--allow-publication", action="store_true")
    parser.add_argument("--release-pr", type=int, default=0)
    args = parser.parse_args()
    try:
        ready = prepare_website(args.candidate, args.artifacts, args.fx_root, args.web_root, args.output, publication_allowed=args.allow_publication, native_pr=args.release_pr)
        print(f"Release preview: {ready['website']['url']}")
    except (ValueError, RuntimeError, OSError) as error:
        parser.exit(1, f"Release preparation stopped: {error}\n")


if __name__ == "__main__":
    main()
