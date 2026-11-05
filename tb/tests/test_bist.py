"""Simulation of the on-board self test (run with scripts/run_bist.py)."""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge

N_WORDS = 6000


async def start(dut, inject, long_pause):
    cocotb.start_soon(Clock(dut.clk, 20_000, unit="ps").start())
    dut.rst_n.value = 0
    dut.inject_error.value = inject
    dut.long_pause.value = long_pause
    await ClockCycles(dut.clk, 5)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


async def run_until(dut, cond, limit=3_000_000):
    for _ in range(limit // 500):
        await ClockCycles(dut.clk, 500)
        if cond():
            return
    raise AssertionError("self test did not finish")


@cocotb.test()
async def bist_passes(dut):
    """Two full loops (3 passes each) over the memory with no errors."""
    await start(dut, inject=0, long_pause=1)
    await run_until(dut, lambda: int(dut.loops.value) >= 2)
    assert int(dut.failed.value) == 0
    assert int(dut.err_count.value) == 0
    assert int(dut.violation_count.value) == 0


@cocotb.test()
async def bist_detects_injected_error(dut):
    """One wrong bit written on purpose must be reported at its address."""
    await start(dut, inject=1, long_pause=0)
    await run_until(dut, lambda: int(dut.failed.value) == 1)
    assert int(dut.first_fail_addr.value) == N_WORDS // 3
    await run_until(dut, lambda: int(getattr(dut, "pass").value) == 1)
    assert int(dut.loops.value) == 0, "a failed loop must not be counted as passed"
    assert int(dut.violation_count.value) == 0
