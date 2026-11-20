// jbus_boot_resp.v - open-source JBus/IO-bridge boot responder.
//
// WHY THIS EXISTS
// ---------------
// In the cmp_top-level env the sparc0 reset fetch (RSTVADDR_BASE
// 34'h3_ffff_c000) is issued as an UNCACHED IMISS whose PCX destination is
// the FP/IO bridge (dest 4), i.e. it is answered over the JBus by an external
// ROM/tester - NOT by DRAM and NOT by the L2 banks.  With `iobdg` not compiled
// (`ifdef RTL_IOBDG) there is no IO bridge at all, so the request goes out on
// the ccx PCX "iob" port and nothing ever answers -> sparc0 thread0 hangs in
// THRFSM_WAIT (sparc_ifu_thrfsm.v:126).
//
// This module sits exactly at the boundary where `iobdg`/i2c would answer:
//   request  in : iop.pcx_iob_data_px2 / pcx_iob_data_rdy_px2  (PCX packet)
//   response out: iop.iob_cpx_req_cq   / iop.iob_cpx_data_ca   (CPX packet)
// i.e. it plays the role of i2c_fdp -> iob_cpx_* for the boot fetch.
//
// It returns a synthesised instruction stream for the reset window so that the
// CPU executes a deterministic self-loop instead of hanging:
//   every returned 64-bit word is  sethi %hi(loop), %g0 ; ba loop ... encoded
// as a simple "ba ." (branch always to self) so the core spins at a known PC
// that the monitor can trap on.  Override the word with +boot_word=<hex>.
//
// PCX field positions (design/sys/iop/include/iop.h:80-104):
//   PCX_VLD=123  PCX_RQ[122:118]  PCX_NC=117  PCX_CP[116:114] PCX_TH[113:112]
//   PCX_BF[111:109] PCX_SZ[106:104] PCX_AD[103:64]
// CPX field positions (iop.h:111-177):
//   CPX_VLD=144  CPX_RQ[143:140]  CPX_ERR[139:137] CPX_NC=136 CPX_TH[135:134]
//   CPX_DA[127:0]

`timescale 1ps/1ps

module jbus_boot_resp (
  input             clk,          // cmp-domain clock (cmp_gclk)
  input             rst_l,        // cmp reset (active low)
  // PCX request from the ccx "iob" port (driven by the chip)
  input  [123:0]    pcx_req,      // iop.pcx_iob_data_px2
  input             pcx_req_rdy,  // iop.pcx_iob_data_rdy_px2
  // CPX response back toward ccx (we drive these)
  output reg [7:0]  cpx_req,      // iop.iob_cpx_req_cq
  output reg [144:0] cpx_data,    // iop.iob_cpx_data_ca
  output reg        pcx_stall     // iop.iob_pcx_stall_pq
);

  //------------------------------------------------------------------
  // Parameterised PCX / CPX bit positions
  //------------------------------------------------------------------
  localparam PCX_VLD   = 123;
  localparam PCX_RQ_HI = 122;
  localparam PCX_RQ_LO = 118;
  localparam PCX_NC    = 117;
  localparam PCX_TH_HI = 113;
  localparam PCX_TH_LO = 112;
  localparam PCX_SZ_HI = 106;
  localparam PCX_SZ_LO = 104;
  localparam PCX_AD_HI = 103;
  localparam PCX_AD_LO = 64;

  localparam CPX_VLD   = 144;
  localparam CPX_RQ_HI = 143;
  localparam CPX_RQ_LO = 140;
  localparam CPX_TH_HI = 135;
  localparam CPX_TH_LO = 134;
  localparam CPX_DA_HI = 127;
  localparam CPX_DA_LO = 0;

  localparam IMISS_RQ  = 5'b10000;   // iop.h
  localparam IFILL_RET = 4'b0001;    // iop.h

  //------------------------------------------------------------------
  // Boot instruction word.  Default = SPARC "ba ." (branch always, +0)
  //   op=00 (00), a=1, cond=1000 (ba), disp22=0  -> 0x10800000
  // The high 32b of the 64-bit word carry the NEXT instruction slot, so
  // returning  {0x01000000, 0x10800000} gives "ba .; nop" which the IFU
  // will keep executing/re-fetching - a stable, observable boot loop.
  // Override with +boot_word=<64-bit hex>.
  //------------------------------------------------------------------
  reg [63:0] boot_word;
  initial begin
    boot_word = 64'h0100_0000_1080_0000;   // {nop, ba .}
    if (!$value$plusargs("boot_word=%h", boot_word))
      boot_word = 64'h0100_0000_1080_0000;
    cpx_req   = 8'b0;
    cpx_data  = 145'b0;
    pcx_stall = 1'b0;
  end

  //------------------------------------------------------------------
  // Monotonic PCX index for the boot window (word address >> 3).
  // The reset fetch address is 0x3_ffff_c000; we simply serve a
  // self-loop at every 8-byte slot in the returned 16B line so the
  // core cannot run off into unmapped space.
  //------------------------------------------------------------------
  reg        pend;                 // a return is being presented
  reg [1:0]  beat;                 // 2-cycle IFILL_RET presentation
  reg [1:0]  req_thr;              // echo the requesting thread

  always @(posedge clk) begin
    if (!rst_l) begin
      cpx_req   <= 8'b0;
      cpx_data  <= 145'b0;
      pcx_stall <= 1'b0;
      pend      <= 1'b0;
      beat      <= 2'b0;
    end else begin
      // Deassert the return after it has been presented for 2 cycles.
      if (pend) begin
        if (beat == 2'b01) begin
          pend    <= 1'b0;
          beat    <= 2'b0;
          cpx_req <= 8'b0;
          cpx_data<= 145'b0;
        end else begin
          beat <= beat + 2'b01;
        end
      end

      // Accept a new boot-fetch request: an uncached IMISS to the iob port.
      if (pcx_req_rdy && pcx_req[PCX_VLD] &&
          (pcx_req[PCX_RQ_HI:PCX_RQ_LO] == IMISS_RQ) && !pend) begin
        req_thr <= pcx_req[PCX_TH_HI:PCX_TH_LO];
        // Build the CPX return: IFILL_RET, NC=1, echo thread, data = boot loop.
        cpx_data <= 145'b0;
        cpx_data[CPX_VLD]                    <= 1'b1;
        cpx_data[CPX_RQ_HI:CPX_RQ_LO]        <= IFILL_RET;
        cpx_data[136]                        <= 1'b1;         // CPX_NC
        cpx_data[CPX_TH_HI:CPX_TH_LO]        <= pcx_req[PCX_TH_HI:PCX_TH_LO];
        cpx_data[CPX_DA_HI:CPX_DA_LO]        <= {2{boot_word}};
        cpx_req  <= 8'b0000_0001;   // one valid return on port 0
        pend     <= 1'b1;
        beat     <= 2'b0;
        // Never backpressure during boot.
        pcx_stall<= 1'b0;
      end
    end
  end

`ifdef BOOT_RESP_DBG
  always @(posedge clk) begin
    if (rst_l && pcx_req_rdy && pcx_req[PCX_VLD])
      $display("[BOOT_RESP] %0t pcx req rq=%b nc=%b thr=%b addr=%h",
               $time, pcx_req[PCX_RQ_HI:PCX_RQ_LO], pcx_req[PCX_NC],
               pcx_req[PCX_TH_HI:PCX_TH_LO], pcx_req[PCX_AD_HI:PCX_AD_LO]);
  end
`endif

endmodule
