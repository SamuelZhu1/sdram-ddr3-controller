"""UVM tests for the memory controller. Run through scripts/run_sim.py."""
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import cocotb
import pyuvm
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, First, RisingEdge
from pyuvm import ConfigDB, uvm_test

from memtb import config
from memtb.env import MemEnv
from memtb.sequences import FillThenCheckSeq, RandomSeq, SmokeSeq


class BaseTest(uvm_test):
    """Reset, wait for initialization, run the sequences, then check the
    scoreboard, the bus model, the properties and collect coverage."""

    drain_cycles = 600

    def build_phase(self):
        self.cfg = config.load()
        self.rng = random.Random(self.cfg.seed)
        ConfigDB().set(self, "*", "cfg", self.cfg)
        self.env = MemEnv("env", self)

    async def reset(self):
        dut = cocotb.top
        dut.rst_n.value = 0
        dut.req_valid.value = 0
        await ClockCycles(dut.clk, 5)
        await FallingEdge(dut.clk)
        dut.rst_n.value = 1

    async def wait_init(self):
        dut = cocotb.top
        while not int(dut.init_done.value):
            await RisingEdge(dut.clk)

    async def run_seq(self, seq):
        await seq.start(self.env.seqr)

    async def stimulus(self):
        raise NotImplementedError

    async def watchdog(self):
        """Stop early once any checker has fired, and never let a stuck
        controller hang the simulation."""
        dut = cocotb.top
        sb = self.env.scoreboard
        last, idle = -1, 0
        while True:
            await ClockCycles(dut.clk, 2000)
            if int(dut.violation_count.value) or int(dut.prop_fail_count.value) or sb.errors:
                self.logger.error("a checker fired, ending the test early")
                return
            done = sb.reads + sb.writes
            idle = idle + 1 if done == last else 0
            last = done
            if idle >= 200:
                self.logger.error("no request accepted for 400,000 clocks")
                self.hung = True
                return

    async def body(self):
        await self.wait_init()
        await self.stimulus()
        await ClockCycles(cocotb.top.clk, self.drain_cycles)

    async def run_phase(self):
        self.raise_objection()
        dut = cocotb.top
        self.hung = False
        cocotb.start_soon(Clock(dut.clk, self.cfg.clk_period_ps, unit="ps").start())
        await self.reset()
        body = cocotb.start_soon(self.body())
        dog = cocotb.start_soon(self.watchdog())
        await First(body, dog)
        self.drop_objection()

    def check_phase(self):
        dut = cocotb.top
        sb = self.env.scoreboard
        cov = self.env.cov
        cov.collect_from_dut(dut, self.cfg.n_banks)
        if self.cfg.cov_file:
            cov.save(self.cfg.cov_file)
        viol = int(dut.violation_count.value)
        props = int(dut.prop_fail_count.value)
        self.logger.info(f"writes={sb.writes} reads={sb.reads} compared={sb.compared} "
                         f"mismatches={sb.errors} bus_violations={viol} "
                         f"property_failures={props} coverage={cov.percent():.1f}%")
        assert not self.hung, "controller stopped accepting requests"
        assert sb.errors == 0, f"{sb.errors} scoreboard errors"
        assert not sb.expected, f"{len(sb.expected)} reads never answered"
        assert viol == 0, f"{viol} bus protocol violations"
        assert props == 0, f"{props} property failures"


@pyuvm.test()
class SmokeTest(BaseTest):
    async def stimulus(self):
        await self.run_seq(SmokeSeq("smoke", self.cfg, self.rng, 0))


@pyuvm.test()
class RandomTest(BaseTest):
    """General mix: mostly open-row hits with row and bank changes."""

    async def stimulus(self):
        await self.run_seq(RandomSeq("rand", self.cfg, self.rng, self.cfg.n_txn))


@pyuvm.test()
class RowThrashTest(BaseTest):
    """Every request changes row inside one or two banks: precharge and
    activate back to back, which leans on tRAS, tRP, tRC and tWR."""

    async def stimulus(self):
        banks = self.rng.sample(range(self.cfg.n_banks), 2)
        await self.run_seq(RandomSeq("thrash", self.cfg, self.rng, self.cfg.n_txn,
                                     p_same_row=0.05, p_same_bank=0.85, rows=4, cols=3,
                                     gap_weights=(90, 10, 0, 0), banks=banks))


@pyuvm.test()
class BankPingPongTest(BaseTest):
    """Every request changes bank: activates on different banks back to back
    (tRRD) with all banks open at once."""

    async def stimulus(self):
        await self.run_seq(RandomSeq("pingpong", self.cfg, self.rng, self.cfg.n_txn,
                                     p_same_row=0.0, p_same_bank=0.0, rows=3, cols=3,
                                     gap_weights=(95, 5, 0, 0)))


@pyuvm.test()
class TurnaroundTest(BaseTest):
    """Stay in open rows with no idle time: read/write and write/read
    turnarounds at minimum spacing."""

    async def stimulus(self):
        await self.run_seq(RandomSeq("turn", self.cfg, self.rng, self.cfg.n_txn,
                                     p_same_row=0.9, p_same_bank=0.02, rows=3, cols=4,
                                     gap_weights=(100, 0, 0, 0)))


@pyuvm.test()
class IdleTest(BaseTest):
    """Sparse traffic with long gaps: refresh while idle, with rows open and
    closed."""

    async def stimulus(self):
        await self.run_seq(RandomSeq("idle", self.cfg, self.rng, max(self.cfg.n_txn // 8, 50),
                                     gap_weights=(10, 10, 20, 60)))


@pyuvm.test()
class FillTest(BaseTest):
    """Sequential block write then read-back across row and bank boundaries."""

    async def stimulus(self):
        await self.run_seq(FillThenCheckSeq("fill", self.cfg, self.rng, self.cfg.n_txn))


@pyuvm.test()
class ResetTest(BaseTest):
    """Reset at random points in the middle of traffic. A request that was
    being driven when reset hit must simply wait for initialization and then
    be served; nothing may be answered twice or lost."""

    async def resets(self, n):
        dut = cocotb.top
        for _ in range(n):
            await ClockCycles(dut.clk, self.rng.randint(300, 900))
            await FallingEdge(dut.clk)
            dut.rst_n.value = 0
            self.env.scoreboard.forget()
            await ClockCycles(dut.clk, self.rng.randint(24, 40))
            self.env.scoreboard.forget()
            await FallingEdge(dut.clk)
            dut.rst_n.value = 1

    async def stimulus(self):
        resets = cocotb.start_soon(self.resets(6))
        await self.run_seq(RandomSeq("rand", self.cfg, self.rng, self.cfg.n_txn,
                                     gap_weights=(85, 10, 5, 0)))
        await resets
        await self.wait_init()
        await self.run_seq(RandomSeq("post", self.cfg, self.rng, 200))
