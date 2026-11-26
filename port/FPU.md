# FPU verification in this port

The shared floating-point unit (`design/sys/iop/fpu/rtl/fpu.v`) is a PCX/CPX
client of the CCX: the core's FFU hands it "fpop" request packets through the
LSU, and it returns the result as a CPX packet.  In the FPGA port top
(`design/sys/iop/rtl/iop_fpga.v`) there is **no FPU instance**, so nothing in
the core-level benches ever exercised the block; `FPU=0` only turns
`sparc_ifu_swl.v`'s `fpen_s` off, which makes FP instructions trap.

Two things now cover it:

| target | what it proves |
| --- | --- |
| `make -C port fpu-unit SMT=4 FPU=1` | the real FPU block computes correct IEEE doubles and returns a well-formed CPX packet |
| `make -C port fpu-smoke SMT=4 FPU=1` | **work in progress** - core-level faddd/fsubd/fmuld/fmovd end to end |

`fpu-unit` is part of `make -C port regress` when `FPU=1` (it is skipped for
`FPU=0`, where the block is not in the netlist).

## fpu-unit

`port/tb/tb_fpu_unit.v` instantiates `fpu` directly and drives the same packets
the core would produce, one packet per cycle: operand 2 first (PCX `5'h0a`),
operand 1 second (PCX `5'h0b`).  It then waits for the CPX return and compares
data, return type and thread id bit-exactly.

```
FPU-UNIT op 42 -> 4014000000000000  (cyc +5)     3.0 + 2.0   = 5.0
FPU-UNIT op 46 -> 3ff0000000000000  (cyc +5)     3.0 - 2.0   = 1.0
FPU-UNIT op 4a -> 400e000000000000  (cyc +8)     1.5 * 2.5   = 3.75
FPU-UNIT op 4e -> 3ff8000000000000  (cyc +62)    3.0 / 2.0   = 1.5   (divider latency)
FPU-UNIT op 42 -> 3ff0000000000001  (cyc +5)     1.0 + 2^-52 = 1.0 + 1 ulp
FPU-UNIT PASS: 5 operations
```

The last case is the interesting one: it only comes out right if the 52-bit
mantissa is added with a proper guard/round/sticky path, so a truncated adder
would fail it.

## Packet formats (from the RTL, not guessed)

`sparc_ffu_ctl.v`, "Create packet for LSU: ffu_lsu_data[80:0]":

```
[80]    vld
[79:78] type   (LSU uses only [78]: 0 -> PCX 5'h0a, 1 -> 5'h0b)
[77:76] tid
[75:68] opf[7:0]
[67:66] fcc, [65:64] rounding mode, [63:0] data
```

`lsu_qdp1.v` "Format fpop_full_pcxpkt" maps that onto PCX: `PCX_RQ =
{4'b0101, ffu_lsu_data[78]}`, `PCX_TH = tid`, `[79:72] = opf`, `[67:64] =
fcc/rnd`, `[63:0] = data`.

`fpu_out_dp.v` builds the CPX return: `[144]` CPX vld, `[143:140]` `4'b1000`
(`FP_RET`), `[135:134]` thread id, `[76:72]` exception, `[63:0]` data.

Three behaviours that cost time to discover and are worth remembering:

1. **Operand order.** rs2 goes out first (`fpop1`, type `5'h0a`), rs1 second
   (`fpop2`, type `5'h0b`); the block takes the *second* packet as `src1`.
   Sending them the other way still gives correct results for `faddd`/`fmuld`
   but silently computes `rs2 - rs1` and `rs2 / rs1`.
2. **CPX is a two stage handshake.** `fp_cpx_req_cq` is a one-cycle request
   pulse and the `fp_cpx_data_ca` packet becomes valid on the *next* cycle.
   Sampling both in the same cycle captures the previous (often empty) packet.
3. **`inq_we`.** `fpu_in_ctl.v` writes the input queue on packet `5'h0a` when
   `opf[7]` is set (single-source ops such as `fmovd`) and on packet `5'h0b`
   otherwise, i.e. a two-source op only becomes visible to a pipe when the
   second packet arrives.  `opf[3:2]` selects add/sub/mul/div.

## fpu-smoke (still open)

`port/diag/fpu_smoke.s` runs four threads that enable FP (FPRS.FEF +
PSTATE.PEF), `ldd` two operands, do `faddd`/`fsubd`/`fmuld`, `std` the result
and compare it word by word.

With `-DFPU_SMOKE` the bench (`port/tb/tb_diag.v`) instantiates the real `fpu`,
splits PCX request types `5'h0a`/`5'h0b` off to it and multiplexes its CPX
returns back onto the core's CPX port.  The integration is sound for
non-FP code: the same binary passes `mt_boot_smoke.mem` with
`thread_status=000000000000000f`.

What does not work yet: after the two `ldd`s the threads reach `faddd` and
stop.  `fp_rq_count` stays 0 - the FFU never drives an fpop request onto PCX in
this harness - and since the FFU stalls the thread, the machine goes idle at
`rsp=IDLE, pcx_vld=0` with no further traffic.  The FPU itself is proven by
`fpu-unit`, so the remaining gap is the core-side FFU/LSU PCX request path,
not the arithmetic.

Earlier failures on the way here, all in the bench, not the RTL:

* the empty return FIFO read out as X and was driven onto the core's CPX data
  bus while `cpx_rdy` was low (fixed by muxing on `fp_vld_out` and reading 0
  from an empty FIFO);
* the `fpu` instance sat above the `fp_pcx_*` wire declarations, so iverilog
  made implicit 1-bit nets with a second driver (fixed by moving the instance
  below the declarations).

## Full-chip route (`port/env/cmp_top_env.v` + `+boot_mem=`)

The stripped FPGA bench cannot finish the core-level FP flow: it has no
D-cache tag/way model, so as soon as the D-cache is enabled the first `ldd`
wedges, and with it disabled `lsu_dcache_wr_vld_e` is gated off by
`~lsu_ncache_ld_e`, so the FFU always reads 0 from the FRF fill path.

The full chip (`iop`, FPU instantiated at `iop.v` PCX/CPX client) is the
alternative.  Findings, all measured, on 2026-11-26:

* The bench boots a real diag image.  `+boot_mem=<diag>.mem` (diag2hex format,
  `@idx = PA/8`) is served by the boot responder: reset vector
  `0xfff0000020` -> trap vector -> boot body `0xfff0004020` -> `main`
  (`0xfff0010000`), 45 `BOOT imiss` for `mem_rw.mem`.  `cmp_top_env` does not
  boot by itself in the default 20 us smoke window: `cmp_grst_out_l` only
  releases at ~4.7 us, so `+no_smoke_finish` (watchdog at 40 us) is required.
* The first *cacheable* data access kills the run.  With the LSU control
  register still 0, the real chip's D-cache is enabled, so the diag's first
  `stx` goes to the L2 instead of the I/O bridge, and the L2 reports
  `ERROR: L2_DATA_ERR: way select error xxx` (`scdata.v:560`,
  `sctag_scdata_way_sel_c2` is X).  The core then stalls at `0xfff0010018`
  and never reaches `ta 0`; the SJM/JBus model also wedges on a snoop
  (`snoop to address 000af3fc980 is blocked by outstanding read`).
* Driver traced to `sctag_tagctl.v:625`
  `scdata_way_sel_c2 = ~(way_sel_unqual_c2_n | {12{vld_mbf_miss_c2_n}})`,
  whose X comes from `lru_way_sel_c3` / `valid_c3`, registered in
  `sctag_tagdp_ctl.v` and fed by `lru_way_sel_c2` / `vuad_dp_valid_c2`
  (the tag RAM read plus the sctag valid/LRU state).

Simulation-only initialisation added for the full-chip build:

* `bw_r_l2t.v` (`bw_r_l2t_subbank`): `way0/way1[1023:0]` cleared under
  `RTL_L2_POR_INIT` (tag array has no reset in silicon, every compare read X);
* `bw_r_l2d_32k.v`: `way0_decc/way1_decc[1023:0]` cleared under the same macro;
* `swrvr_clib.v`: new `dff_s_por0` cell, identical to `dff_s` but with its POR
  initialisation gated by `RTL_ANY_POR_INIT`, so a handful of L2 control flops
  can be given a defined power-up state without enabling the whole-chip
  `RTL_FF_POR_INIT`.  Enabling that macro for `cmp_top_env` is NOT usable:
  it changes the CTU reset chain and `cmp_grst_out_l` never releases, so not a
  single instruction is fetched.
* `sctag_tagdp_ctl.v`: `ff_lru_way_c3`, `ff_lru_way_c3_1`, `ff_valid_c3`
  switched to `dff_s_por0`.

Status: the array init alone does not clear `L2_DATA_ERR`; the way select is
still X, so the L2 valid/LRU/arbitration control state needs its own
bring-up sweep.  Until that is done the full-chip route cannot reach the FP
instructions, and the core-level `fpu-smoke` remains blocked.
