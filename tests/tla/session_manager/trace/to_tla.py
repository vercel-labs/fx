#!/usr/bin/env python3
"""Convert an implementation trace (JSON lines) into the TLA+ module TraceData.

usage: to_tla.py trace.ndjson TraceData.tla

Each JSON line becomes one record in `Trace == << ... >>`. Values map as:
  true/false -> TRUE/FALSE, integers -> integers, strings -> strings,
  lists -> sequences, objects -> records, {"$set": [...]} -> a set.
Floats and null are rejected: the specs have no use for them.
"""
import json
import sys


def value(v):
    if isinstance(v, bool):
        return "TRUE" if v else "FALSE"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, str):
        return json.dumps(v)
    if isinstance(v, list):
        return "<<" + ", ".join(value(x) for x in v) + ">>"
    if isinstance(v, dict):
        if set(v) == {"$set"}:
            return "{" + ", ".join(value(x) for x in v["$set"]) + "}"
        if not v:
            raise ValueError("empty objects have no TLA+ record form")
        return "[" + ", ".join(f"{k} |-> {value(x)}" for k, x in v.items()) + "]"
    raise ValueError(f"unsupported trace value: {v!r}")


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    records = []
    with open(sys.argv[1]) as trace:
        for number, line in enumerate(trace, start=1):
            if not line.strip():
                continue
            try:
                records.append(value(json.loads(line)))
            except (ValueError, json.JSONDecodeError) as err:
                print(f"trace line {number}: {err}", file=sys.stderr)
                return 2
    body = ",\n  ".join(records)
    with open(sys.argv[2], "w") as out:
        out.write("---- MODULE TraceData ----\n")
        # Integers gives negative literals (for example a seq of -1 for a
        # line the implementation could not parse).
        out.write("EXTENDS Integers\n")
        out.write(f"Trace == <<\n  {body}\n>>\n" if records else "Trace == <<>>\n")
        out.write("====\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
