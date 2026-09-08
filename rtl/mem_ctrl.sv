// Memory controller top level: the command engine plus one back end.
//   MEM_TYPE = MEM_SDR  : SDR SDRAM pins (sd_*), 16-bit words
//   MEM_TYPE = MEM_DDR3 : DFI bus (dfi_*), 64-bit words (one burst of 8)
// The ports of the back end that is not selected are tied off.
module mem_ctrl
  import mem_pkg::*;
#(
  parameter int MEM_TYPE      = MEM_SDR,
  parameter int CLK_PERIOD_PS = 20_000,
  parameter int CL            = 2,
  parameter int T_PWR_CK      = 0,
  parameter int T_REFI_CK     = 0,
  parameter int REF_FORCE     = 4,
  parameter int REF_MAX       = 8,
  // derived
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

  // SDR SDRAM
  output logic          sd_cke,
  output logic          sd_cs_n,
  output logic          sd_ras_n,
  output logic          sd_cas_n,
  output logic          sd_we_n,
  output logic [1:0]    sd_ba,
  output logic [12:0]   sd_addr,
  output logic [1:0]    sd_dqm,
  output logic [15:0]   sd_dq_o,
  output logic          sd_dq_oe,
  input  logic [15:0]   sd_dq_i,

  // DDR3 DFI
  output logic          dfi_reset_n,
  output logic          dfi_cke,
  output logic          dfi_cs_n,
  output logic          dfi_ras_n,
  output logic          dfi_cas_n,
  output logic          dfi_we_n,
  output logic          dfi_odt,
  output logic [2:0]    dfi_ba,
  output logic [13:0]   dfi_address,
  output logic          dfi_wrdata_en,
  output logic [15:0]   dfi_wrdata,
  output logic          dfi_rddata_en,
  input  logic [15:0]   dfi_rddata,
  input  logic          dfi_rddata_valid
);

  cmd_e          cmd;
  logic [2:0]    cmd_ba;
  logic [13:0]   cmd_a;
  logic          cmd_wr, cmd_rd;
  logic [DW-1:0] cmd_wdata;
  logic          dev_reset_n, dev_cke;

  mem_ctrl_core #(
    .MEM_TYPE(MEM_TYPE), .CLK_PERIOD_PS(CLK_PERIOD_PS), .CL(CL),
    .BA_W(BA_W), .ROW_W(ROW_W), .COL_W(COL_W),
    .COL_SHIFT((MEM_TYPE == MEM_DDR3) ? 3 : 0),
    .DW(DW), .T_PWR_CK(T_PWR_CK), .T_REFI_CK(T_REFI_CK),
    .REF_FORCE(REF_FORCE), .REF_MAX(REF_MAX)
  ) u_core (.*);

  if (MEM_TYPE == MEM_DDR3) begin : g_ddr3
    dfi_backend #(.DW(DW)) u_dfi (.*);
    assign {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} = 4'b1111;
    assign sd_cke   = 1'b0;
    assign sd_ba    = '0;
    assign sd_addr  = '0;
    assign sd_dqm   = '1;
    assign sd_dq_o  = '0;
    assign sd_dq_oe = 1'b0;
  end else begin : g_sdr
    sdr_backend #(.CL(CL), .DW(DW)) u_sdr (.*);
    assign {dfi_cs_n, dfi_ras_n, dfi_cas_n, dfi_we_n} = 4'b1111;
    assign dfi_reset_n   = 1'b0;
    assign dfi_cke       = 1'b0;
    assign dfi_odt       = 1'b0;
    assign dfi_ba        = '0;
    assign dfi_address   = '0;
    assign dfi_wrdata_en = 1'b0;
    assign dfi_wrdata    = '0;
    assign dfi_rddata_en = 1'b0;
  end

endmodule
