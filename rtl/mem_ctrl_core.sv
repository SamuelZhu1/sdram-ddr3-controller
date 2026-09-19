// Command engine shared by the SDR SDRAM and DDR3 back ends.
//
// Takes one read or write request at a time and turns it into the command
// sequence the memory needs (activate, read/write, precharge, refresh),
// issuing each command only when every timing rule that applies to it has
// been met. Rows are left open after an access (open-row policy).
//
// A decision made in cycle n appears on the registered command outputs in
// cycle n+1, so spacing between decisions equals spacing on the pins.
module mem_ctrl_core
  import mem_pkg::*;
#(
  parameter int MEM_TYPE      = MEM_SDR,
  parameter int CLK_PERIOD_PS = 20_000,
  parameter int CL            = 2,       // SDR CAS latency (DDR3 uses DDR3_CL)
  parameter int BA_W          = 2,
  parameter int ROW_W         = 13,
  parameter int COL_W         = 10,      // column bits in the user address
  parameter int COL_SHIFT     = 0,       // low column bits forced to 0 (DDR3 burst)
  parameter int DW            = 16,
  parameter int T_PWR_CK      = 0,       // 0 = datasheet power-up wait
  parameter int T_REFI_CK     = 0,       // 0 = datasheet refresh interval
  parameter int REF_FORCE     = 4,       // postponed refreshes before traffic is held
  parameter int REF_MAX       = 8,
  parameter int AW            = ROW_W + BA_W + COL_W
)(
  input  logic          clk,
  input  logic          rst_n,
  output logic          init_done,

  input  logic          req_valid,
  output logic          req_ready,
  input  logic          req_we,
  input  logic [AW-1:0] req_addr,
  input  logic [DW-1:0] req_wdata,

  output cmd_e          cmd,
  output logic [2:0]    cmd_ba,
  output logic [13:0]   cmd_a,
  output logic          cmd_wr,
  output logic          cmd_rd,
  output logic [DW-1:0] cmd_wdata,
  output logic          dev_reset_n,
  output logic          dev_cke
);

  localparam int NB = 1 << BA_W;
`include "mem_timing.svh"

  localparam int CW = 20;  // counter width, enough for 500 us at 2.5 ns
  typedef logic [CW-1:0] cnt_t;

  // Load a counter so the next command is legal N cycles after this one,
  // never shortening a longer wait that is already running.
  function automatic cnt_t ld(input cnt_t cur, input int n);
    cnt_t dec;
    cnt_t want;
    dec  = (cur == '0) ? '0 : cur - 1'b1;
    want = cnt_t'(n - 1);
    ld   = (dec > want) ? dec : want;
  endfunction

  function automatic cnt_t dec1(input cnt_t cur);
    dec1 = (cur == '0) ? '0 : cur - 1'b1;
  endfunction

  // ---- state ----------------------------------------------------------
  typedef enum logic [0:0] {S_INIT, S_RUN} state_e;
  state_e state;

  logic [3:0] step;          // initialization step
  cnt_t       gen_cnt;       // initialization wait

  logic [NB-1:0]    open;    // bank has a row open
  logic [ROW_W-1:0] row [NB];
  cnt_t rw_ok  [NB];         // activate -> read/write
  cnt_t pre_ok [NB];         // activate/read/write -> precharge
  cnt_t act_ok [NB];         // precharge/activate/refresh -> activate or refresh
  cnt_t act_any;             // activate -> activate on another bank
  cnt_t rd_ok;               // earliest next read
  cnt_t wr_ok;               // earliest next write

  cnt_t refi_cnt;
  logic [3:0] ref_debt;      // refreshes owed
  logic       ref_overflow;  // sticky: debt would have passed REF_MAX

  // one request held while it is being served
  logic             have_req;
  logic             r_we;
  logic [ROW_W-1:0] r_row;
  logic [BA_W-1:0]  r_bank;
  logic [COL_W-1:0] r_col;
  logic [DW-1:0]    r_wdata;

  // ---- decision for this cycle ---------------------------------------
  cmd_e          d_cmd;
  logic [2:0]    d_ba;
  logic [13:0]   d_a;
  logic          d_fire;      // the held request is issued this cycle
  logic          d_ref;       // a refresh is issued this cycle

  logic any_open, all_pre_ok, all_act_ok, hit, ref_want, ref_hold;

  always_comb begin
    any_open   = |open;
    all_pre_ok = 1'b1;
    all_act_ok = 1'b1;
    for (int b = 0; b < NB; b++) begin
      if (open[b] && pre_ok[b] != '0) all_pre_ok = 1'b0;
      if (act_ok[b] != '0)            all_act_ok = 1'b0;
    end
`ifdef BUG_HIT_IGNORES_ROW
    hit = open[r_bank];
`else
    hit = open[r_bank] && (row[r_bank] == r_row);
`endif
    ref_hold = (ref_debt >= 4'(REF_FORCE));
    ref_want = (ref_debt != '0) && (!have_req || ref_hold);

    d_cmd  = CMD_NOP;
    d_ba   = 3'(r_bank);
    d_a    = '0;
    d_fire = 1'b0;
    d_ref  = 1'b0;

    if (state == S_RUN) begin
      if (ref_want) begin
`ifdef BUG_REF_NO_PREA
        if (all_act_ok) begin
`else
        if (any_open) begin
          if (all_pre_ok) begin
            d_cmd   = CMD_PREA;
            d_a[10] = 1'b1;
          end
        end else if (all_act_ok) begin
`endif
          d_cmd = CMD_REF;
          d_ref = 1'b1;
        end
      end else if (have_req) begin
        if (hit) begin
          if (rw_ok[r_bank] == '0 && (r_we ? (wr_ok == '0) : (rd_ok == '0))) begin
            d_cmd  = r_we ? CMD_WR : CMD_RD;
            d_a    = 14'(r_col) << COL_SHIFT;
            d_fire = 1'b1;
          end
        end else if (open[r_bank]) begin
          if (pre_ok[r_bank] == '0) begin
            d_cmd = CMD_PRE;
`ifdef BUG_PRE_WRONG_BANK
            d_ba  = '0;
`endif
          end
        end else if (act_ok[r_bank] == '0 && act_any == '0) begin
          d_cmd = CMD_ACT;
          d_a   = 14'(r_row);
        end
      end
    end
  end

`ifdef BUG_READY_DROP
  assign req_ready = init_done && !ref_hold;
`else
  assign req_ready = init_done && !ref_hold && (!have_req || d_fire);
`endif

  // ---- sequential -----------------------------------------------------
  logic ref_tick;
  assign ref_tick = init_done && (refi_cnt == '0);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state        <= S_INIT;
      step         <= '0;
      gen_cnt      <= cnt_t'(C_PWR);
      init_done    <= 1'b0;
      open         <= '0;
      act_any      <= '0;
      rd_ok        <= '0;
      wr_ok        <= '0;
      refi_cnt     <= cnt_t'(C_REFI - 1);
      ref_debt     <= '0;
      ref_overflow <= 1'b0;
      have_req     <= 1'b0;
      cmd          <= CMD_NOP;
      cmd_ba       <= '0;
      cmd_a        <= '0;
      cmd_wr       <= 1'b0;
      cmd_rd       <= 1'b0;
      cmd_wdata    <= '0;
      dev_reset_n  <= DDR ? 1'b0 : 1'b1;
      dev_cke      <= DDR ? 1'b0 : 1'b1;
      for (int b = 0; b < NB; b++) begin
        rw_ok[b]  <= '0;
        pre_ok[b] <= '0;
        act_ok[b] <= '0;
      end
    end else begin
      // defaults: NOP, counters run down
      cmd    <= CMD_NOP;
      cmd_wr <= 1'b0;
      cmd_rd <= 1'b0;
      gen_cnt <= dec1(gen_cnt);
      act_any <= dec1(act_any);
      rd_ok   <= dec1(rd_ok);
      wr_ok   <= dec1(wr_ok);
      for (int b = 0; b < NB; b++) begin
        rw_ok[b]  <= dec1(rw_ok[b]);
        pre_ok[b] <= dec1(pre_ok[b]);
        act_ok[b] <= dec1(act_ok[b]);
      end

      // refresh interval timer
      if (init_done) begin
        if (refi_cnt == '0) refi_cnt <= cnt_t'(C_REFI - 1);
        else                refi_cnt <= refi_cnt - 1'b1;
      end
`ifdef BUG_REF_DEBT_DROP
      if (d_ref) ref_debt <= '0;
      else if (ref_tick) ref_debt <= ref_debt + 1'b1;
`else
      case ({ref_tick, d_ref})
        2'b10: begin
          if (ref_debt == 4'(REF_MAX)) ref_overflow <= 1'b1;
          else                         ref_debt     <= ref_debt + 1'b1;
        end
        2'b01:   ref_debt <= ref_debt - 1'b1;
        default: ;
      endcase
`endif

      // request register
      if (req_valid && req_ready) begin
        have_req <= 1'b1;
        r_we     <= req_we;
        r_row    <= req_addr[AW-1 -: ROW_W];
        r_bank   <= req_addr[COL_W +: BA_W];
        r_col    <= req_addr[COL_W-1:0];
        r_wdata  <= req_wdata;
      end else if (d_fire) begin
        have_req <= 1'b0;
      end

      case (state)
        // ---------------- initialization ----------------
        S_INIT: begin
          if (gen_cnt == '0) begin
            step <= step + 1'b1;
            if (!DDR) begin
              // PREA, 8 x REF, MRS
              if (step == 4'd0) begin
`ifndef BUG_INIT_NO_PREA
                cmd       <= CMD_PREA;
                cmd_a     <= 14'h0400;
`endif
                gen_cnt   <= cnt_t'(C_RP);
              end else if (step <= 4'(SDR_INIT_REFS)) begin
                cmd       <= CMD_REF;
                gen_cnt   <= cnt_t'(C_RFC);
              end else if (step == 4'(SDR_INIT_REFS + 1)) begin
                cmd       <= CMD_MRS;
                cmd_ba    <= '0;
                // burst length 1, sequential, CAS latency CL
`ifdef BUG_MRS_CL
                cmd_a     <= {7'b0, 3'(CL + 1), 4'b0000};
`else
                cmd_a     <= {7'b0, 3'(CL), 4'b0000};
`endif
                gen_cnt   <= cnt_t'(C_MRD);
              end else begin
                init_done <= 1'b1;
                state     <= S_RUN;
              end
            end else begin
              // reset release, CKE, MR2, MR3, MR1, MR0, ZQCL
              case (step)
                4'd0: begin dev_reset_n <= 1'b1; gen_cnt <= cnt_t'(C_CKE); end
                4'd1: begin dev_cke     <= 1'b1; gen_cnt <= cnt_t'(C_XPR); end
                4'd2: begin cmd <= CMD_MRS; cmd_ba <= 3'd2; cmd_a <= 14'h0000; gen_cnt <= cnt_t'(C_MRD); end
                4'd3: begin cmd <= CMD_MRS; cmd_ba <= 3'd3; cmd_a <= 14'h0000; gen_cnt <= cnt_t'(C_MRD); end
                4'd4: begin cmd <= CMD_MRS; cmd_ba <= 3'd1; cmd_a <= 14'h0004; gen_cnt <= cnt_t'(C_MRD); end
                4'd5: begin
                  cmd    <= CMD_MRS;
                  cmd_ba <= 3'd0;
                  // write recovery 6, DLL reset, CL 5, burst length 8
`ifdef BUG_MRS_CL
                  cmd_a  <= 14'h0520;
`else
                  cmd_a  <= 14'h0510;
`endif
                  gen_cnt <= cnt_t'(C_MOD);
                end
                4'd6: begin cmd <= CMD_ZQCL; cmd_a <= 14'h0400; gen_cnt <= cnt_t'(C_ZQI); end
                default: begin
                  init_done <= 1'b1;
                  state     <= S_RUN;
                end
              endcase
            end
          end
        end

        // ---------------- normal operation ----------------
        S_RUN: begin
          cmd    <= d_cmd;
          cmd_ba <= d_ba;
          cmd_a  <= d_a;
          case (d_cmd)
            CMD_PREA: begin
              open <= '0;
              for (int b = 0; b < NB; b++) act_ok[b] <= ld(act_ok[b], C_RP);
            end
            CMD_REF: begin
`ifndef BUG_NO_TRFC
              for (int b = 0; b < NB; b++) act_ok[b] <= ld(act_ok[b], C_RFC);
`endif
            end
            CMD_PRE: begin
              open[r_bank]   <= 1'b0;
`ifndef BUG_NO_TRP
              act_ok[r_bank] <= ld(act_ok[r_bank], C_RP);
`endif
            end
            CMD_ACT: begin
              open[r_bank]   <= 1'b1;
              row[r_bank]    <= r_row;
`ifdef BUG_TRCD_OFF1
              rw_ok[r_bank]  <= ld(rw_ok[r_bank], C_RCD - 1);
`else
              rw_ok[r_bank]  <= ld(rw_ok[r_bank], C_RCD);
`endif
`ifndef BUG_NO_TRAS
              pre_ok[r_bank] <= ld(pre_ok[r_bank], C_RAS);
`endif
              act_ok[r_bank] <= ld(act_ok[r_bank], C_RC);
`ifndef BUG_NO_TRRD
              act_any        <= ld(act_any, C_RRD);
`endif
            end
            CMD_WR: begin
              cmd_wr         <= 1'b1;
              cmd_wdata      <= r_wdata;
`ifndef BUG_NO_TWR
              pre_ok[r_bank] <= ld(pre_ok[r_bank], C_WR2PRE);
`endif
              wr_ok          <= ld(wr_ok, C_CCD);
`ifndef BUG_NO_WR2RD
              rd_ok          <= ld(rd_ok, C_WR2RD);
`endif
            end
            CMD_RD: begin
              cmd_rd         <= 1'b1;
              pre_ok[r_bank] <= ld(pre_ok[r_bank], C_RD2PRE);
              rd_ok          <= ld(rd_ok, C_CCD);
`ifndef BUG_RD2WR
              wr_ok          <= ld(wr_ok, C_RD2WR);
`endif
            end
            default: ;
          endcase
        end
        default: ;
      endcase
    end
  end

endmodule
