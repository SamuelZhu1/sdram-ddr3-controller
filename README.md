# SDRAM / DDR3 memory controller with a verification environment

A memory controller written in SystemVerilog, and the environment that tries
to break it: bus models that check every timing rule, a UVM testbench with
constrained-random traffic, functional coverage, bug injection and formal
proofs. One controller core drives two back ends:

- **SDR SDRAM**: runs in simulation and on the 64 MB SDRAM chip of a
  Terasic DE10-Lite (Intel MAX 10, ISSI IS42S16320D)
- **DDR3 over DFI**: a DDR3-800 device behind a DFI PHY interface, verified
  in simulation

## Why

A DRAM chip is not an array. A row has to be opened before it is read, closed
before another one is opened, and every row refreshed about every 64 ms, each
step with a minimum spacing in nanoseconds. A controller that breaks one of
those rules still passes a simple read-back test in simulation. So most of
this repository is not the controller. It is the checking.

## Results

| | |
|---|---|
| Regression | 291 of 291 tests pass (8 tests, 9 build configurations, up to 6 seeds) |
| Transactions checked | 4,421,848 reads and writes against a reference model |
| Functional coverage | 100%: 91 of 91 bins (SDR), 118 of 118 bins (DDR3) |
| Protocol rules checked | 19 (SDR bus model), 28 (DDR3 DFI model), 27 assertions |
| Bug injection | 18 of 19 deliberate RTL bugs caught; the 19th proven unable to change behaviour |
| Formal | all 27 assertions proven for every input sequence at two timing sets |
| On the board | self test passes in simulation; hardware bring-up notes in `docs/bringup.md` |

Reports: [coverage](docs/coverage_report.md), [bug injection](docs/bug_injection_results.md),
[verification plan](docs/verification_plan.md), [bug log](docs/bug_log.md).

## Architecture

```
                 user interface                     abstract command bus
  requester  ->  req_valid/ready, we, addr, wdata -> +----------------------+
  (testbench     rsp_valid, rdata                    |    mem_ctrl_core     |
   or BIST)   <-                                  <- |  init sequence       |
                                                     |  refresh scheduler   |
                                                     |  bank / row tracker  |
                                                     |  timing counters     |
                                                     +----------+-----------+
                                                                |
                                         +----------------------+----------------------+
                                  +------v------+                               +------v------+
                                  | sdr_backend |                               | dfi_backend |
                                  +------+------+                               +------+------+
                                         | SDRAM pins                                  | DFI
                              +----------v-----------+                     +-----------v-----------+
                              | sdr_sdram_model (sim) |                     | ddr3_dfi_model (sim)  |
                              | or the chip (board)   |                     | PHY + DDR3 device     |
                              +-----------------------+                     +-----------------------+
```

The core takes one request at a time and issues the command sequence the
memory needs: activate a row, read or write, precharge, refresh. Rows are
left open after an access, so sequential traffic pays for one activate per
1,024 words. Refresh can be postponed while traffic is flowing (up to 4) and
is paid back when the bus goes idle; past that, traffic is held until the
debt is cleared. Every command waits on counters derived from a single timing
table (`rtl/mem_defs.svh`), converted from nanoseconds to clock cycles by
rounding up.

SDR and DDR3 share the command set and most rules. What differs is
initialization and the data path, which is why those live in the back ends.

## How it is verified

1. **Verification plan** (`docs/verification_plan.md`): every feature mapped
   to a checker and a coverage item.
2. **Bus models** (`tb/models/`): behave like the memory and check every rule
   in picoseconds of simulated time, independently of the controller's cycle
   counts.
3. **UVM testbench** (`tb/memtb/`, pyuvm on cocotb): sequences, driver,
   monitor, scoreboard with a reference model.
4. **Assertions** (`rtl/mem_ctrl_props.sv`): 27 properties on the command
   stream with their own spacing counters, used in simulation and in formal.
5. **Functional coverage** (`tb/memtb/coverage.py`, `tb/mem_ctrl_cov.sv`):
   commands per bank, legal command pairs, each timing rule seen at its
   minimum, refresh falling due in every situation, request patterns.
6. **Bug injection** (`scripts/bug_campaign.py`): 19 deliberate bugs behind
   `` `ifdef ``; the regression must fail on each.
7. **Formal** (`formal/`): unbounded proofs with SymbiYosys and ABC PDR.

The UVM testbench is written with pyuvm, a Python implementation of the UVM
class library, because open-source simulators do not run the SystemVerilog
UVM library. The structure is standard UVM; the syntax is Python.

Things this found, including one design finding that needed a proof to
settle, are written up in `docs/bug_log.md`.

## Running it

```
pip install -r requirements.txt        # cocotb, pyuvm, Verilator, Yosys, z3
sudo apt install yosys                 # for yosys-abc (formal)

make lint
make smoke                             # one quick test per memory type
python3 scripts/run_sim.py --mem DDR3 --test RandomTest --seed 3 --waves
make quick                             # short regression + coverage report
make regress                           # full regression, about 15 minutes
make bugs                              # bug-injection campaign
make formal                            # proofs
make bist                              # simulate the on-board self test
```

If `verilator` is not on your PATH after the pip install, add the `bin`
directory of the `verilator` Python package to it.

## On the DE10-Lite

`fpga/de10_lite/` holds a Quartus Prime Lite project: the controller in SDR
mode plus a built-in self test that writes and reads back all 32M words in
three patterns, with an optional 100 ms wait between write and read-back.
That wait is longer than the chip's 64 ms retention time, so the data only
survives if refresh works, which is something no simulation model proves.
See `docs/bringup.md` for the steps and what to record.

## Layout

```
rtl/          controller core, back ends, assertions, self test
tb/           UVM testbench, bus models, coverage, tests
formal/       SymbiYosys model and proof script
fpga/         DE10-Lite top level and Quartus project
scripts/      simulation runner, regression, bug campaign
docs/         verification plan, reports, bug log, bring-up notes
```
