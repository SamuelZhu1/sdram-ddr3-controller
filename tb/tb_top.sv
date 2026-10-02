`timescale 1ps/1ps
// Simulation top: controller + bus model + coverage and property monitors.
module tb_top
  import mem_pkg::*;
#(
  parameter int MEM_TYPE      = MEM_SDR,
  parameter int CLK_PERIOD_PS = 20_000,
  parameter int CL            = 2,
  parameter int T_PWR_CK      = 200,
  parameter int T_REFI_CK     = 0,
  parameter int REF_FORCE     = 4,
  parameter int REF_MAX       = 8,
  parameter int BA_W  = (MEM_TYPE == MEM_DDR3) ? 3  : 2,
  parameter int ROW_W = (MEM_TYPE == MEM_DDR3) ? 14 : 13,
  parameter int COL_W = (MEM_TYPE == MEM_DDR3) ? 7  : 10,
  parameter int DW    = (MEM_TYPE == MEM_DDR3) ? 64 : 16,
  parameter int AW    = ROW_W + BA_W + COL_W
)(
  input  logic          clk,
  input  logic          rst_n,
  output logic          init_done,
  input  logic          req_valid,
  output logic          req_ready,
  input  logic          req_we,
  input  logic [AW-1:0] req_addr,
  input  logic [DW-1:0] req_wdata,
  output logic          rsp_valid,
  output logic [DW-1:0] rsp_rdata,

  output int            violation_count,
  output int            last_violation,
  output int            prop_fail_count,
  output logic [35:0]   cov_cmd_bank_sdr,
  output logic [71:0]   cov_cmd_bank_ddr3,
  output logic [80:0]   cov_pair,
  output logic [31:0]   cov_min,
  output logic [31:0]   cov_ctrl
);

  logic        sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
  logic [1:0]  sd_ba;
  logic [12:0] sd_addr;
  logic [1:0]  sd_dqm;
  logic [15:0] sd_dq_o, sd_dq_i;
  logic        sd_dq_oe;

  logic        dfi_reset_n, dfi_cke, dfi_cs_n, dfi_ras_n, dfi_cas_n, dfi_we_n, dfi_odt;
  logic [2:0]  dfi_ba;
  logic [13:0] dfi_address;
  logic        dfi_wrdata_en, dfi_rddata_en, dfi_rddata_valid;
  logic [15:0] dfi_wrdata, dfi_rddata;

  mem_ctrl #(
    .MEM_TYPE(MEM_TYPE), .CLK_PERIOD_PS(CLK_PERIOD_PS), .CL(CL),
    .T_PWR_CK(T_PWR_CK), .T_REFI_CK(T_REFI_CK),
    .REF_FORCE(REF_FORCE), .REF_MAX(REF_MAX)
  ) u_dut (.*);

  // What the model's refresh and power-up checks should expect when the
  // testbench shortens them.
  localparam longint REFI_PS = (T_REFI_CK != 0) ? longint'(T_REFI_CK) * CLK_PERIOD_PS
                             : ((MEM_TYPE == MEM_DDR3) ? DDR3_T_REFI_PS : SDR_T_REFI_PS);
  localparam longint PWR_PS  = (T_PWR_CK != 0) ? longint'(T_PWR_CK) * CLK_PERIOD_PS
                             : ((MEM_TYPE == MEM_DDR3) ? DDR3_T_RST_PS : SDR_T_PWR_PS);

  if (MEM_TYPE == MEM_DDR3) begin : g_ddr3
    ddr3_dfi_model #(
      .CLK_PERIOD_PS(CLK_PERIOD_PS), .T_RST_PS(PWR_PS), .T_CKE_PS(PWR_PS),
      .T_REFI_PS(REFI_PS), .REF_MAX(REF_MAX)
    ) u_mem (
      .clk, .dfi_reset_n, .dfi_cke, .dfi_cs_n, .dfi_ras_n, .dfi_cas_n, .dfi_we_n,
      .dfi_odt, .dfi_ba, .dfi_address, .dfi_wrdata_en, .dfi_wrdata,
      .dfi_rddata_en, .dfi_rddata, .dfi_rddata_valid,
      .violation_count, .last_violation,
      .cov_cmd_bank(cov_cmd_bank_ddr3), .cov_pair, .cov_min
    );
    assign sd_dq_i          = '0;
    assign cov_cmd_bank_sdr = '0;
  end else begin : g_sdr
    logic [15:0] m_dq;
    logic        m_dq_en;
    sdr_sdram_model #(
      .CL(CL), .CLK_PERIOD_PS(CLK_PERIOD_PS), .T_PWR_PS(PWR_PS),
      .T_REFI_PS(REFI_PS), .REF_MAX(REF_MAX)
    ) u_mem (
      .sd_clk(~clk), .power_cycle(!rst_n), .sd_cke, .sd_cs_n, .sd_ras_n, .sd_cas_n, .sd_we_n,
      .sd_ba, .sd_addr, .sd_dqm,
      .dq_in(sd_dq_o), .dq_in_oe(sd_dq_oe), .dq_out(m_dq), .dq_out_en(m_dq_en),
      .violation_count, .last_violation,
      .cov_cmd_bank(cov_cmd_bank_sdr), .cov_pair, .cov_min
    );
    // An undriven bus reads back as a recognisable wrong value.
    assign sd_dq_i           = m_dq_en ? m_dq : 16'hDEAD;
    assign dfi_rddata        = '0;
    assign dfi_rddata_valid  = 1'b0;
    assign cov_cmd_bank_ddr3 = '0;
  end

  mem_ctrl_cov   u_cov   (.clk, .rst_n, .cov_ctrl);
  mem_ctrl_props #(
    .MEM_TYPE(MEM_TYPE), .CLK_PERIOD_PS(CLK_PERIOD_PS), .CL(CL),
    .T_PWR_CK(T_PWR_CK), .T_REFI_CK(T_REFI_CK), .BA_W(BA_W),
    .REF_MAX(REF_MAX), .REF_FORCE(REF_FORCE)
  ) u_props (
    .clk, .rst_n,
    .cmd          (u_dut.u_core.cmd),
    .cmd_ba       (u_dut.u_core.cmd_ba),
    .init_done,
    .req_valid, .req_ready,
    .have_req     (u_dut.u_core.have_req),
    .d_fire       (u_dut.u_core.d_fire),
    .ref_debt     (u_dut.u_core.ref_debt),
    .ref_overflow (u_dut.u_core.ref_overflow),
    .fail_count   (prop_fail_count)
  );

endmodule
