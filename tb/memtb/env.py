"""UVM environment (pyuvm): sequence item, driver, monitor, scoreboard, env."""
import cocotb
from cocotb.triggers import FallingEdge
from cocotb.utils import get_sim_time
from pyuvm import (ConfigDB, uvm_analysis_port, uvm_component, uvm_driver, uvm_env,
                   uvm_monitor, uvm_sequence_item, uvm_sequencer, uvm_subscriber)

from .coverage import Coverage


class MemItem(uvm_sequence_item):
    """One read or write request. gap = idle clocks before it is driven."""

    def __init__(self, name, we, addr, data=0, gap=0):
        super().__init__(name)
        self.we = we
        self.addr = addr
        self.data = data
        self.gap = gap


class MemDriver(uvm_driver):
    """Drives the request handshake. Signals change on the falling edge so
    they are stable at the rising edge the controller samples."""

    def build_phase(self):
        self.dut = cocotb.top
        self.ap = uvm_analysis_port("ap", self)

    async def run_phase(self):
        dut = self.dut
        dut.req_valid.value = 0
        aligned_at = -1
        while True:
            item = await self.seq_item_port.get_next_item()
            # Only drive on a falling edge. Back-to-back items are already
            # there; the first item of a sequence usually is not.
            if get_sim_time("step") != aligned_at:
                await FallingEdge(dut.clk)
            for _ in range(item.gap):
                await FallingEdge(dut.clk)
            dut.req_valid.value = 1
            dut.req_we.value = item.we
            dut.req_addr.value = item.addr
            dut.req_wdata.value = item.data
            while True:
                ready = int(dut.req_ready.value)
                await FallingEdge(dut.clk)
                if ready:
                    break
            dut.req_valid.value = 0
            aligned_at = get_sim_time("step")
            self.ap.write(item)          # accepted, in order
            self.seq_item_port.item_done()


class RspMonitor(uvm_monitor):
    """Publishes every read response."""

    def build_phase(self):
        self.dut = cocotb.top
        self.ap = uvm_analysis_port("ap", self)

    async def run_phase(self):
        dut = self.dut
        while True:
            await FallingEdge(dut.clk)
            if int(dut.rsp_valid.value):
                self.ap.write(int(dut.rsp_rdata.value))


class RspSubscriber(uvm_subscriber):
    def __init__(self, name, parent, sb):
        super().__init__(name, parent)
        self.sb = sb

    def write(self, data):
        self.sb.on_response(data)


class Scoreboard(uvm_subscriber):
    """Reference model: a dictionary of what was last written to each address.

    Requests are applied in acceptance order, so the expected value of a read
    is fixed when the read is accepted. A read of an address that was never
    written is not compared.
    """

    def build_phase(self):
        self.cfg = ConfigDB().get(self, "", "cfg")
        self.cov = ConfigDB().get(self, "", "cov")
        self.mem = {}
        self.expected = []          # (addr, value or None) for reads in flight
        self.prev = None
        self.reads = 0
        self.writes = 0
        self.compared = 0
        self.errors = 0

    def write(self, item):          # from the driver: request accepted
        row, bank, _ = self.cfg.split(item.addr)
        cur = (item.we, row, bank)
        self.cov.sample_request(self.prev, cur, item.gap)
        self.prev = cur
        if item.we:
            self.mem[item.addr] = item.data
            self.writes += 1
        else:
            self.expected.append((item.addr, self.mem.get(item.addr)))
            self.reads += 1

    def on_response(self, data):
        if not self.expected:
            self.errors += 1
            self.logger.error(f"response {data:#x} with no read outstanding")
            return
        addr, want = self.expected.pop(0)
        if want is None:
            return
        self.compared += 1
        if data != want:
            self.errors += 1
            row, bank, col = self.cfg.split(addr)
            self.logger.error(f"read mismatch at row {row:#x} bank {bank} col {col:#x}: "
                              f"got {data:#x}, expected {want:#x}")

    def forget(self):
        """After a reset the memory contents are no longer guaranteed."""
        self.mem.clear()
        self.expected.clear()
        self.prev = None


class MemEnv(uvm_env):
    def build_phase(self):
        self.cfg = ConfigDB().get(self, "", "cfg")
        self.cov = Coverage(self.cfg.mem_type, self.cfg.n_banks)
        ConfigDB().set(self, "*", "cov", self.cov)
        self.seqr = uvm_sequencer("seqr", self)
        ConfigDB().set(None, "*", "SEQR", self.seqr)
        self.driver = MemDriver("driver", self)
        self.monitor = RspMonitor("monitor", self)
        self.scoreboard = Scoreboard("scoreboard", self)
        self.rsp_sub = RspSubscriber("rsp_sub", self, self.scoreboard)

    def connect_phase(self):
        self.driver.seq_item_port.connect(self.seqr.seq_item_export)
        self.driver.ap.connect(self.scoreboard.analysis_export)
        self.monitor.ap.connect(self.rsp_sub.analysis_export)
