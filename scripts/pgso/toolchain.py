from __future__ import annotations

import dataclasses
import os
import pathlib
import re
import shutil
import subprocess

from typing import Any

from scripts.pgso.model import PgsoError


REQUIRED_ZIG_VERSION = "0.17.0"
REQUIRED_LLVM_VERSION = "22.1.8"
DEFAULT_TARGET = "aarch64-macos"
IR_SIZE_SCRIPT = pathlib.Path(__file__).resolve().with_name("ir_size.py")


def _resolve_executable(command: str, display_name: str) -> pathlib.Path:
    resolved = shutil.which(command)
    if resolved is None:
        raise PgsoError(f"missing executable: {display_name}")
    return pathlib.Path(resolved).resolve()


def _capture(argv: tuple[str, ...], stage: str) -> str:
    try:
        result = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise PgsoError(f"could not query {stage}: {error}") from error
    if result.returncode != 0:
        raise PgsoError(
            f"could not query {stage}: exit code {result.returncode}: "
            f"{result.stderr.strip()}"
        )
    return result.stdout.strip()


def _llvm_version(tool: pathlib.Path, display_name: str) -> str:
    output = _capture((str(tool), "--version"), f"{display_name} version")
    match = re.search(r"\b\d+\.\d+\.\d+\b", output)
    if match is None:
        raise PgsoError(f"could not parse LLVM version from {display_name}: {output}")
    version = match.group(0)
    if version != REQUIRED_LLVM_VERSION:
        raise PgsoError(
            f"PGSO requires LLVM {REQUIRED_LLVM_VERSION}; "
            f"{display_name} reported {version}"
        )
    return version


@dataclasses.dataclass(frozen=True)
class Toolchain:
    zig: pathlib.Path
    llvm_bin: pathlib.Path
    opt: pathlib.Path
    llc: pathlib.Path
    llvm_profdata: pathlib.Path
    llvm_ar: pathlib.Path
    llvm_nm: pathlib.Path
    clang: pathlib.Path
    libllvm: pathlib.Path
    ir_size: pathlib.Path
    # The platform module that builds `target` (scripts/pgso/platforms.py),
    # and its native tools.
    platform: Any
    tools: Any
    profile_runtime: pathlib.Path
    zig_version: str
    llvm_version: str
    target: str
    host_arch: str

    @classmethod
    def discover(
        cls,
        zig: str,
        llvm_bin: str,
        target: str,
    ) -> "Toolchain":
        # Platform modules import this one, so load the registry here.
        from scripts.pgso import platforms

        host = platforms.for_target(target)
        host_arch = host.check_host()

        zig_path = _resolve_executable(zig, "zig")
        zig_version = _capture((str(zig_path), "version"), "Zig version")
        if zig_version != REQUIRED_ZIG_VERSION:
            raise PgsoError(
                f"PGSO requires Zig {REQUIRED_ZIG_VERSION}; "
                f"zig reported {zig_version}"
            )

        llvm_root = pathlib.Path(llvm_bin).expanduser().resolve()
        if not llvm_root.is_dir():
            raise PgsoError(f"LLVM bin root does not exist: {llvm_root}")

        llvm_tools: dict[str, pathlib.Path] = {}
        for name in (
            "opt",
            "llc",
            "llvm-profdata",
            "llvm-ar",
            "llvm-nm",
            "clang",
        ):
            candidate = llvm_root / name
            if not candidate.is_file() or not os.access(candidate, os.X_OK):
                raise PgsoError(f"missing executable: {name}")
            resolved = candidate.resolve()
            if resolved.parent != llvm_root:
                raise PgsoError(
                    f"LLVM tool escapes configured root: {name}: {resolved}"
                )
            llvm_tools[name] = resolved

        versions = {
            name: _llvm_version(path, name)
            for name, path in llvm_tools.items()
        }
        llvm_version = versions["opt"]

        libllvm = (llvm_root.parent / "lib" / host.LIBLLVM_NAME).resolve()
        if not libllvm.is_file() or libllvm.stat().st_size == 0:
            raise PgsoError(f"missing LLVM C library: {libllvm}")
        if not IR_SIZE_SCRIPT.is_file():
            raise PgsoError(f"missing IR size passes: {IR_SIZE_SCRIPT}")

        tools, profile_runtime = host.discover_tools(zig_path, llvm_tools["clang"])

        return cls(
            zig=zig_path,
            llvm_bin=llvm_root,
            opt=llvm_tools["opt"],
            llc=llvm_tools["llc"],
            llvm_profdata=llvm_tools["llvm-profdata"],
            llvm_ar=llvm_tools["llvm-ar"],
            llvm_nm=llvm_tools["llvm-nm"],
            clang=llvm_tools["clang"],
            libllvm=libllvm,
            ir_size=IR_SIZE_SCRIPT,
            platform=host,
            tools=tools,
            profile_runtime=profile_runtime.resolve(),
            zig_version=zig_version,
            llvm_version=llvm_version,
            target=target,
            host_arch=host_arch,
        )
