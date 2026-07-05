"""Command line entry point: SystemVerilog -> netlist JSON."""

import argparse
import json
import sys
from pathlib import Path

from .netlist import extract_design

RTL_SUFFIXES = (".sv", ".v")


def collect_files(paths):
    """Expand directories into contained RTL files, recursively."""
    files = []
    for p in paths:
        path = Path(p)
        if path.is_dir():
            files.extend(
                str(f) for f in sorted(path.rglob("*")) if f.suffix in RTL_SUFFIXES
            )
        else:
            files.append(p)
    return files


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="diagramgen",
        description="Generate a Yosys-JSON-compatible netlist from SystemVerilog",
    )
    parser.add_argument("files", nargs="+",
                        help="SystemVerilog source files or directories")
    parser.add_argument("--top", help="top module name (default: auto-detect)")
    parser.add_argument("-o", "--output", help="output JSON path (default: stdout)")
    args = parser.parse_args(argv)

    files = collect_files(args.files)
    if not files:
        print("error: no RTL files found", file=sys.stderr)
        return 1

    try:
        design = extract_design(files, top=args.top)
    except RuntimeError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    text = json.dumps(design, indent=2)
    if args.output:
        with open(args.output, "w") as f:
            f.write(text + "\n")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
