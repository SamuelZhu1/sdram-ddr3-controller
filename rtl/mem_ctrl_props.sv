// Protocol properties for the controller's command stream.
//
// Independent of the controller's own counters: this module measures the
// spacing between commands itself and checks every rule in clock cycles. In
// simulation a failed check is counted and printed; with FORMAL defined the
// same checks are assertions for SymbiYosys.
module mem_ctrl_props
  import mem_pkg::*;
#(
  parameter int MEM_TYPE      = MEM_SDR,
  parameter int CLK_PERIOD_PS = 20_000,
  parameter int CL            = 2,
  parameter int T_PWR_CK      = 0,
  parameter int T_REFI_CK     = 0,
  parameter int BA_W          = 2,
  parameter int REF_MAX       = 8,
  parameter int REF_FORCE     = 4,
  parameter int SW            = 12       // width of the spacing counters
)(
  input  logic       clk,
  input  logic       rst_n,
  input  cmd_e       cmd,
  input  logic [2:0] cmd_ba,
  input  logic       init_done,
  input  logic       req_valid,
  input  logic       req_ready,
  input  logic       have_req,
  input  logic       d_fire,
  input  logic [3:0] ref_debt,
  input  logic       ref_overflow,
  output int         fail_count
);

  localparam int NB = 1 << BA_W;
`include "mem_timing.svh"

  // Longest a held request may wait: every postponed refresh, then a full
  // precharge / activate / turnaround sequence.
  localparam int WAIT_LIMIT = (REF_FORCE + 2) * (C_RFC + C_RP + 2) + C_RAS + C_WR2PRE
                            + C_RP + C_RC + C_RCD + C_WR2RD + C_RD2WR + 16;

  typedef logic [SW-1:0] age_t;
  function automatic age_t inc(input age_t a);
    inc = (&a) ? a : a + 1'b1;
  endfunction

  logic [NB-1:0] open;
  age_t since_act [NB];
  age_t since_pre [NB];
  age_t since_wr_b [NB];
  age_t since_rd_b [NB];
  age_t since_act_any, since_ref, since_rd, since_wr, waited;

  logic [BA_W-1:0] b;
  assign b = cmd_ba[BA_W-1:0];

`ifdef FORMAL
  `define CHK(name, cond) assert (cond)
`else
  `define CHK(name, cond) \
    if (!(cond)) begin \
      fail_count <= fail_count + 1; \
      $display("[%0t] PROPERTY FAILED: %s", $time, `"name`"); \
    end
`endif

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      fail_count    <= 0;
      open          <= '0;
      since_act_any <= '1;
      since_ref     <= '1;
      since_rd      <= '1;
      since_wr      <= '1;
      waited        <= '0;
      for (int i = 0; i < NB; i++) begin
        since_act[i]  <= '1;
        since_pre[i]  <= '1;
        since_wr_b[i] <= '1;
        since_rd_b[i] <= '1;
      end
    end else begin
      since_act_any <= inc(since_act_any);
      since_ref     <= inc(since_ref);
      since_rd      <= inc(since_rd);
      since_wr      <= inc(since_wr);
      for (int i = 0; i < NB; i++) begin
        since_act[i]  <= inc(since_act[i]);
        since_pre[i]  <= inc(since_pre[i]);
        since_wr_b[i] <= inc(since_wr_b[i]);
        since_rd_b[i] <= inc(since_rd_b[i]);
      end

      case (cmd)
        CMD_ACT: begin
          `CHK(p_act_after_init,  init_done);
          `CHK(p_act_bank_closed, !open[b]);
          `CHK(p_trp,             since_pre[b]  >= age_t'(C_RP));
          `CHK(p_trc,             since_act[b]  >= age_t'(C_RC));
          `CHK(p_trrd,            since_act_any >= age_t'(C_RRD));
          `CHK(p_trfc_act,        since_ref     >= age_t'(C_RFC));
          open[b]       <= 1'b1;
          since_act[b]  <= age_t'(1);
          since_act_any <= age_t'(1);
        end
        CMD_RD: begin
          `CHK(p_rd_bank_open, open[b]);
          `CHK(p_trcd_rd,      since_act[b] >= age_t'(C_RCD));
          `CHK(p_tccd_rd,      since_rd     >= age_t'(C_CCD));
          `CHK(p_wr_to_rd,     since_wr     >= age_t'(C_WR2RD));
          since_rd      <= age_t'(1);
          since_rd_b[b] <= age_t'(1);
        end
        CMD_WR: begin
          `CHK(p_wr_bank_open, open[b]);
          `CHK(p_trcd_wr,      since_act[b] >= age_t'(C_RCD));
          `CHK(p_tccd_wr,      since_wr     >= age_t'(C_CCD));
          `CHK(p_rd_to_wr,     since_rd     >= age_t'(C_RD2WR));
          since_wr      <= age_t'(1);
          since_wr_b[b] <= age_t'(1);
        end
        CMD_PRE: begin
          if (open[b]) begin
            `CHK(p_tras,      since_act[b]  >= age_t'(C_RAS));
            `CHK(p_wr_to_pre, since_wr_b[b] >= age_t'(C_WR2PRE));
            `CHK(p_rd_to_pre, since_rd_b[b] >= age_t'(C_RD2PRE));
          end
          open[b]      <= 1'b0;
          since_pre[b] <= age_t'(1);
        end
        CMD_PREA: begin
          for (int i = 0; i < NB; i++) begin
            if (open[i]) begin
              `CHK(p_tras_all,      since_act[i]  >= age_t'(C_RAS));
              `CHK(p_wr_to_pre_all, since_wr_b[i] >= age_t'(C_WR2PRE));
              `CHK(p_rd_to_pre_all, since_rd_b[i] >= age_t'(C_RD2PRE));
            end
            since_pre[i] <= age_t'(1);
          end
          open <= '0;
        end
        CMD_REF: begin
          `CHK(p_ref_all_closed, open == '0);
          `CHK(p_trfc_ref,       since_ref >= age_t'(C_RFC));
          for (int i = 0; i < NB; i++) begin
            `CHK(p_trp_ref, since_pre[i] >= age_t'(C_RP));
          end
          since_ref <= age_t'(1);
        end
        default: ;
      endcase

      // refresh bookkeeping can never lose a refresh
      `CHK(p_ref_debt_bounded, ref_debt <= 4'(REF_MAX));
      `CHK(p_ref_no_overflow,  !ref_overflow);

      // a request is never overwritten while it is still waiting
      if (req_valid && req_ready) begin
        `CHK(p_no_request_dropped, !have_req || d_fire);
      end

      // a held request is always served within a bounded time
      waited <= (have_req && !d_fire) ? inc(waited) : '0;
      `CHK(p_request_served, waited < age_t'(WAIT_LIMIT));
    end
  end

endmodule
