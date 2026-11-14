# Bug log

Everything the verification environment found while it was being built, in
order. Testbench bugs are listed too: a checker that cries wolf is as much a
problem as one that stays silent.

## 1. Driver could "send" a request the controller never saw (testbench)

**Symptom.** SmokeTest: 24 reads, 1 mismatch, always the first address written.
The read returned the model's "never written" pattern.

**Isolation.** The other 23 addresses were fine, so the data path worked. The
bus model had seen no write to that address, so the request never reached the
pins. The first request of a sequence starts at an arbitrary point in the
clock cycle.

**Root cause.** The driver sampled `req_ready`, waited for the next falling
edge and declared the request accepted. For the first item it was started
just after a rising edge, so no rising edge fell between raising `req_valid`
and dropping it. The scoreboard recorded a write that never happened.

**Fix.** The driver now aligns to a falling edge before driving unless it is
already on one (back-to-back items).

## 2. SDR model did not know about resets (testbench)

**Symptom.** ResetTest on the short-refresh build: "refresh behind schedule",
and the coverage model raised "command pair REF->PREA observed but listed as
impossible".

**Root cause.** After a controller reset the model kept its old state. It kept
counting the refresh schedule through the 200-cycle power-up wait, and its
"previous command" survived the reset, so the first precharge-all of the new
initialization looked like it followed a refresh.

**Fix.** The model takes a `power_cycle` input and restarts its initialization
checks, which also means initialization is now checked after every reset
instead of only the first time.

## 3. DDR3 model expected write data across a reset (testbench)

**Symptom.** ResetTest, DDR3: "dfi_wrdata_en outside the write window".

**Root cause.** A reset during a write burst abandons the burst; the model
still expected the remaining beats.

**Fix.** The model clears its data schedules while `dfi_reset_n` is low.

## 4. Initialization waited one clock longer than needed (RTL)

**Symptom.** No failure. Coverage holes: `min_spacing.tXPR`, `tMRD` and `tMOD`
were never hit in DDR3 mode, although the initialization sequence has nothing
else to wait for.

**Root cause.** Each initialization step loaded its wait counter with N and
moved on when the counter reached zero, which is N+1 clocks. Legal, but every
step was one clock slow, and the "at minimum" bins could never be hit.

**Fix.** Steps load N-1. The bus models confirm the spacing is now exactly the
minimum and never below it.

## 5. A stuck controller hung the simulation (testbench)

**Symptom.** The bug-injection run for a too-short tRCD counter never
finished.

**Root cause.** That bug makes the controller stop serving requests. The
liveness property fired, but the test kept waiting for its sequence to
complete.

**Fix.** A watchdog ends the test as soon as any checker has fired, or when no
request has been accepted for 400,000 clocks.

## 6. The tRRD counter can never matter (finding, RTL kept as is)

**Symptom.** Two things pointed the same way: the coverage bin "tRRD seen at
its minimum" stayed empty in every configuration, and removing the tRRD
counter was the only injected bug that no test caught.

**Analysis.** The controller serves one request at a time. Between two
activates there is always the first request's read or write, which waits tRCD
after its own activate, and tRCD is at least as long as tRRD at every
supported clock rate.

**Resolution.** Instead of arguing it, proved it: with the counter removed,
the tRRD property still holds for every input sequence
(`formal/prove.sh F_143MHZ BUG_NO_TRRD`, where tRRD is 2 clocks and tRCD is
3). The bin is excluded with this reasoning and the counter is kept for the
day the controller is pipelined.
