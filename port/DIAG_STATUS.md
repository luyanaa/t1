# Diag bring-up status (tb_diag.v + t1boot_min.s shim)

Boot path: reset -> POR slot (0xfff0000040) -> boot_main -> main.
Trap services via `ta N` -> tt=0x100+N -> t1boot_min.s handlers -> `done`.
Verdict: `stx` to thread_status_mem (PA 0xfffff0020000); upper32=0 PASS, 0xf FAIL.

## DIAG PASS (verified end-to-end on Icarus)
- tlu_tick_read_1
- tlu_multi_intl_00
- tlu_multi_intl_01

## Running (expected PASS — only `ta` services used, killed mid-flight for CPU)
- tlu_gl_lvl_1   reached 0x140 of ~0x1a8 (gl write seq, ends ta 0) — progressing
- tlu_tl_lvl_1   reached 0x300 of ~0x364 (tl wrpr seq, ends ta 0) — progressing

## FAIL — needs real trap-handler env (out of shim scope)
These take a *hardware* trap the diag expects its own handler (my_trap_handlers /
My_HT0_* defines / error injection) to service.  Shim vectors them to SLOT_BAD -> FAIL.
- irf_err_pic_ovfl_test  (pic/irf_ce overflow trap)
- tlu_asiacc_trap_1      (illegal ASI access trap 0x30)
- tlu_asracc_trap_1      (illegal ASR access trap)
- tlu_mtb2b_tsasr_00     (data-access-exception 0x34)
- tlu_lsu_tt_00          (data-access-error 0x32)
- dtlb_err_on_sir        (sir -> data_access_error handler)
- sus_res_*              (halt/resume needs external resume agent)

## TIMEOUT — needs interrupt env
- tlu_multi_intl_00/01 pass only because they finish via ta; the wait-loop
  for tick_cmpr would otherwise stall (no interrupt model in shim).

## Build blockers
- tlu_cmpr_intdis_1: `wrhpr %g1,0x200,%hsys_tick_cmpr` — %hsys_tick_cmpr
  not a GNU-as-recognized hyperpriv reg.  Needs operand rewrite or skip.

## Notes
- `th_fork(lbl)` expanded by build_diag.py (ta 0x2e rdth_id + cmp/be per
  THREAD_MASK bit, fallback ta 0x01).  Numeric trap literals (T_* are cpp
  defines, not link symbols).
- NC fetch: every instruction is an IMISS (~1 instr / PCX roundtrip), so sim
  wall-time is minutes; correct but slow.  Enabling I$ needs a tag-init slam
  (I$ contents are X until written) — not yet done.
- Runner: port/scripts/run_diag.sh <diag.s> [timeout] -> verdict line.

## cmp_top path (in progress)
- iop (OpenSPARCT1: 8 sparc + 4 sctag + scbuf/scdata + 4 dram + ccx + jbi + ctu
  + efc + pads) compiles cleanly under iverilog as top `cmp_top` / inst `iop`
  (the single upward XMR `` `CTU_PATH`` resolves because of that naming).
  RC=0, 234MB vvp.
- port/pli/sjm/sjm.vpi — all 22 `$sjm_*` tasks ported to VPI (TF/acc shim +
  untouched engine); $sjm_init/POR verified. Use for JBus slave-agent IO diags.
- port/pli/dispmon.vpi — in progress (no-op shim for 124 unguarded $dispmon
  CoverMeter hooks; iverilog ignores `synopsys translate_off`).
- Still needed: dispmon shim compile+run, cmp_dram glue, monitor_min
  (de-SAS good/bad-trap scoring), jbus_mon VPI (optional).

## Integration plan (deferred until all lanes land)
- Integrate SJM.vpi + dispmon.vpi + cmp_top_port + monitor_min into ONE
  cmp_top simulation. Load order / -m flags reconciled at integration, not
  during per-lane bring-up (avoid double-registration / task-name conflicts).
- SJM command files chosen via plusarg at run time, not compile-time.

## Lane progress (unified cmp_top integration)
- port/env/monitor_min.v (DONE): de-SAS'd monitor, local XMR trap-watch
  (sparcN.tlu.trappc_vld/pc + ifu thrfsm thr_state) -> DIAG PASS/FAIL verdict.
  All external PLI tasks ($bw_good_trap/$sas_*/$x_checker/monitor.cc tasks)
  stubbed or replaced with a local plusarg tokenizer.
- port/env/cmp_top_env.v + port/pli/init_jbus_model_vpi.c: IN PROGRESS
  (fixer ses_e0ed2b...) - SJM JBus wiring + memory-image backdoor.

## Unified cmp_top integration - COMPLETE (cmp-env)
- port/env/cmp_top_env.v: top `cmp_top` + inst `iop` (CTU_PATH XMR resolves).
  Full JBus plumbing (weak pull-ups, req cross-connects), jp_sjm j_sjm_4/5
  (j_id 3'b100/101) on real JBus inouts, SJM POR/start_exec sequence,
  parity gen, $init_jbus_model + +mem.image, monitor instantiated
  (clk=iop.ccx.rclk, cmp_gclk=iop.cmp_gclk, rst_l=iop.cmp_grst_out_l).
- port/env/monitor_min.v: de-SAS monitor, ifdef RTL_SPARC<N> guards so only
  existing cores' XMRs elaborate (build has RTL_SPARC0 only). Local trap-watch
  -> DIAG PASS/FAIL/TIMEOUT verdicts via +good_trap=/+bad_trap=/+finish_mask.
- port/env/sjm_front.v: task-style $sjm_* port copy of sjm.v.
- port/env/mem_backdoor.v: reg[63:0] mem[0:16383] backdoor @ cmp_top.mem_backdoor.
- port/pli/init_jbus_model_vpi.c/.vpi: $init_jbus_model -> $readmemh into backdoor.
- Build: make -C port cmp-env-build (RC=0); run: make -C port cmp-env-run.
  sjm.vpi embedded at compile (-m sjm); dispmon+init_jbus_model via vvp -m.
- Verified: CMP-ENV PASS (full chip + DDR + SJM 4/5 + POR), RC=0, ~55s.
  SJM cmd files parsed, POR asserted/deasserted, JBus high-Z, backdoor loaded
  + read-back, monitor scope present, no XMR bind errors.
- Known bring-up gaps (next): iop.jbus_grst_l does not deassert yet (efc/efuse
  chain not exercised -> +sjm_trigger_force fallback used); dimm_stub DIMMs
  inert (no real DRAM storage -> image lands in mem_backdoor array, real
  DRAM-content delivery needs a DRAM-capable dimm); no diag image booted yet.

## Clock bring-up (cmp domain)
- Root cause: X-init deadlock in CTU Johnson clock dividers
  (init_div_l/jbus_dup_1sht/clk_str_en_buf boot to X, self-lock ->
  cmp_gclk/jbus_gclk/dram_gclk never toggle -> whole cmp domain held in
  reset). Legacy bench papers over it by randomly slamming flop internals
  (verif/env/cmp/cmp_clk.v:657-680). NOT a JTAG problem (oracle-verified).
- Fix (cmp_top_env.v): force u_pll.pll_bypass=1 (pll_clk_out=J_CLK),
  ctu_sel_cpu/jbus=3'b100 (bypass enc), ctu_sel_dram=3'b001 (no bypass path,
  must use its divider), init_div_l 0->1 edge, clk_str_en_buf[_b]=3'b111.
  J_RST_L released AFTER clocks up (legacy order), not with PWRON_RST_L.
- Result so far: PLL locks, dram_gclk/jbus_gclk toggle -> DDR MRS/SETUP
  commands stream on CH0/CH1, SJM sees IFETCH. cmp_grst_out_l release +
  sparc0 fetch + DIMM data = the depth the in-flight dbg run is measuring.
  (CTU_mpath_check_error at startup is a benign bypass bring-up artifact.)
- Verified live (CLKCHAIN probe): cmp_gclk/jbus_gclk/dram_gclk ALL toggle
  (3864/1004/999 edges by 4us). DRAM controller alive -> MRS/SETUP commands
  on CH0/CH1. SJM receives IFETCH over JBus. grst_l release is
  de_grst/lcm_cnt latency-gated (longer sim window needed to observe).

## Post-clock-fix status
- cmp/jbus/dram gclks toggle; cmp_grst_out_l/dram_grst_l/jbus_grst_l release
  at ~4.5us. DDR2 init (MRS/SETUP) streams on CH0/CH1. sparc0 fetch begins.
- NEXT BLOCKER: L2_DATA_ERR "way select error xxx" x8168 - L2 way-select is X
  after reset release. Same X-init family (uninit array or undriven XMR
  input like sctag_pcx_stall_pq that legacy pcx_stall/slam_init slammed).
  Under oracle diagnosis (ses_e0dbad...) for exact X source + minimal fix.

## L2 way-select X - iterating X-init (whack-a-mole)
- mil0.q..mil3.q (ifu.ifqdp.milN.q) slam to 0 + pcxthr_ff.q slam to 0001 +
  spc1..7_pcx tie-offs (ifndef RTL_SPARCn) all applied - L2 flood UNCHANGED
  (~1600/10us). Per-flop patching not converging.
- Steady-state cone (probe13 @11us): whole pcx->l2 path still X, VLD=1 IMISS
  still fires w/ X addr, csr_l2_control_reg=xxxxxx (L2 CSR never written),
  pcx_pkt_src_sel=X, arb0.src0_arb_req_q=X.
- sparc0 thr_state=00000 @10us (not THRFSM_HALT=00010) - thread FSM X too.
- Escalated to oracle (ses_e0d315...) for the COMPLETE unreset-flop init set
  in the IFU-IMISS->LSU->CCX->L2 path (milfsm state, req_pending, errthr,
  qbyp/thr selects, + L2 CSR default) - exhaustive list, not iteration.

## SOLVED: L2 way-select X flood -> CTU clkctrl X-poison (ROOT CAUSE)
- Real cause: ctu_clsp_clkctrl.update_clkctrl_reg_cl X-poisoned at t0
  (ctu_clsp_synch_jlcl.v:958, D=(...)&start_clk_cl). Its X propagates through
  the async-set flops (ctu_clsp_clkctrl.v:1237-1261) into
  clsp_ctrl_*_en_cl -> ctu_*_cken_cl -> *_cmp_cken_cg -> cluster_cken ->
  cluster_header.v:92 rclk=gclk&sync_enable=X. No posedge => SYNCHRONOUS
  resets (dffre_s swrvr_clib.v:314) never fire => csr_l2_control_reg/way_sel
  stay X forever. NOT an L2 array issue, NOT missing CSR boot write.
- Fix (cmp_top_env.v): force update_clkctrl_reg_cl=0 AND rd_clkctrl_reg_cl=0
  (NOT 1 - 1 re-arms mux & re-poisons); force cluster_cken=1 on sparc0,
  sctag0-3, scdata0-3, scbuf0-3, fpu, and ccx.clk_ccx_cken (ccx has no
  cluster_cken port) at t=0 BEFORE first cmp_gclk edge (so spc_hdr
  syncff_4x samples defined cken -> sync_enable resolves -> sparc0.grst_l ok).
  Removed the bogus `assign spcN_pcx_*` block (downward assign into iop-driven
  child nets - wrong in Icarus, was causing no change).
- Keep (C): mil0-3.q=0 + ifqctl.pcxthr_ff.q=0001 HELD (not released) - upstream
  select still X; holding prevents re-poison of the dp_mux4ds.
- VERIFIED: L2_DATA_ERR 25712 -> 0. sparc0 grst_l=1, dtu_reset=0, rclk toggling,
  sync_enable=1. csr_l2_control_reg=X00001 (bit0=1 POR L2-off default).
- IMISS packet now CLEAN (ifu_lsu_pcxpkt_e=0x1000000000000, reqvalid_e=0) with
  MIL/pcxthr held. Residual post-grst L2 errors ~450 (down from 16925).
- NEXT: sparc0 sits in THRFSM_IDLE (legal 00000, not X) waiting for
  start_thread<=fcl_dtu_resum_thr_w (TLU POR rst+resume to thread0 never
  issues). Under oracle trace (ses_e0c3f1...) together with residual L2 X.
- Regression: `make -C port dimm-unit` PASS; `make -C port cmp-env-build` clean.
- Toolchain ready for real boot: port/scripts/diag2hex.py emits @byte/8 sparse hex
  (exact $init_jbus_model format); prebuilt port/build/diag/tlu_tick_read_1/
  tlu_tick_read_1.mem exists (targets @1ffe000000).
- NOTE: PA->dimm index still approximate (index = faddr[19:0], not pa>>3).
  Reset fetch PA 0x3_ffff_c000 => dram_addr_gen folds row/col/bank from PA +
  runtime config_reg, so index can't be computed statically. Once the core
  issues a DRAM READ, DDR_DBG prints ba/addr -> calibrate mapping then.

## BREAKTHROUGH: thread 0 starts and fetches
- Full oracle fix set A+B applied (cmp_top_env.v) with L2_DATA_ERR=0 verified:
  (1) force sparc0.ifu.fcl.thrf_reg.q=4'b0001  (ISSUE A: dff_s no reset, must POR to
      thread0; X blocked thr_d/e/m/w -> thrfsm stuck IDLE)
  (2) force sparc0.lsu.qctl2.fwdpkt_vld_unmasked=0  (ISSUE B: root of L2 X flood -
      fwdpkt_ff dffre_s rst+en both X -> spc_pcx_req_pq X -> CCX -> sctag way_sel X)
  (3) force sparc0.lsu.qctl1.{l2bank0-3,fpiobridge}_qmon.entry{0,1}_full=0
      (rst/en mutually dependent dffre_s -> queue_write X blocked 1st IMISS)
  (4) force spc1-7_pcx_req_pq=0/atom_pq=0 (absent cores -> shared arbiter)
  (5) force iobdg CCX CPX port + ccx.cpx.io_* = 0 (iobdg not compiled, was Z->X)
- Injected POR thread0 reset CPX packet (emulates missing iobdg firstthr_int):
  VLD=1,RQ=INT_RET,type=IOB_RESET,cputhread=core0/thr0,vector=1.
- RESULT: thr0 00(IDLE)->01(WAIT)->19(RDY)->05(RUN), reset fetch issued,
  thr_state=00001 (WAIT on IMISS completion), trap_vld0=0 (defined). L2=0.
- Fetch target: reset PC low bits = RSTVADDR_BASE 0x3_ffff_c000, request is
  UNCACHED, dest=PCX 4 (FP/IO bridge) => served over JBUS, not DRAM.
  Env has no JBus ROM/tester responder for this address (sjm_4/5.cmd only
  issue legacy DRAM master traffic). NEXT SCOPE DECISION: provide a JBus
  responder for the boot fetch, or move RSTVADDR into DRAM space.

## JBus boot responder: route chosen
- Recon: no JBus slave/ROM BFM exists in repo (jbus_mon is inputs-only monitor;
  jp_sjm is a master BFM needing C PLI). Recommended interpose = drive
  jbi_iob_pio_vld/data at the jbi->i2c UCB boundary — BUT that lives in
  iobdg/i2c, and `iobdg` is `ifdef RTL_IOBDG`-excluded from our build
  (same reason iob_cpx_req_cq floats Z).
- DECISION: include iobdg (`-DRTL_IOBDG`) rather than fake CPX. Benefits:
  * real PCX->c2i->jbi->JBus path (and jbi_iob_pio return path) present
  * genuine iobdg firstthr_int POR thread-reset packet -> no CPX injection hack
  * removes the CPX parking hack (which would block L2 fill returns later)
- Build in progress (iobdg is large; elaboration ~10+ min).
- Fallback if iobdg won't elaborate: CPX-side responder (drive cpx_spc_data_cx2
  with IFILL_RET matched to the LSU miss-buffer) - but must pair with the
  outstanding miss entry, so harder than it first looked.

## BOOT FETCH SERVED - thread 0 runs (milestone)
- Implemented port/env/jbus_boot_resp.v: watches the ccx iob PCX request
  (iop.pcx_iob_data_px2/_rdy_px2) and returns an IFILL_RET CPX packet.
  NOTE: driving iob_cpx_* dynamically (force or assign) HANGS iverilog at
  grst release (multiple-driver oscillation with the v_m_help repeater).
  Working approach: keep iob_cpx_* forced to constants (known-good) and
  inject the IFILL_RET at sparc0.cpx_spc_data_cx2 - the injection point that
  does not hang. Echo PCX_BF/PCX_TH into CPX_BF/CPX_TH.
- VERIFIED (probe @4.712us): core asserts IMISS on iob PCX (rq=10000),
  env delivers IFILL_RET (data = {nop; ba .}), and:
    cpx_spc_data_rdy_cx2=1, lsu_ifu_cpxpkt_vld_i1=1, imissrtn_i2=1,
    thr0_state = 05 (THRFSM_RUN)   <-- thread left WAIT and RAN
- It then returns to WAIT(01) for the NEXT fetch, which no longer appears on
  the iob PCX port -> subsequent fetches take the cached L2 path.
- L2_DATA_ERR = 0 throughout. iobdg build (-DRTL_IOBDG) elaborates but hangs
  at grst release; non-iobdg + sparc0 injection is the working config.
- NEXT: put a real image at the boot/L2 addresses (mem.image is a 3-word
  placeholder) so the L2/DRAM path serves the instruction stream.

## *** SOLVED: CPU executes continuously from the boot ROM ***
- ROOT X fix (oracle-verified): `iob_clsp_vld/data/stall` have ZERO DRIVERS
  because iobdg isn't compiled (iop.v:3227 ifdef) -> the CTU UCB captures HiZ
  -> dbginit_sel=dbginit_1sht=X -> cmp_dbginit_cl_l=X -> cmp_gdbginit_out_l=X
  -> ccx_gdbginit_l=X -> ccx.rst_l_buf1_middle=X -> ccx_arbctl.ff_rstl latches
  X -> ccx_arbdp dira/dird gated -> grant_a=X -> ccx_dest_data_rdy_a=X ->
  arb4.dff_ccx_com_dr -> pcx_io_data_rdy_px2=X. ONE X killed ALL 5 ccx
  arbiters, so the IMISS was never acked -> only 1 fetch.
  FIX: force iob_clsp_vld=0, iob_clsp_data=0, iob_clsp_stall=0 (0 drivers, so
  force is safe/no hang). NOT the downstream rdy flops - measured 0 fetches.
- RESULT: 552+ sequential fetches, PC walks 0xfff0000020 -> ... -> 0xfff00008bc
  (contiguous), thr0_state cycles RUN(05)/WAIT(01), L2_DATA_ERR = 0.
  The CPU is EXECUTING the boot ROM one instruction at a time via the
  responder (CPX_IF4B=1, one 4B instr per IMISS).
- This is the first time real instruction execution has been observed in the
  open-source cmp_top flow.

### Execution-depth investigation (in progress)
- Fetching is continuous (1100+ IMISS, PC walks the ROM). Verified the IFU
  pipeline DOES advance: `fcl.inst_vld_e` is observed =1 (e.g. @4.61us) with
  stall_f=0, inst_vld_f=1, dtu_fcl_running_s=1, thr0_state=05 (RUN).
  So instructions reach E-valid - sparse sampling earlier just missed pulses.
- Still open: whether instructions retire into the RF (ecl_irf_wen_w pulses)
  and whether a trap is reached. bw_r_irf has a built-in `$display`
  "Write Port / Read Port" hook (synthesis translate_off) that proves RF
  traffic; a long run is capturing it.
- Note: `ifu_exu_inst_vld_e` samples 0 in steady probes because it pulses -
  dense per-edge VPI counting was too slow to be useful (callback throttles
  the sim from ~1us/s to ~0.3us/s).
- VERIFIED with a long run: 181+ IMISS served, but ZERO RF writes
  (bw_r_irf's built-in "Write Port"/"Read Port" $display never fires).
  So instruction fetch + IFU pipeline to E-valid works, but nothing retires
  into the register file yet -> the D/E-stage advance seen at 4.61us is not
  sustained into writeback.
- Remaining gap: IFU->EXU retire. Candidates to probe next:
  * fcl_dtu_inst_vld_e / dtu_inst_anull_e (writeback enable path)
  * dtu_fcl_running_s dropping (stall_thisthr_f |= ~dtu_fcl_running_s)
  * ecl_irf_wen_w source gating (sparc_exu_ecl.v) - perhaps needs a
    window/ren state that never initialises
  * whether the "ba ." style self-loop words are being decoded as illegal
    (they are real sethi/or/inc though)

## *** REAL PROGRAM EXECUTION CONFIRMED ***
- Corrected responder lane bug (oracle-diagnosed): the IFU consumes
  data[lane] where lane = PC[3:2] (ifqdp.v:309/424, ifqctl.v:944-947), NOT
  data[0]. My responder always wrote lane 0, so the `ba` sat in a lane that
  was never read -> PC walked forward through default nops forever.
  FIX: pad all 4 lanes with nop, place boot_prog_word(pc_lo) into lane
  pc_lo[3:2]. (Also corrected the debug lane read to pcx[66:65].)
- TWO EARLIER CONCLUSIONS WERE WRONG (documented so nobody repeats them):
  1. "zero RF writes => retire blocked" was VOID: bw_r_irf.v has 3 module
     defs; with no FPGA_SYN defines the `else at :2135 binds, and that
     variant has NO $display hooks. b:330-350 is dead code. Verified:
     strings cmp_top_env_boot.vvp | grep -c "Write Port 1" -> 0.
  2. ecl_irf_wen_w / inst_vld_w/e are ONE-CYCLE pulses; sparse $time
     sampling misses them. Must use cbValueChange.
- PROOF (VPI value-change watch on exu.irf.active_window[1] = thr0 %g1):
    %g1 <- 0x...deadb000   (sethi %hi(0xdeadb000),%g1 @0x20)
    %g1 <- 0x...deadb123   (or    %g1,0x123,%g1     @0x24)
    %g1 <- 0x...deadb124   (inc   %g1               @0x28)
    %g1 <- 0x...deadb000   (ba    0x20              @0x2C - loop taken!)
  i.e. sethi -> or -> inc -> branch, looping deterministically.
  Observed 309 RF events / 171 fetches, L2_DATA_ERR = 0.
  => decode + ALU + register writeback + branch all WORK.
- Boot program (keyed on pc[15:0], all verified encodings):
  0x0020 0337AB6C sethi %hi(0xdeadb000),%g1
  0x0024 82106123 or    %g1,0x123,%g1
  0x0028 82006001 inc   %g1
  0x002C 10BFFFFD ba    0x0020
  0x0030 01000000 nop (delay slot)

## Summary: what now works end-to-end at cmp_top level under Icarus
Full chip (iop) + functional DDR (dimm_mem) + SJM VPI + monitor, no vendor tools:
  1. 724-file full-chip elaboration (234MB vvp), top `cmp_top`, inst `iop`
     (keeps CTU_PATH upward XMR working -> zero RTL edits).
  2. CTU clock bring-up: PLL bypass + divider init_div_l edge + stretch kill;
     cmp/jbus/dram gclks all toggle.
  3. All domain resets release (~4.5us) -> DDR MRS/SETUP, SJM sees IFETCH.
  4. L2 way-select X flood eliminated (CTU clkctrl un-poison + cluster_cken).
  5. sparc0 thread0 POR start (emulated iobdg firstthr_int CPX packet).
  6. IO/JBus boot fetch served by env responder (CPX_IF4B=1 one 4B instr).
  7. **Real instruction execution**: sethi/or/inc/ba loop, %g1 verified in RF.

## *** DIAG PASS ACHIEVED AT cmp_top LEVEL UNDER ICARUS ***
Boot program: sethi %hi(0xdeadb000),%g1 / or %g1,0x123,%g1 / ta 0x40 / ba .
  (0x0020 0337AB6C, 0x0024 82106123, 0x0028 91D02040, 0x002C 10800000,
   0x0030 01000000)
Run: +sjm_trigger_force=1200000 +no_smoke_finish +good_trap=0 +finish_mask=1
Output:
  4554500: MON: finish_mask 00000001
  MON: good_trap list (1 entries), bad_trap list (0 entries)
  Info: spc(0) thread(0) Hit Good trap pc=000000000000
  4698510: Simulation -> PASS (HIT GOOD TRAP)
  DIAG PASS: good trap
=> fetch -> decode -> ALU -> register writeback -> ta trap -> monitor verdict.

### Trap-PC X fix (needed for the verdict)
tlu_ifu_trappc_w2 = {1'b0, TBA[33:0], ttype[8:0], 5'b0} (tlu_tcl.v:3820).
%tba (tlu_tdp.v:1453 tba0) is a reset-less dff_s -> X until SW writes it,
and a real boot ROM writes %tba first. Ours doesn't, so the trap PC was X.
FIX (env, not RTL): force true_tba0..3=0, tba_data=0, htba_data=0 and
partial_trap_pc_w2=0. NOTE: forcing true_tba0 alone is NOT enough - tba_data
and htba_data are mux4ds on tlu_thrd_wsel_w2, and mux4ds emits x for a
non-one-hot select. With TBA=0 the trap PC is purely ttype-derived and
deterministic -> matchable via +good_trap=0 (ta 0x40 with TBA=0 -> PC 0).

=====================================================================
## *** REAL DIAG BOOTS AND PASSES: tlu_tick_read_1 (2113 words) ***
=====================================================================
Command (from /shared/t1):
  python3 port/scripts/build_diag.py \
      verif/diag/assembly/TLU/direct/tlu_tick_read_1.s
  vvp -n -M port/pli -m dispmon -M port/pli -m init_jbus_model_vpi \
      port/build/cmp_top_env_boot.vvp +sjm_trigger_force=1200000 \
      +no_smoke_finish \
      +boot_mem=port/build/diag/tlu_tick_read_1/tlu_tick_read_1.mem

Output:
  [cmp_top_env] boot image: 2113 words from .../tlu_tick_read_1.mem
  [cmp_top_env] BOOT imiss at 4707500 pc=fff0000020 thr=00 lane=0
  ...  (130 IMISS served; PC walks 0xfff0000020 -> boot_main)
  [cmp_top_env] BOOT imiss at 5125500 pc=fff0010000 thr=00 lane=0   <- main
  ...  (ta 0x100..0x120 -> software trap slots 0x2040/0x2060/0x2400.., done)
  [cmp_top_env] BOOT imiss at 5939500 pc=fff0002000 thr=00 lane=0   <- T_GOOD_TRAP
  [cmp_top_env] BOOT imiss at 5961500 pc=fff00040a0 thr=00 lane=0   <- proc_good_trap
  [cmp_top_env] BOOT store at 6135500 pa=fff0020000 \
                data=0000000000000001 thr=00
  [cmp_top_env] DIAG PASS: thread_status_mem=0000000000000001

=> Real image: boot -> main -> 6 software traps serviced -> good trap ->
   thread_status_mem written (one-hot TID, upper 32 bits 0) -> PASS.
   No L2_DATA_ERR, no unhandled PCX request.

### Root cause 1: non-canonical 48-bit VA in a register -> INST_ACC_EXC
sparc_exu_alu_16eql (sparc_exu_alu.v:184) checks va_e[63:47] are ALL equal;
a mixed value sets exu_ifu_va_oor_m (sparc_exu_ecl.v:808) -> fcl set_oor_m
(sparc_ifu_fcl.v:1926) -> per-thread pc_oor_vec -> INST_ACC_EXC (tt 0x08),
which vectors to TBA|0x100.  A plain `setx` of an address in the RED IO
window (0xfffffxxxxxxxxx) produces 0x0000FFFFxxxxxxxx: bit 47 = 1 but
bits 63:48 = 0 -> mixed -> trap.  Direct `ba` branches are immune (their
target is derived from the already sign-extended PC); register addresses
(setx/jmp and load/store VAs) are not.
FIX (port/scripts/t1boot_min.s): SETXVA macro ORs in 0xFFFF000000000000
after setx; used for `main` and for both thread_status_mem addresses.
This is why the `jmp %g2` "lost" the high bits: g2 really was
0x0000FFFFF0010000 and the next fetch trapped, it was not an RF failure.

### Root cause 2: boot responder dropped a store issued during a hold
Measured in the previous run: 133 IOB PCX requests but only 132 IMISS and
zero "unhandled" -> exactly one request (the final `stx` STQ) arrived while
the responder was blocked in its 8-cycle CPX response hold and was lost.
FIX (port/env/cmp_top_env.v): boot_bus_hold keeps the response stable but
sniffs pcx_iob_data_rdy_px2 each cycle for STORE_RQ/STQ_RQ; the main loop
then records (boot_store_record) and acks (boot_store_ack) it.  The env
also prints the verdict when the word lands at PA 0xfff0020000.

### Layout / addressing notes (now working)
- .vectors/.boot at 0xfffff0000000, diag .text/.data at 0xfffff0010000,
  .tstatus at 0xfffff0020000 (port/scripts/t1boot.ld), all inside the RED
  IO window (PA[39]=1) so every fetch is an uncached IOB IMISS.
- The core's first IMISS is PA 0xfff0000020 (one slot below the POR vector),
  so t1boot_min.s puts `ba boot_main` in that slot as well as in 0x40.

## Multi-thread status collection (A3a)

`tb_diag.v` now resets one CPX reset packet per thread and collects a
per-thread verdict, so a diag can report from any subset of threads:

- `+threads=N` (1..SMT width, default 1) selects how many threads are
  released.  The bench stops only when every released thread has reported.
- `thread_status_mem` word is read as four nibbles; the PASS/FAIL decision
  only looks at the released threads.
- `port/diag/mt_boot_smoke.s` exercises this: `THREAD_MASK 0xf`, a
  `th_fork` to four labels that each branch to a common `ta 0`, so all four
  threads must reach the trap handler and store `0xf`.
  `make -C port diag-smoke` builds and runs it, and `regress` includes it.
- `build_diag.py` reads `THREAD_MASK` from the diag source *before* cpp, so
  `th_fork` expands to the threads the diag asked for (previously the macro
  was already stripped by cpp and every diag silently ran single-threaded,
  sending threads 1-3 into `ta 0x01` = BAD_TRAP).
- `t1boot_min.s` writes the status word with `membar #Sync` after the
  `stx`; without it the store-buffer contents are dropped when the bench
  stops on the report.

## Power-up modelling instead of testbench forces (A3b)

The flop library (`design/sys/iop/common/rtl/swrvr_clib.v`) now has a
`POR` parameter on `dff_s`, `dff_sscan`, `dffr_s`, `dffe_s`, `dffre_s` and an
`initial q = POR` guarded by `RTL_FF_POR_INIT`, which the port build always
defines for simulation (`SIM_DEFS` in `port/Makefile`) and never for
synthesis.  Real flops power up in a defined state; simulators start at
`x`, which is why the benches used to force thread-state flops.  No force
is needed anymore:

- MIL entries (`mil0..3`, 41 bits): POR = 0.
- `pcxthr_ff` (IFU PCX thread select): POR = 4'b0001.
- `thrf_reg` (FCL thread select): POR = 4'b0001.
- `tlu_thrd_wsel_w2`: decoded from `tsa_wr_tid`, which powers up 00 ->
  `thread0_wtrp_w2` = 1 -> one-hot 0001 automatically.
- `spu_lsu_ldst_pckt_d1`, `fwdpkt_vld_unmasked`, the `lsu_pcx_qmon`
  `entry*_full` flops: POR = 0.

`cmp_top_env.v` keeps only the CTU clock-control un-poison forces and the
CPX stimulus injection.
