// Formal top level: the controller core with free inputs.
//
// Bank, row and column widths are reduced so the solver can explore every
// state; the timing counters are the real SDR values at 50 MHz or 143 MHz. Reset is
// applied in the first cycle and may be applied again at any time.
module mem_ctrl_formal (
  input logic       clk,
  input logic       rst_n,
  input logic       req_valid,
  input logic       req_we,
  input logic [3:0] req_addr,
  input logic [1:0] req_wdata
);
  import mem_pkg::*;

  logic f_past_valid = 1'b0;
  always_ff @(posedge clk) f_past_valid <= 1'b1;
  always_comb if (!f_past_valid) assume (!rst_n);

  logic        init_done, req_ready, cmd_wr, cmd_rd, dev_reset_n, dev_cke;
  cmd_e        cmd;
  logic [2:0]  cmd_ba;
  logic [13:0] cmd_a;
  logic [1:0]  cmd_wdata;

  // F_143MHZ selects the 143 MHz timing set, where the rules span several
  // clocks (tRCD 3, tRAS 6, tRC 9, tRRD 2) instead of one or two.
`ifdef F_143MHZ
  localparam int F_CLK = 7_000, F_CL = 3, F_REFI = 40;
`else
  localparam int F_CLK = 20_000, F_CL = 2, F_REFI = 14;
`endif

  mem_ctrl_core #(
    .MEM_TYPE(MEM_SDR), .CLK_PERIOD_PS(F_CLK), .CL(F_CL),
    .BA_W(1), .ROW_W(2), .COL_W(1), .DW(2),
    .T_PWR_CK(2), .T_REFI_CK(F_REFI), .REF_FORCE(2), .REF_MAX(4), .CW(7)
  ) u_core (.*);

  // Reachability: the proof is not passing because nothing can happen.
  always_ff @(posedge clk) begin
    if (f_past_valid && rst_n) begin
      c_init:    cover (init_done);
      c_write:   cover (cmd == CMD_WR);
      c_read:    cover (cmd == CMD_RD);
      c_miss:    cover (cmd == CMD_PRE);
      c_refresh: cover (init_done && cmd == CMD_REF);
      c_prea:    cover (cmd == CMD_PREA);
    end
  end
endmodule
