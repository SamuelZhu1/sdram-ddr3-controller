// Built-in self test for the memory controller.
//
// Three passes over the first N_WORDS words. Each pass writes every word,
// optionally waits (longer than the DRAM retention time, so the data only
// survives if refresh works), then reads every word back and compares.
//   pass 0: address as data      catches address lines stuck or shorted
//   pass 1: inverted pattern     catches data bits stuck at 0 or 1
//   pass 2: scrambled pattern    catches coupling the regular patterns miss
// After the last pass it starts again and counts completed loops.
module mem_bist #(
  parameter int AW          = 25,
  parameter int DW          = 16,
  parameter int N_WORDS     = 1 << 25,
  parameter int PAUSE_CK    = 5_000_000    // 100 ms at 50 MHz
)(
  input  logic          clk,
  input  logic          rst_n,
  input  logic          init_done,
  input  logic          inject_error,     // write one wrong bit, to prove the test can fail
  input  logic          long_pause,       // enable the retention wait

  output logic          req_valid,
  input  logic          req_ready,
  output logic          req_we,
  output logic [AW-1:0] req_addr,
  output logic [DW-1:0] req_wdata,
  input  logic          rsp_valid,
  input  logic [DW-1:0] rsp_rdata,

  output logic          running,
  output logic          failed,           // sticky until reset
  output logic [1:0]    pass,
  output logic [15:0]   loops,            // completed error-free loops
  output logic [15:0]   err_count,
  output logic [AW-1:0] first_fail_addr
);

  typedef enum logic [2:0] {S_WAIT_INIT, S_WRITE, S_PAUSE, S_READ, S_DRAIN, S_NEXT} state_e;
  state_e state;

  logic [AW-1:0] addr;        // next address to request
  logic [AW-1:0] chk_addr;    // address of the next read response
  logic [31:0]   pause_cnt;

  function automatic logic [DW-1:0] pattern(input logic [AW-1:0] a, input logic [1:0] p);
    logic [31:0] x;
    x = 32'(a);
    case (p)
      2'd0:    pattern = DW'(x) ^ DW'(x >> 16);
      2'd1:    pattern = ~(DW'(x) ^ DW'(x >> 16));
      default: pattern = DW'(x * 32'h9E37_79B1 >> 11) ^ DW'(x);
    endcase
  endfunction

  localparam logic [AW-1:0] LAST = AW'(N_WORDS - 1);
  // the one word that is corrupted when inject_error is set
  localparam logic [AW-1:0] BAD_ADDR = AW'(N_WORDS / 3);

  assign req_valid = (state == S_WRITE) || (state == S_READ);
  assign req_we    = (state == S_WRITE);
  assign req_addr  = addr;
  assign req_wdata = pattern(addr, pass) ^ DW'(inject_error && addr == BAD_ADDR);
  assign running   = (state != S_WAIT_INIT);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state           <= S_WAIT_INIT;
      addr            <= '0;
      chk_addr        <= '0;
      pause_cnt       <= '0;
      pass            <= '0;
      loops           <= '0;
      failed          <= 1'b0;
      err_count       <= '0;
      first_fail_addr <= '0;
    end else begin
      // compare every read response, in request order
      if (rsp_valid) begin
        chk_addr <= chk_addr + 1'b1;
        if (rsp_rdata != pattern(chk_addr, pass)) begin
          if (!failed) first_fail_addr <= chk_addr;
          failed <= 1'b1;
          if (err_count != '1) err_count <= err_count + 1'b1;
        end
      end

      case (state)
        S_WAIT_INIT: if (init_done) state <= S_WRITE;

        S_WRITE: if (req_ready) begin
          if (addr == LAST) begin
            addr      <= '0;
            pause_cnt <= long_pause ? PAUSE_CK : 32'd0;
            state     <= S_PAUSE;
          end else begin
            addr <= addr + 1'b1;
          end
        end

        S_PAUSE: begin
          if (pause_cnt == 32'd0) begin
            chk_addr <= '0;
            state    <= S_READ;
          end else begin
            pause_cnt <= pause_cnt - 1'b1;
          end
        end

        S_READ: if (req_ready) begin
          if (addr == LAST) begin
            addr      <= '0;
            pause_cnt <= 32'd64;         // let the last responses arrive
            state     <= S_DRAIN;
          end else begin
            addr <= addr + 1'b1;
          end
        end

        S_DRAIN: begin
          if (pause_cnt == 32'd0) state <= S_NEXT;
          else                    pause_cnt <= pause_cnt - 1'b1;
        end

        S_NEXT: begin
          if (pass == 2'd2) begin
            pass <= '0;
            if (!failed && loops != '1) loops <= loops + 1'b1;
          end else begin
            pass <= pass + 1'b1;
          end
          state <= S_WRITE;
        end

        default: state <= S_WAIT_INIT;
      endcase
    end
  end

endmodule
