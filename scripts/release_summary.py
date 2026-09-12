"""Write one review summary for the prepared native, SDK and website release."""

from __future__ import annotations

import json
import pathlib
import sys


def summary(root: pathlib.Path) -> str:
    candidate = json.loads((root / "candidate.json").read_text())
    ready = json.loads((root / "ready.json").read_text())
    report = json.loads((root / "website-evidence/report.json").read_text())
    website = ready["website"]
    lines = [
        f"## Prepared fx v{candidate['version']}", "",
        f"[Review the website]({website['url']}) · [Changelog]({website['url']}/changelog) · [Terminal]({website['url']}/try)", "",
        f"Source: `{candidate['source_sha']}`. Stable SDK: `{candidate['sdk']['version']}`.", "",
        "| Platform | Final binary |", "| --- | ---: |",
        *[f"| {platform} | {binary['size_bytes'] / 1048576:.2f} MiB |" for platform, binary in candidate["binaries"].items()],
        "", f"Browser checks: {len(report['checks'])}, passed: {report['passed']}. Desktop and mobile screenshots are in the retained release artifact.", "",
        f"[Website PR #{website['pr']}](https://github.com/vercel-labs/fx-web/pull/{website['pr']}) is prepared; no website promotion has happened.", "",
        "Final approval publishes these exact artifacts and promotes this deployment." if ready["publication_allowed"] else "Preparation-only rehearsal: this candidate cannot be published.",
        "", "### Release notes", "", candidate["changelog"],
    ]
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: python3 -m scripts.release_summary ARTIFACT_DIRECTORY")
    print(summary(pathlib.Path(sys.argv[1])), end="")
