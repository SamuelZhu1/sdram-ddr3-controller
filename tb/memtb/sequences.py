"""Stimulus sequences."""
import random

from pyuvm import uvm_sequence

from .env import MemItem


class BaseSeq(uvm_sequence):
    def __init__(self, name, cfg, rng, n):
        super().__init__(name)
        self.cfg = cfg
        self.rng = rng
        self.n = n

    def rdata(self):
        return self.rng.getrandbits(self.cfg.data_w)

    async def send(self, we, addr, data=0, gap=0):
        item = MemItem("item", we, addr, data, gap)
        await self.start_item(item)
        await self.finish_item(item)


class SmokeSeq(BaseSeq):
    """Write a handful of addresses in every bank, read them back."""

    async def body(self):
        c = self.cfg
        addrs = [c.addr(r, b, col) for b in range(c.n_banks) for r in (0, 5) for col in (0, 1, 9)]
        for a in addrs:
            await self.send(1, a, self.rdata())
        for a in addrs:
            await self.send(0, a)


class RandomSeq(BaseSeq):
    """Constrained-random traffic.

    Knobs:
      p_same_row   chance the next request stays in the current row
      p_same_bank  chance it stays in the bank but changes row
      rows         size of the row pool (small pools mean rewrites and read-backs)
      p_write      write probability
      gap_weights  weights for idle gaps of 0, 1-3, 4-15 and 16-400 clocks
    """

    def __init__(self, name, cfg, rng, n, p_same_row=0.5, p_same_bank=0.2, rows=6,
                 cols=12, p_write=0.5, gap_weights=(70, 15, 10, 5), banks=None):
        super().__init__(name, cfg, rng, n)
        self.p_same_row = p_same_row
        self.p_same_bank = p_same_bank
        self.p_write = p_write
        self.gap_weights = gap_weights
        c = cfg
        rmax, cmax = (1 << c.row_w) - 1, (1 << c.col_w) - 1
        self.rows = [0, rmax] + [rng.randrange(1, rmax) for _ in range(max(rows - 2, 0))]
        self.cols = [0, cmax] + [rng.randrange(1, cmax) for _ in range(max(cols - 2, 0))]
        self.banks = list(range(c.n_banks)) if banks is None else banks

    def gap(self):
        k = self.rng.choices(range(4), weights=self.gap_weights)[0]
        return (0, self.rng.randint(1, 3), self.rng.randint(4, 15), self.rng.randint(16, 400))[k]

    async def body(self):
        rng = self.rng
        row, bank = rng.choice(self.rows), rng.choice(self.banks)
        for _ in range(self.n):
            x = rng.random()
            if x < self.p_same_row:
                pass
            elif x < self.p_same_row + self.p_same_bank:
                row = rng.choice([r for r in self.rows if r != row] or self.rows)
            else:
                bank = rng.choice([b for b in self.banks if b != bank] or self.banks)
                row = rng.choice(self.rows)
            addr = self.cfg.addr(row, bank, rng.choice(self.cols))
            if rng.random() < self.p_write:
                await self.send(1, addr, self.rdata(), self.gap())
            else:
                await self.send(0, addr, 0, self.gap())


class FillThenCheckSeq(BaseSeq):
    """Write a block of sequential addresses that crosses row and bank
    boundaries, then read it all back."""

    async def body(self):
        c = self.cfg
        start = self.cfg.addr(self.rng.randrange(1 << c.row_w), 0, 0) + (1 << c.col_w) - self.n // 4
        start = max(start, 0)
        last = (1 << (c.row_w + c.ba_w + c.col_w)) - 1
        addrs = [min(start + i, last) for i in range(self.n // 2)]
        for a in addrs:
            await self.send(1, a, self.rdata())
        for a in addrs:
            await self.send(0, a)
