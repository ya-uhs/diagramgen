"""Local web UI: serves the editor page and a compile endpoint.

Standard library only — no server-side dependencies beyond pyslang.
"""

import argparse
import json
import shutil
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from .netlist import extract_design_from_sources

ROOT = Path(__file__).resolve().parents[2]
WEB_DIR = ROOT / "web"


def _stage_assets() -> None:
    """Copy browser assets that live outside web/ into place."""
    vendor = WEB_DIR / "vendor"
    vendor.mkdir(parents=True, exist_ok=True)
    nsvg = ROOT / "node_modules" / "netlistsvg"
    shutil.copy(nsvg / "built" / "netlistsvg.bundle.js", vendor)
    shutil.copy(nsvg / "lib" / "default.svg", vendor)
    shutil.copy(ROOT / "node_modules" / "elkjs" / "lib" / "elk.bundled.js", vendor)
    # yosys-wasm frontend (used when no slang server is reachable, e.g. static
    # hosting). The gen/ dir holds the wasm binaries after a first Node run.
    yowasp = ROOT / "node_modules" / "@yowasp" / "yosys" / "gen"
    if yowasp.exists():
        shutil.copytree(yowasp, vendor / "yowasp", dirs_exist_ok=True)
    sample = ROOT / "rtl" / "soc.sv"
    if sample.exists():
        shutil.copy(sample, WEB_DIR / "sample.sv")


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(WEB_DIR), **kwargs)

    def do_POST(self):
        if self.path != "/api/netlist":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", 0))
        try:
            req = json.loads(self.rfile.read(length))
            if "files" in req:
                sources = [(f["name"], f["content"]) for f in req["files"]]
            else:
                sources = [(req.get("name", "input.sv"), req.get("source", ""))]
            design = extract_design_from_sources(sources, top=req.get("top"))
            payload = {"ok": True, "netlist": design}
        except RuntimeError as e:
            payload = {"ok": False, "error": str(e)}
        except (json.JSONDecodeError, KeyError) as e:
            payload = {"ok": False, "error": f"bad request: {e}"}
        data = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):
        pass  # keep the terminal quiet


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="diagramgen-server")
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args(argv)

    _stage_assets()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"diagramgen web UI: http://127.0.0.1:{args.port}/")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
