create_clock -name clk50 -period 20.000 [get_ports MAX10_CLK1_50]
derive_clock_uncertainty

# SDRAM interface. The SDRAM clock is the inverted system clock, so the chip
# launches and captures half a period (10 ns) away from the FPGA.
create_generated_clock -name dram_clk -source [get_ports MAX10_CLK1_50] -invert [get_ports DRAM_CLK]

# Check these against the datasheet for the chip on your board.
# IS42S16320D-7: input setup 1.5 ns, hold 0.8 ns; access time 5.4 ns (CL=3) / 6 ns (CL=2), output hold 2.7 ns.
set dram_out [get_ports {DRAM_ADDR[*] DRAM_BA[*] DRAM_CAS_N DRAM_CKE DRAM_CS_N DRAM_DQ[*] DRAM_LDQM DRAM_UDQM DRAM_RAS_N DRAM_WE_N}]
set_output_delay -clock dram_clk -max  1.5 $dram_out
set_output_delay -clock dram_clk -min -0.8 $dram_out
set_input_delay  -clock dram_clk -max  6.0 [get_ports {DRAM_DQ[*]}]
set_input_delay  -clock dram_clk -min  2.7 [get_ports {DRAM_DQ[*]}]

set_false_path -from [get_ports {KEY[*] SW[*]}]
set_false_path -to   [get_ports {LEDR[*] HEX*}]
