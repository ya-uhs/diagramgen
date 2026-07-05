"""diagramgen: generate block diagrams from Verilog/SystemVerilog.

Pipeline: slang (pyslang) elaboration -> Yosys-JSON-compatible netlist
-> layout/rendering (netlistsvg/ELK for now).
"""

__version__ = "0.1.0"
