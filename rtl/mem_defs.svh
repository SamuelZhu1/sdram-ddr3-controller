// Shared definitions: memory types, commands and timing tables.
// Wrapped by mem_pkg for simulation and synthesis; the formal flow includes
// this file directly because Yosys does not support package imports.
  localparam int MEM_SDR  = 0;
  localparam int MEM_DDR3 = 1;

  typedef enum logic [3:0] {
    CMD_NOP,
    CMD_MRS,   // mode register set
    CMD_REF,   // auto refresh
    CMD_PRE,   // precharge one bank
    CMD_PREA,  // precharge all banks
    CMD_ACT,   // activate a row
    CMD_WR,
    CMD_RD,
    CMD_ZQCL   // DDR3 ZQ calibration long
  } cmd_e;

  // {cs_n, ras_n, cas_n, we_n}
  function automatic logic [3:0] cmd_pins(input cmd_e c);
    case (c)
      CMD_MRS:  cmd_pins = 4'b0000;
      CMD_REF:  cmd_pins = 4'b0001;
      CMD_PRE,
      CMD_PREA: cmd_pins = 4'b0010;
      CMD_ACT:  cmd_pins = 4'b0011;
      CMD_WR:   cmd_pins = 4'b0100;
      CMD_RD:   cmd_pins = 4'b0101;
      CMD_ZQCL: cmd_pins = 4'b0110;
      default:  cmd_pins = 4'b0111;
    endcase
  endfunction

  // Pin levels back to a command. a10 separates PRE from PREA.
  function automatic cmd_e pins_cmd(input logic cs_n, input logic ras_n,
                                    input logic cas_n, input logic we_n,
                                    input logic a10);
    if (cs_n) pins_cmd = CMD_NOP;
    else
      case ({ras_n, cas_n, we_n})
        3'b000:  pins_cmd = CMD_MRS;
        3'b001:  pins_cmd = CMD_REF;
        3'b010:  pins_cmd = a10 ? CMD_PREA : CMD_PRE;
        3'b011:  pins_cmd = CMD_ACT;
        3'b100:  pins_cmd = CMD_WR;
        3'b101:  pins_cmd = CMD_RD;
        3'b110:  pins_cmd = CMD_ZQCL;
        default: pins_cmd = CMD_NOP;
      endcase
  endfunction

  // ---------------------------------------------------------------
  // Timing tables, in picoseconds.
  // SDR: ISSI IS42S16320D-7.  DDR3: JEDEC DDR3-800 (tCK = 2.5 ns).
  // ---------------------------------------------------------------
  localparam int SDR_T_RCD_PS  = 15_000;
  localparam int SDR_T_RP_PS   = 15_000;
  localparam int SDR_T_RAS_PS  = 37_000;
  localparam int SDR_T_RC_PS   = 60_000;
  localparam int SDR_T_RRD_PS  = 14_000;
  localparam int SDR_T_WR_PS   = 14_000;
  localparam int SDR_T_RFC_PS  = 60_000;
  localparam int SDR_T_MRD_CK  = 2;
  localparam int SDR_T_REFI_PS = 7_812_500;
  localparam int SDR_T_PWR_PS  = 200_000_000;
  localparam int SDR_INIT_REFS = 8;

  localparam int DDR3_T_RCD_PS  = 13_125;
  localparam int DDR3_T_RP_PS   = 13_125;
  localparam int DDR3_T_RAS_PS  = 37_500;
  localparam int DDR3_T_RC_PS   = 50_625;
  localparam int DDR3_T_RRD_PS  = 10_000;   // max(4 ck, 10 ns)
  localparam int DDR3_T_WR_PS   = 15_000;
  localparam int DDR3_T_WTR_PS  = 7_500;    // max(4 ck, 7.5 ns)
  localparam int DDR3_T_RTP_PS  = 7_500;    // max(4 ck, 7.5 ns)
  localparam int DDR3_T_RFC_PS  = 110_000;  // 1 Gb device
  localparam int DDR3_T_REFI_PS = 7_800_000;
  localparam int DDR3_T_CCD_CK  = 4;
  localparam int DDR3_T_MRD_CK  = 4;
  localparam int DDR3_T_MOD_CK  = 12;
  localparam int DDR3_T_ZQI_CK  = 512;
  localparam int DDR3_T_RST_PS  = 200_000_000;
  localparam int DDR3_T_CKE_PS  = 500_000_000;
  localparam int DDR3_CL        = 5;
  localparam int DDR3_CWL       = 5;
  localparam int DDR3_BEATS     = 4;        // burst of 8 = 4 clocks of 2 beats

  function automatic int imax(input int a, input int b);
    imax = (a > b) ? a : b;
  endfunction

  // Nanosecond rules become clock cycles by rounding UP. Rounding down is a
  // silent timing violation.
  function automatic int ps2ck(input int t_ps, input int tck_ps);
`ifdef BUG_ROUND_DOWN
    ps2ck = imax(t_ps / tck_ps, 1);
`else
    ps2ck = imax((t_ps + tck_ps - 1) / tck_ps, 1);
`endif
  endfunction
