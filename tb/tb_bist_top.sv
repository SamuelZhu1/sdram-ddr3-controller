`timescale 1ps/1ps
// Simulation top for the built-in self test: the same controller and BIST
// that go on the board, with the SDRAM model in place of the chip and a
// small word count so a full loop takes milliseconds.
module tb_bist_top
  import mem_pkg::*;
#(
  parameter int N_WORDS  = 6000,
  parameter int PAUSE_CK = 3000
)(
  input  logic        clk,
  input  logic        rst_n,
  input  logic        inject_error,
  input  logic        long_pause,
  output logic        init_done,
  output logic        running,
  output logic        failed,
  output logic [1:0]  pass,
  output logic [15:0] loops,
  output logic [15:0] err_count,
  output logic [24:0] first_fail_addr,
  output int          violation_count
);
  logic        req_valid, req_ready, req_we, rsp_valid;
  logic [24:0] req_addr;
  logic [15:0] req_wdata, rsp_rdata;
  logic        sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n, sd_dq_oe, m_dq_en;
  logic [1:0]  sd_ba, sd_dqm;
  logic [12:0] sd_addr;
  logic [15:0] sd_dq_o, sd_dq_i, m_dq;
  int          last_violation;

  mem_ctrl #(.MEM_TYPE(MEM_SDR), .CLK_PERIOD_PS(20_000), .CL(2), .T_PWR_CK(200)) u_ctrl (
    .clk, .rst_n, .init_done,
    .req_valid, .req_ready, .req_we, .req_addr, .req_wdata, .rsp_valid, .rsp_rdata,
    .sd_cke, .sd_cs_n, .sd_ras_n, .sd_cas_n, .sd_we_n, .sd_ba, .sd_addr, .sd_dqm,
    .sd_dq_o, .sd_dq_oe, .sd_dq_i,
    .dfi_reset_n(), .dfi_cke(), .dfi_cs_n(), .dfi_ras_n(), .dfi_cas_n(), .dfi_we_n(),
    .dfi_odt(), .dfi_ba(), .dfi_address(), .dfi_wrdata_en(), .dfi_wrdata(),
    .dfi_rddata_en(), .dfi_rddata('0), .dfi_rddata_valid(1'b0)
  );

  mem_bist #(.AW(25), .DW(16), .N_WORDS(N_WORDS), .PAUSE_CK(PAUSE_CK)) u_bist (
    .clk, .rst_n, .init_done, .inject_error, .long_pause,
    .req_valid, .req_ready, .req_we, .req_addr, .req_wdata, .rsp_valid, .rsp_rdata,
    .running, .failed, .pass, .loops, .err_count, .first_fail_addr
  );

  sdr_sdram_model #(.CL(2), .CLK_PERIOD_PS(20_000), .T_PWR_PS(200 * 20_000)) u_mem (
    .sd_clk(~clk), .power_cycle(!rst_n), .sd_cke, .sd_cs_n, .sd_ras_n, .sd_cas_n, .sd_we_n,
    .sd_ba, .sd_addr, .sd_dqm,
    .dq_in(sd_dq_o), .dq_in_oe(sd_dq_oe), .dq_out(m_dq), .dq_out_en(m_dq_en),
    .violation_count, .last_violation,
    .cov_cmd_bank(), .cov_pair(), .cov_min()
  );
  assign sd_dq_i = m_dq_en ? m_dq : 16'hDEAD;
endmodule
