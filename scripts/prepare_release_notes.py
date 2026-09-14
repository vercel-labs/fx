"""Prepare a release from the maintainer's committed changelog without rewriting it."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import subprocess

from scripts.release_preparation import prepared_readme, verify_version_only_change

SEMVER = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
SECTIONS = ("Breaking Changes", "New Features", "Improvements", "Bug Fixes", "Security")


def command(*args: str, strip: bool = True) -> str:
    output = subprocess.check_output(args, text=True)
    return output.strip() if strip else output


def source_version(text: str) -> str:
    matches = re.findall(r'^pub const version = "([^"]+)";$', text, re.MULTILINE)
    if len(matches) != 1 or not re.fullmatch(SEMVER, matches[0]):
        raise ValueError("src/main.zig must declare one stable SemVer")
    return matches[0]


def validate_body(body: str) -> None:
    lines = [line for line in body.strip().splitlines() if line.strip()]
    if not lines or not re.fullmatch(r"\*\*[^*\n]+\*\*", lines[0]):
        raise ValueError("release notes need one bold summary paragraph")
    section = None
    counts: dict[str, int] = {}
    for line in lines[1:]:
        if line.startswith("### "):
            section = line[4:]
            if section not in SECTIONS or section in counts:
                raise ValueError("unsupported or duplicate release section")
            counts[section] = 0
        elif section and line.startswith("- ") and line[2:].strip():
            if re.match(r"- \*\*[^*]+\*\*\s*:?", line):
                raise ValueError("release bullets must be plain sentences, without bold labels")
            counts[section] += 1
        else:
            raise ValueError("release notes require one-line bullets inside sections")
    if not counts or not all(counts.values()):
        raise ValueError("release notes cannot contain empty sections")
    forbidden = (
        r"\b(?:Fx|FX)\b(?!_)",
        r"#[0-9]+\b|\bPRs?\s*#?[0-9]+\b|github\.com/[^\s)]+/(?:pull|issues|commit)/",
        r"(?i)\b(?:contributors?|co-authored-by|assisted-by|generated with)\b",
        r"(?i)\b(?:GitHub Actions|CI|CDN|fx-web|marketing|release workflow|"
        r"test fixtures?|test suites?|repository moves?|repository split|"
        r"website|documentation-only|documentation updates?|docs updates?|"
        r"branch history|commit hashes?|implementation-only refactors?)\b",
        r"(?i)vercel-labs/[A-Za-z0-9_.-]+",
    )
    if any(re.search(pattern, body) for pattern in forbidden):
        raise ValueError("release notes contain attribution, tracker, casing, or internal-delivery details")


def active_notes(changelog: str, version: str) -> str:
    start, end = "<!-- release:start -->", "<!-- release:end -->"
    if changelog.count(start) != 1 or changelog.count(end) != 1:
        raise ValueError("changelog needs one active release marker pair")
    before, remainder = changelog.split(start)
    headings = re.findall(r"^## ([^\n]+)$", before, re.MULTILINE)
    if not headings or headings[-1] != version or end in before:
        raise ValueError("active release notes do not match the prepared version")
    body, _ = remainder.split(end)
    if "\n## " in body:
        raise ValueError("release markers cross a version boundary")
    validate_body(body)
    return body.strip()


def version_updates(source: str, readme: str, current: str, version: str) -> dict[str, str]:
    if source_version(source) not in (current, version):
        raise ValueError("release PR source version differs from its changelog")
    return {
        "src/main.zig": re.sub(r'^pub const version = "[^"]+";$',
                               f'pub const version = "{version}";', source, count=1, flags=re.MULTILINE),
        "README.md": prepared_readme(readme, current, version),
    }


def make_plan(number: int) -> dict:
    if type(number) is not int or number <= 0:
        raise ValueError("release PR number must be positive")
    pr = json.loads(command("gh", "pr", "view", str(number), "--repo", "vercel-labs/fx",
                            "--json", "number,state,headRefOid,headRefName,baseRefName,isCrossRepository,isDraft,labels"))
    if (pr["number"] != number or pr["state"] != "OPEN" or pr["isCrossRepository"]
            or pr["isDraft"] or pr["baseRefName"] != "main" or pr["headRefName"] == "main"):
        raise ValueError("select an open, non-draft fx release PR targeting main")
    if any(label["name"].startswith("type:") and label["name"] != "type: release" for label in pr["labels"]):
        raise ValueError("release PR has a different type label; preserving it")
    head = pr["headRefOid"]
    if not re.fullmatch(r"[0-9a-f]{40}", head):
        raise ValueError("release PR source must be a full commit SHA")
    command("git", "check-ref-format", "--branch", pr["headRefName"])
    command("git", "fetch", "--quiet", "--no-recurse-submodules", "origin", head)
    changelog = command("git", "show", f"{head}:CHANGELOG.md", strip=False)
    heading = re.search(r"^## (" + SEMVER + r")$", changelog, re.MULTILINE)
    if not heading:
        raise ValueError("commit a marked stable-version changelog entry in the release PR first")
    version = heading[1]
    body = active_notes(changelog, version)
    if len(body.encode()) > 256 * 1024:
        raise ValueError("release notes exceed the publication size limit")
    main_version = source_version(pathlib.Path("src/main.zig").read_text())
    if tuple(map(int, version.split("."))) <= tuple(map(int, main_version.split("."))):
        raise ValueError("changelog version must advance main's version")
    base = command("git", "merge-base", "origin/main", head)
    before = command("git", "show", f"{base}:src/main.zig", strip=False)
    current = source_version(before)
    source = command("git", "show", f"{head}:src/main.zig", strip=False)
    readme = command("git", "show", f"{head}:README.md", strip=False)
    readme_before = command("git", "show", f"{base}:README.md", strip=False)
    if readme not in (readme_before, prepared_readme(readme_before, current, version)):
        raise ValueError("release README contains changes beyond its install version")
    changed = set(command("git", "diff", "--name-only", "--no-renames", base, head).splitlines())
    updates = version_updates(source, readme, current, version)
    verify_version_only_change(before, updates["src/main.zig"], changed | {"src/main.zig"}, version)
    return dict(current=current, version=version, branch=pr["headRefName"], base_sha=base,
                expected_head=head, prepare=updates != {"src/main.zig": source, "README.md": readme},
                pr_number=number)


def apply_version(plan: dict) -> None:
    if make_plan(plan["pr_number"]) != plan:
        raise ValueError("release PR changed after inspection; retry without replacing its edits")
    if not plan["prepare"]:
        return
    head = plan["expected_head"]
    source = command("git", "show", f"{head}:src/main.zig", strip=False)
    readme = command("git", "show", f"{head}:README.md", strip=False)
    for path, contents in version_updates(source, readme, plan["current"], plan["version"]).items():
        pathlib.Path(path).write_text(contents)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("plan", "apply"))
    parser.add_argument("--pr", type=int)
    parser.add_argument("--plan", type=pathlib.Path, required=True)
    args = parser.parse_args()
    try:
        if args.operation == "plan":
            plan = make_plan(args.pr)
            args.plan.write_text(json.dumps(plan, indent=2) + "\n")
            with open(os.environ["GITHUB_OUTPUT"], "a") as outputs:
                for key, value in plan.items():
                    print(f"{key}={str(value).lower() if isinstance(value, bool) else value}", file=outputs)
        else:
            apply_version(json.loads(args.plan.read_text()))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Release preparation stopped: {error}\n")


if __name__ == "__main__":
    main()
