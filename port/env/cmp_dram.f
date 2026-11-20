// File list for the Phase-1 behavioral DRAM environment (cmp_dram +
// ch_mem channel models + dimm_if_mon), compiled together with
// port/env/cmp_top_port.v.  All sources are copies of
// ~/t1_dram_models/env_cmp (see port/env/cmp_top_port.v header).
//
// iverilog (via `make -C port cmp-build`):
//   iverilog -g2005 -s cmp_top -f port/build/core1_rtl.f \
//            port/env/cmp_top_port.v -f port/env/cmp_dram.f \
//            -o port/build/cmp_top.vvp -DIVPORT_NO_MON \
//            -I. -Iport/tb -Iport/env -Iport/env/dram

port/env/dram/ch_mem.v
port/env/dram/cmp_dram.v
// IVPORT: cmp_dram_mon.v / dram_mon.v are skipped for Phase 1 — they are
// coverage monitors built entirely out of cross-module references, which
// Icarus Verilog cannot compile (see cmp_dram.v `IVPORT_NO_MON guard).
// port/env/dram/cmp_dram_mon.v
// port/env/dram/dram_mon.v
port/env/dram/dimm_if_mon.v
// IVPORT: cmp_mem.v (misc debug/checking tasks with hierarchical
// assignments iverilog rejects) is not needed by ch_mem/cmp_dram in
// Phase 1 — left out of the build.
// port/env/dram/cmp_mem.v
// Both DIMM variants are compiled with compile-time guards so only one
// `dimm` module exists per build:
//   default        -> dimm_mem.v  (functional: local 72b array, image
//                     preload via $init_jbus_model VPI)
//   -DINERT_DIMM   -> dimm_stub.v (old tri-state smoke fallback;
//                     e.g. make -C port cmp-env-build INERT_DIMM=1)
port/env/dram/dimm_mem.v
port/env/dram/dimm_stub.v
