# Verification plan

Device under test: `mem_ctrl` in both configurations (SDR SDRAM, DDR3 over DFI).

A feature counts as verified only when it has a row here: a checker that fails
if the feature is broken, and a coverage item that shows the situation was
actually exercised.

## 1. What can go wrong

A memory controller has two ways to be wrong. It can return the wrong data,
which a scoreboard sees immediately. Or it can break a timing rule, which a
simple memory model happily tolerates and real silicon does not, usually only
at some temperature or after some hours. The second kind is the reason this
environment exists: every timing rule is checked on every command, by two
independent checkers, and then proven.

## 2. Checkers

| Checker | Where | What it catches |
|---|---|---|
| Scoreboard | `tb/memtb/env.py` | Wrong, missing, extra or out-of-order read data, against a reference model of every write |
| SDR bus model | `tb/models/sdr_sdram_model.sv` | 19 rules: power-up wait, initialization order, mode register value, tMRD, tRCD, tRAS, tRC, tRP, tRRD, tWR, tRFC, access to a closed bank, activate on an open bank, refresh or mode register set with a row open, read-to-write turnaround, write without data, bus contention, refresh falling behind |
| DDR3 DFI model | `tb/models/ddr3_dfi_model.sv` | 28 rules: reset width, CKE wait, tXPR, mode register order and values, tMRD, tMOD, tZQinit, tRCD, tRAS, tRC, tRP, tRRD, tWR, tRFC, tCCD, tWTR, tRTP, read-to-write, write data window, read enable window, ODT, burst alignment, closed/open bank errors, refresh falling behind |
| Properties | `rtl/mem_ctrl_props.sv` | 27 assertions on the command stream, measured with their own counters: every spacing rule in clock cycles, no request dropped, every request served within a bound, refresh debt bounded |
| Watchdog | `tb/tests/test_mem.py` | A controller that stops accepting requests |

The bus models check in picoseconds of simulated time. The controller and the
properties count clock cycles. A wrong nanosecond-to-cycle conversion is
therefore caught by the models even though the properties share the
controller's timing table.

## 3. Feature list

| # | Feature | Checked by | Coverage |
|---|---|---|---|
| 1 | SDR initialization: wait, precharge-all, 8 refreshes, mode register | SDR model rules 0 to 3 | `pair.NOP->PREA`, `pair.REF->MRS`, `cmd.MRS` |
| 2 | DDR3 initialization: reset, CKE, MR2, MR3, MR1, MR0, ZQCL | DDR3 model rules 0 to 7 | `pair.NOP->MRS`, `pair.MRS->MRS`, `pair.MRS->ZQCL`, `cmd.MRS.mr0..3`, `min_spacing.tXPR/tMRD/tMOD` |
| 3 | Full-length power-up waits (200 us SDR; 200 us + 500 us DDR3) | models, `fullinit` build | SmokeTest and ResetTest on `fullinit` |
| 4 | Read and write return the right data | scoreboard | `cmd.RD.bank*`, `cmd.WR.bank*`, `seq.*` |
| 5 | Open-row hit goes straight to read/write | scoreboard, properties | `ctrl.access_hit`, `seq.*.same_row` |
| 6 | Row miss: precharge, activate, access | models, properties | `ctrl.access_miss_open`, `ctrl.access_miss_closed`, `seq.*.same_bank_other_row` |
| 7 | Every bank usable, several open at once | models | `cmd.ACT.bank*`, `cmd.PRE.bank*`, `ctrl.all_banks_open` |
| 8 | Each timing rule is respected at its minimum | models, properties, formal | `min_spacing.*` |
| 9 | Read/write turnarounds | models, properties | `pair.RD->WR`, `pair.WR->RD`, `min_spacing.read_to_write`, `min_spacing.write_to_read` |
| 10 | Refresh keeps up on average | model rule "refresh behind schedule", property on debt | `ctrl.tick_*` (refresh falling due in each situation) |
| 11 | Refresh closes open rows first | model, property | `ctrl.refresh_needs_prea`, `ctrl.refresh_no_prea` |
| 12 | Refresh is postponed under traffic and paid back | model, property | `ctrl.refresh_postponed`, `ctrl.refresh_debt_1..4` |
| 13 | Traffic is held when too many refreshes are owed, and nothing is lost | scoreboard, property `p_no_request_dropped` | `ctrl.req_held_by_refresh` |
| 14 | Back-to-back requests with no idle cycle | scoreboard | `ctrl.req_back_to_back`, `req.gap_0` |
| 15 | Idle gaps of every length | scoreboard | `req.gap_*` |
| 16 | Address corners | scoreboard | `ctrl.row_first/last`, `ctrl.col_first/last`, `ctrl.bank_first/last` |
| 17 | Reset in the middle of traffic | all checkers | ResetTest |
| 18 | DDR3 write data and read enable windows | DDR3 model rules 22, 23, 27 | every DDR3 read and write |
| 19 | Three clock rates in SDR mode (50, 100, 143 MHz; CAS latency 2 and 3) | models | separate builds in the regression |
| 20 | Every legal command pair occurs, no illegal pair occurs | coverage model raises an error on a pair it lists as impossible | `pair.*` |

## 4. Coverage exclusions

Bins that cannot be hit by construction. Each was first a coverage hole, then
explained, then removed from the goal.

| Bin | Why it is unreachable |
|---|---|
| `min_spacing.tRRD` (both) | The controller serves one request at a time, so two activates are always separated by a read or write, which itself waits tRCD. tRCD is longer than tRRD in every configuration, so tRRD can never be the rule that decides. Confirmed two ways: removing the tRRD counter is the one injected bug no test catches, and the tRRD property is formally proven with the counter removed (`formal/prove.sh F_143MHZ BUG_NO_TRRD`). The counter stays in the design in case the controller is ever pipelined. |
| `min_spacing.tMRD` (SDR), `min_spacing.tZQinit` (DDR3) | The first command after initialization needs a request to be accepted first, which takes more clocks than the rule requires. |
| Command pairs not listed in `coverage.py` | For example refresh followed by read: refresh requires every row closed. Observing one of these pairs fails the test. |

The rules themselves are still checked on every command; only the "seen at
minimum spacing" bin is excluded.

## 5. Stimulus

| Test | Purpose |
|---|---|
| SmokeTest | A few writes and reads in every bank |
| RandomTest | Constrained-random mix with knobs for row locality, write ratio and idle gaps |
| RowThrashTest | Row change on almost every request in two banks: tRAS, tRP, tRC, tWR at their limits |
| BankPingPongTest | Bank change on every request: all banks open |
| TurnaroundTest | No idle time inside open rows: read/write turnarounds |
| IdleTest | Long gaps: refresh while idle, first command after initialization is a refresh |
| FillTest | Sequential block across row and bank boundaries, then read-back |
| ResetTest | Reset at random points during traffic |

Build configurations: SDR at 50, 100 and 143 MHz; a "storm" build per memory
type with the refresh interval shortened so refresh collides with everything;
a "fullinit" build with real power-up waits.

## 6. Is the testbench any good? Bug injection

Coverage shows what was exercised, not what would have been noticed. So the
controller is rebuilt with one deliberate bug at a time (`scripts/bug_campaign.py`)
and the regression has to fail. Results are in `bug_injection_results.md`.

## 7. Formal

`formal/prove.sh` proves all 27 properties for every possible sequence of
requests and resets (unbounded proof, PDR engine), at the 50 MHz and 143 MHz
timing sets, with bank, row and column widths reduced. The same script with a
bug define must fail; several do, which shows the proof is not vacuous.

## 8. Exit criteria

- every regression test passes for both memory types
- functional coverage 100% of the bins that remain after section 4
- every injected bug is caught or proven unable to change behaviour
- formal proofs pass
- on the board: the self test passes over all 32M words with the retention
  wait enabled, and reports the injected error
