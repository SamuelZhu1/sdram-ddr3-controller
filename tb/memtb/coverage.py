"""Functional coverage model.

The bins here are the coverage half of docs/verification_plan.md. Request-side
bins are sampled in Python by the request monitor. Pin-level and controller
bins are sampled in SystemVerilog (bus model and mem_ctrl_cov) and read out at
the end of a test, because sampling every clock from Python is slow.
"""
import json

CMDS = ["NOP", "MRS", "REF", "PRE", "PREA", "ACT", "WR", "RD", "ZQCL"]
C = {name: i for i, name in enumerate(CMDS)}

# Legal command pairs (previous non-NOP command -> next), with NOP as the
# start of time. Every other pair is impossible by construction; the reason
# for each exclusion is in the verification plan.
RUN_PAIRS = [
    ("ACT", "RD"), ("ACT", "WR"), ("ACT", "PREA"),
    ("RD", "RD"), ("RD", "WR"), ("RD", "PRE"), ("RD", "ACT"), ("RD", "PREA"),
    ("WR", "RD"), ("WR", "WR"), ("WR", "PRE"), ("WR", "ACT"), ("WR", "PREA"),
    ("PRE", "ACT"), ("PRE", "PREA"), ("PRE", "REF"),
    ("PREA", "ACT"), ("PREA", "REF"),
    ("REF", "ACT"), ("REF", "REF"),
]
INIT_PAIRS = {
    "SDR": [("NOP", "PREA"), ("REF", "MRS"), ("MRS", "ACT"), ("MRS", "REF")],
    "DDR3": [("NOP", "MRS"), ("MRS", "MRS"), ("MRS", "ZQCL"), ("ZQCL", "ACT"), ("ZQCL", "REF")],
}

# Timing rules that must be seen at exactly their minimum spacing
# (index = rule id in the bus model).
#
# Excluded on purpose, with the reasoning in docs/verification_plan.md:
#   tRRD            the controller serves one request at a time, so a read or
#                   write (after tRCD >= tRRD) always sits between two
#                   activates; tRRD can never be the limiting rule
#   SDR tMRD and    the first command after initialization needs a request to
#   DDR3 tZQinit    be accepted first, which takes longer than the rule
# These rules are still checked on every command; only the "seen at minimum"
# bin is excluded.
MIN_RULES = {
    "SDR": {4: "tRCD", 5: "tRAS", 6: "tRC", 7: "tRP",
            9: "tWR", 10: "tRFC", 14: "read_to_write"},
    "DDR3": {2: "tXPR", 5: "tMRD", 6: "tMOD", 8: "tRCD", 9: "tRAS",
             10: "tRC", 11: "tRP", 13: "tWR", 14: "tRFC", 18: "tCCD",
             19: "write_to_read", 20: "tRTP", 21: "read_to_write"},
}

CTRL_BINS = [
    "tick_idle_closed", "tick_idle_open", "tick_req_hit", "tick_req_miss",
    "tick_req_closed", "tick_recovery", "access_hit", "access_miss_open",
    "access_miss_closed", "req_back_to_back", "req_held_by_refresh",
    "refresh_debt_1", "refresh_debt_2", "refresh_debt_3", "refresh_debt_4",
    "refresh_needs_prea", "refresh_no_prea", "row_first", "row_last",
    "col_first", "col_last", "bank_first", "bank_last", "refresh_postponed",
    "all_banks_open",
]

OPS = ["R", "W"]
RELS = ["same_row", "same_bank_other_row", "other_bank"]
GAPS = ["gap_0", "gap_1_3", "gap_4_15", "gap_16_plus"]


def gap_bin(gap: int) -> str:
    if gap == 0:
        return "gap_0"
    if gap <= 3:
        return "gap_1_3"
    if gap <= 15:
        return "gap_4_15"
    return "gap_16_plus"


class Coverage:
    def __init__(self, mem_type: str, n_banks: int):
        self.mem_type = mem_type
        self.bins = {}
        add = self._declare
        for cmd in ("ACT", "RD", "WR", "PRE"):
            for b in range(n_banks):
                add(f"cmd.{cmd}.bank{b}")
        for cmd in ("REF", "PREA"):
            add(f"cmd.{cmd}")
        if mem_type == "DDR3":
            for mr in range(4):
                add(f"cmd.MRS.mr{mr}")
            add("cmd.ZQCL")
        else:
            add("cmd.MRS")
        for a, b in RUN_PAIRS + INIT_PAIRS[mem_type]:
            add(f"pair.{a}->{b}")
        for name in MIN_RULES[mem_type].values():
            add(f"min_spacing.{name}")
        for name in CTRL_BINS:
            add(f"ctrl.{name}")
        for p in OPS:
            for n in OPS:
                for rel in RELS:
                    add(f"seq.{p}{n}.{rel}")
        for g in GAPS:
            add(f"req.{g}")

    def _declare(self, name):
        self.bins[name] = 0

    def hit(self, name):
        if name in self.bins:
            self.bins[name] += 1

    # ---- request-side sampling ----
    def sample_request(self, prev, cur, gap):
        """prev/cur are (we, row, bank) tuples; gap is idle clocks before cur."""
        self.hit(f"req.{gap_bin(gap)}")
        if prev is None:
            return
        if prev[2] != cur[2]:
            rel = "other_bank"
        elif prev[1] != cur[1]:
            rel = "same_bank_other_row"
        else:
            rel = "same_row"
        self.hit(f"seq.{OPS[prev[0]]}{OPS[cur[0]]}.{rel}")

    # ---- bins sampled in SystemVerilog ----
    def collect_from_dut(self, dut, n_banks):
        ddr3 = self.mem_type == "DDR3"
        vec = int((dut.cov_cmd_bank_ddr3 if ddr3 else dut.cov_cmd_bank_sdr).value)
        for cmd in CMDS:
            for b in range(n_banks):
                if not (vec >> (C[cmd] * n_banks + b)) & 1:
                    continue
                if cmd in ("ACT", "RD", "WR", "PRE"):
                    self.hit(f"cmd.{cmd}.bank{b}")
                elif cmd == "MRS" and ddr3:
                    self.hit(f"cmd.MRS.mr{b}")
                else:
                    self.hit(f"cmd.{cmd}")
        pair = int(dut.cov_pair.value)
        for a in CMDS:
            for b in CMDS:
                if (pair >> (C[a] * 9 + C[b])) & 1:
                    name = f"pair.{a}->{b}"
                    if name in self.bins:
                        self.hit(name)
                    elif not self._init_only(a, b):
                        raise AssertionError(f"command pair {a}->{b} was observed but is "
                                             "listed as impossible in the coverage model")
        mins = int(dut.cov_min.value)
        for rule, name in MIN_RULES[self.mem_type].items():
            if (mins >> rule) & 1:
                self.hit(f"min_spacing.{name}")
        ctrl = int(dut.cov_ctrl.value)
        for i, name in enumerate(CTRL_BINS):
            if (ctrl >> i) & 1:
                self.hit(f"ctrl.{name}")

    @staticmethod
    def _init_only(a, b):
        # pairs that only occur inside the fixed initialization sequence
        return (a, b) in {("PREA", "REF"), ("REF", "REF"), ("REF", "MRS")} or "MRS" in (a, b)

    def percent(self):
        return 100.0 * sum(1 for v in self.bins.values() if v) / len(self.bins)

    def holes(self):
        return [k for k, v in self.bins.items() if not v]

    def save(self, path):
        with open(path, "w") as f:
            json.dump({"mem_type": self.mem_type, "bins": self.bins}, f, indent=1)
