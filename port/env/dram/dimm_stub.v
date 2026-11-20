// dimm_stub.v - Phase-1 open-source replacement for the Sun DDR2 DIMM model
// (model_verilog/mem/dram/dimm.v).  The original dimm model depends on the
// Denali-style PLI system tasks $read_mem()/$write_mem() (dimm.v:251, dimm.v:291)
// which are unavailable under Icarus Verilog without SJM/PLI (forbidden in the
// Phase-1 port).  This stub provides a module named `dimm` with the identical
// port list so ch_mem (env_cmp/ch_mem.v) elaborates; the data pins are left
// permanently tri-stated, i.e. the DIMMs are inert.  Functional DRAM traffic
// is Phase-2 work.

`timescale 1ps/1ps

// IVPORT: only compiled when INERT_DIMM is defined (see dimm_mem.v for
// the functional replacement used by the default cmp-env build).
`ifdef INERT_DIMM

module dimm(// inputs
	clk, cs, ras, cas, we, ba, addr, cs_sel,
	// inouts
	dataq, ecc, dqs, dm_rdqs
	);

   parameter addr_width=17,
`ifdef DRAM_BANK_BITS2
             bank_width=2,
`else
             bank_width=3,
`endif
	     dqs_width=9;

   // inputs
   input [2:0]             clk;
   input [1:0]		   cs;
   input                   ras, cas, we;
   input [(bank_width-1):0] ba;
   input [(addr_width-1):0] addr;
   input [7:0]		   cs_sel;

   // inouts
   inout [63:0] dataq;
   inout [7:0] 		   ecc;
   inout [(dqs_width-1):0]  dqs, dm_rdqs;

   // Inert DIMM: never drive the shared data pins.
   assign dataq    = 64'bz;
   assign ecc      = 8'bz;
   assign dqs      = {dqs_width{1'bz}};
   assign dm_rdqs  = {dqs_width{1'bz}};

   initial begin
      $display("[dimm_stub] %m inert DIMM instantiated (cs_sel=%b)", cs_sel);
   end

endmodule

`endif // INERT_DIMM
