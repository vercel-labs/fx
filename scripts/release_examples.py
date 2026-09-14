"""Qualify the shipped examples and stage changed demos without promoting aliases."""

from __future__ import annotations

import contextlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import tempfile

from scripts.release_candidate import SEMVER

PROJECTS = {
    "node-chat": "prj_W5dY7GTXPZ66l2AVL5q39RuyIirt",
    "browser-agent": "prj_uqZvHZYVkbFilG75KBxKdevCKnuw",
    "nextjs-agent": "prj_h46gu35MkMwBncsoYr7Rp8Bawgrb",
    "nuxt-agent": "prj_6iUWAGkO6MHq7lBNOTHQpy7KxIQy",
}
DEPLOYMENT_ID = r"dpl_[A-Za-z0-9]+"
DEPLOYMENT_URL = r"https://[A-Za-z0-9-]+\.(?:vercel\.app|labs\.vercel\.dev)"
CHILD_ENV = ("PATH", "HOME", "TMPDIR", "TEMP", "TMP", "SHELL", "LANG", "LC_ALL",
             "USER", "LOGNAME", "SYSTEMROOT", "NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE",
             "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY")


def run(args: list[str], *, cwd: pathlib.Path, token: str | None = None) -> str:
    env = {key: os.environ[key] for key in CHILD_ENV if key in os.environ}
    env.update(CI="1", NO_COLOR="1", NEXT_TELEMETRY_DISABLED="1", NUXT_TELEMETRY_DISABLED="1")
    if token is not None:
        env["VERCEL_TOKEN"] = token
    result = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True)
    if result.returncode:
        # Build output may include pulled production settings. Never echo it or credentials.
        raise RuntimeError(f"example {args[0]} {args[1] if len(args) > 1 else ''} failed (exit {result.returncode})")
    return result.stdout.strip()


def vercel_team() -> str:
    team = os.environ.get("FX_RELEASE_VERCEL_TEAM_ID", "")
    if not re.fullmatch(r"team_[A-Za-z0-9]{24}", team):
        raise ValueError("FX_RELEASE_VERCEL_TEAM_ID must contain the configured Vercel team ID")
    return team


def vercel(path: str, *, cwd: pathlib.Path, token: str) -> dict:
    team = vercel_team()
    return json.loads(run(["vercel", "api", f"{path}?teamId={team}", "--scope", team, "--raw"],
                          cwd=cwd, token=token))


def affected_examples(paths: list[str]) -> set[str]:
    affected: set[str] = set()
    for value in paths:
        path = pathlib.PurePosixPath(value)
        if path.is_absolute() or ".." in path.parts:
            raise ValueError("invalid changed example path")
        if not path.parts or path.parts[0] != "examples":
            continue
        if len(path.parts) <= 2 or path.parts[1] == "shared":
            affected.update(PROJECTS)
        elif path.parts[1] in PROJECTS:
            affected.add(path.parts[1])
        else:
            raise ValueError(f"example has no configured deployment project: {path.parts[1]}")
    return affected


def scoped_tokens(ids: set[str]) -> dict[str, str]:
    raw = os.environ.get("FX_EXAMPLE_VERCEL_TOKENS") or "{}"
    try:
        tokens = json.loads(raw)
    except json.JSONDecodeError:
        raise ValueError("FX_EXAMPLE_VERCEL_TOKENS must be a JSON map of example IDs to scoped tokens") from None
    if not isinstance(tokens, dict) or set(tokens) - PROJECTS.keys():
        raise ValueError("FX_EXAMPLE_VERCEL_TOKENS contains an unknown example ID")
    if any(not isinstance(value, str) or not value.strip() for value in tokens.values()):
        raise ValueError("example tokens must be nonempty strings")
    missing = ids - tokens.keys()
    if missing:
        raise ValueError("missing scoped example credentials: " + ", ".join(sorted(missing)))
    return {ident: tokens[ident] for ident in ids}


def catalog(fx_root: pathlib.Path) -> dict[str, str]:
    entries = json.loads((fx_root / "examples/examples.json").read_text())
    ids = [entry["id"] for entry in entries]
    if len(ids) != len(PROJECTS) or set(ids) != PROJECTS.keys():
        raise ValueError("example catalog must contain exactly the four configured projects")
    versions = {}
    for ident in PROJECTS:
        app = fx_root / "examples" / ident
        package = json.loads((app / "package.json").read_text())
        version = package.get("dependencies", {}).get("libfx")
        if not isinstance(version, str) or not re.fullmatch(SEMVER, version):
            raise ValueError(f"{ident} must declare an exact stable libfx version")
        lock = json.loads((app / "package-lock.json").read_text())
        packages = lock.get("packages", {})
        if (packages.get("", {}).get("dependencies", {}).get("libfx") != version
                or packages.get("node_modules/libfx", {}).get("version") != version):
            raise ValueError(f"{ident} SDK lockfile differs from its declared pin")
        versions[ident] = version
    return versions


def project_state(ident: str, *, cwd: pathlib.Path, token: str) -> dict:
    project = vercel(f"/v9/projects/{PROJECTS[ident]}", cwd=cwd, token=token)
    if (project.get("id") != PROJECTS[ident] or project.get("accountId") != vercel_team()
            or project.get("rootDirectory") != f"examples/{ident}"):
        raise ValueError(f"{ident} project identity or rootDirectory differs from its configured example")
    previous = project.get("targets", {}).get("production", {}).get("id")
    if not isinstance(previous, str) or not re.fullmatch(DEPLOYMENT_ID, previous):
        raise ValueError(f"{ident} has no identifiable production deployment")
    return project


def qualify(fx_root: pathlib.Path, output_dir: pathlib.Path) -> None:
    if not run(["node", "-p", "process.versions.node"], cwd=fx_root).startswith("24."):
        raise ValueError("example qualification requires the declared Node.js 24 runtime")
    for ident in PROJECTS:
        app = fx_root / "examples" / ident
        run(["npm", "ci"], cwd=app)
        if ident == "node-chat":
            tests = sorted((fx_root / "examples/shared").glob("*.test.mjs"))
            if not tests:
                raise ValueError("shared example tests are missing")
            run(["node", "--test", *(str(path) for path in tests)], cwd=app)
        elif ident == "browser-agent":
            run(["node", "--experimental-vm-modules", "--test", "main.test.mjs"], cwd=app)
        elif ident == "nuxt-agent":
            run(["node", "--test", "dev.test.mjs"], cwd=app)
        if ident != "node-chat":
            run(["npm", "run", "build"], cwd=app)
        (output_dir / f"{ident}-qualification.json").write_text(
            json.dumps({"id": ident, "validation": "passed"}, indent=2) + "\n")


@contextlib.contextmanager
def linked_project(fx_root: pathlib.Path, ident: str):
    # Each production pull/build gets its own local state; never replace a pre-existing link.
    local = fx_root / ".vercel"
    if local.exists() or local.is_symlink():
        raise ValueError("example staging requires an fx checkout without an existing .vercel directory")
    local.mkdir(mode=0o700)
    try:
        (local / "project.json").write_text(json.dumps({"projectId": PROJECTS[ident], "orgId": vercel_team()}))
        yield
    finally:
        shutil.rmtree(local)


def checked_deployment(record: dict, *, cwd: pathlib.Path, token: str) -> None:
    deployed = vercel(f"/v13/deployments/{record['deployment_id']}", cwd=cwd, token=token)
    metadata = deployed.get("meta", {})
    if (deployed.get("id") != record["deployment_id"]
            or deployed.get("projectId") != record["project_id"]
            or deployed.get("readyState") != "READY"
            or deployed.get("target") != "production"
            or deployed.get("url") != record["url"].removeprefix("https://")
            or metadata.get("fxSourceSha") != record["source_sha"]
            or metadata.get("fxExampleId") != record["id"]
            or metadata.get("fxSdkVersion") != record["sdk_version"]):
        raise ValueError(f"{record['id']} prepared deployment identity differs or is not ready")


def prepare_examples(candidate: dict, previous_version: str, fx_root: pathlib.Path,
                     output_dir: pathlib.Path) -> list[dict]:
    fx_root = pathlib.Path(fx_root).resolve()
    output_dir = pathlib.Path(output_dir).resolve()
    sha = candidate.get("source_sha")
    if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("example candidate needs a full source SHA")
    if run(["git", "rev-parse", "HEAD"], cwd=fx_root) != sha:
        raise ValueError("example checkout differs from the candidate source")
    previous = previous_version.removeprefix("v")
    if not re.fullmatch(SEMVER, previous):
        raise ValueError("previous example release must be stable SemVer")
    baseline = run(["git", "rev-parse", "--verify", f"refs/tags/v{previous}^{{commit}}"], cwd=fx_root)
    changed = run(["git", "diff", "--name-only", "--no-renames", "-z",
                   f"{baseline}..{sha}", "--", "examples/"], cwd=fx_root)
    affected = affected_examples([path for path in changed.split("\0") if path])
    versions = catalog(fx_root)
    tokens = scoped_tokens(affected)
    if run(["git", "diff", "--name-only", sha, "--", "examples/"], cwd=fx_root):
        raise ValueError("example source has uncommitted changes")
    if run(["git", "ls-files", "--others", "--exclude-standard", "--", "examples/"], cwd=fx_root):
        raise ValueError("example source has untracked files")
    # Read every target before local production pulls or any deployment can start.
    projects = {ident: project_state(ident, cwd=fx_root, token=tokens[ident])
                for ident in PROJECTS if ident in affected}
    output_dir.mkdir(parents=True, exist_ok=True)
    qualify(fx_root, output_dir)
    if catalog(fx_root) != versions or run(["git", "diff", "--name-only", sha, "--", "examples/"], cwd=fx_root):
        raise ValueError("example qualification changed the declared source or SDK pins")
    records = [dict(id=ident, project_id=PROJECTS[ident], source_sha=sha, sdk_version=versions[ident],
                    validation="passed", affected=ident in affected, deployment_id=None, url=None,
                    previous_deployment_id=None) for ident in PROJECTS]
    for record in records:
        if record["affected"]:
            ident, token = record["id"], tokens[record["id"]]
            record["previous_deployment_id"] = projects[ident]["targets"]["production"]["id"]
            with linked_project(fx_root, ident):
                run(["vercel", "pull", "--yes", "--environment=production", "--scope", vercel_team()],
                    cwd=fx_root, token=token)
                run(["vercel", "build", "--prod", "--yes"], cwd=fx_root, token=token)
                if run(["git", "diff", "--name-only", sha, "--", "examples/"], cwd=fx_root):
                    raise ValueError(f"{ident} production build changed the example source")
                url = run(["vercel", "deploy", "--prebuilt", "--prod", "--skip-domain", "--yes",
                           "--scope", vercel_team(), "--meta", f"fxSourceSha={sha}",
                           "--meta", f"fxExampleId={ident}", "--meta", f"fxSdkVersion={versions[ident]}"],
                          cwd=fx_root, token=token)
            if not re.fullmatch(DEPLOYMENT_URL, url):
                raise ValueError(f"{ident} returned an unexpected deployment URL")
            deployed = vercel(f"/v13/deployments/{url.removeprefix('https://')}", cwd=fx_root, token=token)
            record.update(deployment_id=deployed.get("id"), url=url)
            if not re.fullmatch(DEPLOYMENT_ID, str(record["deployment_id"])):
                raise ValueError(f"{ident} returned an invalid deployment ID")
            checked_deployment(record, cwd=fx_root, token=token)
            current = project_state(ident, cwd=fx_root, token=token)["targets"]["production"]["id"]
            if current != record["previous_deployment_id"]:
                raise ValueError(f"{ident} production changed during preparation")
        (output_dir / "examples.json").write_text(json.dumps(records, indent=2) + "\n")
    return records


def validate_records(records: list[dict]) -> list[dict]:
    if not isinstance(records, list) or len(records) > len(PROJECTS):
        raise ValueError("invalid prepared example records")
    seen = set()
    for record in records:
        if not isinstance(record, dict):
            raise ValueError("invalid prepared example record")
        ident = record.get("id")
        if not isinstance(ident, str) or ident not in PROJECTS or ident in seen or record.get("project_id") != PROJECTS[ident]:
            raise ValueError("unknown, duplicate, or mismatched example project")
        seen.add(ident)
        if (record.get("validation") != "passed" or type(record.get("affected")) is not bool
                or not re.fullmatch(r"[0-9a-f]{40}", str(record.get("source_sha", "")))
                or not re.fullmatch(SEMVER, str(record.get("sdk_version", "")))):
            raise ValueError("example source, SDK pin, or qualification is invalid")
        if record["affected"]:
            if (not re.fullmatch(DEPLOYMENT_ID, str(record.get("deployment_id", "")))
                    or not re.fullmatch(DEPLOYMENT_ID, str(record.get("previous_deployment_id", "")))
                    or not re.fullmatch(DEPLOYMENT_URL, str(record.get("url", "")))):
                raise ValueError("invalid prepared example deployment")
        elif any(record.get(key) is not None for key in ("deployment_id", "previous_deployment_id", "url")):
            raise ValueError("unchanged example must not carry a deployment to promote")
    if len({record["source_sha"] for record in records}) > 1:
        raise ValueError("prepared examples have different source revisions")
    return [record for record in records if record["affected"]]


def preflight_examples(records: list[dict]) -> None:
    """Check prepared deployments and current targets without promoting any project."""
    affected = validate_records(records)
    tokens = scoped_tokens({record["id"] for record in affected})
    with tempfile.TemporaryDirectory(prefix="fx-example-preflight-") as tmp:
        cwd = pathlib.Path(tmp)
        for record in affected:
            ident, token = record["id"], tokens[record["id"]]
            checked_deployment(record, cwd=cwd, token=token)
            current = project_state(ident, cwd=cwd, token=token)["targets"]["production"]["id"]
            if current not in (record["previous_deployment_id"], record["deployment_id"]):
                raise ValueError(f"{ident} has a newer production deployment")


def promote_examples(records: list[dict]) -> None:
    preflight_examples(records)
    affected = [record for record in records if record["affected"]]
    tokens = scoped_tokens({record["id"] for record in affected})
    with tempfile.TemporaryDirectory(prefix="fx-example-promotion-") as tmp:
        cwd = pathlib.Path(tmp)
        for record in affected:
            ident, token = record["id"], tokens[record["id"]]
            current = project_state(ident, cwd=cwd, token=token)["targets"]["production"]["id"]
            if current == record["deployment_id"]:
                continue
            if current != record["previous_deployment_id"]:
                raise ValueError(f"{ident} production changed before promotion")
            run(["vercel", "promote", record["deployment_id"], "--yes", "--scope", vercel_team()],
                cwd=cwd, token=token)
            if project_state(ident, cwd=cwd, token=token)["targets"]["production"]["id"] != record["deployment_id"]:
                raise ValueError(f"{ident} did not promote the prepared deployment")
