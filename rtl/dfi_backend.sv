// DDR3 back end on a DFI bus (controller clock = memory clock).
//
// A 64-bit user word is one burst of 8 on an 8-bit device. DFI carries the
// rising-edge and falling-edge bytes together, so a burst is 4 clocks of 16
// bits. Write data starts CWL-1 clocks after the write command; the read data
// enable starts CL-1 clocks after the read command and the PHY answers with
// dfi_rddata_valid.
module dfi_backend
  import mem_pkg::*;
#(
  parameter int DW = 64
)(
  input  logic          clk,
  input  logic          rst_n,

  input  cmd_e          cmd,
  input  logic [2:0]    cmd_ba,
  input  logic [13:0]   cmd_a,
  input  logic          cmd_wr,
  input  logic          cmd_rd,
  input  logic [DW-1:0] cmd_wdata,
  input  logic          dev_reset_n,
  input  logic          dev_cke,

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
  input  logic          dfi_rddata_valid,

  output logic          rsp_valid,
  output logic [DW-1:0] rsp_rdata
);

  localparam int WDLY = DDR3_CWL - 1;   // stages from core strobe to data start
  localparam int RDLY = DDR3_CL  - 1;

  logic [WDLY-1:0] wv;
  logic [DW-1:0]   wd [WDLY];
  logic [RDLY-1:0] rv;

  logic [DW-1:0] wbuf;
  logic [1:0]    wbeat;
  logic [1:0]    rbeat_en;
  logic [1:0]    rbeat;
  logic [47:0]   rbuf;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      {dfi_cs_n, dfi_ras_n, dfi_cas_n, dfi_we_n} <= 4'b0111;
      dfi_reset_n   <= 1'b0;
      dfi_cke       <= 1'b0;
      dfi_odt       <= 1'b0;
      dfi_ba        <= '0;
      dfi_address   <= '0;
      dfi_wrdata_en <= 1'b0;
      dfi_wrdata    <= '0;
      dfi_rddata_en <= 1'b0;
      wv            <= '0;
      rv            <= '0;
      wbeat         <= '0;
      rbeat_en      <= '0;
      rbeat         <= '0;
      rsp_valid     <= 1'b0;
    end else begin
      {dfi_cs_n, dfi_ras_n, dfi_cas_n, dfi_we_n} <= cmd_pins(cmd);
      dfi_reset_n <= dev_reset_n;
      dfi_cke     <= dev_cke;
      dfi_ba      <= cmd_ba;
      dfi_address <= cmd_a;

      // delay lines
      wv    <= {wv[WDLY-2:0], cmd_wr};
      wd[0] <= cmd_wdata;
      for (int i = 1; i < WDLY; i++) wd[i] <= wd[i-1];
      rv    <= {rv[RDLY-2:0], cmd_rd};

      // write data: 4 beats, low word first
      if (wv[WDLY-1]) begin
        wbuf          <= wd[WDLY-1];
        dfi_wrdata    <= wd[WDLY-1][15:0];
        dfi_wrdata_en <= 1'b1;
        wbeat         <= 2'd1;
      end else if (wbeat != 2'd0) begin
`ifdef BUG_WBEAT_ORDER
        dfi_wrdata    <= wbuf[16*(3-wbeat) +: 16];
`else
        dfi_wrdata    <= wbuf[16*wbeat +: 16];
`endif
        dfi_wrdata_en <= 1'b1;
        wbeat         <= wbeat + 2'd1;   // wraps to 0 after the 4th beat
      end else begin
        dfi_wrdata_en <= 1'b0;
      end
      dfi_odt <= wv[WDLY-1] || (wbeat != 2'd0);

      // read data enable: 4 clocks
      if (rv[RDLY-1]) begin
        dfi_rddata_en <= 1'b1;
        rbeat_en      <= 2'd1;
      end else if (rbeat_en != 2'd0) begin
        dfi_rddata_en <= 1'b1;
        rbeat_en      <= rbeat_en + 2'd1;
      end else begin
        dfi_rddata_en <= 1'b0;
      end

      // read data: collect 4 beats into one response
      rsp_valid <= 1'b0;
      if (dfi_rddata_valid) begin
        rbeat <= rbeat + 2'd1;
        if (rbeat == 2'd3) begin
          rsp_valid <= 1'b1;
          rsp_rdata <= {dfi_rddata, rbuf};
        end else begin
          rbuf[16*rbeat +: 16] <= dfi_rddata;
        end
      end
    end
  end

endmodule
