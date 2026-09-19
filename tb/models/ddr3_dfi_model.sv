`timescale 1ps/1ps
// DDR3 device behind a DFI PHY, as seen from the controller, with checks.
//
// Models a 1 Gb x8 DDR3-800 device (CL 5, CWL 5, burst of 8) and a PHY with
// a fixed read latency. Checks the JEDEC initialization sequence, every
// command spacing rule against wall-clock time, and the DFI data timing.
module ddr3_dfi_model
  import mem_pkg::*;
#(
  parameter int     CLK_PERIOD_PS = 2_500,
  parameter longint T_RST_PS      = DDR3_T_RST_PS,
  parameter longint T_CKE_PS      = DDR3_T_CKE_PS,
  parameter longint T_REFI_PS     = DDR3_T_REFI_PS,
  parameter int     REF_MAX       = 8,
  parameter int     PHY_RDLAT     = 2
)(
  input  logic        clk,
  input  logic        dfi_reset_n,
  input  logic        dfi_cke,
  input  logic        dfi_cs_n,
  input  logic        dfi_ras_n,
  input  logic        dfi_cas_n,
  input  logic        dfi_we_n,
  input  logic        dfi_odt,
  input  logic [2:0]  dfi_ba,
  input  logic [13:0] dfi_address,
  input  logic        dfi_wrdata_en,
  input  logic [15:0] dfi_wrdata,
  input  logic        dfi_rddata_en,
  output logic [15:0] dfi_rddata,
  output logic        dfi_rddata_valid,

  output int          violation_count,
  output int          last_violation,
  output logic [71:0] cov_cmd_bank,   // [cmd*8 + bank]
  output logic [80:0] cov_pair,
  output logic [31:0] cov_min
);

  localparam int R_RESET_WIDTH = 0;
  localparam int R_CKE_WAIT    = 1;
  localparam int R_TXPR        = 2;
  localparam int R_MR_ORDER    = 3;
  localparam int R_MR_VALUE    = 4;
  localparam int R_TMRD        = 5;
  localparam int R_TMOD        = 6;
  localparam int R_TZQINIT     = 7;
  localparam int R_TRCD        = 8;
  localparam int R_TRAS        = 9;
  localparam int R_TRC         = 10;
  localparam int R_TRP         = 11;
  localparam int R_TRRD        = 12;
  localparam int R_TWR         = 13;
  localparam int R_TRFC        = 14;
  localparam int R_RW_CLOSED   = 15;
  localparam int R_ACT_OPEN    = 16;
  localparam int R_REF_OPEN    = 17;
  localparam int R_TCCD        = 18;
  localparam int R_TWTR        = 19;
  localparam int R_TRTP        = 20;
  localparam int R_RD2WR       = 21;
  localparam int R_WRDATA      = 22;
  localparam int R_RDDATA_EN   = 23;
  localparam int R_REF_STARVE  = 24;
  localparam int R_INIT_ORDER  = 25;
  localparam int R_COL_ALIGN   = 26;
  localparam int R_ODT         = 27;

  localparam longint NEVER = -64'sd1_000_000_000_000;
  localparam longint CK    = CLK_PERIOD_PS;
  localparam int     WL    = DDR3_CWL;
  localparam int     RL    = DDR3_CL;

  function automatic longint lmax(input longint a, input longint b);
    lmax = (a > b) ? a : b;
  endfunction

  localparam longint T_XPR_PS = (5 * CK > DDR3_T_RFC_PS + 10_000) ? 5 * CK : DDR3_T_RFC_PS + 10_000;

  logic [63:0] mem [logic [23:0]];

  logic   [7:0] bank_open;
  logic  [13:0] bank_row [8];
  longint t_act [8];
  longint t_pre [8];
  longint t_wr  [8];
  longint t_rd  [8];
  longint t_act_any, t_ref, t_mrs, t_zq, t_wr_any, t_rd_any;
  longint t_rst_fall, t_rst_rise, t_cke_rise, t_init_done;
  logic   rst_q, cke_q, seen_reset, first_cmd_seen, init_ok, zq_seen;
  int     mr_step;        // 0..4: next expected MR2, MR3, MR1, MR0, done
  longint refs_done;
  logic   starve_flagged;
  cmd_e   prev_cmd;

  // data schedules, index = clocks from now
  logic        wv [16];
  logic [1:0]  wbeat [16];
  logic [23:0] waddr [16];
  logic        rv [16];
  logic [1:0]  rbeat [16];
  logic [23:0] raddr [16];

  logic        ret_v [4];
  logic [15:0] ret_d [4];

  task automatic viol(input int rule, input string name, input longint got, input longint need);
    violation_count <= violation_count + 1;
    last_violation  <= rule;
    $display("[%0t] DDR3 VIOLATION %s: got %0d, need %0d", $time, name, got, need);
  endtask

  task automatic chk(input int rule, input string name, input longint since, input longint need);
    longint got;
    got = $time - since;
    if (got < need) viol(rule, name, got, need);
    else if (got < need + CK) cov_min[rule] <= 1'b1;
  endtask

  cmd_e c;
  logic [2:0]  b;
  logic [23:0] a;
  logic [63:0] word;

  initial begin
    violation_count  = 0;
    last_violation   = -1;
    cov_cmd_bank     = '0;
    cov_pair         = '0;
    cov_min          = '0;
    bank_open        = '0;
    rst_q            = 1'b1;
    cke_q            = 1'b0;
    seen_reset       = 1'b0;
    first_cmd_seen   = 1'b0;
    init_ok          = 1'b0;
    zq_seen          = 1'b0;
    mr_step          = 0;
    refs_done        = 0;
    starve_flagged   = 1'b0;
    prev_cmd         = CMD_NOP;
    dfi_rddata_valid = 1'b0;
    dfi_rddata       = '0;
    t_act_any = NEVER; t_ref = NEVER; t_mrs = NEVER; t_zq = NEVER;
    t_wr_any  = NEVER; t_rd_any = NEVER;
    t_rst_fall = NEVER; t_rst_rise = NEVER; t_cke_rise = NEVER;
    for (int i = 0; i < 8; i++) begin
      t_act[i] = NEVER; t_pre[i] = NEVER; t_wr[i] = NEVER; t_rd[i] = NEVER;
    end
    for (int i = 0; i < 16; i++) begin
      wv[i] = 1'b0; rv[i] = 1'b0;
    end
    for (int i = 0; i < 4; i++) ret_v[i] = 1'b0;
  end

  always @(posedge clk) begin
    // ---- reset and CKE sequencing ----
    rst_q <= dfi_reset_n;
    cke_q <= dfi_cke;
    if (rst_q && !dfi_reset_n) t_rst_fall <= $time;
    if (!dfi_reset_n) begin
      // device reset: back to the start of initialization
      bank_open      <= '0;
      mr_step        <= 0;
      init_ok        <= 1'b0;
      zq_seen        <= 1'b0;
      first_cmd_seen <= 1'b0;
      starve_flagged <= 1'b0;
      refs_done      <= 0;
      t_mrs          <= NEVER;
      t_zq           <= NEVER;
      t_ref          <= NEVER;
    end
    if (!rst_q && dfi_reset_n) begin
      t_rst_rise <= $time;
      seen_reset <= 1'b1;
      if (t_rst_fall != NEVER && ($time - t_rst_fall) < T_RST_PS)
        viol(R_RESET_WIDTH, "reset low time", $time - t_rst_fall, T_RST_PS);
    end
    if (!cke_q && dfi_cke) begin
      t_cke_rise <= $time;
      if (!dfi_reset_n || ($time - t_rst_rise) < T_CKE_PS)
        viol(R_CKE_WAIT, "reset release to CKE", $time - t_rst_rise, T_CKE_PS);
    end

    // ---- data schedules advance one clock ----
    for (int i = 0; i < 15; i++) begin
      wv[i] <= wv[i+1]; wbeat[i] <= wbeat[i+1]; waddr[i] <= waddr[i+1];
      rv[i] <= rv[i+1]; rbeat[i] <= rbeat[i+1]; raddr[i] <= raddr[i+1];
    end
    wv[15] <= 1'b0;
    rv[15] <= 1'b0;

    // write data must arrive exactly in its window
    if (wv[0] != dfi_wrdata_en)
      viol(R_WRDATA, "dfi_wrdata_en outside the write window", longint'(dfi_wrdata_en), longint'(wv[0]));
    if (wv[0] && !dfi_odt) viol(R_ODT, "ODT low during write data", 0, 1);
    if (wv[0] && dfi_wrdata_en) begin
      word = mem.exists(waddr[0]) ? mem[waddr[0]] : 64'h0;
      word[16*wbeat[0] +: 16] = dfi_wrdata;
      mem[waddr[0]] = word;
    end

    // read data enable must match its window; the PHY answers PHY_RDLAT later
    if (rv[0] != dfi_rddata_en)
      viol(R_RDDATA_EN, "dfi_rddata_en outside the read window", longint'(dfi_rddata_en), longint'(rv[0]));
    ret_v[0] <= dfi_rddata_en;
    if (rv[0]) begin
      word     = mem.exists(raddr[0]) ? mem[raddr[0]] : {40'h0, ~raddr[0]};
      ret_d[0] <= word[16*rbeat[0] +: 16];
    end else begin
      ret_d[0] <= 16'hDEAD;
    end
    for (int i = 1; i < 4; i++) begin
      ret_v[i] <= ret_v[i-1];
      ret_d[i] <= ret_d[i-1];
    end
    dfi_rddata_valid <= ret_v[PHY_RDLAT-2];
    dfi_rddata       <= ret_d[PHY_RDLAT-2];

    // ---- commands ----
    c = (dfi_cke && dfi_reset_n)
        ? pins_cmd(dfi_cs_n, dfi_ras_n, dfi_cas_n, dfi_we_n, dfi_address[10]) : CMD_NOP;
    b = dfi_ba;

    if (c != CMD_NOP) begin
      cov_cmd_bank[int'(c) * 8 + int'(b)] <= 1'b1;
      cov_pair[int'(prev_cmd) * 9 + int'(c)] <= 1'b1;
      prev_cmd <= c;

      if (!first_cmd_seen) begin
        first_cmd_seen <= 1'b1;
        chk(R_TXPR, "tXPR", t_cke_rise, T_XPR_PS);
      end
      chk(R_TRFC,    "tRFC",    t_ref, DDR3_T_RFC_PS);
      chk(R_TZQINIT, "tZQinit", t_zq,  longint'(DDR3_T_ZQI_CK) * CK);
      if (c == CMD_MRS) chk(R_TMRD, "tMRD", t_mrs, longint'(DDR3_T_MRD_CK) * CK);
      else              chk(R_TMOD, "tMOD", t_mrs, longint'(DDR3_T_MOD_CK) * CK);
      if (c != CMD_MRS && c != CMD_ZQCL && !init_ok)
        viol(R_INIT_ORDER, "command before initialization finished", longint'(c), 0);
    end

    case (c)
      CMD_MRS: begin
        // expected order MR2, MR3, MR1, MR0
        if (mr_step > 3 ||
            b != ((mr_step == 0) ? 3'd2 : (mr_step == 1) ? 3'd3 : (mr_step == 2) ? 3'd1 : 3'd0))
          viol(R_MR_ORDER, "mode register order", longint'(b), longint'(mr_step));
        if (b == 3'd2 && dfi_address[5:3] != 3'b000)
          viol(R_MR_VALUE, "MR2 CAS write latency", longint'(dfi_address), 0);
        if (b == 3'd0 && (dfi_address[6:4] != 3'b001 || dfi_address[2] != 1'b0 ||
                          dfi_address[11:9] != 3'b010 || dfi_address[8] != 1'b1 ||
                          dfi_address[1:0] != 2'b00))
          viol(R_MR_VALUE, "MR0 value", longint'(dfi_address), 0);
        if (b == 3'd1 && dfi_address[0] != 1'b0)
          viol(R_MR_VALUE, "MR1 DLL disabled", longint'(dfi_address), 0);
        mr_step <= mr_step + 1;
        t_mrs   <= $time;
      end

      CMD_ZQCL: begin
        if (mr_step != 4) viol(R_INIT_ORDER, "ZQCL before the mode registers", mr_step, 4);
        t_zq        <= $time;
        zq_seen     <= 1'b1;
        init_ok     <= 1'b1;
        t_init_done <= $time;
      end

      CMD_PREA: begin
        for (int i = 0; i < 8; i++) begin
          if (bank_open[i]) begin
            chk(R_TRAS, "tRAS", t_act[i], DDR3_T_RAS_PS);
            chk(R_TWR,  "tWR",  t_wr[i],  (WL + DDR3_BEATS) * CK + DDR3_T_WR_PS);
            chk(R_TRTP, "tRTP", t_rd[i],  lmax(4 * CK, DDR3_T_RTP_PS));
          end
          t_pre[i] <= $time;
        end
        bank_open <= '0;
      end

      CMD_PRE: begin
        if (bank_open[b]) begin
          chk(R_TRAS, "tRAS", t_act[b], DDR3_T_RAS_PS);
          chk(R_TWR,  "tWR",  t_wr[b],  (WL + DDR3_BEATS) * CK + DDR3_T_WR_PS);
          chk(R_TRTP, "tRTP", t_rd[b],  lmax(4 * CK, DDR3_T_RTP_PS));
        end
        t_pre[b]     <= $time;
        bank_open[b] <= 1'b0;
      end

      CMD_REF: begin
        if (bank_open != '0) viol(R_REF_OPEN, "refresh with a row open", 0, 0);
        for (int i = 0; i < 8; i++) chk(R_TRP, "tRP", t_pre[i], DDR3_T_RP_PS);
        t_ref     <= $time;
        refs_done <= refs_done + 1;
      end

      CMD_ACT: begin
        if (bank_open[b]) viol(R_ACT_OPEN, "activate on an open bank", 0, 0);
        chk(R_TRP,  "tRP",  t_pre[b],  DDR3_T_RP_PS);
        chk(R_TRC,  "tRC",  t_act[b],  DDR3_T_RC_PS);
        chk(R_TRRD, "tRRD", t_act_any, lmax(4 * CK, DDR3_T_RRD_PS));
        t_act[b]     <= $time;
        t_act_any    <= $time;
        bank_open[b] <= 1'b1;
        bank_row[b]  <= dfi_address;
      end

      CMD_WR: begin
        a = {b, bank_row[b], dfi_address[9:3]};
        if (!bank_open[b]) viol(R_RW_CLOSED, "write to a closed bank", 0, 0);
        else begin
          if (dfi_address[2:0] != 3'b000) viol(R_COL_ALIGN, "burst not aligned", 0, 0);
          chk(R_TRCD,  "tRCD",  t_act[b],  DDR3_T_RCD_PS);
          chk(R_TCCD,  "tCCD",  t_wr_any,  longint'(DDR3_T_CCD_CK) * CK);
          chk(R_RD2WR, "read-to-write", t_rd_any, (RL + DDR3_T_CCD_CK + 2 - WL) * CK);
          // data window: WL-1 clocks after this sample, 4 beats (the shift
          // above has already moved the schedule by one)
          for (int k = 0; k < 4; k++) begin
            wv[WL - 2 + k]    <= 1'b1;
            wbeat[WL - 2 + k] <= 2'(k);
            waddr[WL - 2 + k] <= a;
          end
          t_wr[b]  <= $time;
          t_wr_any <= $time;
        end
      end

      CMD_RD: begin
        a = {b, bank_row[b], dfi_address[9:3]};
        if (!bank_open[b]) viol(R_RW_CLOSED, "read from a closed bank", 0, 0);
        else begin
          if (dfi_address[2:0] != 3'b000) viol(R_COL_ALIGN, "burst not aligned", 0, 0);
          chk(R_TRCD, "tRCD", t_act[b], DDR3_T_RCD_PS);
          chk(R_TCCD, "tCCD", t_rd_any, longint'(DDR3_T_CCD_CK) * CK);
          chk(R_TWTR, "write-to-read", t_wr_any,
              (WL + DDR3_BEATS) * CK + lmax(4 * CK, DDR3_T_WTR_PS));
          for (int k = 0; k < 4; k++) begin
            rv[RL - 2 + k]    <= 1'b1;
            rbeat[RL - 2 + k] <= 2'(k);
            raddr[RL - 2 + k] <= a;
          end
          t_rd[b]  <= $time;
          t_rd_any <= $time;
        end
      end

      default: ;
    endcase

    if (init_ok && !starve_flagged &&
        (($time - t_init_done) / T_REFI_PS) > refs_done + REF_MAX + 1) begin
      starve_flagged <= 1'b1;
      viol(R_REF_STARVE, "refresh behind schedule",
           refs_done, ($time - t_init_done) / T_REFI_PS);
    end
  end

endmodule
