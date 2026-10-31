"""The PGSO targets and the platform that builds each one.

A platform, either a module such as `macos` or a `linux.Platform`, provides,
for its target:

- `TARGET`, `DISPLAY_NAME`, `HOST_ARCH`, the only host architecture it
  builds on, and `LIBLLVM_NAME`, the LLVM C library `ir_size.py` loads;
- `SIZE_CEILING_MIB`, the largest candidate it accepts;
- `check_host()`, which returns the host architecture after checking the host
  can build and run the target natively;
- `discover_tools(zig, clang)`, which returns the platform's native tools and
  the LLVM profile runtime, and `os_versions(paths)`, the host OS evidence;
- `CONTROL_BUILD_FLAGS` and `record_control_build(toolchain, result, paths)`,
  which add to the control build and keep what the later links reuse;
- `STARTUP_SCENARIOS`, the corpus scenarios whose cold functions profile use
  must not compile for size, or `()` for none;
- `ZIG_CC_LINK_FLAGS`, the dead-code removal flags for `zig cc` links, and
  `external_control_strip_argv(toolchain, binary)`, the command that strips
  such a link afterward, or `()` when the link already strips it;
- `read_control_identity(toolchain, binary, log)` and
  `control_identity_from_evidence(control)`: the control's properties the
  candidate must match, as the evidence fields the control records;
- `link_instrumented(toolchain, paths, control)`, which links and checks the
  instrumented executable;
- `public_api_flags(toolchain, paths)`, the symbols the outlined-IR cleanup
  keeps external;
- `candidate_object_flags(paths)`, extra code-generation flags for the
  candidate object, and `link_candidate_binary(toolchain, paths)`, which links
  that object into the final executable;
- `inspect_candidate(toolchain, paths, control)`, which checks the candidate's
  layout against the control and returns its metadata, and
  `candidate_evidence(metadata)`, the evidence fields for that metadata.
"""
from __future__ import annotations

from types import ModuleType

from scripts.pgso import linux, macos
from scripts.pgso.model import PgsoError

_PLATFORMS: dict[str, ModuleType | linux.Platform] = {
    module.TARGET: module for module in (macos, linux.ARM64, linux.X86_64)
}


def for_target(target: str) -> ModuleType | linux.Platform:
    try:
        return _PLATFORMS[target]
    except KeyError:
        raise PgsoError(f"unsupported target: {target}") from None
