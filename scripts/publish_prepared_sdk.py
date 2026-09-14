"""Publish or verify one immutable SDK archive; never rebuild it."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import pathlib
import re
import time
import urllib.error
import urllib.parse
import urllib.request

from scripts.release_delivery import TransientDeliveryError, command


REGISTRY = "https://registry.npmjs.org"
PUBLICATION_POLLS = 16


def registry_json(path: str, *, missing_ok: bool = False):
    for attempt in range(3):
        try:
            with urllib.request.urlopen(REGISTRY + path, timeout=30) as response:
                data = response.read(1024 * 1024 + 1)
                if len(data) > 1024 * 1024:
                    raise ValueError("npm metadata exceeds the release limit")
                return json.loads(data)
        except urllib.error.HTTPError as error:
            if missing_ok and error.code == 404:
                return None
            if error.code not in (408, 429, 500, 502, 503, 504) or attempt == 2:
                raise RuntimeError(f"npm metadata request failed (HTTP {error.code})") from None
        except urllib.error.URLError:
            if attempt == 2:
                raise RuntimeError("npm metadata transport is unavailable") from None
        time.sleep(2 ** attempt)


def archive_integrity(path: pathlib.Path) -> str:
    return "sha512-" + base64.b64encode(hashlib.sha512(path.read_bytes()).digest()).decode()


def check_registry_identity(metadata: dict, version: str, integrity: str) -> None:
    if metadata.get("name") != "libfx" or metadata.get("version") != version or metadata.get("dist", {}).get("integrity") != integrity:
        raise ValueError("npm version exists with different package bytes")


def check_channel_advance(current: str | None, version: str) -> None:
    def key(value):
        matched = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:-dev\.(\d+)\.g[0-9a-f]{12})?", value)
        if not matched:
            raise ValueError("current npm channel has an unrecognized version")
        return tuple(map(int, matched.group(1, 2, 3))) + (1 if matched[4] is None else 0, int(matched[4] or 0))
    if current is not None and key(current) > key(version):
        raise ValueError("refusing to move an npm channel backwards")


def wait_for_publication(version: str, tag: str, integrity: str) -> dict:
    metadata = None
    for attempt in range(PUBLICATION_POLLS):
        metadata = registry_json(f"/libfx/{urllib.parse.quote(version)}", missing_ok=True)
        if metadata is not None:
            check_registry_identity(metadata, version, integrity)
        tags = registry_json("/-/package/libfx/dist-tags")
        check_channel_advance(tags.get(tag), version)
        if metadata is not None and tags.get(tag) == version:
            return metadata
        if attempt + 1 < PUBLICATION_POLLS:
            time.sleep(5)
    if metadata is None:
        raise ValueError("SDK publication is not visible; preserve this archive and retry verification")
    raise ValueError(f"SDK version exists but npm {tag} does not identify it; trusted publishing cannot repair distribution tags")


def publish(archive: pathlib.Path, version: str, tag: str) -> None:
    if tag not in ("latest", "dev") or not re.fullmatch(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-dev\.[1-9]\d*\.g[0-9a-f]{12})?", version):
        raise ValueError("invalid SDK version or channel")
    if (tag == "dev") != ("-dev." in version):
        raise ValueError("SDK version does not match its publication channel")
    integrity = archive_integrity(archive)
    tags = registry_json("/-/package/libfx/dist-tags")
    check_channel_advance(tags.get(tag), version)
    metadata = registry_json(f"/libfx/{urllib.parse.quote(version)}", missing_ok=True)
    if metadata is None:
        try:
            command(["npm", "publish", str(archive.resolve()), "--ignore-scripts", "--access", "public", "--tag", tag, "--provenance"])
        except TransientDeliveryError:
            print("SDK publish response was uncertain; checking the immutable registry version", flush=True)
    else:
        check_registry_identity(metadata, version, integrity)
    metadata = wait_for_publication(version, tag, integrity)
    url = metadata["dist"].get("tarball", "")
    if not url.startswith(REGISTRY + "/libfx/-/"):
        raise ValueError("npm returned an unexpected SDK archive URL")
    with urllib.request.urlopen(url, timeout=120) as response:
        downloaded = response.read(256 * 1024 * 1024 + 1)
    if "sha512-" + base64.b64encode(hashlib.sha512(downloaded).digest()).decode() != integrity:
        raise ValueError("published SDK download differs from the prepared archive")
    wait_for_publication(version, tag, integrity)
    print(f"Verified published libfx@{version}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=pathlib.Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--tag", choices=("latest", "dev"), required=True)
    args = parser.parse_args()
    try:
        publish(args.archive, args.version, args.tag)
    except (ValueError, RuntimeError, OSError) as error:
        parser.exit(1, f"SDK publication stopped: {error}\n")
