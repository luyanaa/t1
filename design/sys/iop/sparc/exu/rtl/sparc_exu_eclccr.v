// ========== Copyright Header Begin ==========================================
// 
// OpenSPARC T1 Processor File: sparc_exu_eclccr.v
// Copyright (c) 2006 Sun Microsystems, Inc.  All Rights Reserved.
// DO NOT ALTER OR REMOVE COPYRIGHT NOTICES.
// 
// The above named program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public
// License version 2 as published by the Free Software Foundation.
// 
// The above named program is distributed in the hope that it will be 
// useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// General Public License for more details.
// 
// You should have received a copy of the GNU General Public
// License along with this work; if not, write to the Free Software
// Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1301, USA.
// 
// ========== Copyright Header End ============================================
////////////////////////////////////////////////////////////////////////
/*
//  Module Name: sparc_exu_eclccr
//	Description: 4 bit condition code registers with forwarding.  Takes
//	the e_stage result and writes on the w stage.
*/

`include "sparc_config.h"

module sparc_exu_eclccr (/*AUTOARG*/
   // Outputs
   exu_ifu_cc_d, exu_tlu_ccr0_w, exu_tlu_ccr1_w, exu_tlu_ccr2_w, 
   exu_tlu_ccr3_w, 
   // Inputs
   clk, se, alu_xcc_e, alu_icc_e, tid_d, thrdec_d, thr_match_dm, 
   thr_match_de, tid_w, thr_w, ifu_exu_kill_e, ifu_exu_setcc_d, 
   byp_ecl_wrccr_data_w, wb_ccr_wrccr_w, wb_ccr_setcc_g, 
   divcntl_ccr_cc_w2, wb_ccr_thr_g, tlu_exu_cwpccr_update_m, 
   tlu_exu_ccr_m, ifu_exu_inst_vld_w, ifu_tlu_flush_w, early_flush_w
   ) ;
   input clk;
   input se;
   input [3:0] alu_xcc_e;    // condition codes from the alu
   input [3:0] alu_icc_e;
   input [1:0] tid_d;   // thread for each stage
   input [3:0] thrdec_d;   // decoded tid_d for mux select
   input       thr_match_dm;
   input       thr_match_de;
   input [1:0] tid_w;
   input [3:0] thr_w;        // decoded tid_w
   input       ifu_exu_kill_e;
   input       ifu_exu_setcc_d;
   input [7:0] byp_ecl_wrccr_data_w;// for the WRCCR operation (LSBs of
   input       wb_ccr_wrccr_w; // ALU result) + wen signal
   input       wb_ccr_setcc_g;
   input [7:0] divcntl_ccr_cc_w2;
   input [1:0] wb_ccr_thr_g;
   input       tlu_exu_cwpccr_update_m;
   input [7:0] tlu_exu_ccr_m;
   input       ifu_exu_inst_vld_w;
   input       ifu_tlu_flush_w;
   input       early_flush_w;
   
   output [7:0] exu_ifu_cc_d;   // condition codes for current thread
   output [7:0] exu_tlu_ccr0_w;
   output [7:0] exu_tlu_ccr1_w;
   output [7:0] exu_tlu_ccr2_w;
   output [7:0] exu_tlu_ccr3_w;

   // Parameterized per-thread CCR copies (1/2/4).
   parameter THREADS = `SPARC_SMT;

   wire [7:0]   partial_cc_d;   // partial bypassed ccr
   wire [7:0]   alu_cc_e;   // alu combined condition codes
   wire [7:0]   alu_cc_m;   // m stage alu ccs
   wire [7:0]   alu_cc_w; 
   wire [7:0]   exu_ifu_cc_w;   // writeback data
   wire         setcc_e;        // from previous stage
   wire         setcc_m;
   wire         setcc_w;
   wire         valid_setcc_e;  // after comparing with kill
   wire         valid_setcc_m;
   wire         valid_setcc_w;
   wire         setcc_w2;
   wire [7:0]   ccrin_thr [0:THREADS-1];
   wire [7:0]   ccr_d;
   wire [7:0]   ccr_thr [0:THREADS-1];
   wire [7:0]   ccr_out [0:3];
   wire         use_alu_cc;
   wire         use_ccr;
   wire         use_cc_e;
   wire         use_cc_m;
   wire         use_cc_w;
   wire  [1:0]   tid_dxorw;
   wire         thr_match_de;
   wire         thrmatch_w;
   wire [1:0]   thr_w2;
   wire          bypass_cc_w;

   wire [7:0]    ccr_m;


   // D2E flops
   dff_s dff_setcc_d2e(.din(ifu_exu_setcc_d), .clk(clk), .q(setcc_e),
                     .se(se), .si(), .so());
   
   // E stage
   assign       alu_cc_e = {alu_xcc_e, alu_icc_e};
   assign       valid_setcc_e = setcc_e & ~ifu_exu_kill_e;

   dff_s #(8) dff_cc_e2m(.din(alu_cc_e[7:0]), .clk(clk), .q(alu_cc_m[7:0]),
                  .se(se), .si(), .so());
   dff_s dff_setcc_e2m(.din(valid_setcc_e), .clk(clk), .q(setcc_m),
                     .se(se), .si(), .so());
   
   // M stage
   assign       valid_setcc_m = setcc_m | tlu_exu_cwpccr_update_m;
   mux2ds #(8) mux_ccr_m(.dout(ccr_m[7:0]),
                            .in0(alu_cc_m[7:0]),
                            .in1(tlu_exu_ccr_m[7:0]),
                            .sel0(~tlu_exu_cwpccr_update_m),
                            .sel1(tlu_exu_cwpccr_update_m));

   dff_s #(8) dff_cc_m2w(.din(ccr_m[7:0]), .clk(clk), .q(alu_cc_w[7:0]),
                  .se(se), .si(), .so());
   dff_s dff_setcc_m2w(.din(valid_setcc_m), .clk(clk), .q(setcc_w),
                     .se(se), .si(), .so());

   // W stage
   assign bypass_cc_w = ifu_exu_inst_vld_w & setcc_w;
   assign valid_setcc_w = ~ifu_tlu_flush_w & ~early_flush_w & ifu_exu_inst_vld_w & (setcc_w | wb_ccr_wrccr_w);

   // mux with wrccr
   assign        use_alu_cc = ~(wb_ccr_wrccr_w);
   mux2ds #(8) mux_ccrin_cc(.dout(exu_ifu_cc_w[7:0]), .sel0(wb_ccr_wrccr_w),
                          .sel1(use_alu_cc),
                          .in0(byp_ecl_wrccr_data_w[7:0]),
                          .in1(alu_cc_w[7:0]));

   dff_s #(3) setcc_g2w2 (.din({wb_ccr_setcc_g, wb_ccr_thr_g[1:0]}), .clk(clk), 
                        .q({setcc_w2, thr_w2[1:0]}),
                        .se(se), .si(), .so());

   
   /////////////////////////
   // Storage of ccr
   /////////////////////////
   genvar gi, gj;
   generate
      for (gi = 0; gi < THREADS; gi = gi + 1) begin : gen_ccr
         wire        thr_w2_dec = (thr_w2 == gi);
         wire        wen_w2     = thr_w2_dec & setcc_w2;
         wire        wen_w      = (thr_w[gi] & valid_setcc_w & ~wen_w2);
         wire        wen_l      = ~(wen_w | wen_w2);

         // mux between cc_w, cc_w2, old value, tlu value
         mux3ds #(8) mux_ccrin(
            .dout(ccrin_thr[gi][7:0]),
            .sel0(wen_w), .sel1(wen_w2), .sel2(wen_l),
            .in0(exu_ifu_cc_w[7:0]),
            .in1(divcntl_ccr_cc_w2[7:0]),
            .in2(ccr_thr[gi][7:0]));
         // store new value
         dff_s #(8) dff_ccr(
            .din(ccrin_thr[gi][7:0]), .clk(clk),
            .q(ccr_thr[gi][7:0]), .se(se), .si(), .so());
      end

      // Publish all four TLU CCR outputs; unused threads read 0.
      for (gj = 0; gj < 4; gj = gj + 1) begin : gen_ccr_out
         if (gj < THREADS)
            assign ccr_out[gj] = ccr_thr[gj];
         else
            assign ccr_out[gj] = 8'b0;
      end
   endgenerate

   // Select the requested thread's CCR for the pipeline.
   reg [7:0] ccr_d_r;
   integer k;
   always @* begin
      ccr_d_r = 8'b0;
      for (k = 0; k < 4; k = k + 1)
         if (thrdec_d[k]) ccr_d_r = ccr_out[k];
   end
   assign ccr_d[7:0] = ccr_d_r[7:0];

   
   // bypass the ccs to the output.  Only alu result needs to be bypassed
   assign        exu_ifu_cc_d[7:0] = (use_cc_e)? alu_cc_e[7:0]: partial_cc_d[7:0]; 
   mux3ds #(8) mux_ccr_bypass1(.dout(partial_cc_d[7:0]), 
                               .sel0(use_ccr),
                               .sel1(use_cc_m),
                               .sel2(use_cc_w), 
                               .in0(ccr_d[7:0]),
                               .in1(alu_cc_m[7:0]),
                               .in2(alu_cc_w[7:0]));

   assign        use_cc_e = valid_setcc_e & thr_match_de;
   assign        use_cc_m = setcc_m & thr_match_dm;
   assign        use_cc_w = bypass_cc_w & thrmatch_w & ~use_cc_m;
   assign        use_ccr = ~(use_cc_m | use_cc_w);

   assign        tid_dxorw = tid_w ^ tid_d;
   
   assign        thrmatch_w = ~(tid_dxorw[1] | tid_dxorw[0]);

   // generate ccr_w for the tlu
   assign        exu_tlu_ccr0_w[7:0] = ccr_out[0][7:0];
   assign        exu_tlu_ccr1_w[7:0] = ccr_out[1][7:0];
   assign        exu_tlu_ccr2_w[7:0] = ccr_out[2][7:0];
   assign        exu_tlu_ccr3_w[7:0] = ccr_out[3][7:0];

   
endmodule // sparc_exu_eclccr
