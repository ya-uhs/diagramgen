"""Command line entry point: SystemVerilog -> netlist JSON."""

import argparse
import json
import sys

from .netlist import extract_design


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="diagramgen",
        description="Generate a Yosys-JSON-compatible netlist from SystemVerilog",
    )
    parser.add_argument("files", nargs="+", help="SystemVerilog source files")
    parser.add_argument("--top", help="top module name (default: auto-detect)")
    parser.add_argument("-o", "--output", help="output JSON path (default: stdout)")
    args = parser.parse_args(argv)

    try:
        design = extract_design(args.files, top=args.top)
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
