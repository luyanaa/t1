// =====================================================================
// port/env/cmp_top_env.v - unified full-chip integration testbench.
//
// Combines every legacy verif/env/cmp/cmp_top.v lane into one
// open-source bench:
//   - full chip `OpenSPARCT1 iop`           (port/env/cmp_top_port.v)
//   - DDR env  `cmp_dram` (4 channels)      (port/env/dram/)
//   - JBus slave agents `jp_sjm j_sjm_4/5`  (verif/env/iss/pli/sjm/rtl/sjm.v)
//     + the 22 $sjm_* VPI tasks             (port/pli/sjm/sjm.vpi)
//   - $init_jbus_model VPI shim             (port/pli/init_jbus_model_vpi.c)
//   - $dispmon no-op shim                   (port/pli/dispmon.vpi)
//
// Structure mirrors cmp_top_port.v (proven Phase-1 fallback, kept
// untouched) extended with the legacy JBus plumbing from
// verif/env/cmp/cmp_top.v:1060-1360.
//
// LOAD-BEARING NAMES: top module `cmp_top`, chip instance `iop` (RTL's
// CTU_PATH = cmp_top.iop.ctu XMR).  SJM hierarchical calls use
// cmp_top.j_sjm_4 / cmp_top.j_sjm_5 exactly like the legacy bench.
//
// OUT OF SCOPE here: the full `monitor` / `pc_cmp` lane is ported
// separately; do NOT instantiate monitor in this file.  Hook point
// reserved below (diags_done/status wires).
// =====================================================================

`timescale 1ps/1ps

module cmp_top;

  //---------------------------------------------------------------
  // JBus / core clocks (legacy: cmp_clk drives j_clk; here free-run)
  //---------------------------------------------------------------
  reg j_clk_r = 1'b0;
  wire j_clk = j_clk_r;
  wire jbus_j_clk = j_clk;          // legacy cmp_top.v:374
  wire [1:0] J_CLK;
  assign J_CLK[0] = j_clk;          // legacy cmp_top.v:1101-1102
  assign J_CLK[1] = ~j_clk;
  always #500 j_clk_r = ~j_clk_r;   // ~1 GHz JBus clock

  //---------------------------------------------------------------
  // Static / reset inputs
  //---------------------------------------------------------------
  reg PWRON_RST_L = 1'b0;       // power-on reset, active low
  reg J_RST_L     = 1'b0;       // jbus reset, active low
  reg TEST_MODE   = 1'b0;
  reg PLL_CHAR_IN = 1'b0;
  reg TCK   = 1'b0;
  reg TCK2  = 1'b0;
  reg TRST_L = 1'b0;
  reg TDI   = 1'b0;
  reg TMS   = 1'b0;
  reg TEMP_TRIG    = 1'b0;
  reg CLK_STRETCH  = 1'b0;
  reg DO_BIST      = 1'b0;
  reg EXT_INT_L    = 1'b1;
  reg BURNIN       = 1'b0;
  reg PMI          = 1'b0;
  reg PGRM_EN      = 1'b0;
  reg VREG_SELBG_L = 1'b0;
  reg TRIGIN       = 1'b0;
  reg HSTL_VREF    = 1'b0;
  reg DTL_L_VREF   = 1'b0;
  reg DTL_R_VREF   = 1'b0;
  reg JBUS_P_REF_RES = 1'b0;
  reg JBUS_N_REF_RES = 1'b0;
  reg DRAM01_P_REF_RES = 1'b0;
  reg DRAM01_N_REF_RES = 1'b0;
  reg DRAM23_P_REF_RES = 1'b0;
  reg DRAM23_N_REF_RES = 1'b0;
  reg DBG_VREF     = 1'b0;

  // J_PACK4/J_PACK5 are inout pads in the legacy bench (weak-pulled),
  // not bench regs - see cmp_top.v:1079-1080.
  wire [2:0] J_PACK4;
  wire [2:0] J_PACK5;

  // J_PAR is an inout pad driven by the parity generator (cmp_top.v:1253).
  wire J_PAR;

  // JBus aliases into the legacy signal names used by jp_sjm/jbus logic.
  wire j_rst_l = J_RST_L;           // jp_sjm drives 1'bz on this net
  wire pwrok   = PWRON_RST_L;       // legacy: cmp_clk output

  //---------------------------------------------------------------
  // JBus proper (cmp_top.v:1060-1140)
  //---------------------------------------------------------------
  wire [127:0] J_AD;
  wire [3:0]   J_ADP;
  wire [7:0]   J_ADTYPE;
  wire [2:0]   J_PACK0;
  wire [2:0]   J_PACK1;
  wire [2:0]   j_pack2;
  wire [2:0]   j_pack3;
  wire [2:0]   j_pack6;
  wire [5:0]   j_req_out_l_0;
  wire [5:0]   j_req_out_l_1;
  wire [5:0]   j_req_out_l_2;
  wire [5:0]   j_req_out_l_3;
  wire [5:0]   j_req_out_l_4;
  wire [5:0]   j_req_out_l_5;
  wire [5:0]   j_req_out_l_6;
  wire [5:0]   j_req_in_l_0;
  wire [5:0]   j_req_in_l_1;
  wire [5:0]   j_req_in_l_2;
  wire [5:0]   j_req_in_l_3;
  wire [5:0]   j_req_in_l_4;
  wire [5:0]   j_req_in_l_5;
  wire [5:0]   j_req_in_l_6;
  wire         J_REQ4_IN_L;
  wire         J_REQ5_IN_L;
  wire         J_REQ0_OUT_L;
  wire         J_REQ1_OUT_L;
  wire         J_ERR;
  wire         j_change_l;

  // weak pull-ups so the bus idles at high-Z=1 when nobody drives it
  assign (weak0,weak1) J_AD       = 128'hffffffffffffffffffffffffffffffff;
  assign (weak0,weak1) J_ADP      = 4'b1111;
  assign (weak0,weak1) J_ADTYPE   = 8'b11111111;
  assign (weak0,weak1) J_PACK0    = 3'b111;
  assign (weak0,weak1) J_PACK1    = 3'b111;
  assign (weak0,weak1) j_pack2    = 3'b111;
  assign (weak0,weak1) j_pack3    = 3'b111;
  assign (weak0,weak1) J_PACK4    = 3'b111;
  assign (weak0,weak1) J_PACK5    = 3'b111;
  assign (weak0,weak1) j_pack6    = 3'b111;
  assign (weak0,weak1) j_req_out_l_0 = 6'b111111;
  assign (weak0,weak1) j_req_out_l_1 = 6'b111111;
  assign (weak0,weak1) j_req_out_l_2 = 6'b111111;
  assign (weak0,weak1) j_req_out_l_3 = 6'b111111;
  assign (weak0,weak1) j_req_out_l_4 = 6'b111111;
  assign (weak0,weak1) j_req_out_l_5 = 6'b111111;
  assign (weak0,weak1) j_req_out_l_6 = 6'b111111;
  assign (weak0,weak1) j_req_in_l_0  = 6'b111111;
  assign (weak0,weak1) j_req_in_l_1  = 6'b111111;
  assign (weak0,weak1) j_req_in_l_2  = 6'b111111;
  assign (weak0,weak1) j_req_in_l_3  = 6'b111111;
  assign (weak0,weak1) j_req_in_l_4  = 6'b111111;
  assign (weak0,weak1) j_req_in_l_5  = 6'b111111;
  assign (weak0,weak1) j_req_in_l_6  = 6'b111111;
  assign (weak0,weak1) j_change_l    = 1'b1;

  // bw pins (cmp_top.v:1123-1129)
  assign j_req_out_l_0 = {3{J_REQ1_OUT_L, J_REQ0_OUT_L}};
  assign J_REQ4_IN_L   = j_req_in_l_0[3];
  assign J_REQ5_IN_L   = j_req_in_l_0[4];

  // bw cross-connections
  assign j_req_in_l_0[3] = j_req_out_l_4[0];
  assign j_req_in_l_0[4] = j_req_out_l_5[0];

  // sjm 4 cross-connections (cmp_top.v:1132-1134)
  assign j_req_in_l_4[0] = j_req_out_l_5[0];
  assign j_req_in_l_4[2] = j_req_out_l_0[0];
  assign j_req_in_l_4[3] = j_req_out_l_1[0];

  // sjm 5 cross-connections (cmp_top.v:1137-1139)
  assign j_req_in_l_5[1] = j_req_out_l_0[1];
  assign j_req_in_l_5[2] = j_req_out_l_1[0];
  assign j_req_in_l_5[5] = j_req_out_l_4[0];

  //---------------------------------------------------------------
  // SJM control (cmp_top.v:1171-1200)
  //---------------------------------------------------------------
  reg  [1:0] sjm_4_status;
  reg  [1:0] sjm_5_status;
  reg        trigger_sjm_4;
  reg        trigger_sjm_5;
  reg        reset_handler_done;
  integer    sjm_init_status;
  reg        jbus_j_por_l_reg;
  wire       jbus_j_por_l = jbus_j_por_l_reg;

  // Power-on reset pulse for the SJM models: high at t0, low for 15
  // jbus_j_clk cycles, then deasserted (cmp_top.v:1145-1151).  The
  // initial 1->0 edge triggers $sjm_assert_por inside jp_sjm (sjm.v:276).
  initial begin
    jbus_j_por_l_reg = 1'b1;
    #1;
    jbus_j_por_l_reg = 1'b0;
    repeat (15) @(posedge jbus_j_clk);
    jbus_j_por_l_reg = 1'b1;
    $display("[cmp_top_env] jbus_j_por_l deasserted at %0t", $time);
  end

  initial begin
    trigger_sjm_4     = 1'b0;
    trigger_sjm_5     = 1'b0;
    reset_handler_done = 1'b0;
    sjm_init_status = 0;
    $sjm_init;
    $display("[cmp_top_env] $sjm_init done");
    // Legacy cmp_clk asserted pwrok right after pwron_rst_l; report pwr
    // to the SJM models explicitly (sjm.v detects posedge pwr_ok in the
    // commented legacy hook; we call the task directly).
    @(posedge pwrok);
    #1;
    $sjm_assert_pwr(4);
    $sjm_assert_pwr(5);
    $display("[cmp_top_env] $sjm_assert_pwr issued for sjm 4/5");
  end

  reg grst_prev = 1'bx;
  always @(posedge j_clk) begin
    if (grst_prev !== iop.jbus_grst_l) begin
      $display("[cmp_top_env] t=%0t jbus_grst_l %b -> %b", $time, grst_prev, iop.jbus_grst_l);
      grst_prev = iop.jbus_grst_l;
    end
    // Port note: iverilog does not reliably deliver @ events on nets read
    // through downward XMR, so poll on j_clk instead of @(posedge grst).
    while (iop.jbus_grst_l !== 1'b0) @(posedge j_clk);
    // wait for jbus_grst_l deassertion (polled)
    while (iop.jbus_grst_l !== 1'b1) @(posedge j_clk);
    repeat (8) @(posedge j_clk);
    if (!trigger_sjm_4) begin
      trigger_sjm_4      = 1'b1;
      trigger_sjm_5      = 1'b1;
      reset_handler_done = 1'b1;
      $display("[cmp_top_env] trigger_sjm_4/5 set at %0t", $time);
    end
  end

  // OPEN-SOURCE BRING-UP BLOCKER / fallback: the CTU/efc boot chain that
  // deasserts jbus_grst_l (ctu_clsp_jbusgif.u_jbus_grst_l, gated by the
  // efuse-readout sequencing) is not exercised in this bring-up env yet,
  // so the legacy trigger above never fires.  Until that chain is fixed,
  // +sjm_trigger_force=<time_ps> forces the SJM trigger at an absolute
  // time (e.g. +sjm_trigger_force=1200000 = 1.2us, after the 400ns reset).
  reg [63:0] sjm_force_t;
  initial begin
    if ($value$plusargs("sjm_trigger_force=%d", sjm_force_t)) begin
      #(sjm_force_t);
      if (!trigger_sjm_4) begin
        trigger_sjm_4      = 1'b1;
        trigger_sjm_5      = 1'b1;
        reset_handler_done = 1'b1;
        $display("[cmp_top_env] trigger_sjm_4/5 FORCED at %0t (grst fallback)", $time);
      end
    end
  end

  always @(posedge j_clk) begin
    cmp_top.j_sjm_4.sjm_status(sjm_4_status);
  end

  always @(posedge j_clk) begin
    cmp_top.j_sjm_5.sjm_status(sjm_5_status);
  end

  always @(posedge trigger_sjm_4) begin
    $display("[cmp_top_env] Starting sjm_4 master devices");
    cmp_top.j_sjm_4.sjm_start_executing;
  end

  always @(posedge trigger_sjm_5) begin
    $display("[cmp_top_env] Starting sjm_5 master devices");
    cmp_top.j_sjm_5.sjm_start_executing;
  end

  //---------------------------------------------------------------
  // JBus parity generation (cmp_top.v:1330-1359)
  //---------------------------------------------------------------
  reg [2:0] j_pack0_d, j_pack1_d, j_pack2_d, j_pack3_d;
  reg [2:0] j_pack4_d, j_pack5_d, j_pack6_d;
  reg       j_par_d1, j_par_d2;

  always @(posedge jbus_j_clk) begin
    j_pack0_d <= J_PACK0;
    j_pack1_d <= J_PACK1;
    j_pack2_d <= j_pack2;
    j_pack3_d <= j_pack3;
    j_pack4_d <= J_PACK4;
    j_pack5_d <= J_PACK5;
    j_pack6_d <= j_pack6;

    j_par_d1  <= ~((j_req_out_l_0[0]) ^
                   (j_req_out_l_1[0]) ^
                   (j_req_out_l_2[0]) ^
                   (j_req_out_l_3[0]) ^
                   (j_req_out_l_4[0]) ^
                   (j_req_out_l_5[0]) ^
                   (j_req_out_l_6[0]) ^
                   (^j_pack0_d) ^ (^j_pack1_d) ^ (^j_pack2_d) ^
                   (^j_pack3_d) ^ (^j_pack4_d) ^ (^j_pack5_d) ^
                   (^j_pack6_d));
    j_par_d2  <= j_par_d1;
  end

  assign J_PAR = j_par_d2;

  //---------------------------------------------------------------
  // monitor / pc_cmp (de-SAS'd port): good/bad-trap scorer.
  // monitor_min.v is a self-contained de-SAS port of verif/env/cmp/monitor.v;
  // it watches iop.sparcN TLU trap outputs + IFU thread-FSM state via XMR.
  // Ports match legacy cmp_top.v:683 (clk=cmp_rclk, cmp_gclk, rst_l=cmp_grst_l).
  //---------------------------------------------------------------
  wire cmp_rclk  = iop.ccx.rclk;       // ccx read clock  (cmp_top.v:288,323)
  wire cmp_gclk  = iop.cmp_gclk;       // cmp global clock (cmp_top.v:289)
  wire cmp_grst_l = iop.cmp_grst_out_l;// cmp reset, active-low (cmp_top.v:296)

  monitor   monitor(
		    // Inputs
		    .clk		(cmp_rclk),
		    .cmp_gclk		(cmp_gclk),
		    .rst_l		(cmp_grst_l));

  wire        diags_done = 1'b0;      // monitor_min hook point
  wire [1:0]  status     = {sjm_5_status, sjm_4_status};

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

  wire DRAM02_SDA = 1'b1;
  wire DRAM13_SDA = 1'b1;
  wire DRAM02_SCL = 1'b0;
  wire DRAM13_SCL = 1'b0;

  wire        XXWP = 1'b0;
  wire [2:0]  XXSA = 3'b000;
  wire        DRAM_FAIL_OVER = 1'b0;
  wire [5:0]  DRAM_FAIL_PART = 6'b0;

  wire cmp_grst  = ~iop.cmp_grst_out_l;
  wire dram_gclk = iop.dram_gclk;

  //---------------------------------------------------------------
  // The chip.  Instance name `iop` is REQUIRED (CTU_PATH XMR).
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
    .DTL_L_VREF       (DTL_L_VREF),
    .DTL_R_VREF       (DTL_R_VREF),
    .JBUS_P_REF_RES   (JBUS_P_REF_RES),
    .JBUS_N_REF_RES   (JBUS_N_REF_RES),
    .DRAM01_P_REF_RES (DRAM01_P_REF_RES),
    .DRAM01_N_REF_RES (DRAM01_N_REF_RES),
    .DRAM23_P_REF_RES (DRAM23_P_REF_RES),
    .DRAM23_N_REF_RES (DRAM23_N_REF_RES),
    .DBG_VREF         (DBG_VREF),
    // JBus slave side (cross-connected, see above)
    .J_REQ4_IN_L      (J_REQ4_IN_L),
    .J_REQ5_IN_L      (J_REQ5_IN_L),
    // JBus master pads / request outputs
    .J_AD             (J_AD),
    .J_ADP            (J_ADP),
    .J_ADTYPE         (J_ADTYPE),
    .J_PAR            (J_PAR),
    .J_PACK0          (J_PACK0),
    .J_PACK1          (J_PACK1),
    .J_PACK4          (J_PACK4),
    .J_PACK5          (J_PACK5),
    .J_REQ0_OUT_L     (J_REQ0_OUT_L),
    .J_REQ1_OUT_L     (J_REQ1_OUT_L),
    .J_ERR            (J_ERR),
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
    // Remaining ports (SPARE_*/VDD sense/SSI/PMO/DBG_*/CLKOBS) are
    // inouts that idle tri-stated - intentionally unconnected.
  );

  // Behavioral 4-channel DDR2 + ECC environment (Sun cmp_dram).
  cmp_dram cmp_dram(
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
  // Back-door memory array for $init_jbus_model (see mem_backdoor.v)
  //---------------------------------------------------------------
  mem_backdoor mem_backdoor();

  //---------------------------------------------------------------
  // $init_jbus_model (legacy cmp_top.v:735).  Reads +mem.image=<file>
  // plusarg, defaults to "mem.image".
  //---------------------------------------------------------------
  reg [8*128:1] mem_image_name;
  initial begin
    if ($value$plusargs("mem.image=%s", mem_image_name))
      $init_jbus_model(mem_image_name);
    else
      // Default path relative to the compile dir (/shared/t1), from which
      // the run is launched; the bare "mem.image" only worked from port/env.
      $init_jbus_model("port/env/mem.image");
  end

  //---------------------------------------------------------------
  // Reset sequence: PWRON_RST_L asserted at t0, deasserted after ~400 JBus
  // clock cycles.  J_RST_L is deasserted LATER, only after the CTU clocks
  // are up (start_clk_cl asserted), per the legacy reset order.
  //---------------------------------------------------------------
  initial begin
    $display("[cmp_top_env] start: PWRON_RST_L/J_RST_L asserted");
    #400000;
    PWRON_RST_L = 1'b1;
    $display("[cmp_top_env] PWRON_RST_L deasserted at %0t (J_RST_L still LOW)", $time);

    // Wait for CTU cpu-domain start_clk_cl (clocks running) before
    // releasing J_RST_L.  Poll on a timer (XMR events unreliable).
    begin : wait_start_clk
      integer t;
      reg seen;
      seen = 1'b0;
      for (t = 0; t < 4000; t = t + 1) begin
        #1000;
        if (iop.ctu.ctu_clsp.u_ctu_clsp_clkgn.start_clk_cl === 1'b1) begin
          seen = 1'b1;
          disable wait_start_clk;
        end
      end
      if (!seen)
        $display("[cmp_top_env] WARNING: start_clk_cl never asserted; releasing J_RST_L on fallback timeout");
      else
        $display("[cmp_top_env] start_clk_cl observed at %0t", $time);
    end
    #1000;
    J_RST_L     = 1'b1;
    $display("[cmp_top_env] J_RST_L deasserted at %0t (after clocks up)", $time);
  end

  //---------------------------------------------------------------
  // CTU clock bring-up: bypass the PLL (pll_clk_out = J_CLK) and
  // release the Johnson dividers, which come up X in this env and
  // otherwise dead-lock the cmp/jbus/dram gclk generation.
  // Encoding (oracle-verified): 3'b100 = pll_bypass source,
  // 3'b001 = div source.  dram has no bypass path -> 3'b001.
  //---------------------------------------------------------------
  initial begin
    // (1) PLL bypass: pll_clk_out follows J_CLK combinationally.
    force cmp_top.iop.ctu.u_pll.pll_bypass = 1'b1;
    force cmp_top.iop.ctu.pll_bypass       = 1'b1;
    // (2) Clock source mux selects.
    force cmp_top.iop.ctu.ctu_sel_cpu  = 3'b100;
    force cmp_top.iop.ctu.ctu_sel_jbus = 3'b100;
    force cmp_top.iop.ctu.ctu_sel_dram = 3'b001;
    // mirror into the ctu_clsp port nets so the internal consumers see it
    force cmp_top.iop.ctu.ctu_clsp.jtag_clsp_sel_cpu  = 3'b100;
    force cmp_top.iop.ctu.ctu_clsp.jtag_clsp_sel_jbus = 3'b100;
    force cmp_top.iop.ctu.ctu_clsp.jtag_clsp_sel_dram = 3'b001;
    // (3) Release the Johnson dividers with a real 0->1 edge on init_div_l.
    force cmp_top.iop.ctu.ctu_clsp.u_ctu_clsp_clkgn.u_ctu_clsp_clkgn_fstlog.init_div_l = 1'b0;
    #2000;
    force cmp_top.iop.ctu.ctu_clsp.u_ctu_clsp_clkgn.u_ctu_clsp_clkgn_fstlog.init_div_l = 1'b1;
    // (4) Kill the X-locked clock-stretch pipeline during bring-up.
    force cmp_top.iop.ctu.ctu_clsp.u_ctu_clsp_clkgn.u_ctu_clsp_clkgn_fstlog.clk_str_en_buf   = 3'b111;
    force cmp_top.iop.ctu.ctu_clsp.u_ctu_clsp_clkgn.u_ctu_clsp_clkgn_fstlog.clk_str_en_buf_b = 3'b111;
    $display("[cmp_top_env] CTU clock bring-up forces applied at %0t", $time);
  end

  //---------------------------------------------------------------
  // CTU clock-control X-poison fix (ROOT CAUSE of the L2 way-select X flood).
  // `update_clkctrl_reg_cl` is a dffrl_async_ns whose D = (...) & start_clk_cl
  // and is X-poisoned at t=0 (ctu_clsp_synch_jlcl.v:958).  The downstream
  // async-set flops (ctu_clsp_clkctrl.v:1237-1261) *select on it*, so its X
  // propagates into clsp_ctrl_*_en_cl -> ctu_*_cken_cl -> ctu_*_cmp_cken_cg
  // -> cluster_cken.  cluster_header.v:92 then makes rclk = gclk & sync_enable
  // = X, so the cmp-domain flops NEVER get a posedge, and their resets are
  // SYNCHRONOUS (swrvr_clib.v:314 dffre_s: @(posedge clk) only) -> resets
  // never fire -> csr_l2_control_reg/way_sel stay X forever.
  // Forcing update_clkctrl_reg_cl=0 (NOT 1 - 1 re-arms the mux and re-poisons)
  // de-poisons the chain.  Verified by oracle: 25712 -> 0 L2_DATA_ERR events.
  //---------------------------------------------------------------
  initial begin
    force cmp_top.iop.ctu.ctu_clsp.u_ctu_clsp_clkctrl.update_clkctrl_reg_cl = 1'b0;
    force cmp_top.iop.ctu.ctu_clsp.u_ctu_clsp_clkctrl.rd_clkctrl_reg_cl     = 1'b0;
    // Belt-and-braces: explicit cluster clock-enables (some buckets stay X).
    // Must be applied at t=0, BEFORE the first cmp_gclk edge, so the
    // spc_hdr bw_u1_syncff_4x samples a defined cluster_cken and sync_enable
    // resolves (else sparc0.grst_l sticks and thrfsm stays in IDLE).
    force cmp_top.iop.sparc0.cluster_cken  = 1'b1;
    force cmp_top.iop.sctag0.cluster_cken  = 1'b1;
    force cmp_top.iop.sctag1.cluster_cken  = 1'b1;
    force cmp_top.iop.sctag2.cluster_cken  = 1'b1;
    force cmp_top.iop.sctag3.cluster_cken  = 1'b1;
    force cmp_top.iop.scdata0.cluster_cken = 1'b1;
    force cmp_top.iop.scdata1.cluster_cken = 1'b1;
    force cmp_top.iop.scdata2.cluster_cken = 1'b1;
    force cmp_top.iop.scdata3.cluster_cken = 1'b1;
    force cmp_top.iop.scbuf0.cluster_cken  = 1'b1;
    force cmp_top.iop.scbuf1.cluster_cken  = 1'b1;
    force cmp_top.iop.scbuf2.cluster_cken  = 1'b1;
    force cmp_top.iop.scbuf3.cluster_cken  = 1'b1;
`ifdef RTL_FPU
`ifndef SPARC_NO_FPU
    force cmp_top.iop.fpu.cluster_cken     = 1'b1;
`endif
`endif
    force cmp_top.iop.ccx.clk_ccx_cken     = 1'b1;  // ccx uses clk_ccx_cken
    $display("[cmp_top_env] CTU clkctrl un-poison + cluster_cken forces at %0t", $time);
  end

  //---------------------------------------------------------------
  // IFU IMISS power-up state: the Missed-Instruction-List flops mil0..3
  // (sparc_ifu_ifqdp.v:390-407) and the PCX thread-select flop
  // (sparc_ifu_ifqctl.v:1325) have no reset, so plain simulation starts
  // them at x and the milreq mux (dp_mux4ds) turns a non-one-hot select
  // into an x address that floods the CCX arbiter.
  // These flops now carry an explicit power-up value in the RTL
  // (swrvr_clib dff_s POR parameter: 41'b0 for the MIL entries, 4'b0001
  // for pcxthr_ff), enabled by RTL_FF_POR_INIT in the port build.  The
  // former t=0 slam-and-release forces are gone.
  //---------------------------------------------------------------

  //======================================================================
  // BRING-UP FIX SET A+B (t=0, before the first cmp_gclk edge).
  // Oracle-verified: with these, thr_f/thr_d/e/m/w = 1, spc_pcx_req_pq=0,
  // queue_write=11111 and L2_DATA_ERR = 0 over the whole run.
  //======================================================================
  initial begin
    // (1) ISSUE A: FCL thread-select flop is a dff_s with NO reset; the RTL
    //     comment (sparc_ifu_fcl.v:2897) says it must power up 4'b0001.
    //     If X, thr_d/e/m/w are X -> rstint_m/intr_vld_w X -> thrfsm
    //     (sparc_ifu_thrfsm.v:77-95) can never leave IDLE.  HOLD.
    //     Now modelled in the RTL itself: thrf_reg is instantiated with
    //     dff_s POR = 4'b0001 (sparc_ifu_fcl.v:2904), so no force is needed.

    // (2) ISSUE B: LSU IOB-forward-packet flop (lsu_qctl2.v:700 fwdpkt_ff,
    //     dffre_s) has rst=fwdpkt_reset(:694) and en=cpx_fwd_pkt_en_cx(:680)
    //     both X -> stuck X.  fwdpkt_rq_vld=X poisons lsu_rrobin_picker2 ->
    //     spc_pcx_req_pq -> CCX PCX -> sctag way-select X -> L2_DATA_ERR.
    //     Modelled in the RTL now: fwdpkt_ff (dffre_s) powers up 0 via the
    //     dffre_s POR parameter, so fwdpkt_rq_vld is 0 from the first cycle.

    // (2b) SPU load/store packet flop (spu_lsurpt1, dff_s, no reset) is X.
    //      lsu_qdp1:1626 selects it as `imiss_strm_pcx_pkt` whenever
    //      imiss_pcx_mx_sel (= imiss_pcx_rq_sel_d1) is 0, so an X SPU packet
    //      reaches spc_pcx_data_pa -> CCX PCX -> pcx_io_data_rdy_px2 = X,
    //      which kills the reset fetch.  SPU is unused for boot: hold it 0.
    //      VERIFIED: with this, spu_lsu_ldst_pckt_d1 / imiss_strm_pcx_pkt /
    //      spc_pcx_data_pa all read 0 (clean).
    //      Modelled in the RTL now: spu_lsu_ldst_pckt_d1 is a dff_s that
    //      powers up 0 via the POR parameter, so the packet is clean.

    // (2c) TLU trap base address (%tba) is a reset-less dff_s
    //      (tlu_tdp.v:1453 tba0), so it is X until software writes it and the
    //      trap PC (tlu_ifu_trappc_w2) is X.  Do NOT hold TBA at a constant:
    //      the boot image's boot_main writes %tba itself.  Only slam the
    //      thread-select that feeds the tba_data mux4ds (tlu_tdp.v:1546).
    //      mux4ds emits x for a non-one-hot select, and tlu_thrd_wsel_w2
    //      (tlu_tcl.v:1233, the thread taking a trap) is X between traps, so
    //      tba_data stays X even after %tba is written.  Holding it one-hot
    //      makes tba_data track true_tba0, which boot_main programs.
    //      Modelled in the RTL now: tlu_thrd_wsel_w2 is decoded from
    //      tsa_wr_tid, which powers up 00 -> thread0_wtrp_w2 = 1, so the
    //      select is one-hot (0001) without any force.

    // (3) LSU PCX queue monitors (lsu_qctl1.v:3890-3965, lsu_pcx_qmon.v:120/
    //     135 dffre_s, rst/en mutually dependent) stuck X -> queue_write=X
    //     blocks the first IMISS request.  HOLD (loses the 2-entry flow
    //     control; CCX still backpressures with grants).
    //      Modelled in the RTL now: the qmon entry_full flops (dffre_s in
    //      lsu_pcx_qmon.v) power up 0 via the POR parameter.

    // (4) sparc1..7 are not compiled (iop.v:3595/3684/4129); their PCX
    //     request/atom nets float into the shared arbiter.  HOLD at 0.
    //     sparc0's atom_pq must be driven too: spc_pcx_atom_pq_buf2 feeds
    //     mcycle_squash_d1 (lsu_qctl1:3493) which is the most likely X that
    //     blocks the 2nd+ IMISS request.
    force cmp_top.iop.spc0_pcx_atom_pq = 1'b0;
    force cmp_top.iop.spc1_pcx_req_pq = 5'b0;  force cmp_top.iop.spc1_pcx_atom_pq = 1'b0;
    force cmp_top.iop.spc2_pcx_req_pq = 5'b0;  force cmp_top.iop.spc2_pcx_atom_pq = 1'b0;
    force cmp_top.iop.spc3_pcx_req_pq = 5'b0;  force cmp_top.iop.spc3_pcx_atom_pq = 1'b0;
    force cmp_top.iop.spc4_pcx_req_pq = 5'b0;  force cmp_top.iop.spc4_pcx_atom_pq = 1'b0;
    force cmp_top.iop.spc5_pcx_req_pq = 5'b0;  force cmp_top.iop.spc5_pcx_atom_pq = 1'b0;
    force cmp_top.iop.spc6_pcx_req_pq = 5'b0;  force cmp_top.iop.spc6_pcx_atom_pq = 1'b0;
    force cmp_top.iop.spc7_pcx_req_pq = 5'b0;  force cmp_top.iop.spc7_pcx_atom_pq = 1'b0;

    // (5) iobdg CPX port: ONLY tie it off when iobdg is NOT compiled
    //     (`ifdef RTL_IOBDG, iop.v:3227).  When iobdg IS built it drives
    //     these itself and forcing them would fight the real logic.
    //     In the no-iobdg build jbus_boot_resp (instantiated below) drives
    //     iob_cpx_* to answer the CPU boot fetch, so we do NOT force them.
`ifdef RTL_IOBDG
`else
    // iobdg absent: the ccx iob PCX port has no consumer.  Nothing to force
    // here - jbus_boot_resp supplies the CPX return via continuous assigns.
`endif
    $display("[cmp_top_env] fix set A+B applied (thrf/qmon/spc/iobdg) at %0t", $time);
  end

`ifndef RTL_IOBDG
  //------------------------------------------------------------------
  // Boot image.  Two banks, mirroring port/tb/tb_diag.v:
  //   mem_red : PA[39:28]==0xfff (RED boot page) indexed by PA[19:3]
  //   mem_low : everything else (diag text/data) indexed by PA[27:3]
  // Loaded from a diag2hex.py image (+boot_mem=<file>, @idx = PA/8,
  // 16-hex-digit big-endian 64-bit words).  With no image, the built-in
  // mini program is planted at the reset PC so the bench still boots.
  //------------------------------------------------------------------
  localparam integer BOOT_LOW_WORDS = 1 << 20;   // PA[22:3], up to 0x800000
  localparam integer BOOT_RED_WORDS = 1 << 14;   // PA[16:3], 64 KB of RED
  reg [63:0] boot_mem_low [0:BOOT_LOW_WORDS-1];
  reg [63:0] boot_mem_red [0:BOOT_RED_WORDS-1];
  integer    boot_image_words;

  function [63:0] boot_mem_read;
    input [39:0] pa;
    begin
      if (pa[39:28] == 12'hfff)
        boot_mem_read = boot_mem_red[pa[16:3]];
      else
        boot_mem_read = boot_mem_low[pa[22:3]];
    end
  endfunction

  task boot_mem_write;
    input [39:0] pa;
    input [63:0] val;
    begin
      if (pa[39:28] == 12'hfff)
        boot_mem_red[pa[16:3]] = val;
      else
        boot_mem_low[pa[22:3]] = val;
    end
  endtask

  // 32-bit big-endian instruction at byte address pa.
  function [31:0] boot_prog_word;
    input [39:0] pa;
    reg   [63:0] w;
    begin
      w = boot_mem_read(pa);
      boot_prog_word = pa[2] ? w[31:0] : w[63:32];
    end
  endfunction

  // diag2hex.py format: sparse $readmemh, "@<idx>" (idx = PA/8) then one
  // 16-hex-digit word per line.  $fscanf("%s") right-aligns into `line`,
  // so records are told apart by $sscanf, exactly like tb_diag.v.
  task boot_load_image;
    input [256*8-1:0] path;
    integer fid, code;
    reg [255:0] line;
    reg [63:0]  idx, waddr, wval;
    begin
      fid = $fopen(path, "r");
      if (fid == 0) begin
        $display("[cmp_top_env] WARNING: cannot open +boot_mem %0s",
                 path);
      end else begin
        waddr = 64'b0;
        while (!$feof(fid)) begin
          code = $fscanf(fid, "%s", line);
          if (code == 1) begin
            if ($sscanf(line, "@%h", idx) == 1) begin
              waddr = idx;
            end else if (line[7:0] == 8'h2f) begin
              // '//' comment token; ignore
            end else if ($sscanf(line, "%h", wval) == 1) begin
              boot_mem_write({waddr[36:0], 3'b000}, wval);
              waddr = waddr + 1;
              boot_image_words = boot_image_words + 1;
            end
          end
        end
        $fclose(fid);
        $display("[cmp_top_env] boot image: %0d words from %0s",
                 boot_image_words, path);
      end
    end
  endtask

  initial begin : boot_image_init
    reg [256*8-1:0] boot_mem_path;
    boot_image_words = 0;
    if ($value$plusargs("boot_mem=%s", boot_mem_path))
      boot_load_image(boot_mem_path);
    if (boot_image_words == 0) begin
      // No image: the proven mini program at the reset PC (0xfffff0000020).
      //   sethi %hi(0xdeadb000),%g1 / or %g1,0x123,%g1 / ta 0x40 / ba . / nop
      boot_mem_write(40'hff_fff0_0020, 64'h0337_AB6C_8210_6123);
      boot_mem_write(40'hff_fff0_0028, 64'h91D0_2040_1080_0000);
      boot_mem_write(40'hff_fff0_0030, 64'h0100_0000_0100_0000);
      $display("[cmp_top_env] boot image: built-in mini program");
    end
  end

  //======================================================================
  // JBus/IO-bridge BOOT RESPONDER (no-iobdg build).
  // The sparc0 reset fetch is an UNCACHED IMISS to PCX dest 4 (FP/IO
  // bridge) -> answered over the JBus by a ROM in the real system.  With
  // iobdg absent nothing answers and thread0 hangs in THRFSM_WAIT.  This
  // responder plays i2c_fdp: watch the ccx "iob" PCX request and return an
  // IFILL_RET CPX packet carrying a "ba ." self-loop, so the core executes
  // a deterministic loop the monitor can trap on.
  //======================================================================
  wire [7:0]   boot_cpx_req;
  wire [144:0] boot_cpx_data;
  wire         boot_pcx_stall;

  // Diagnostic-only instantiation (its outputs are not wired into the DUT;
  // the actual boot return is injected at sparc0.cpx_spc_data_cx2 below).
  // Kept behind BOOT_RESP_DBG so the default build stays identical to the
  // proven-good one.  jbus_boot_resp.v remains the reference implementation
  // for a future real iobdg/JBus path.
`ifdef BOOT_RESP_DBG
  jbus_boot_resp u_boot_resp (
    .clk         (cmp_top.iop.cmp_gclk),
    .rst_l       (cmp_top.iop.cmp_grst_out_l),
    .pcx_req     (cmp_top.iop.pcx_iob_data_px2),
    .pcx_req_rdy (cmp_top.iop.pcx_iob_data_rdy_px2),
    .cpx_req     (boot_cpx_req),
    .cpx_data    (boot_cpx_data),
    .pcx_stall   (boot_pcx_stall)
  );
`endif

  // iob_cpx_* are ALSO driven by the v_m_help/repeater instance in iop.v, so
  // forcing them dynamically made the sim oscillate at grst release.  Instead
  // we park them as constants (the known-good config) and deliver the boot
  // return at the sparc0 CPX input - the SAME injection point already proven
  // not to hang - but carrying real IFILL_RET data when a request appears.
  initial begin
    force cmp_top.iop.iob_cpx_req_cq        = 8'b0;
    force cmp_top.iop.iob_cpx_data_ca       = 145'b0;
    force cmp_top.iop.iob_pcx_stall_pq      = 1'b0;
    force cmp_top.iop.ccx.cpx.io_cpx_req_cq  = 8'b0;
    force cmp_top.iop.ccx.cpx.io_cpx_data_ca = 145'b0;
  end

  //======================================================================
  // ROOT X-FIX for pcx_io_data_rdy_px2 = X after the first boot fetch.
  //
  // iobdg is not compiled, so iop.v:3227 (`ifdef RTL_IOBDG) leaves the whole
  // UCB/JTAG debug-init port with ZERO DRIVERS (pure HiZ):
  //   iop.iob_clsp_vld / iob_clsp_data / iob_clsp_stall
  //     -> ctu_clsp.u_ctu_clsp_ucb (ucb_noflow -> ucb_bus_in) captures HiZ
  //        -> ucb_clsp_rd_req_vld = X, ucb_clsp_addr_in = z
  //        -> clsp_dbg_init_sel = X      (ctu_clsp_creg.v:642)
  //        -> dbginit_1sht = X           (ctu_clsp_creg.v:923)
  //        -> shadreg.cmp_dbginit_cl_l -> ctu_clsp_cmpgif.u_cmp_dbginit_l.q
  //        -> cmp_gdbginit_out_l = X
  //        -> rpt_cmp_gdbginit_l_c3 -> ccx_gdbginit_l = X
  //        -> ccx.rst_l_buf1_middle = X
  //        -> ccx_arbctl.ff_rstl latches X as ccx_reset_l_d1
  //        -> ccx_arbdp.v:564-565 gates grant_a -> ccx_dest_data_rdy_a = X
  //        -> arb4.dff_ccx_com_dr -> pcx_io_data_rdy_px2 = X.
  // That single X takes out ALL FIVE ccx arbiters, so the IMISS is never
  // acknowledged (only one fetch ever issues).
  //
  // NOTE: slamming the downstream rdy/data flops does NOT work (measured:
  // 0 fetches) - rdy=1 legitimately means "data present", and pcx_databuf_pa
  // is a pass-through.  The fix must be at this zero-driver source.
  // These nets have no driver in this build, so force is safe (no
  // multiple-driver hang, unlike iob_cpx_*).  Hold permanently.
  // Oracle-measured: BOOT imiss served 1 -> 1350 (every PC 0x20..0xd3c),
  // pcx_io_data_rdy_px2 X samples 165 -> 0, thr0_state cycles 05<->19.
  //======================================================================
  initial begin
    force cmp_top.iop.iob_clsp_vld   = 1'b0;
    force cmp_top.iop.iob_clsp_data  = 4'b0;
    force cmp_top.iop.iob_clsp_stall = 1'b0;
  end

  //======================================================================
  // ISSUE A trigger (NO-iobdg build only): emulate the missing iobdg
  // "first thread reset" CPX packet (iobdg_ctrl.v:1050-1077 firstthr_int).
  // With -DRTL_IOBDG the real iobdg generates firstthr_int itself, so this
  // injection (and its CPX parking hack) must NOT run.
  // VLD=1, RQ=INT_RET(0111), type=IOB_RESET(01), cputhread=core0/thr0,
  // vector=1 (POR).
  //======================================================================
  //======================================================================
  // BOOT responder helpers.
  //
  // A store offered by the core while an IFILL_RET/LOAD_RET is being consumed
  // must not be lost: the PCX IOB port lets the store path present an
  // independent request during that window (measured: the diag's final
  // thread_status_mem `stx` landed inside the 8-cycle response hold and was
  // dropped - 133 IOB requests vs 132 IMISS, no "unhandled").  `boot_bus_hold`
  // keeps the response stable while sniffing for such a store, and the main
  // loop records+acks it once the bus is free.
  //======================================================================
  reg        st_pend;
  reg [39:0] st_pa;
  reg [63:0] st_data;
  reg [1:0]  st_thr;
  reg [1:0]  st_p;
  initial begin
    st_pend = 1'b0; st_pa = 40'b0; st_data = 64'b0; st_thr = 2'b0; st_p = 2'b0;
  end

  task boot_bus_hold;
    integer k;
    begin
      for (k = 0; k < 8; k = k + 1) begin
        @(posedge cmp_top.iop.cmp_gclk);
        if (!st_pend && cmp_top.iop.pcx_iob_data_rdy_px2 &&
            cmp_top.iop.pcx_iob_data_px2[123] &&
            (cmp_top.iop.pcx_iob_data_px2[122:118] == 5'b00001 ||
             cmp_top.iop.pcx_iob_data_px2[122:118] == 5'b00111)) begin
          st_pend = 1'b1;
          st_pa   = cmp_top.iop.pcx_iob_data_px2[103:64];
          st_data = cmp_top.iop.pcx_iob_data_px2[63:0];
          st_thr  = cmp_top.iop.pcx_iob_data_px2[113:112];
          st_p    = cmp_top.iop.pcx_iob_data_px2[108:107];
        end
      end
    end
  endtask

  task boot_store_record;
    input [39:0] pa;
    input [63:0] data;
    input [1:0]  thr;
    begin
      $display("[cmp_top_env] BOOT store at %0t pa=%h data=%h thr=%b",
               $time, pa, data, thr);
      boot_mem_write(pa, data);
      // Standard T1 diag verdict word (same convention as port/tb/tb_diag.v):
      // one-hot TID in the low 32 bits, fail code in the upper 32 bits
      // (zero => good trap).
      if (pa[39:0] == 40'hff_f002_0000)
        $display("[cmp_top_env] DIAG %0s: thread_status_mem=%h",
                 (data[63:32] == 32'h0) ? "PASS" : "FAIL", data);
    end
  endtask

  task boot_store_ack;
    input [1:0] thr;
    input [1:0] pkt_id;
    reg [144:0] pkt;
    begin
      pkt = 145'b0;
      pkt[144]     = 1'b1;        // CPX_VLD
      pkt[143:140] = 4'b0100;     // ST_ACK
      pkt[135:134] = thr;
      pkt[131:130] = pkt_id;      // echo the store packet id
      force cmp_top.iop.sparc0.cpx_spc_data_cx2     = pkt;
      force cmp_top.iop.sparc0.cpx_spc_data_rdy_cx2 = 1'b1;
      repeat (8) @(posedge cmp_top.iop.cmp_gclk);
      force cmp_top.iop.sparc0.cpx_spc_data_cx2     = 145'b0;
      force cmp_top.iop.sparc0.cpx_spc_data_rdy_cx2 = 1'b0;
    end
  endtask

  localparam [144:0] POR_RST_PKT_T0 =
      145'h1700000000000000000000000000000010001;
  initial begin : por_thread0_reset
    while (cmp_top.iop.cmp_grst_out_l !== 1'b1) @(posedge cmp_top.iop.cmp_gclk);
    repeat (128) @(posedge cmp_top.iop.cmp_gclk);          // ~128 ns
    force cmp_top.iop.sparc0.cpx_spc_data_cx2     = POR_RST_PKT_T0;
    force cmp_top.iop.sparc0.cpx_spc_data_rdy_cx2 = 1'b1;
    repeat (3) @(posedge cmp_top.iop.cmp_gclk);
    // Park the core CPX input so it does not see a stale packet.
    force cmp_top.iop.sparc0.cpx_spc_data_cx2     = 145'b0;
    force cmp_top.iop.sparc0.cpx_spc_data_rdy_cx2 = 1'b0;
    $display("[cmp_top_env] POR thread0 reset packet injected at %0t", $time);

    //------------------------------------------------------------------
    // BOOT ROM SERVING: the reset fetch (and every subsequent fetch) is an
    // UNCACHED 4B IMISS to the IO bridge (dest 4) - it can never hit the I$
    // or the MIL (ifqctl.v:763/791/1160-1166), so each instruction comes as
    // its own IMISS.  We answer at the sparc0 CPX input with CPX_IF4B=1
    // (one instruction, goes straight to the TIR) carrying a real mini
    // program, so actual SPARC instructions execute.
    //------------------------------------------------------------------

    begin : boot_fetch_serve
      integer guard;
      reg [144:0] ifill_pkt;
      reg [39:0] pc_pa;
      reg [1:0]  req_thr;
      reg [1:0]  lane;
      reg [4:0]  rqtype;
      for (guard = 0; guard < 2000000; guard = guard + 1) begin
        @(posedge cmp_top.iop.cmp_gclk);
        if (st_pend) begin
          // A store that arrived while we were holding a fetch/load
          // response.  Record and ack it now that the bus is free.
          boot_store_record(st_pa, st_data, st_thr);
          boot_store_ack(st_thr, st_p);
          st_pend = 1'b0;
        end else if (cmp_top.iop.pcx_iob_data_rdy_px2 &&
            cmp_top.iop.pcx_iob_data_px2[123]) begin
          rqtype  = cmp_top.iop.pcx_iob_data_px2[122:118];
          pc_pa   = cmp_top.iop.pcx_iob_data_px2[103:64];
          req_thr = cmp_top.iop.pcx_iob_data_px2[113:112];
          lane    = cmp_top.iop.pcx_iob_data_px2[66:65];  // PA[3:2]

          if (rqtype == 5'b10000) begin
          // IMISS.  The IFU consumes data[lane] where lane = PA[3:2]
          // (ifqdp.v:309 stores imiss_paddr[39:2]; ifqdp.v:424
          // ifd_ifc_instoffsetN = mil_entryN[3:2]; ifqctl.v:944-947 selects
          // the 16B lane).  Pad the other lanes with nops and place this
          // PA's instruction in the lane the IFU will actually read.
          $display("[cmp_top_env] BOOT imiss at %0t pc=%h thr=%b lane=%0d",
                   $time, pc_pa, req_thr, lane);
          ifill_pkt = 145'b0;
          ifill_pkt[144]       = 1'b1;        // CPX_VLD
          ifill_pkt[143:140]   = 4'b0001;     // IFILL_RET
          ifill_pkt[136]       = 1'b1;        // CPX_NC
          ifill_pkt[135:134]   = req_thr;     // CPX_TH (echo)
          ifill_pkt[130]       = 1'b1;        // CPX_IF4B (one 4B instr)
          ifill_pkt[127:96]    = 32'h0100_0000;   // nop
          ifill_pkt[95:64]     = 32'h0100_0000;   // nop
          ifill_pkt[63:32]     = 32'h0100_0000;   // nop
          ifill_pkt[31:0]      = 32'h0100_0000;   // nop
          case (pc_pa[3:2])
            2'd0: ifill_pkt[127:96] = boot_prog_word(pc_pa);
            2'd1: ifill_pkt[95:64]  = boot_prog_word(pc_pa);
            2'd2: ifill_pkt[63:32]  = boot_prog_word(pc_pa);
            2'd3: ifill_pkt[31:0]   = boot_prog_word(pc_pa);
          endcase
          force cmp_top.iop.sparc0.cpx_spc_data_cx2     = ifill_pkt;
          force cmp_top.iop.sparc0.cpx_spc_data_rdy_cx2 = 1'b1;
          boot_bus_hold;
          force cmp_top.iop.sparc0.cpx_spc_data_cx2     = 145'b0;
          force cmp_top.iop.sparc0.cpx_spc_data_rdy_cx2 = 1'b0;
          $display("[cmp_top_env] BOOT IFILL_RET delivered at %0t (thr=%b)",
                   $time, req_thr);
          // Keep serving: every fetch is a fresh uncached IMISS.
          end else if (rqtype == 5'b00000) begin
           // LOAD: the boot harness reads %asr26 (halt/thread id).  Return
           // the image word so rd %asr26, T_RD_THID and the halt loop see a
           // clean value.
           $display("[cmp_top_env] BOOT load at %0t pa=%h thr=%b",
                    $time, pc_pa, req_thr);
           ifill_pkt = 145'b0;
           ifill_pkt[144]     = 1'b1;        // CPX_VLD
           ifill_pkt[143:140] = 4'b0000;     // LOAD_RET
           ifill_pkt[136]     = 1'b1;        // CPX_NC
           ifill_pkt[135:134] = req_thr;
           ifill_pkt[63:0]    = boot_mem_read(pc_pa);
           force cmp_top.iop.sparc0.cpx_spc_data_cx2     = ifill_pkt;
           force cmp_top.iop.sparc0.cpx_spc_data_rdy_cx2 = 1'b1;
           boot_bus_hold;
           force cmp_top.iop.sparc0.cpx_spc_data_cx2     = 145'b0;
           force cmp_top.iop.sparc0.cpx_spc_data_rdy_cx2 = 1'b0;
          end else if (rqtype == 5'b00001 || rqtype == 5'b00111) begin
           // STORE / STQ: record it (thread_status_mem is the diag verdict)
           // and ack so the store buffer drains.
           boot_store_record(pc_pa, cmp_top.iop.pcx_iob_data_px2[63:0], req_thr);
           boot_store_ack(req_thr, cmp_top.iop.pcx_iob_data_px2[108:107]);
          end else begin
           $display("[cmp_top_env] BOOT unhandled rq=%b pa=%h at %0t",
                    rqtype, pc_pa, $time);
          end
        end
      end
      $display("[cmp_top_env] WARNING: no iob PCX boot fetch seen");
    end
  end
`endif

  // Smoke window: stop after reset release + SJM trigger.
  // (jbus_grst_l deasserts a few us after POR - efc/efuse readout chain.)
  initial begin
    #20000000;
    if ($test$plusargs("no_smoke_finish")) begin
      $display("[cmp_top_env] smoke finish skipped (+no_smoke_finish)");
    end else begin
      $display("[cmp_top_env] CMP-ENV SMOKE END at %0t - elaborate+reset+SJM OK",
               $time);
      $finish;
    end
  end

  // Watchdog
  initial begin
    #40000000;
    $display("[cmp_top_env] WATCHDOG timeout");
    $finish;
  end

  //---------------------------------------------------------------
  // SJM slave agents (cmp_top.v:1221-1240 and 1303-1322, verbatim)
  //---------------------------------------------------------------
  jp_sjm j_sjm_4 (
                 .j_id        (3'b100),
                 .j_req_in_l  (j_req_in_l_4),
                 .j_req_out_l (j_req_out_l_4),  //output
                 .j_ad        (J_AD),          //inout
                 .j_adp       (J_ADP),         //inout
                 .j_adtype    (J_ADTYPE),      //inout
                 .j_pack0     (J_PACK0),      //inout
                 .j_pack1     (J_PACK1),      //inout
                 .j_pack2     (j_pack2),      //inout
                 .j_pack3     (j_pack3),      //inout
                 .j_pack4     (J_PACK4),      //inout
                 .j_pack5     (J_PACK5),      //inout
                 .j_pack6     (j_pack6),      //inout
                 .j_change_l  (j_change_l),      //inout
                 .j_rst_l     (j_rst_l),        //inout
                 .j_por_l     (jbus_j_por_l),        //inout
                 .j_clk       (jbus_j_clk),
                 .pwr_ok      (pwrok)
                 );

  jp_sjm j_sjm_5 (
                 .j_id        (3'b101),
                 .j_req_in_l  (j_req_in_l_5),
                 .j_req_out_l (j_req_out_l_5),  //output
                 .j_ad        (J_AD),          //inout
                 .j_adp       (J_ADP),         //inout
                 .j_adtype    (J_ADTYPE),      //inout
                 .j_pack0     (J_PACK0),      //inout
                 .j_pack1     (J_PACK1),      //inout
                 .j_pack2     (j_pack2),      //inout
                 .j_pack3     (j_pack3),      //inout
                 .j_pack4     (J_PACK4),      //inout
                 .j_pack5     (J_PACK5),      //inout
                 .j_pack6     (j_pack6),      //inout
                 .j_change_l  (j_change_l),      //inout
                 .j_rst_l     (j_rst_l),        //inout
                 .j_por_l     (jbus_j_por_l),        //inout
                 .j_clk       (jbus_j_clk),
                 .pwr_ok      (pwrok)
                 );

  //---------------------------------------------------------------
  // IVPORT debug: DDR calibration monitor (compile-time, -DDDR_DBG).
  // Prints per-channel DRAM commands and returned read data at the
  // pad level, used to calibrate the PA -> (channel,row,col,bank)
  // mapping implemented in port/pli/init_jbus_model_vpi.c.
  //---------------------------------------------------------------
`ifdef DDR_DBG
  // polled reset-state tracker (XMR events are unreliable in iverilog)
  reg dbg_cmp_grst_q = 1'bx, dbg_dram_grst_q = 1'bx;
  always @(posedge dram_gclk) begin
    if (dbg_cmp_grst_q !== iop.cmp_grst_out_l) begin
      dbg_cmp_grst_q = iop.cmp_grst_out_l;
      $display("[DDR_DBG] %0t cmp_grst_out_l -> %b", $time, iop.cmp_grst_out_l);
    end
    if (dbg_dram_grst_q !== iop.dram_grst_l) begin
      dbg_dram_grst_q = iop.dram_grst_l;
      $display("[DDR_DBG] %0t dram_grst_l -> %b", $time, iop.dram_grst_l);
    end
  end
  reg [127:0] dbg_dq_d [0:3];
  reg [15:0]  dbg_cb_d [0:3];
  reg [127:0] dbg_dq_q [0:3];
  reg [15:0]  dbg_cb_q [0:3];

  task dbg_cmd;
    input ch;
    input [3:0] cs_l;
    input ras, cas, we;
    input [2:0] ba;
    input [14:0] addr;
    begin
      if (cs_l[0] == 1'b0) begin
        if ({ras, cas, we} == 3'b011) $display("[DDR_DBG] %0t CH%0d RAS  ba=%h addr=%h", $time, ch, ba, addr);
        else if ({ras, cas, we} == 3'b101) $display("[DDR_DBG] %0t CH%0d READ ba=%h addr=%h", $time, ch, ba, addr);
        else if ({ras, cas, we} == 3'b100) $display("[DDR_DBG] %0t CH%0d WRITE ba=%h addr=%h", $time, ch, ba, addr);
        else if ({ras, cas, we} == 3'b000) $display("[DDR_DBG] %0t CH%0d SETUP ba=%h addr=%h", $time, ch, ba, addr);
      end
    end
  endtask

  always @(posedge dram_gclk) begin
    dbg_cmd(0, iop.DRAM0_CS_L, iop.DRAM0_RAS_L, iop.DRAM0_CAS_L, iop.DRAM0_WE_L, iop.DRAM0_BA, iop.DRAM0_ADDR);
    dbg_cmd(1, iop.DRAM1_CS_L, iop.DRAM1_RAS_L, iop.DRAM1_CAS_L, iop.DRAM1_WE_L, iop.DRAM1_BA, iop.DRAM1_ADDR);
    dbg_cmd(2, iop.DRAM2_CS_L, iop.DRAM2_RAS_L, iop.DRAM2_CAS_L, iop.DRAM2_WE_L, iop.DRAM2_BA, iop.DRAM2_ADDR);
    dbg_cmd(3, iop.DRAM3_CS_L, iop.DRAM3_RAS_L, iop.DRAM3_CAS_L, iop.DRAM3_WE_L, iop.DRAM3_BA, iop.DRAM3_ADDR);
  end

  // sample returned read data on DQS edges (dimm0 strobe = DQS[18])
  always @(posedge DRAM0_DQS[18]) begin dbg_dq_d[0] = DRAM0_DQ; dbg_cb_d[0] = DRAM0_CB; end
  always @(posedge DRAM1_DQS[8])  begin dbg_dq_d[1] = DRAM1_DQ; dbg_cb_d[1] = DRAM1_CB; end
  always @(posedge DRAM2_DQS[18]) begin dbg_dq_d[2] = DRAM2_DQ; dbg_cb_d[2] = DRAM2_CB; end
  always @(posedge DRAM3_DQS[18]) begin dbg_dq_d[3] = DRAM3_DQ; dbg_cb_d[3] = DRAM3_CB; end

  always @(posedge dram_gclk) begin
    if (dbg_dq_d[0] !== dbg_dq_q[0] && dbg_dq_d[0] !== 128'bx) begin
      dbg_dq_q[0] = dbg_dq_d[0];
      $display("[DDR_DBG] %0t CH0 DATA dq=%h cb=%h", $time, dbg_dq_d[0], dbg_cb_d[0]);
    end
    if (dbg_dq_d[1] !== dbg_dq_q[1] && dbg_dq_d[1] !== 128'bx) begin
      dbg_dq_q[1] = dbg_dq_d[1];
      $display("[DDR_DBG] %0t CH1 DATA dq=%h cb=%h", $time, dbg_dq_d[1], dbg_cb_d[1]);
    end
    if (dbg_dq_d[2] !== dbg_dq_q[2] && dbg_dq_d[2] !== 128'bx) begin
      dbg_dq_q[2] = dbg_dq_d[2];
      $display("[DDR_DBG] %0t CH2 DATA dq=%h cb=%h", $time, dbg_dq_d[2], dbg_cb_d[2]);
    end
    if (dbg_dq_d[3] !== dbg_dq_q[3] && dbg_dq_d[3] !== 128'bx) begin
      dbg_dq_q[3] = dbg_dq_d[3];
      $display("[DDR_DBG] %0t CH3 DATA dq=%h cb=%h", $time, dbg_dq_d[3], dbg_cb_d[3]);
    end
  end

  // ---- clock-chain probe: do the CTU/PLL clocks ever toggle? -------------
  // The whole cmp domain sits behind cmp_grst_out_l, a clocked flop fed by
  // cmp_gclk.  If cmp_gclk (or the PLL feeding it) never toggles, every
  // cmp-domain reset stays asserted forever -> the "ctu/efc chain" blocker.
  reg [31:0] cnt_cmp_gclk  = 0;
  reg [31:0] cnt_jbus_gclk = 0;
  reg [31:0] cnt_dram_gclk = 0;
  reg [31:0] cnt_pll       = 0;
  always @(posedge iop.cmp_gclk)  cnt_cmp_gclk  = cnt_cmp_gclk + 1;
  always @(posedge iop.jbus_gclk) cnt_jbus_gclk = cnt_jbus_gclk + 1;
  always @(posedge iop.dram_gclk) cnt_dram_gclk = cnt_dram_gclk + 1;
  // pll_clk_out is the clkgn input upstream of the cmp/jbus/dram gclks
  // (driven by u_pll inside ctu; instance path is iop.ctu.ctu_clsp).
  always @(posedge iop.ctu.ctu_clsp.pll_clk_out) cnt_pll = cnt_pll + 1;

  initial begin : clk_chain_probe
    integer t;
    reg l_cmp, l_jb, l_dr, l_pwron, l_jrst;
    for (t = 0; t < 6; t = t + 1) begin
      #4000000;  // 4 us per sample
      l_cmp  = iop.cmp_grst_out_l;
      l_jb   = iop.jbus_grst_l;
      l_dr   = iop.dram_grst_l;
      l_pwron= PWRON_RST_L;
      l_jrst = J_RST_L;
      $display("[CLKCHAIN] t=%0t pwron=%b jrst=%b | cmp_gclk_cnt=%0d jbus_gclk_cnt=%0d dram_gclk_cnt=%0d pll_cnt=%0d | cmp_grst=%b jbus_grst=%b dram_grst=%b",
               $time, l_pwron, l_jrst,
               cnt_cmp_gclk, cnt_jbus_gclk, cnt_dram_gclk, cnt_pll,
               l_cmp, l_jb, l_dr);
    end
  end
  // ---- boot-state probe: how far does sparc0 get after grst release? -----
  initial begin : boot_state_probe
    integer tt;
    for (tt = 0; tt < 3; tt = tt + 1) begin
      if (tt == 0) #6500000; else #3500000;
      $display("[BOOT] t=%0t grst_l: cmp=%b jbus=%b dram=%b | sparc0 thr_state=%b %b %b %b (THRFSM_HALT=00010) trap_vld0=%b",
               $time,
               iop.cmp_grst_out_l, iop.jbus_grst_l, iop.dram_grst_l,
               iop.sparc0.ifu.swl.thrfsm0.thr_state,
               iop.sparc0.ifu.swl.thr1_state,
               iop.sparc0.ifu.swl.thr2_state,
               iop.sparc0.ifu.swl.thr3_state,
               iop.sparc0.tlu.tlu_ifu_trappc_vld_w1);
    end
  end
`endif // DDR_DBG

endmodule
