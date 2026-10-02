`timescale 1ps/1ps
// Behavioural SDR SDRAM (ISSI IS42S16320D class) that checks the bus.
//
// It stores data like the real chip and, on every command, checks the
// initialization order and every timing rule against wall-clock time in
// picoseconds. The controller counts in clock cycles; checking in time here
// is what catches a wrong nanosecond-to-cycle conversion.
//
// Each broken rule prints one line and increments violation_count. The
// cov_* outputs are coverage bins read by the testbench at the end of a test.
module sdr_sdram_model
  import mem_pkg::*;
#(
  parameter int CL          = 2,
  parameter int CLK_PERIOD_PS = 20_000,
  parameter longint T_PWR_PS  = SDR_T_PWR_PS,
  parameter longint T_REFI_PS = SDR_T_REFI_PS,
  parameter int REF_MAX     = 8
)(
  input  logic        sd_clk,
  input  logic        power_cycle,    // testbench: the chip was power cycled
  input  logic        sd_cke,
  input  logic        sd_cs_n,
  input  logic        sd_ras_n,
  input  logic        sd_cas_n,
  input  logic        sd_we_n,
  input  logic [1:0]  sd_ba,
  input  logic [12:0] sd_addr,
  input  logic [1:0]  sd_dqm,
  input  logic [15:0] dq_in,      // driven by the controller
  input  logic        dq_in_oe,
  output logic [15:0] dq_out,     // driven by the memory
  output logic        dq_out_en,

  output int          violation_count,
  output int          last_violation,
  output logic [35:0] cov_cmd_bank,   // [cmd*4 + bank]
  output logic [80:0] cov_pair,       // [prev*9 + next], NOPs skipped
  output logic [31:0] cov_min         // rule seen at exactly its minimum spacing
);

  // rule ids
  localparam int R_INIT_PWR   = 0;
  localparam int R_INIT_ORDER = 1;
  localparam int R_MRS_VALUE  = 2;
  localparam int R_TMRD       = 3;
  localparam int R_TRCD       = 4;
  localparam int R_TRAS       = 5;
  localparam int R_TRC        = 6;
  localparam int R_TRP        = 7;
  localparam int R_TRRD       = 8;
  localparam int R_TWR        = 9;
  localparam int R_TRFC       = 10;
  localparam int R_RW_CLOSED  = 11;
  localparam int R_ACT_OPEN   = 12;
  localparam int R_REF_OPEN   = 13;
  localparam int R_TURNAROUND = 14;
  localparam int R_REF_STARVE = 15;
  localparam int R_MRS_OPEN   = 16;
  localparam int R_WR_NO_DATA = 17;
  localparam int R_CONTENTION = 18;

  localparam longint NEVER = -64'sd1_000_000_000_000;

  logic [15:0] mem [logic [24:0]];

  logic   [3:0] bank_open;
  logic  [12:0] bank_row [4];
  longint t_act [4];
  longint t_pre [4];
  longint t_wr  [4];
  longint t_act_any, t_ref, t_mrs, t_first_edge, t_init_done;
  longint cyc, cyc_rd;
  logic   seen_edge, seen_prea, seen_mrs, init_ok;
  int     init_refs;
  longint refs_done;
  logic   starve_flagged;
  cmd_e   prev_cmd;

  logic [15:0] rd_data_sr [4];
  logic  [3:0] rd_vld_sr;

  task automatic viol(input int rule, input string name, input longint got, input longint need);
    violation_count <= violation_count + 1;
    last_violation  <= rule;
    $display("[%0t] SDR VIOLATION %s: got %0d ps, need %0d ps", $time, name, got, need);
  endtask

  // Check "now - since >= need". Also record when the rule was met with less
  // than one clock of slack, i.e. the command could not have come a cycle
  // earlier.
  task automatic chk(input int rule, input string name, input longint since, input longint need);
    longint got;
    got = $time - since;
    if (got < need) viol(rule, name, got, need);
    else if (got < need + CLK_PERIOD_PS) cov_min[rule] <= 1'b1;
  endtask

  cmd_e c;
  logic [1:0]  b;
  logic [24:0] a;

  initial begin
    violation_count = 0;
    last_violation  = -1;
    cov_cmd_bank    = '0;
    cov_pair        = '0;
    cov_min         = '0;
    bank_open       = '0;
    seen_edge       = 1'b0;
    seen_prea       = 1'b0;
    seen_mrs        = 1'b0;
    init_ok         = 1'b0;
    init_refs       = 0;
    refs_done       = 0;
    starve_flagged  = 1'b0;
    prev_cmd        = CMD_NOP;
    rd_vld_sr       = '0;
    dq_out_en       = 1'b0;
    dq_out          = '0;
    cyc             = 0;
    cyc_rd          = -1000;
    t_act_any       = NEVER;
    t_ref           = NEVER;
    t_mrs           = NEVER;
    for (int i = 0; i < 4; i++) begin
      t_act[i] = NEVER;
      t_pre[i] = NEVER;
      t_wr[i]  = NEVER;
    end
  end

  always @(posedge sd_clk) begin
    cyc <= cyc + 1;
    if (power_cycle) begin
      // contents and state are gone; initialization is checked again
      seen_edge      <= 1'b0;
      seen_prea      <= 1'b0;
      seen_mrs       <= 1'b0;
      init_ok        <= 1'b0;
      init_refs      <= 0;
      refs_done      <= 0;
      starve_flagged <= 1'b0;
      bank_open      <= '0;
      prev_cmd       <= CMD_NOP;
      rd_vld_sr      <= '0;
      t_ref          <= NEVER;
      t_mrs          <= NEVER;
    end else if (!seen_edge) begin
      seen_edge    <= 1'b1;
      t_first_edge <= $time;
    end

    // read data pipeline: sampled at T0, driven from T(CL-1) to T(CL)
    if (!power_cycle) rd_vld_sr <= {rd_vld_sr[2:0], 1'b0};
    rd_data_sr[1] <= rd_data_sr[0];
    rd_data_sr[2] <= rd_data_sr[1];
    dq_out_en     <= (CL == 2) ? rd_vld_sr[0] : rd_vld_sr[1];
    dq_out        <= (CL == 2) ? rd_data_sr[0] : rd_data_sr[1];

    if (dq_in_oe && dq_out_en) viol(R_CONTENTION, "bus contention", 0, 0);

    c = (sd_cke && !power_cycle) ? pins_cmd(sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sd_addr[10]) : CMD_NOP;
    b = sd_ba;

    if (c != CMD_NOP) begin
      cov_cmd_bank[int'(c) * 4 + int'(b)] <= 1'b1;
      cov_pair[int'(prev_cmd) * 9 + int'(c)] <= 1'b1;
      prev_cmd <= c;

      // rules that apply to every command
      if (seen_edge && ($time - t_first_edge) < T_PWR_PS && !seen_prea)
        viol(R_INIT_PWR, "power-up wait", $time - t_first_edge, T_PWR_PS);
      chk(R_TRFC, "tRFC", t_ref, SDR_T_RFC_PS);
      chk(R_TMRD, "tMRD", t_mrs, longint'(SDR_T_MRD_CK) * CLK_PERIOD_PS);
    end

    case (c)
      CMD_PREA: begin
        for (int i = 0; i < 4; i++) begin
          if (bank_open[i]) begin
            chk(R_TRAS, "tRAS", t_act[i], SDR_T_RAS_PS);
            chk(R_TWR,  "tWR",  t_wr[i],  SDR_T_WR_PS);
          end
          t_pre[i] <= $time;
        end
        bank_open <= '0;
        seen_prea <= 1'b1;
      end

      CMD_PRE: begin
        if (bank_open[b]) begin
          chk(R_TRAS, "tRAS", t_act[b], SDR_T_RAS_PS);
          chk(R_TWR,  "tWR",  t_wr[b],  SDR_T_WR_PS);
        end
        t_pre[b]     <= $time;
        bank_open[b] <= 1'b0;
      end

      CMD_REF: begin
        if (!seen_prea) viol(R_INIT_ORDER, "refresh before precharge-all", 0, 0);
        if (bank_open != '0) viol(R_REF_OPEN, "refresh with a row open", 0, 0);
        for (int i = 0; i < 4; i++) chk(R_TRP, "tRP", t_pre[i], SDR_T_RP_PS);
        t_ref <= $time;
        if (!init_ok) init_refs <= init_refs + 1;
        else          refs_done <= refs_done + 1;
      end

      CMD_MRS: begin
        if (bank_open != '0) viol(R_MRS_OPEN, "mode register set with a row open", 0, 0);
        if (init_refs < SDR_INIT_REFS)
          viol(R_INIT_ORDER, "mode register set before 8 refreshes", init_refs, SDR_INIT_REFS);
        if (sd_addr[6:4] != 3'(CL) || sd_addr[2:0] != 3'b000 || sd_addr[3] != 1'b0)
          viol(R_MRS_VALUE, "mode register value", longint'(sd_addr), 0);
        for (int i = 0; i < 4; i++) chk(R_TRP, "tRP", t_pre[i], SDR_T_RP_PS);
        t_mrs       <= $time;
        seen_mrs    <= 1'b1;
        init_ok     <= 1'b1;
        t_init_done <= $time;
      end

      CMD_ACT: begin
        if (!init_ok) viol(R_INIT_ORDER, "activate before initialization", 0, 0);
        if (bank_open[b]) viol(R_ACT_OPEN, "activate on an open bank", 0, 0);
        chk(R_TRP,  "tRP",  t_pre[b],  SDR_T_RP_PS);
        chk(R_TRC,  "tRC",  t_act[b],  SDR_T_RC_PS);
        chk(R_TRRD, "tRRD", t_act_any, SDR_T_RRD_PS);
        t_act[b]     <= $time;
        t_act_any    <= $time;
        bank_open[b] <= 1'b1;
        bank_row[b]  <= sd_addr;
      end

      CMD_WR: begin
        a = {bank_row[b], b, sd_addr[9:0]};
        if (!bank_open[b]) viol(R_RW_CLOSED, "write to a closed bank", 0, 0);
        else begin
          chk(R_TRCD, "tRCD", t_act[b], SDR_T_RCD_PS);
          if (!dq_in_oe) viol(R_WR_NO_DATA, "write without data driven", 0, 0);
          if ((cyc - cyc_rd) < CL + 1)
            viol(R_TURNAROUND, "read-to-write turnaround (cycles)", cyc - cyc_rd, CL + 1);
          else if ((cyc - cyc_rd) == CL + 1) cov_min[R_TURNAROUND] <= 1'b1;
          if (!sd_dqm[0]) mem[a][7:0]  = dq_in[7:0];
          if (!sd_dqm[1]) mem[a][15:8] = dq_in[15:8];
          t_wr[b] <= $time;
        end
      end

      CMD_RD: begin
        a = {bank_row[b], b, sd_addr[9:0]};
        if (!bank_open[b]) viol(R_RW_CLOSED, "read from a closed bank", 0, 0);
        else begin
          chk(R_TRCD, "tRCD", t_act[b], SDR_T_RCD_PS);
          rd_vld_sr[0]  <= 1'b1;
          rd_data_sr[0] <= mem.exists(a) ? mem[a] : ~a[15:0];
          cyc_rd        <= cyc;
        end
      end

      default: ;
    endcase

    // Refresh must keep up: at most REF_MAX refreshes may be postponed.
    if (init_ok && !starve_flagged &&
        (($time - t_init_done) / T_REFI_PS) > refs_done + REF_MAX + 1) begin
      starve_flagged <= 1'b1;
      viol(R_REF_STARVE, "refresh behind schedule",
           refs_done, ($time - t_init_done) / T_REFI_PS);
    end
  end

endmodule
