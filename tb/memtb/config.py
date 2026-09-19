"""Run configuration, taken from environment variables set by scripts/run_sim.py."""
import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Config:
    mem_type: str          # "SDR" or "DDR3"
    clk_period_ps: int
    seed: int
    n_txn: int
    cov_file: str

    @property
    def ddr3(self) -> bool:
        return self.mem_type == "DDR3"

    @property
    def n_banks(self) -> int:
        return 8 if self.ddr3 else 4

    @property
    def row_w(self) -> int:
        return 14 if self.ddr3 else 13

    @property
    def ba_w(self) -> int:
        return 3 if self.ddr3 else 2

    @property
    def col_w(self) -> int:
        return 7 if self.ddr3 else 10

    @property
    def data_w(self) -> int:
        return 64 if self.ddr3 else 16

    def addr(self, row: int, bank: int, col: int) -> int:
        return (row << (self.ba_w + self.col_w)) | (bank << self.col_w) | col

    def split(self, addr: int):
        col = addr & ((1 << self.col_w) - 1)
        bank = (addr >> self.col_w) & ((1 << self.ba_w) - 1)
        row = addr >> (self.ba_w + self.col_w)
        return row, bank, col


def load() -> Config:
    return Config(
        mem_type=os.environ.get("MEM_TYPE", "SDR"),
        clk_period_ps=int(os.environ.get("CLK_PERIOD_PS", "20000")),
        seed=int(os.environ.get("SEED", "1")),
        n_txn=int(os.environ.get("N_TXN", "2000")),
        cov_file=os.environ.get("COV_FILE", ""),
    )
