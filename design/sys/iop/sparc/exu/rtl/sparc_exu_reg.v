// ========== Copyright Header Begin ==========================================
// 
// OpenSPARC T1 Processor File: sparc_exu_reg.v
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
`include "sparc_config.h"

module sparc_exu_reg (/*AUTOARG*/
   // Outputs
   data_out, 
   // Inputs
   clk, se, thr_out, wen_w, thr_w, data_in_w
   ) ;
   parameter SIZE = 3;
   // Number of per-thread copies.  SPARC_SMT is 1/2/4 from sparc_config.h.
   parameter THREADS = `SPARC_SMT;

   input     clk;
   input     se;
   input [3:0]       thr_out;
   input             wen_w;
   input [3:0]       thr_w;
   input [SIZE -1:0] data_in_w;

   output [SIZE-1:0] data_out;

   wire [SIZE-1:0]   data_thr [0:THREADS-1];
   wire [SIZE-1:0]   data_thr_next [0:THREADS-1];
   wire [THREADS-1:0] wen_thr_w;

   genvar i;
   generate
      for (i = 0; i < THREADS; i = i + 1) begin : gen_thr
         assign wen_thr_w[i] = (thr_w[i] & wen_w);
         // mux between new and current value
         mux2ds #(SIZE) data_next_mux(
            .dout(data_thr_next[i][SIZE-1:0]),
            .in0 (data_thr[i][SIZE-1:0]),
            .in1 (data_in_w[SIZE-1:0]),
            .sel0(~wen_thr_w[i]),
            .sel1(wen_thr_w[i]));
         dff_s #(SIZE) dff_reg(
            .din(data_thr_next[i][SIZE-1:0]),
            .clk(clk),
            .q  (data_thr[i][SIZE-1:0]),
            .se (se), .si(), .so());
      end
   endgenerate

   // Select the requested thread.  thr_out remains a 4-bit one-hot vector
   // (TID is still 2 bits for PCX/CPX compatibility); unused bits read 0.
   reg [SIZE-1:0] data_out_r;
   integer j;
   always @* begin
      data_out_r = {SIZE{1'b0}};
      for (j = 0; j < THREADS; j = j + 1) begin
         if (thr_out[j])
            data_out_r = data_thr[j];
      end
   end
   assign data_out = data_out_r;

endmodule // sparc_exu_reg
