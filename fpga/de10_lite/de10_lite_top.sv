// DE10-Lite top level: the controller in SDR mode on the board's 64 MB SDRAM
// (ISSI IS42S16320D) with the built-in self test.
//
//   KEY[0]   reset (hold to reset, release to start)
//   SW[0]    inject one wrong bit (the test must report FAIL)
//   SW[1]    add a 100 ms wait between writing and reading back each pass
//   SW[9]    show the error count instead of the loop count
//   LEDR[0]  SDRAM initialized      LEDR[1]  test running
//   LEDR[3:2] current pass          LEDR[8]  at least one full loop passed
//   LEDR[9]  FAIL (sticky)
//   HEX5..0  completed loops, or on failure the first failing word address
module de10_lite_top (
  input  logic        MAX10_CLK1_50,
  input  logic [1:0]  KEY,
  input  logic [9:0]  SW,
  output logic [9:0]  LEDR,
  output logic [7:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,

  output logic [12:0] DRAM_ADDR,
  output logic [1:0]  DRAM_BA,
  output logic        DRAM_CAS_N,
  output logic        DRAM_CKE,
  output logic        DRAM_CLK,
  output logic        DRAM_CS_N,
  inout  wire  [15:0] DRAM_DQ,
  output logic        DRAM_LDQM,
  output logic        DRAM_RAS_N,
  output logic        DRAM_UDQM,
  output logic        DRAM_WE_N
);

  logic clk;
  assign clk = MAX10_CLK1_50;

  // The SDRAM samples on its rising edge, half a cycle after the FPGA changes
  // its outputs, and its read data is stable at the FPGA's next rising edge.
  assign DRAM_CLK = ~clk;

  // reset synchronizer (KEY is active low; MAX 10 registers power up at 0)
  logic [2:0] rst_sr;
  logic       rst_n;
  always_ff @(posedge clk) rst_sr <= {rst_sr[1:0], KEY[0]};
  assign rst_n = rst_sr[2];

  logic [1:0] sw_q0, sw_q1;
  always_ff @(posedge clk) begin
    sw_q0 <= SW[1:0];
    sw_q1 <= sw_q0;
  end

  logic        init_done, req_valid, req_ready, req_we, rsp_valid;
  logic [24:0] req_addr;
  logic [15:0] req_wdata, rsp_rdata;
  logic [15:0] dq_o, dq_i;
  logic        dq_oe;
  logic [1:0]  dqm;

  mem_ctrl #(
    .MEM_TYPE(mem_pkg::MEM_SDR), .CLK_PERIOD_PS(20_000), .CL(2)
  ) u_ctrl (
    .clk, .rst_n, .init_done,
    .req_valid, .req_ready, .req_we, .req_addr, .req_wdata, .rsp_valid, .rsp_rdata,
    .sd_cke(DRAM_CKE), .sd_cs_n(DRAM_CS_N), .sd_ras_n(DRAM_RAS_N), .sd_cas_n(DRAM_CAS_N),
    .sd_we_n(DRAM_WE_N), .sd_ba(DRAM_BA), .sd_addr(DRAM_ADDR), .sd_dqm(dqm),
    .sd_dq_o(dq_o), .sd_dq_oe(dq_oe), .sd_dq_i(dq_i),
    .dfi_reset_n(), .dfi_cke(), .dfi_cs_n(), .dfi_ras_n(), .dfi_cas_n(), .dfi_we_n(),
    .dfi_odt(), .dfi_ba(), .dfi_address(), .dfi_wrdata_en(), .dfi_wrdata(),
    .dfi_rddata_en(), .dfi_rddata('0), .dfi_rddata_valid(1'b0)
  );

  assign DRAM_DQ               = dq_oe ? dq_o : 16'hzzzz;
  assign dq_i                  = DRAM_DQ;
  assign {DRAM_UDQM, DRAM_LDQM} = dqm;

  logic        running, failed;
  logic [1:0]  pass;
  logic [15:0] loops, err_count;
  logic [24:0] first_fail_addr;

  mem_bist #(.AW(25), .DW(16)) u_bist (
    .clk, .rst_n, .init_done,
    .inject_error(sw_q1[0]), .long_pause(sw_q1[1]),
    .req_valid, .req_ready, .req_we, .req_addr, .req_wdata, .rsp_valid, .rsp_rdata,
    .running, .failed, .pass, .loops, .err_count, .first_fail_addr
  );

  assign LEDR[0]   = init_done;
  assign LEDR[1]   = running;
  assign LEDR[3:2] = pass;
  assign LEDR[7:4] = '0;
  assign LEDR[8]   = (loops != '0) && !failed;
  assign LEDR[9]   = failed;

  logic [23:0] shown;
  always_comb begin
    if (SW[9])       shown = {8'h00, err_count};
    else if (failed) shown = first_fail_addr[23:0];
    else             shown = {8'h00, loops};
  end

  // seven-segment decoder, segments active low, bit 7 is the decimal point
  function automatic logic [7:0] seg7(input logic [3:0] v);
    case (v)
      4'h0: seg7 = 8'b1100_0000; 4'h1: seg7 = 8'b1111_1001;
      4'h2: seg7 = 8'b1010_0100; 4'h3: seg7 = 8'b1011_0000;
      4'h4: seg7 = 8'b1001_1001; 4'h5: seg7 = 8'b1001_0010;
      4'h6: seg7 = 8'b1000_0010; 4'h7: seg7 = 8'b1111_1000;
      4'h8: seg7 = 8'b1000_0000; 4'h9: seg7 = 8'b1001_0000;
      4'hA: seg7 = 8'b1000_1000; 4'hB: seg7 = 8'b1000_0011;
      4'hC: seg7 = 8'b1100_0110; 4'hD: seg7 = 8'b1010_0001;
      4'hE: seg7 = 8'b1000_0110; default: seg7 = 8'b1000_1110;
    endcase
  endfunction

  assign HEX0 = seg7(shown[3:0]);
  assign HEX1 = seg7(shown[7:4]);
  assign HEX2 = seg7(shown[11:8]);
  assign HEX3 = seg7(shown[15:12]);
  assign HEX4 = seg7(shown[19:16]);
  assign HEX5 = seg7(shown[23:20]);

endmodule
