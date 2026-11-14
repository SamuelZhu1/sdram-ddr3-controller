#!/usr/bin/env python3
"""Bug-injection campaign: does the testbench catch a broken controller?

Each entry is a deliberate RTL bug behind an `ifdef. The controller is rebuilt
with one bug at a time and tests are run until one fails. A bug that no test
catches is a hole in the verification plan (or a bug that cannot change
behaviour, which then needs a proof; see docs/bug_injection.md).

  scripts/bug_campaign.py            all bugs
  scripts/bug_campaign.py BUG_NO_TWR one bug
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run_sim  # noqa: E402

ROOT = run_sim.ROOT
import os
ONLY_MEM = os.environ.get("ONLY_MEM", "SDR,DDR3").split(",")

# define -> (what is broken, memory types it applies to)
BUGS = {
    "BUG_ROUND_DOWN":      ("nanoseconds converted to clock cycles by rounding down", ["SDR", "DDR3"]),
    "BUG_TRCD_OFF1":       ("activate-to-read/write counter one cycle short", ["SDR", "DDR3"]),
    "BUG_NO_TRAS":         ("minimum row-open time (tRAS) not enforced", ["SDR", "DDR3"]),
    "BUG_NO_TWR":          ("write recovery before precharge (tWR) not enforced", ["SDR", "DDR3"]),
    "BUG_NO_TRP":          ("precharge time before activate (tRP) not enforced", ["SDR", "DDR3"]),
    "BUG_NO_TRFC":         ("refresh recovery time (tRFC) not enforced", ["SDR", "DDR3"]),
    "BUG_NO_TRRD":         ("activate-to-activate spacing across banks (tRRD) not enforced", ["SDR", "DDR3"]),
    "BUG_RD2WR":           ("read-to-write bus turnaround not enforced", ["SDR", "DDR3"]),
    "BUG_NO_WR2RD":        ("write-to-read spacing (tWTR) not enforced", ["DDR3"]),
    "BUG_PRE_WRONG_BANK":  ("precharge sent to bank 0 instead of the requested bank", ["SDR", "DDR3"]),
    "BUG_HIT_IGNORES_ROW": ("open-row hit ignores the row address", ["SDR", "DDR3"]),
    "BUG_REF_NO_PREA":     ("refresh issued without closing open rows", ["SDR", "DDR3"]),
    "BUG_REF_DEBT_DROP":   ("one refresh clears every postponed refresh", ["SDR", "DDR3"]),
    "BUG_REFI_SLOW":       ("refresh interval twice too long", ["SDR", "DDR3"]),
    "BUG_INIT_NO_PREA":    ("initialization skips precharge-all", ["SDR"]),
    "BUG_MRS_CL":          ("wrong CAS latency written to the mode register", ["SDR", "DDR3"]),
    "BUG_READY_DROP":      ("a new request accepted while one is still waiting", ["SDR", "DDR3"]),
    "BUG_RD_LAT":          ("read data captured one cycle late", ["SDR"]),
    "BUG_WBEAT_ORDER":     ("write data beats sent in reverse order", ["DDR3"]),
}

# Bugs that cannot change behaviour. Each needs a proof, not an opinion:
# formal/prove.sh F_143MHZ BUG_NO_TRRD proves the tRRD property with the tRRD
# counter removed (see docs/bug_log.md, entry 6).
PROVEN_HARMLESS = {"BUG_NO_TRRD"}

ATTEMPTS = {
    "SDR":  [("default", "RandomTest"), ("143mhz", "RandomTest"), ("143mhz", "RowThrashTest"),
             ("storm", "RandomTest"), ("143mhz", "TurnaroundTest"), ("default", "IdleTest"),
             ("storm143", "RowThrashTest"), ("100mhz", "RandomTest")],
    "DDR3": [("default", "RandomTest"), ("default", "RowThrashTest"), ("storm", "RandomTest"),
             ("default", "TurnaroundTest"), ("default", "IdleTest"), ("storm", "RowThrashTest")],
}


def first_detection(log: str) -> str:
    """Name the checker that fired first."""
    for line in log.splitlines():
        m = re.search(r"(SDR|DDR3) VIOLATION ([^:]+):", line)
        if m:
            return f"bus model: {m.group(2)}"
        m = re.search(r"PROPERTY FAILED: (\w+)", line)
        if m:
            return f"property {m.group(1)}"
        if "read mismatch" in line or "no read outstanding" in line:
            return "scoreboard: read data mismatch"
        if "never answered" in line:
            return "scoreboard: read never answered"
        if "no request accepted" in line:
            return "watchdog: controller stopped accepting requests"
    return "test failed"


def main():
    only = sys.argv[1:]
    rows = []
    for bug, (what, mems) in BUGS.items():
        mems = [m for m in mems if m in ONLY_MEM]
        if only and bug not in only:
            continue
        for mem in mems:
            caught = None
            for config, test in ATTEMPTS[mem]:
                xml = run_sim.run(mem, test, 1, 3000, config, defines=[bug], quiet=True)
                if not run_sim.passed(xml):
                    log = (ROOT / "sim_build" / f"{mem}_{config}_{bug}" / f"{test}_1.log").read_text()
                    caught = (config, test, first_detection(log))
                    break
            rows.append((bug, what, mem, caught))
            print(f"{'CAUGHT ' if caught else 'MISSED '} {bug:20} {mem:4} "
                  f"{(caught[0] + ' ' + caught[1] + ' -> ' + caught[2]) if caught else ''}", flush=True)

    n_caught = sum(1 for r in rows if r[3])
    bugs = {r[0] for r in rows}
    caught_bugs = {r[0] for r in rows if r[3]}
    escaped = sorted(bugs - caught_bugs - PROVEN_HARMLESS)
    lines = ["# Bug-injection results", "",
             "Generated by `scripts/bug_campaign.py`. Each row is the controller rebuilt with one",
             "deliberate bug; the last columns show the first test that failed and the checker",
             "that fired first.", "",
             f"**{len(caught_bugs)} of {len(bugs)} distinct bugs caught "
             f"({n_caught} of {len(rows)} runs across the two memory types).** "
             f"The remaining {len(bugs - caught_bugs)} cannot change behaviour and "
             "is covered by a formal proof instead (see `bug_log.md`, entry 6).", "",
             "| Bug | Memory | Caught by test | First checker to fire |", "|---|---|---|---|"]
    for bug, what, mem, caught in rows:
        if caught:
            lines.append(f"| {what} (`{bug}`) | {mem} | {caught[0]} / {caught[1]} | {caught[2]} |")
        else:
            note = ("no test can fail: proven harmless by `formal/prove.sh F_143MHZ BUG_NO_TRRD`"
                    if bug in PROVEN_HARMLESS else "**ESCAPED**")
            lines.append(f"| {what} (`{bug}`) | {mem} | not caught | {note} |")
    if not only:
        (ROOT / "docs" / "bug_injection_results.md").write_text("\n".join(lines) + "\n")
    print(f"\n{n_caught}/{len(rows)} runs caught; escaped without a proof: {escaped or 'none'}")
    sys.exit(1 if escaped else 0)


if __name__ == "__main__":
    main()
