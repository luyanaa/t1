// ========== Copyright Header Begin ==========================================
// 
// OpenSPARC T1 Processor File: sparc_exu_div_yreg.v
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
//  Module Name: sparc_exu_div_yreg
//	Description: The per-thread 32 bit Y registers.
*/
`include "sparc_config.h"

module sparc_exu_div_yreg (/*AUTOARG*/
   // Outputs
   yreg_mdq_y_e, div_ecl_yreg_0_l, 
   // Inputs
   clk, se, byp_div_yreg_data_w, mul_div_yreg_data_g, ecl_div_thr_e, 
   ecl_div_yreg_wen_w, ecl_div_yreg_wen_g, ecl_div_yreg_wen_l, 
   ecl_div_yreg_data_31_g, ecl_div_yreg_shift_g
   ) ;
   // Number of per-thread Y registers (1/2/4 from sparc_config.h).
   parameter THREADS = `SPARC_SMT;

   input clk;
   input se;
   input [31:0] byp_div_yreg_data_w;
   input [31:0] mul_div_yreg_data_g;
   input [3:0]  ecl_div_thr_e;
   input [3:0]  ecl_div_yreg_wen_w;
   input [3:0]  ecl_div_yreg_wen_g;
   input [3:0]  ecl_div_yreg_wen_l;// w or w2
   input        ecl_div_yreg_data_31_g;// bit shifted in on muls
   input [3:0]  ecl_div_yreg_shift_g;// yreg should be shifted
   
   output [31:0] yreg_mdq_y_e;
   output [3:0]  div_ecl_yreg_0_l;

   wire [31:0]   next_yreg_thr [0:THREADS-1];
   wire [31:0]   yreg_thr [0:THREADS-1];
   wire [3:0]    div_ecl_yreg_0;
   wire [31:0]   yreg_data_w1;

   // pass along yreg w to w2 (for control signal timing)
   dff_s #(32) yreg_dff_w2w2(.din(byp_div_yreg_data_w[31:0]), .clk(clk),
                             .q(yreg_data_w1[31:0]), .se(se), .si(), .so());

   genvar i;
   generate
      for (i = 0; i < THREADS; i = i + 1) begin : gen_yreg
         // mux between yreg_w, yreg_g, old value, shifted value
         mux4ds #(32) mux_yregin(
            .dout(next_yreg_thr[i][31:0]),
            .sel0(ecl_div_yreg_wen_w[i]),
            .sel1(ecl_div_yreg_wen_g[i]),
            .sel2(ecl_div_yreg_wen_l[i]),
            .sel3(ecl_div_yreg_shift_g[i]),
            .in0(yreg_data_w1[31:0]),
            .in1(mul_div_yreg_data_g[31:0]),
            .in2(yreg_thr[i][31:0]),
            .in3({ecl_div_yreg_data_31_g, yreg_thr[i][31:1]}));
         dff_s #(32) dff_yreg(
            .din(next_yreg_thr[i][31:0]), .clk(clk),
            .q(yreg_thr[i][31:0]), .se(se), .si(), .so());
      end
   endgenerate

   // Select the requested thread's Y register.
   reg [31:0] yreg_out_r;
   integer j;
   always @* begin
      yreg_out_r = 32'b0;
      for (j = 0; j < THREADS; j = j + 1)
         if (ecl_div_thr_e[j]) yreg_out_r = yreg_thr[j];
   end
   assign yreg_mdq_y_e[31:0] = yreg_out_r[31:0];

   // LSB of all four threads; unused threads read 0.
   genvar k;
   generate
      for (k = 0; k < 4; k = k + 1) begin : gen_lsb
         if (k < THREADS)
            assign div_ecl_yreg_0[k] = yreg_thr[k][0];
         else
            assign div_ecl_yreg_0[k] = 1'b0;
      end
   endgenerate
   assign div_ecl_yreg_0_l[3:0] = ~div_ecl_yreg_0[3:0];

endmodule // sparc_exu_div_yreg
