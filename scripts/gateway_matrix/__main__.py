"""Command line entry point: ``python3 -m scripts.gateway_matrix --fx zig-out/bin/fx --model ...``."""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

from .runner import DEFAULT_PROMPTS, format_table, run_matrix, summarize


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="python3 -m scripts.gateway_matrix",
        description=(
            "Run a live multi-turn fx conversation against each Gateway model through a "
            "loopback logging proxy, then print a per-turn table of request shape, upstream "
            "status, route and error. Every turn costs real Gateway requests."
        ),
    )
    parser.add_argument("--fx", required=True, type=pathlib.Path, help="path to a built fx binary")
    parser.add_argument(
        "--model",
        action="append",
        dest="models",
        required=True,
        help="Gateway model id; repeat for several models",
    )
    parser.add_argument("--label", default="run", help="label recorded on every row, e.g. main or fixed")
    parser.add_argument(
        "--out",
        type=pathlib.Path,
        default=pathlib.Path("zig-out/gateway-matrix"),
        help="output directory for captures and summaries (default: zig-out/gateway-matrix)",
    )
    parser.add_argument(
        "--workspace",
        type=pathlib.Path,
        default=None,
        help="workspace fx runs in (default: <out>/workspace, created with a note.txt)",
    )
    parser.add_argument(
        "--prompt",
        action="append",
        dest="prompts",
        help="override the turn prompts; repeat once per turn",
    )
    parser.add_argument("--timeout", type=float, default=180.0, help="seconds per fx invocation")
    parser.add_argument("--trace", action="store_true", help="also write FX_TRACE_LOG per turn")
    parser.add_argument("--upstream", default=None, help="Gateway host to forward to (default: production)")
    parser.add_argument("--json", action="store_true", help="print the summary rows as JSON instead of a table")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    fx_binary = args.fx.resolve()
    if not fx_binary.is_file():
        print(f"fx binary not found: {fx_binary}", file=sys.stderr)
        return 2
    out_dir = args.out.resolve()
    workspace = (args.workspace or out_dir / "workspace").resolve()
    prompts = tuple(args.prompts) if args.prompts else DEFAULT_PROMPTS
    result = run_matrix(
        fx_binary=fx_binary,
        models=args.models,
        label=args.label,
        out_dir=out_dir,
        workspace=workspace,
        prompts=prompts,
        timeout_seconds=args.timeout,
        trace=args.trace,
        upstream=args.upstream,
    )
    rows = summarize(result)
    (out_dir / f"summary-{args.label}.json").write_text(json.dumps(rows, indent=2), encoding="utf-8")
    if args.json:
        print(json.dumps(rows, indent=2))
    else:
        print(format_table(rows))
    print(f"\ncaptures: {out_dir / 'captures'}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
