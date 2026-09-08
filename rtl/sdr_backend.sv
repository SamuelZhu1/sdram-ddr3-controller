// SDR SDRAM back end: registers the command onto the pins, drives write data
// in the same cycle as the write command, and captures read data CL cycles
// after the read command.
//
// The SDRAM clock is the inverted system clock, so the chip samples the pins
// in the middle of each cycle and read data is stable at the capture edge.
module sdr_backend
  import mem_pkg::*;
#(
  parameter int CL = 2,
  parameter int DW = 16
)(
  input  logic          clk,
  input  logic          rst_n,

  input  cmd_e          cmd,
  input  logic [2:0]    cmd_ba,
  input  logic [13:0]   cmd_a,
  input  logic          cmd_wr,
  input  logic          cmd_rd,
  input  logic [DW-1:0] cmd_wdata,
  input  logic          dev_cke,

  output logic          sd_cke,
  output logic          sd_cs_n,
  output logic          sd_ras_n,
  output logic          sd_cas_n,
  output logic          sd_we_n,
  output logic [1:0]    sd_ba,
  output logic [12:0]   sd_addr,
  output logic [1:0]    sd_dqm,
  output logic [DW-1:0] sd_dq_o,
  output logic          sd_dq_oe,
  input  logic [DW-1:0] sd_dq_i,

  output logic          rsp_valid,
  output logic [DW-1:0] rsp_rdata
);

  logic        rd_q;
  logic [3:0]  rd_sr;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} <= 4'b0111;
      sd_cke    <= 1'b1;
      sd_ba     <= '0;
      sd_addr   <= '0;
      sd_dqm    <= 2'b11;
      sd_dq_o   <= '0;
      sd_dq_oe  <= 1'b0;
      rd_q      <= 1'b0;
      rd_sr     <= '0;
      rsp_valid <= 1'b0;
    end else begin
      {sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n} <= cmd_pins(cmd);
      sd_cke   <= dev_cke;
      sd_ba    <= cmd_ba[1:0];
      sd_addr  <= cmd_a[12:0];
      sd_dqm   <= 2'b00;
      sd_dq_o  <= cmd_wdata;
      sd_dq_oe <= cmd_wr;

      // rd_q is high in the cycle the READ is on the pins; data is captured
      // CL cycles later.
      rd_q  <= cmd_rd;
      rd_sr <= {rd_sr[2:0], rd_q};
`ifdef BUG_RD_LAT
      rsp_valid <= rd_sr[CL-1];
      if (rd_sr[CL-1]) rsp_rdata <= sd_dq_i;
`else
      rsp_valid <= rd_sr[CL-2];
      if (rd_sr[CL-2]) rsp_rdata <= sd_dq_i;
`endif
    end
  end

endmodule
