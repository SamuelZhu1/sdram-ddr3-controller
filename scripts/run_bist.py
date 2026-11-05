#!/usr/bin/env python3
"""Simulate the on-board self test against the SDRAM model."""
import sys
from pathlib import Path

from cocotb_tools.runner import get_runner

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run_sim  # noqa: E402

ROOT = run_sim.ROOT
SOURCES = ["rtl/mem_pkg.sv", "rtl/mem_ctrl_core.sv", "rtl/sdr_backend.sv", "rtl/dfi_backend.sv",
           "rtl/mem_ctrl.sv", "rtl/mem_bist.sv", "tb/models/sdr_sdram_model.sv", "tb/tb_bist_top.sv"]

if __name__ == "__main__":
    build_dir = ROOT / "sim_build" / "bist"
    runner = get_runner("verilator")
    runner.build(sources=[ROOT / s for s in SOURCES], hdl_toplevel="tb_bist_top",
                 build_args=["-Wno-fatal", "-Wno-WIDTHEXPAND", "-Wno-WIDTHTRUNC",
                             "--timescale", "1ps/1ps", "-O3", f"-I{ROOT / 'rtl'}"],
                 build_dir=build_dir, always=False)
    xml = runner.test(hdl_toplevel="tb_bist_top", test_module="test_bist",
                      test_dir=ROOT / "tb" / "tests", build_dir=build_dir,
                      results_xml=str(build_dir / "results.xml"))
    sys.exit(0 if run_sim.passed(xml) else 1)
