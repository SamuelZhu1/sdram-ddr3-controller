#!/usr/bin/env python3
"""Build and run one simulation.

  scripts/run_sim.py --mem SDR --test RandomTest --seed 3
  scripts/run_sim.py --mem DDR3 --test SmokeTest --waves
  scripts/run_sim.py --mem SDR --test RowThrashTest --define BUG_NO_TRAS

Each distinct build (memory type, clock, parameters, defines) gets its own
directory under sim_build/ and is only compiled once.
"""
import argparse
import os
import sys
from pathlib import Path

from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parent.parent

SOURCES = [
    "rtl/mem_pkg.sv", "rtl/mem_ctrl_core.sv", "rtl/sdr_backend.sv", "rtl/dfi_backend.sv",
    "rtl/mem_ctrl.sv", "rtl/mem_ctrl_props.sv",
    "tb/models/sdr_sdram_model.sv", "tb/models/ddr3_dfi_model.sv",
    "tb/mem_ctrl_cov.sv", "tb/tb_top.sv",
]

# Named build configurations. "storm" shortens the refresh interval so that
# refresh collides with every other activity.
CONFIGS = {
    "SDR":  {"default": dict(clk=20_000, cl=2),
             "100mhz":  dict(clk=10_000, cl=2),
             "143mhz":  dict(clk=7_000,  cl=3),
             "storm":   dict(clk=20_000, cl=2, refi=24, force=4),
             "storm143": dict(clk=7_000, cl=3, refi=60, force=4),
             "fullinit": dict(clk=20_000, cl=2, pwr=0)},
    "DDR3": {"default": dict(clk=2_500),
             "storm":   dict(clk=2_500, refi=110, force=4),
             "fullinit": dict(clk=2_500, pwr=0)},
}


def run(mem, test, seed=1, n_txn=2000, config="default", defines=(), waves=False,
        cov_file="", coverage=False, quiet=False):
    c = CONFIGS[mem][config]
    params = {
        "MEM_TYPE": 1 if mem == "DDR3" else 0,
        "CLK_PERIOD_PS": c["clk"],
        "CL": c.get("cl", 2),
        "T_PWR_CK": c.get("pwr", 200),
        "T_REFI_CK": c.get("refi", 0),
        "REF_FORCE": c.get("force", 4),
    }
    tag = f"{mem}_{config}" + "".join(f"_{d}" for d in defines) + ("_cov" if coverage else "")
    build_dir = ROOT / "sim_build" / tag
    runner = get_runner("verilator")
    build_args = ["--assert", "-Wno-fatal", "-Wno-WIDTHEXPAND", "-Wno-WIDTHTRUNC",
                  "--timescale", "1ps/1ps", "-O3", f"-I{ROOT / 'rtl'}"]
    build_args += [f"-D{d}" for d in defines]
    if coverage:
        build_args += ["--coverage-line", "--coverage-toggle"]
    runner.build(
        sources=[ROOT / s for s in SOURCES],
        hdl_toplevel="tb_top",
        parameters=params,
        build_args=build_args,
        build_dir=build_dir,
        waves=waves,
        always=False,
    )
    env = {
        "MEM_TYPE": mem, "CLK_PERIOD_PS": str(c["clk"]), "SEED": str(seed),
        "N_TXN": str(n_txn), "COV_FILE": cov_file,
    }
    results = runner.test(
        hdl_toplevel="tb_top",
        test_module="test_mem",
        test_filter=rf"\.{test}$" if test else None,
        test_dir=ROOT / "tb" / "tests",
        build_dir=build_dir,
        extra_env=env,
        seed=seed,
        waves=waves,
        results_xml=str(build_dir / f"results_{test}_{seed}.xml"),
        log_file=str(build_dir / f"{test}_{seed}.log") if quiet else None,
    )
    return results


def passed(results_xml):
    import xml.etree.ElementTree as ET
    root = ET.parse(results_xml).getroot()
    cases = list(root.iter("testcase"))
    bad = [c for c in cases if c.find("failure") is not None or c.find("error") is not None]
    return bool(cases) and not bad


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--mem", default="SDR", choices=["SDR", "DDR3"])
    ap.add_argument("--config", default="default")
    ap.add_argument("--test", default="SmokeTest")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--n", type=int, default=2000, help="transactions")
    ap.add_argument("--define", action="append", default=[])
    ap.add_argument("--waves", action="store_true")
    ap.add_argument("--cov-file", default="")
    a = ap.parse_args()
    xml = run(a.mem, a.test, a.seed, a.n, a.config, a.define, a.waves, a.cov_file)
    sys.exit(0 if passed(xml) else 1)
