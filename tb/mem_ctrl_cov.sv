`timescale 1ps/1ps
// Functional coverage of controller situations that are not visible on the
// pins. Looks into the controller through hierarchical references; each bit
// of cov_ctrl is one bin that sticks once hit.
module mem_ctrl_cov (
  input  logic        clk,
  input  logic        rst_n,
  output logic [31:0] cov_ctrl
);
  // bin numbers (kept in step with tb/coverage.py)
  localparam int TICK_IDLE_CLOSED = 0;   // refresh falls due: nothing pending, all rows closed
  localparam int TICK_IDLE_OPEN   = 1;   // nothing pending, a row open
  localparam int TICK_REQ_HIT     = 2;   // a request waiting on an open row
  localparam int TICK_REQ_MISS    = 3;   // a request waiting to precharge
  localparam int TICK_REQ_CLOSED  = 4;   // a request waiting to activate
  localparam int TICK_RECOVERY    = 5;   // during tRP/tRFC of an earlier refresh
  localparam int ACC_HIT          = 6;   // request served from an open row
  localparam int ACC_MISS_OPEN    = 7;   // another row open in that bank
  localparam int ACC_MISS_CLOSED  = 8;   // bank closed
  localparam int REQ_BACK2BACK    = 9;   // accepted in the cycle the previous one issued
  localparam int REQ_HELD_BY_REF  = 10;  // request made to wait for a forced refresh
  localparam int REF_DEBT_1       = 11;  // refresh issued with 1..4 owed
  localparam int REF_DEBT_2       = 12;
  localparam int REF_DEBT_3       = 13;
  localparam int REF_DEBT_4       = 14;
  localparam int REF_NEEDS_PREA   = 15;  // refresh had to close rows first
  localparam int REF_NO_PREA      = 16;  // refresh with all rows already closed
  localparam int ROW_FIRST        = 17;
  localparam int ROW_LAST         = 18;
  localparam int COL_FIRST        = 19;
  localparam int COL_LAST         = 20;
  localparam int BANK_FIRST       = 21;
  localparam int BANK_LAST        = 22;
  localparam int REF_POSTPONED    = 23;  // request served while a refresh was owed
  localparam int ALL_BANKS_OPEN   = 24;

  logic prea_seen;  // a precharge-all has been issued since the last refresh

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cov_ctrl  <= '0;
      prea_seen <= 1'b0;
    end else if (tb_top.u_dut.u_core.init_done) begin
      if (tb_top.u_dut.u_core.ref_tick) begin
        if (!tb_top.u_dut.u_core.have_req) begin
          if (!tb_top.u_dut.u_core.all_act_ok && !tb_top.u_dut.u_core.any_open)
            cov_ctrl[TICK_RECOVERY] <= 1'b1;
          else if (tb_top.u_dut.u_core.any_open) cov_ctrl[TICK_IDLE_OPEN]   <= 1'b1;
          else                                   cov_ctrl[TICK_IDLE_CLOSED] <= 1'b1;
        end else if (tb_top.u_dut.u_core.hit)                           cov_ctrl[TICK_REQ_HIT]    <= 1'b1;
        else if (tb_top.u_dut.u_core.open[tb_top.u_dut.u_core.r_bank]) cov_ctrl[TICK_REQ_MISS]   <= 1'b1;
        else                                                            cov_ctrl[TICK_REQ_CLOSED] <= 1'b1;
      end

      if (tb_top.u_dut.u_core.have_req && !tb_top.u_dut.u_core.ref_want) begin
        if (tb_top.u_dut.u_core.d_cmd == mem_pkg::CMD_PRE) cov_ctrl[ACC_MISS_OPEN]   <= 1'b1;
        if (tb_top.u_dut.u_core.d_cmd == mem_pkg::CMD_ACT) cov_ctrl[ACC_MISS_CLOSED] <= 1'b1;
        if (tb_top.u_dut.u_core.d_fire && tb_top.u_dut.u_core.ref_debt != '0)
          cov_ctrl[REF_POSTPONED] <= 1'b1;
      end
      if (tb_top.u_dut.u_core.d_fire) cov_ctrl[ACC_HIT] <= 1'b1;

      if (tb_top.u_dut.u_core.req_valid && tb_top.u_dut.u_core.req_ready) begin
        if (tb_top.u_dut.u_core.d_fire) cov_ctrl[REQ_BACK2BACK] <= 1'b1;
        if (tb_top.req_addr[tb_top.AW-1 -: tb_top.ROW_W] == '0) cov_ctrl[ROW_FIRST] <= 1'b1;
        if (tb_top.req_addr[tb_top.AW-1 -: tb_top.ROW_W] == '1) cov_ctrl[ROW_LAST]  <= 1'b1;
        if (tb_top.req_addr[tb_top.COL_W-1:0] == '0)            cov_ctrl[COL_FIRST] <= 1'b1;
        if (tb_top.req_addr[tb_top.COL_W-1:0] == '1)            cov_ctrl[COL_LAST]  <= 1'b1;
        if (tb_top.req_addr[tb_top.COL_W +: tb_top.BA_W] == '0) cov_ctrl[BANK_FIRST] <= 1'b1;
        if (tb_top.req_addr[tb_top.COL_W +: tb_top.BA_W] == '1) cov_ctrl[BANK_LAST]  <= 1'b1;
      end
      if (tb_top.u_dut.u_core.have_req && tb_top.u_dut.u_core.ref_hold)
        cov_ctrl[REQ_HELD_BY_REF] <= 1'b1;

      if (tb_top.u_dut.u_core.d_ref) begin
        case (tb_top.u_dut.u_core.ref_debt)
          4'd1: cov_ctrl[REF_DEBT_1] <= 1'b1;
          4'd2: cov_ctrl[REF_DEBT_2] <= 1'b1;
          4'd3: cov_ctrl[REF_DEBT_3] <= 1'b1;
          4'd4: cov_ctrl[REF_DEBT_4] <= 1'b1;
          default: ;
        endcase
      end
      if (tb_top.u_dut.u_core.d_cmd == mem_pkg::CMD_PREA) begin
        cov_ctrl[REF_NEEDS_PREA] <= 1'b1;
        prea_seen                <= 1'b1;
      end
      if (tb_top.u_dut.u_core.d_ref) begin
        if (!prea_seen) cov_ctrl[REF_NO_PREA] <= 1'b1;
        prea_seen <= 1'b0;
      end
      if (&tb_top.u_dut.u_core.open) cov_ctrl[ALL_BANKS_OPEN] <= 1'b1;
    end
  end
endmodule
