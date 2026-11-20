// =====================================================================
// port/env/mem_backdoor.v - back-door memory array for $init_jbus_model.
//
// The functional DDR environment now has TWO DIMM variants (see
// port/env/cmp_dram.f):
//   - dimm_mem.v (default): functional model with a real 72-bit array;
//     $init_jbus_model ALSO writes the image into
//     cmp_top.cmp_dram.memN.dimmM.mem (redundantly across all
//     channels/ranks; see port/pli/init_jbus_model_vpi.c for the
//     PA->index mapping and its documented caveats).
//   - dimm_stub.v (compile with -DINERT_DIMM): the original inert
//     pad-level stub, kept for the old smoke path.  With the stub,
//     only this backdoor array receives the image.
// So with the functional DIMMs the image is staged BOTH here and in
// the DIMM storage; this array remains as a bench-side scratch copy.
// =====================================================================

`timescale 1ps/1ps

module mem_backdoor;

  // 128KB flat window, 64-bit words, initialized to X so untouched
  // entries are visible in waves.
  reg [63:0] mem [0:16383];

  initial begin
    // Reference the array so Icarus elaborates it (it is otherwise only
    // reached from the $init_jbus_model VPI back door and may be
    // optimized away as dead storage).
    #0;
    $display("[mem_backdoor] backdoor array ready at cmp_top.mem_backdoor.mem (mem[0]=%h)",
             mem[0]);
  end

endmodule
