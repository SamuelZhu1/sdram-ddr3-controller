#!/usr/bin/env python3
"""Make Yosys-readable copies of the RTL for the formal flow.

The open-source Yosys front end does not support `import pkg::*`, so each
module gets the shared definitions included in its body instead, and enum
typed ports become plain vectors. Nothing else changes.
"""
import re
import sys
from pathlib import Path

rtl = Path(__file__).resolve().parent.parent / "rtl"
out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)

for name in ["mem_ctrl_props.sv", "mem_ctrl_core.sv"]:
    s = (rtl / name).read_text()
    s = re.sub(r"\n\s*import mem_pkg::\*;\n", "\n", s)
    s = re.sub(r"(input|output)(\s+)cmd_e(\s+)", r"\1\2logic [3:0]\3", s)
    # first ");" at the start of a line ends the port list
    s = s.replace("\n);\n", '\n);\n`include "mem_defs.svh"\n', 1)
    (out / name).write_text(s)

f = (Path(__file__).resolve().parent / "mem_ctrl_formal.sv").read_text()
f = f.replace("  import mem_pkg::*;\n", '`include "mem_defs.svh"\n')
(out / "mem_ctrl_formal.sv").write_text(f)
for h in ["mem_defs.svh", "mem_timing.svh"]:
    (out / h).write_text((rtl / h).read_text())
