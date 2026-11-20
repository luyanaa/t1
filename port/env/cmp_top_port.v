// =====================================================================
// port/env/cmp_top_port.v - Phase-1 open-source top-level testbench for
// the full OpenSPARC T1 chip (OpenSPARCT1: 8 sparc cores + 4 sctag L2 +
// scbuf/scdata + 4 dram controllers + ccx + jbi + ctu + efc + pads).
//
// Phase-1 scope: compile + elaborate + reset only (no SJM/PLI, no boot).
//
// NOTES:
//  - Top module MUST be named `cmp_top` and the chip instance `iop`:
//    the RTL's only upward cross-module reference is `CTU_PATH =
//    cmp_top.iop.ctu (design/sys/iop/ctu), so both names are load-bearing.
//  - DRAM0..3 are wired to the Sun behavioral channel model cmp_dram
//    (port/env/dram/cmp_dram.v), matching verif/env/cmp/cmp_top.v:607.
//  - DRAMx_RST_L / dram_gclk / cmp_grst are read from iop internals via
//    downward XMR (legal for a parent reading a child net), exactly like
//    the legacy bench (cmp_top.v:634, cmp_top.v:671).
// =====================================================================

`timescale 1ps/1ps

module cmp_top;

  //---------------------------------------------------------------
  // JBus / core clocks
  //---------------------------------------------------------------
  reg jbus_clk_r = 1'b0;
  reg jbus_clk2_r = 1'b0;
  wire [1:0] J_CLK = {jbus_clk2_r, jbus_clk_r};

  // ~1 GHz equivalent JBus clock (1 ns half period), scaled ps timescale.
  always #500 jbus_clk_r  = ~jbus_clk_r;
  always #500 jbus_clk2_r = ~jbus_clk2_r;

  //---------------------------------------------------------------
  // Static / reset inputs (keep low during POR, deassert after)
  //---------------------------------------------------------------
  reg PWRON_RST_L = 1'b0;       // power-on reset, active low
  reg J_RST_L     = 1'b0;       // jbus reset, active low
  reg TEST_MODE   = 1'b0;
  reg PLL_CHAR_IN = 1'b0;
  reg TCK   = 1'b0;
  reg TCK2  = 1'b0;
  reg TRST_L = 1'b0;            // jtag reset asserted for the whole run
  reg TDI   = 1'b0;
  reg TMS   = 1'b0;
  reg TEMP_TRIG    = 1'b0;
  reg CLK_STRETCH  = 1'b0;
  reg DO_BIST      = 1'b0;
  reg EXT_INT_L    = 1'b1;      // no external interrupt
  reg BURNIN       = 1'b0;
  reg PMI          = 1'b0;
  reg PGRM_EN      = 1'b0;      // efuse programming disabled (legacy: cmp_top.v:761)
  reg VREG_SELBG_L = 1'b0;
  reg TRIGIN       = 1'b0;
  reg HSTL_VREF    = 1'b0;
  reg J_PAR        = 1'b0;
  reg DTL_L_VREF   = 1'b0;
  reg DTL_R_VREF   = 1'b0;
  reg JBUS_P_REF_RES = 1'b0;    // resistor strap pins (analog in RTL, tie 0)
  reg JBUS_N_REF_RES = 1'b0;
  reg DRAM01_P_REF_RES = 1'b0;
  reg DRAM01_N_REF_RES = 1'b0;
  reg DRAM23_P_REF_RES = 1'b0;
  reg DRAM23_N_REF_RES = 1'b0;
  reg DBG_VREF     = 1'b0;
  reg [2:0] J_PACK4 = 3'b0;     // packaging straps
  reg [2:0] J_PACK5 = 3'b0;

  //---------------------------------------------------------------
  // JBus slave-side tie-offs: no external JBus master requests.
  //---------------------------------------------------------------
  wire J_REQ4_IN_L = 1'b1;      // request lines idle high (active low)
  wire J_REQ5_IN_L = 1'b1;

  //---------------------------------------------------------------
  // DDR pad <-> behavioral DRAM channel model (cmp_dram)
  //---------------------------------------------------------------
  wire        DRAM0_RAS_L, DRAM0_CAS_L, DRAM0_WE_L, DRAM0_CKE;
  wire [3:0]  DRAM0_CS_L, DRAM0_CK_P, DRAM0_CK_N;
  wire [14:0] DRAM0_ADDR;
  wire [2:0]  DRAM0_BA;
  wire [127:0] DRAM0_DQ;
  wire [15:0]  DRAM0_CB;
  wire [35:0]  DRAM0_DQS;

  wire        DRAM1_RAS_L, DRAM1_CAS_L, DRAM1_WE_L, DRAM1_CKE;
  wire [3:0]  DRAM1_CS_L, DRAM1_CK_P, DRAM1_CK_N;
  wire [14:0] DRAM1_ADDR;
  wire [2:0]  DRAM1_BA;
  wire [127:0] DRAM1_DQ;
  wire [15:0]  DRAM1_CB;
  wire [35:0]  DRAM1_DQS;

  wire        DRAM2_RAS_L, DRAM2_CAS_L, DRAM2_WE_L, DRAM2_CKE;
  wire [3:0]  DRAM2_CS_L, DRAM2_CK_P, DRAM2_CK_N;
  wire [14:0] DRAM2_ADDR;
  wire [2:0]  DRAM2_BA;
  wire [127:0] DRAM2_DQ;
  wire [15:0]  DRAM2_CB;
  wire [35:0]  DRAM2_DQS;

  wire        DRAM3_RAS_L, DRAM3_CAS_L, DRAM3_WE_L, DRAM3_CKE;
  wire [3:0]  DRAM3_CS_L, DRAM3_CK_P, DRAM3_CK_N;
  wire [14:0] DRAM3_ADDR;
  wire [2:0]  DRAM3_BA;
  wire [127:0] DRAM3_DQ;
  wire [15:0]  DRAM3_CB;
  wire [35:0]  DRAM3_DQS;

  // I2C (SPD) tie-offs: SCL idle low, SDA pulled up, no DIMM management.
  wire DRAM02_SDA = 1'b1;
  wire DRAM13_SDA = 1'b1;
  wire DRAM02_SCL = 1'b0;
  wire DRAM13_SCL = 1'b0;

  wire        XXWP = 1'b0;       // write-protect off
  wire [2:0]  XXSA = 3'b000;     // no DIMM straps
  wire        DRAM_FAIL_OVER = 1'b0;
  wire [5:0]  DRAM_FAIL_PART = 6'b0;

  // cmp_dram sees the chip's own grst/gclk (same nets the legacy bench
  // drives back into the pads, see verif/env/cmp/cmp_top.v:634,671).
  wire cmp_grst  = ~iop.cmp_grst_out_l;
  wire dram_gclk = iop.dram_gclk;

  //---------------------------------------------------------------
  // The chip.  Instance name `iop` is REQUIRED (see header note).
  //---------------------------------------------------------------
  OpenSPARCT1 iop(
    // JBus / core clocks + resets
    .J_CLK            (J_CLK),
    .PWRON_RST_L      (PWRON_RST_L),
    .J_RST_L          (J_RST_L),
    // static / reference inputs
    .TEST_MODE        (TEST_MODE),
    .PLL_CHAR_IN      (PLL_CHAR_IN),
    .TCK              (TCK),
    .TCK2             (TCK2),
    .TRST_L           (TRST_L),
    .TDI              (TDI),
    .TMS              (TMS),
    .TEMP_TRIG        (TEMP_TRIG),
    .CLK_STRETCH      (CLK_STRETCH),
    .DO_BIST          (DO_BIST),
    .EXT_INT_L        (EXT_INT_L),
    .BURNIN           (BURNIN),
    .PMI              (PMI),
    .PGRM_EN          (PGRM_EN),
    .VREG_SELBG_L     (VREG_SELBG_L),
    .TRIGIN           (TRIGIN),
    .HSTL_VREF        (HSTL_VREF),
    .J_PAR            (J_PAR),
    .J_PACK4          (J_PACK4),
    .J_PACK5          (J_PACK5),
    .DTL_L_VREF       (DTL_L_VREF),
    .DTL_R_VREF       (DTL_R_VREF),
    .JBUS_P_REF_RES   (JBUS_P_REF_RES),
    .JBUS_N_REF_RES   (JBUS_N_REF_RES),
    .DRAM01_P_REF_RES (DRAM01_P_REF_RES),
    .DRAM01_N_REF_RES (DRAM01_N_REF_RES),
    .DRAM23_P_REF_RES (DRAM23_P_REF_RES),
    .DRAM23_N_REF_RES (DRAM23_N_REF_RES),
    .DBG_VREF         (DBG_VREF),
    // JBus slave side: no external master
    .J_REQ4_IN_L      (J_REQ4_IN_L),
    .J_REQ5_IN_L      (J_REQ5_IN_L),
    // DDR channel 0
    .DRAM0_RAS_L      (DRAM0_RAS_L),
    .DRAM0_CAS_L      (DRAM0_CAS_L),
    .DRAM0_WE_L       (DRAM0_WE_L),
    .DRAM0_CS_L       (DRAM0_CS_L),
    .DRAM0_CKE        (DRAM0_CKE),
    .DRAM0_ADDR       (DRAM0_ADDR),
    .DRAM0_BA         (DRAM0_BA),
    .DRAM0_CK_P       (DRAM0_CK_P),
    .DRAM0_CK_N       (DRAM0_CK_N),
    .DRAM0_DQ         (DRAM0_DQ),
    .DRAM0_CB         (DRAM0_CB),
    .DRAM0_DQS        (DRAM0_DQS),
    // DDR channel 1
    .DRAM1_RAS_L      (DRAM1_RAS_L),
    .DRAM1_CAS_L      (DRAM1_CAS_L),
    .DRAM1_WE_L       (DRAM1_WE_L),
    .DRAM1_CS_L       (DRAM1_CS_L),
    .DRAM1_CKE        (DRAM1_CKE),
    .DRAM1_ADDR       (DRAM1_ADDR),
    .DRAM1_BA         (DRAM1_BA),
    .DRAM1_CK_P       (DRAM1_CK_P),
    .DRAM1_CK_N       (DRAM1_CK_N),
    .DRAM1_DQ         (DRAM1_DQ),
    .DRAM1_CB         (DRAM1_CB),
    .DRAM1_DQS        (DRAM1_DQS),
    // DDR channel 2
    .DRAM2_RAS_L      (DRAM2_RAS_L),
    .DRAM2_CAS_L      (DRAM2_CAS_L),
    .DRAM2_WE_L       (DRAM2_WE_L),
    .DRAM2_CS_L       (DRAM2_CS_L),
    .DRAM2_CKE        (DRAM2_CKE),
    .DRAM2_ADDR       (DRAM2_ADDR),
    .DRAM2_BA         (DRAM2_BA),
    .DRAM2_CK_P       (DRAM2_CK_P),
    .DRAM2_CK_N       (DRAM2_CK_N),
    .DRAM2_DQ         (DRAM2_DQ),
    .DRAM2_CB         (DRAM2_CB),
    .DRAM2_DQS        (DRAM2_DQS),
    // DDR channel 3
    .DRAM3_RAS_L      (DRAM3_RAS_L),
    .DRAM3_CAS_L      (DRAM3_CAS_L),
    .DRAM3_WE_L       (DRAM3_WE_L),
    .DRAM3_CS_L       (DRAM3_CS_L),
    .DRAM3_CKE        (DRAM3_CKE),
    .DRAM3_ADDR       (DRAM3_ADDR),
    .DRAM3_BA         (DRAM3_BA),
    .DRAM3_CK_P       (DRAM3_CK_P),
    .DRAM3_CK_N       (DRAM3_CK_N),
    .DRAM3_DQ         (DRAM3_DQ),
    .DRAM3_CB         (DRAM3_CB),
    .DRAM3_DQS        (DRAM3_DQS)
    // All remaining ports (SPARE_*/inout pads, VDD sense, SSI, PMO,
    // DBG_*, J_AD/J_ADP/J_ADTYPE, CLKOBS, ...) are intentionally left
    // unconnected: they are inouts that idle tri-stated in Phase 1.
  );

  // Behavioral 4-channel DDR2 + ECC environment (Sun cmp_dram).
  cmp_dram cmp_dram(
    // inouts
    .DRAM0_CB         (DRAM0_CB),
    .DRAM0_DQ         (DRAM0_DQ),
    .DRAM0_DQS        (DRAM0_DQS),
    .DRAM1_CB         (DRAM1_CB),
    .DRAM1_DQ         (DRAM1_DQ),
    .DRAM1_DQS        (DRAM1_DQS),
    .DRAM2_CB         (DRAM2_CB),
    .DRAM2_DQ         (DRAM2_DQ),
    .DRAM2_DQS        (DRAM2_DQS),
    .DRAM3_CB         (DRAM3_CB),
    .DRAM3_DQ         (DRAM3_DQ),
    .DRAM3_DQS        (DRAM3_DQS),
    .DRAM02_SDA       (DRAM02_SDA),
    .DRAM13_SDA       (DRAM13_SDA),
    // inputs
    .DRAM02_SCL       (DRAM02_SCL),
    .DRAM13_SCL       (DRAM13_SCL),
    .DRAM0_ADDR       (DRAM0_ADDR),
    .DRAM0_BA         (DRAM0_BA),
    .DRAM0_CAS_L      (DRAM0_CAS_L),
    .DRAM0_CKE        (DRAM0_CKE),
    .DRAM0_CK_N       (DRAM0_CK_N),
    .DRAM0_CK_P       (DRAM0_CK_P),
    .DRAM0_CS_L       (DRAM0_CS_L),
    .DRAM0_RAS_L      (DRAM0_RAS_L),
    .DRAM0_RST_L      (iop.cmp_grst_out_l),
    .DRAM0_WE_L       (DRAM0_WE_L),
    .DRAM1_ADDR       (DRAM1_ADDR),
    .DRAM1_BA         (DRAM1_BA),
    .DRAM1_CAS_L      (DRAM1_CAS_L),
    .DRAM1_CKE        (DRAM1_CKE),
    .DRAM1_CK_N       (DRAM1_CK_N),
    .DRAM1_CK_P       (DRAM1_CK_P),
    .DRAM1_CS_L       (DRAM1_CS_L),
    .DRAM1_RAS_L      (DRAM1_RAS_L),
    .DRAM1_RST_L      (iop.cmp_grst_out_l),
    .DRAM1_WE_L       (DRAM1_WE_L),
    .DRAM2_ADDR       (DRAM2_ADDR),
    .DRAM2_BA         (DRAM2_BA),
    .DRAM2_CAS_L      (DRAM2_CAS_L),
    .DRAM2_CKE        (DRAM2_CKE),
    .DRAM2_CK_N       (DRAM2_CK_N),
    .DRAM2_CK_P       (DRAM2_CK_P),
    .DRAM2_CS_L       (DRAM2_CS_L),
    .DRAM2_RAS_L      (DRAM2_RAS_L),
    .DRAM2_RST_L      (iop.cmp_grst_out_l),
    .DRAM2_WE_L       (DRAM2_WE_L),
    .DRAM3_ADDR       (DRAM3_ADDR),
    .DRAM3_BA         (DRAM3_BA),
    .DRAM3_CAS_L      (DRAM3_CAS_L),
    .DRAM3_CKE        (DRAM3_CKE),
    .DRAM3_CK_N       (DRAM3_CK_N),
    .DRAM3_CK_P       (DRAM3_CK_P),
    .DRAM3_CS_L       (DRAM3_CS_L),
    .DRAM3_RAS_L      (DRAM3_RAS_L),
    .DRAM3_RST_L      (iop.cmp_grst_out_l),
    .DRAM3_WE_L       (DRAM3_WE_L),
    .DRAM_FAIL_OVER   (DRAM_FAIL_OVER),
    .DRAM_FAIL_PART   (DRAM_FAIL_PART),
    .XXSA             (XXSA),
    .XXWP             (XXWP),
    .cmp_grst         (cmp_grst),
    .dram_gclk        (dram_gclk)
  );

  //---------------------------------------------------------------
  // Reset sequence (legacy-like): PWRON_RST_L / J_RST_L asserted at
  // time 0, deasserted together after ~400 clock cycles of J_CLK.
  //---------------------------------------------------------------
  initial begin
    $display("[cmp_top_port] start: PWRON_RST_L/J_RST_L asserted");
    #400000;                     // 400 ns of reset while J_CLK runs
    PWRON_RST_L = 1'b1;
    J_RST_L     = 1'b1;
    $display("[cmp_top_port] reset deasserted at %0t", $time);
  end

  // Phase-1 smoke window: no full boot chase; stop after reset release.
  initial begin
    #1000000;
    $display("[cmp_top_port] PHASE1 SMOKE END at %0t - elaborate+reset OK", $time);
    $finish;
  end

  // Watchdog
  initial begin
    #3000000;
    $display("[cmp_top_port] WATCHDOG timeout");
    $finish;
  end

endmodule
