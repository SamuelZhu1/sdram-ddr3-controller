# DE10-Lite bring-up

Status: the design passes the self test in simulation against the SDRAM model
(`make bist`). The steps below are the hardware run.

## Before building

1. Open `fpga/de10_lite/de10_lite.qpf` in Quartus Prime Lite.
2. Paste the pin locations from Terasic's DE10-Lite golden top `.qsf` into
   `de10_lite.qsf` (the port names match).
3. Check the SDRAM part number printed on the chip against the timing table in
   `rtl/mem_defs.svh` and the delays in `de10_lite.sdc`.

## Run

1. Compile, check the timing report for failing paths on the `DRAM_*` pins,
   program the board over USB-Blaster.
2. Release KEY0. LEDR0 lights when initialization finishes, LEDR1 while the
   test runs. One loop over 64 MB in three patterns takes roughly a minute.
3. LEDR8 lights after the first error-free loop; the hex displays count loops.
4. Turn SW1 on (100 ms retention wait) and let it run for several loops.
5. Turn SW0 on. LEDR9 must light and the displays must show the failing
   address (`0xAAAAAA`). This proves the test can fail. Press KEY0 to clear.

## Record

| Measurement | Result |
|---|---|
| Error-free loops with SW1 off | |
| Error-free loops with SW1 on (retention) | |
| Injected error detected at the expected address | |
| Worst setup / hold slack on `DRAM_*` (timing report) | |
| Signal Tap capture of initialization matches the simulation waveform | |
| Anything that failed on the board but passed in simulation | |

## Signal Tap

Add `DRAM_CS_N, DRAM_RAS_N, DRAM_CAS_N, DRAM_WE_N, DRAM_BA, DRAM_ADDR` and
`u_ctrl|init_done`, trigger on the falling edge of reset, and compare with
`python3 scripts/run_sim.py --mem SDR --config fullinit --test SmokeTest --waves`.

## If the test fails intermittently

Suspect I/O timing before the controller: confirm the fast I/O register
assignments took effect (Fitter report), then try shifting the SDRAM clock
with a PLL instead of the plain inversion.
