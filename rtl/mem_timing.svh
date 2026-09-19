// Timing rules converted to clock cycles. Included inside a module that has
// MEM_TYPE, CLK_PERIOD_PS, CL, T_PWR_CK and T_REFI_CK in scope, so the
// controller and the property checker work from one definition.
  localparam bit DDR = (MEM_TYPE == MEM_DDR3);
  localparam int TCK = CLK_PERIOD_PS;

  // ---- timing rules in clock cycles ---------------------------------
  localparam int C_RCD = DDR ? ps2ck(DDR3_T_RCD_PS, TCK) : ps2ck(SDR_T_RCD_PS, TCK);
  localparam int C_RP  = DDR ? ps2ck(DDR3_T_RP_PS,  TCK) : ps2ck(SDR_T_RP_PS,  TCK);
  localparam int C_RAS = DDR ? ps2ck(DDR3_T_RAS_PS, TCK) : ps2ck(SDR_T_RAS_PS, TCK);
  localparam int C_RC  = DDR ? ps2ck(DDR3_T_RC_PS,  TCK) : ps2ck(SDR_T_RC_PS,  TCK);
  localparam int C_RRD = DDR ? imax(4, ps2ck(DDR3_T_RRD_PS, TCK)) : ps2ck(SDR_T_RRD_PS, TCK);
  localparam int C_WR  = DDR ? ps2ck(DDR3_T_WR_PS,  TCK) : ps2ck(SDR_T_WR_PS,  TCK);
  localparam int C_RFC = DDR ? ps2ck(DDR3_T_RFC_PS, TCK) : ps2ck(SDR_T_RFC_PS, TCK);
  localparam int C_MRD = DDR ? DDR3_T_MRD_CK : SDR_T_MRD_CK;
  localparam int C_MOD = DDR ? DDR3_T_MOD_CK : SDR_T_MRD_CK;
  localparam int C_CCD = DDR ? DDR3_T_CCD_CK : 1;

  // write command to precharge, same bank
  localparam int C_WR2PRE = DDR ? (DDR3_CWL + DDR3_BEATS + C_WR) : C_WR;
  // read command to precharge, same bank
  localparam int C_RD2PRE = DDR ? imax(4, ps2ck(DDR3_T_RTP_PS, TCK)) : 1;
  // read command to write command (data bus turnaround)
  localparam int C_RD2WR  = DDR ? (DDR3_CL + C_CCD + 2 - DDR3_CWL) : (CL + 1);
  // write command to read command
  localparam int C_WR2RD  = DDR ? (DDR3_CWL + DDR3_BEATS + imax(4, ps2ck(DDR3_T_WTR_PS, TCK))) : 1;

  // The refresh interval is a maximum, so it rounds DOWN.
  localparam int C_REFI_SPEC = (DDR ? DDR3_T_REFI_PS : SDR_T_REFI_PS) / TCK;
`ifdef BUG_REFI_SLOW
  localparam int C_REFI = 2 * ((T_REFI_CK != 0) ? T_REFI_CK : C_REFI_SPEC);
`else
  localparam int C_REFI = (T_REFI_CK != 0) ? T_REFI_CK : C_REFI_SPEC;
`endif

  localparam int C_PWR = (T_PWR_CK != 0) ? T_PWR_CK
                       : (DDR ? ps2ck(DDR3_T_RST_PS, TCK) : ps2ck(SDR_T_PWR_PS, TCK));
  localparam int C_CKE = (T_PWR_CK != 0) ? T_PWR_CK : ps2ck(DDR3_T_CKE_PS, TCK);
  localparam int C_XPR = imax(5, ps2ck(DDR3_T_RFC_PS + 10_000, TCK));
  localparam int C_ZQI = DDR3_T_ZQI_CK;
