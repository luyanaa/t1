# FPGA area baseline (GW5AST-138C)

Two configurations are measured with the same flow so the numbers are
comparable:

| Config | Make invocation | Cells | LUT4 | LUT1..4 total | MUX2_* | DFF | DFFRE | RAM16SDP4 |
|---|---|---|---|---|---|---|---|---|
| SMT=4, FPU=1 (default) | `make -C port fpga-synth` | 148720 | 47741 | 96868 | 18728 | 8587 | 23522 | 1568 |
| SMT=1, FPU=0 (reduced) | `make -C port fpga-synth SMT=1 FPU=0` | 83134 | 27681 | 48551 | 9764 | 7235 | 11894 | 962 |

Delta (SMT1/FPU0 vs default): **-65586 cells (-44.1%)**, LUT4 **-20060
(-42%)**, LUT1..4 total **-48317 (-49.9%)**, RAM16SDP4 **-606**,
DFFRE **-15628**.

Full cell dumps: `port/area/smt4_fpu1.stat`,
`port/area/smt1_fpu0.stat`.

## How to reproduce

```
make -C port fpga-synth SMT=4 FPU=1      # or nothing, those are the defaults
sed -n '/cells$/,$p' port/build/fpga/synth.log | tail -30
```

`fpga-synth` runs yosys with `-q -l port/build/fpga/synth.log`, so the `stat`
block lands in the log, not on stdout.

**Sanity check before trusting a number**: the generated script must carry
the matching defines, because yosys silently ignores a missing
`SPARC_1THREAD` and happily synthesizes the 4-thread core:

```
grep -c SPARC_1THREAD port/build/fpga/t1_fpga.ys    # 1 for SMT=1, 0 for SMT=4
grep -c SPARC_NO_FPU  port/build/fpga/t1_fpga.ys    # 1 for FPU=0
```

An earlier measurement in this repo was wrong exactly this way: a hand
written `.ys` without `-DSPARC_1THREAD` produced the SMT=4 netlist and was
reported as the SMT=1 number.

## Where the area goes

- 1568 `RAM16SDP4` in the default config are the TLB tag/data arrays
  (`core.sparc0.lsu.dtlb.bw_r_tlb_tag_ram.tte_tag_ram2`, `stb_cam.stb_ramc`,
  `ifu.itlb...`), not register files; they drop to 962 with SMT=1 because the
  1-thread build trims the TLB/CAM replicas.
- The 23.5k `DFFRE` are mostly the per-thread PC/state and queue flops that
   the SMT=1 guards remove (-15.6k).
- Utilisation on GW5AST-138 (138240 LUT4): LUT4 34.5% -> 20.0%, LUT1..4
  70.1% -> 35.1%.  The full 4-thread core failed nextpnr legalization at
  75% LUT4 utilisation; the SMT1/FPU0 build is small enough that PnR is worth
  retrying (`make -C port fpga-pnr SMT=1 FPU=0`).
- The FPU is not in the DFF/LUT4 totals of either column when `FPU=0`; the
  `iop.v` FPU instance was estimated at ~9.5k LUT4, unverified.
