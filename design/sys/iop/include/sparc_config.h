/*
 * OpenSPARC T1 configuration macros.
 *
 * These are compile-time configuration switches for the port.  They are
 * intentionally Verilog-2001 `ifdef/`ifndef macros (not SystemVerilog
 * `if) so the original RTL can still be parsed as Verilog-2001.
 *
 * SMT selection:
 *   -DSPARC_1THREAD  : one thread per core (SMT1)
 *   -DSPARC_2THREAD  : two threads per core (SMT2)
 *   (none)           : four threads per core (SMT4, default)
 *
 * FPU selection:
 *   -DSPARC_NO_FPU   : no shared FPU; FP instructions take FP_DISABLED
 *   (none)           : FPU enabled (default)
 */

`ifndef SPARC_CONFIG_H
`define SPARC_CONFIG_H

// SMT default is SMT4.
`ifndef SPARC_1THREAD
 `ifndef SPARC_2THREAD
  `ifndef SPARC_4THREAD
   `define SPARC_4THREAD
  `endif
 `endif
`endif

`ifdef SPARC_1THREAD
 `define SPARC_SMT 1
`else
 `ifdef SPARC_2THREAD
  `define SPARC_SMT 2
 `else
  `define SPARC_SMT 4
 `endif
`endif

// The Sun RTL already uses FPGA_SYN_1THREAD for its single-thread guards.
// Keep it as an alias so both names select the same path.
`ifdef SPARC_1THREAD
 `ifndef FPGA_SYN_1THREAD
  `define FPGA_SYN_1THREAD
 `endif
`endif

`ifdef SPARC_NO_FPU
 `ifndef SPARC_FPU_DISABLE
  `define SPARC_FPU_DISABLE
 `endif
`endif

// TID remains 2 bits for PCX/CPX packet compatibility; SMT1/SMT2 use TID 0/1.
`define SPARC_TID_WIDTH 2

`endif // SPARC_CONFIG_H
