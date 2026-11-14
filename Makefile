RTL  = rtl/mem_pkg.sv rtl/mem_ctrl_core.sv rtl/sdr_backend.sv rtl/dfi_backend.sv rtl/mem_ctrl.sv
LINT = verilator --lint-only -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY -Irtl

.PHONY: lint smoke regress quick bist bugs formal clean

lint:
	$(LINT) $(RTL) --top-module mem_ctrl
	$(LINT) -GMEM_TYPE=1 -GCLK_PERIOD_PS=2500 $(RTL) --top-module mem_ctrl
	$(LINT) $(RTL) rtl/mem_bist.sv fpga/de10_lite/de10_lite_top.sv --top-module de10_lite_top

smoke:
	python3 scripts/run_sim.py --mem SDR --test SmokeTest
	python3 scripts/run_sim.py --mem DDR3 --test SmokeTest

regress:
	python3 scripts/regress.py

quick:
	python3 scripts/regress.py --quick

bist:
	python3 scripts/run_bist.py

bugs:
	python3 scripts/bug_campaign.py

formal:
	formal/prove.sh
	formal/prove.sh F_143MHZ

clean:
	rm -rf sim_build coverage_raw formal/work* formal/gen
