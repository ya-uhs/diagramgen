"""Extract a Yosys-JSON-compatible netlist from an elaborated slang design.

The output targets block diagrams: each module instance becomes a cell,
each module-local signal becomes one net (buses are collapsed to a single
net token; bit-level accuracy is a non-goal at this stage). The JSON is
consumable by netlistsvg, d3-hwschematic and other Yosys-JSON tools.

Known limitations (MVP):
  - selects/concats on port connections resolve to the whole signal
  - interface ports, instance arrays and generate blocks are skipped
  - continuous assigns between nets are not modeled (no alias merging)
"""

from typing import Dict, List, Optional, Union

import pyslang
import pyslang.ast as A
from pyslang.syntax import SyntaxTree

BitToken = Union[int, str]  # net id, or "0"/"1"/"x" constant

_DIRECTION = {
    A.ArgumentDirection.In: "input",
    A.ArgumentDirection.Out: "output",
    A.ArgumentDirection.InOut: "inout",
}


class ModuleNets:
    """Per-module net numbering (one id per named signal)."""

    def __init__(self) -> None:
        self._ids: Dict[str, int] = {}
        self._next = 2  # ids 0/1 are reserved by Yosys convention

    def id_for(self, name: str) -> int:
        if name not in self._ids:
            self._ids[name] = self._next
            self._next += 1
        return self._ids[name]

    def fresh(self, hint: str) -> int:
        name = f"${hint}${self._next}"
        return self.id_for(name)

    @property
    def names(self) -> Dict[str, int]:
        return dict(self._ids)


def _resolve(expr, nets: ModuleNets) -> Optional[List[BitToken]]:
    """Map a port-connection expression to net tokens.

    Returns None for genuinely unconnected ports.
    """
    kind = expr.kind
    if kind == A.ExpressionKind.Assignment:
        return _resolve(expr.left, nets)
    if kind == A.ExpressionKind.Conversion:
        return _resolve(expr.operand, nets)
    if kind in (A.ExpressionKind.NamedValue, A.ExpressionKind.HierarchicalValue):
        return [nets.id_for(expr.symbol.name)]
    if kind in (A.ExpressionKind.ElementSelect, A.ExpressionKind.RangeSelect,
                A.ExpressionKind.MemberAccess):
        return _resolve(expr.value, nets)
    if kind == A.ExpressionKind.Concatenation:
        tokens: List[BitToken] = []
        for op in expr.operands:
            tokens.extend(_resolve(op, nets) or [])
        return tokens or None
    if kind == A.ExpressionKind.EmptyArgument:
        return None
    const = expr.constant
    if const is not None:
        value = const.value
        if isinstance(value, int):
            return ["1" if value else "0"]
        return ["x"]
    # Fallback: synthesize an anonymous net so the diagram stays connected.
    return [nets.fresh("expr")]


def _extract_module(inst_body) -> dict:
    nets = ModuleNets()
    ports = {}
    cells = {}

    for member in inst_body:
        if member.kind == A.SymbolKind.Port:
            if member.isNullPort or member.internalSymbol is None:
                continue
            ports[member.name] = {
                "direction": _DIRECTION.get(member.direction, "input"),
                "bits": [nets.id_for(member.internalSymbol.name)],
            }
        elif member.kind == A.SymbolKind.Instance:
            connections = {}
            directions = {}
            for pc in member.portConnections:
                if pc.port.kind != A.SymbolKind.Port:
                    continue  # interface port etc.
                directions[pc.port.name] = _DIRECTION.get(pc.port.direction, "input")
                tokens = _resolve(pc.expression, nets) if pc.expression else None
                if tokens is None:
                    tokens = [nets.fresh(f"unconn_{member.name}_{pc.port.name}")]
                connections[pc.port.name] = tokens
            cells[member.name] = {
                "type": member.definition.name,
                "port_directions": directions,
                "connections": connections,
            }

    netnames = {
        name: {"bits": [nid], "hide_name": 1 if name.startswith("$") else 0}
        for name, nid in nets.names.items()
    }
    return {"ports": ports, "cells": cells, "netnames": netnames}


def _render_diagnostics(diags, source_manager) -> str:
    engine = pyslang.DiagnosticEngine(source_manager)
    client = pyslang.TextDiagnosticClient()
    engine.addClient(client)
    for d in diags:
        engine.issue(d)
    return client.getString()


def extract_design(files: List[str], top: Optional[str] = None) -> dict:
    """Elaborate `files` with slang and return a Yosys-JSON-compatible dict."""
    sources = []
    for path in files:
        with open(path) as f:
            sources.append((path, f.read()))
    return extract_design_from_sources(sources, top)


def extract_design_from_sources(sources, top: Optional[str] = None) -> dict:
    """Like extract_design, but for in-memory buffers: iterable of (name, text)."""
    sm = pyslang.SourceManager()
    trees = [SyntaxTree.fromText(text, sm, name, name) for name, text in sources]
    return _extract_from_trees(trees, top, sm)


def extract_design_from_text(text: str, name: str = "input.sv",
                             top: Optional[str] = None) -> dict:
    """Like extract_design, but for a single in-memory source buffer."""
    return extract_design_from_sources([(name, text)], top)


def _extract_from_trees(trees, top: Optional[str], source_manager) -> dict:
    comp = A.Compilation()
    for tree in trees:
        comp.addSyntaxTree(tree)

    errors = [d for d in comp.getAllDiagnostics() if d.isError()]
    if errors:
        raise RuntimeError(_render_diagnostics(errors, source_manager))

    top_instances = list(comp.getRoot().topInstances)
    if not top_instances:
        raise RuntimeError("no top-level modules found")
    if top is not None:
        top_instances = [i for i in top_instances if i.name == top]
        if not top_instances:
            raise RuntimeError(f"top module '{top}' not found")

    modules: dict = {}

    def visit(inst, is_top: bool) -> None:
        name = inst.definition.name
        if name in modules:
            if is_top:
                modules[name].setdefault("attributes", {})["top"] = 1
            return
        modules[name] = _extract_module(inst.body)
        if is_top:
            modules[name]["attributes"] = {"top": 1}
        for member in inst.body:
            if member.kind == A.SymbolKind.Instance:
                visit(member, False)

    for inst in top_instances:
        visit(inst, True)

    return {"creator": "diagramgen", "modules": modules}
