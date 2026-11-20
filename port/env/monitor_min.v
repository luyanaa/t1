// ========== Copyright Header Begin ==========================================
//
// OpenSPARC T1 Processor File: monitor_min.v
// Derived from verif/env/cmp/monitor.v + verif/env/cmp/pc_cmp.v
// (Copyright (c) 2006 Sun Microsystems, Inc., GPL v2).
// Icarus-Verilog port ("de-SAS'd" minimal monitor): PASS/FAIL scorer for the
// cmp_top-level simulation.
//
// PORTED FOR: Icarus Verilog (iverilog -g2005).  Top must be `cmp_top` with
// the chip instance `iop` (port/env/cmp_top_port.v), so the downward XMRs
// below (cmp_top.iop.sparcN.*) resolve.
//
// STUBBED / REMOVED TASKS (external C PLI not available in this repo):
//   $bw_good_trap, $bw_sas_send, $bw_list   - SAS post-processing lib, cut.
//   $sas_client, $x_checker                 - SAS lib, cut.
//   $check_mon, $writemon, $initmon,        - monitor.cc PLI tasks, NOT
//   $dispmon_status, $enable_errwarnmon,      built (see port/pli/); all
//   $disable_errwarnmon                      calls removed.
//   $ModuleStart/$ModuleEnd/$ModulesDone/$GetModules - monitor.cc tasks, cut.
//   $parse (PLI)                            - replaced by a local Verilog
//                                             string tokenizer.
//   $dispmon                                - real impl exists in
//                                             port/pli/dispmon.vpi (no-op
//                                             unless +dispmon); nothing here
//                                             needed it, so it is not called.
//   sas_def plusarg (+use_sas_tasks)        - hard-coded to 0; no SAS path.
//
// LOCAL SCORING (replaces $bw_good_trap):
//   Legacy pc_cmp got its good/bad-trap verdict from the SAS daemon via
//   $bw_good_trap.  Here the monitor watches the per-core TLU trap outputs
//   directly via downward XMR:
//       cmp_top.iop.sparcN.tlu.tlu_ifu_trappc_vld_w1  (trap taken, w1 stage)
//       cmp_top.iop.sparcN.tlu.tlu_ifu_trappc_w2      [47:0] (trap PC)
//       cmp_top.iop.sparcN.tlu.tlu_ifu_trap_tid_w1    (trap thread id)
//   (net names verified against design/sys/iop/sparc/tlu/rtl/tlu.v:358-361
//    and tlu_tcl.v outputs).
//   Thread activity comes from the IFU wait-stage thread FSMs:
//       cmp_top.iop.sparcN.ifu.swl.thrfsmT.thr_state[4:0]
//   (THRFSM_HALT = 5'b00010, design/sys/iop/include/ifu.h:81).
//
//   Scoring model (same verdict style as port/tb/tb_diag.v):
//     +good_trap=<pc:pc:...>  40/48-bit trap-PC list (":" separated hex).
//       A trap whose PC matches -> good[core*4+tid] = 1.
//       When every +finish_mask thread is good and no bad trap was hit:
//         "DIAG PASS: good trap" + $finish.
//     +bad_trap=<pc:pc:...>   trap PC list that FAILs immediately:
//         "DIAG FAIL: bad trap" + $finish.
//     +finish_mask=<hex>      bit mask of threads expected to hit a good
//                             trap (default: threads with a good-trap list,
//                             i.e. all threads that can ever pass).
//     +TIMEOUT=<cycles>       per-thread inactivity timeout (default 100000);
//                             a thread that neither hits a good trap nor
//                             halts -> "DIAG FAIL: TIMEOUT".
//     +max_cycle=<cycles>     global watchdog (default 30000), legacy
//                             monitor.v behaviour.
//     With no +good_trap list the monitor only reports traps/timeout info
//     ("DIAG TIMEOUT: no PASS/FAIL within N cycles") and lets an outer
//     testbench (e.g. tb_diag's thread_status_mem scoreboard) decide.
// ========== Copyright Header End ============================================

`timescale 1ps/1ps

module monitor(clk, cmp_gclk, rst_l);
   input clk;
   input cmp_gclk;
   input rst_l;

   localparam [4:0] THRFSM_HALT = 5'b00010;  // design/sys/iop/include/ifu.h
   localparam        MAX_TRAPS   = 32;

   wire  reset = ~rst_l;

   reg      sas_def;      // hard-coded 0: no SAS in the Icarus port
   reg      dum;
   reg      diag_done;    // local stand-in for `TOP_MOD.diag_done
   reg      fail_flag;    // local stand-in for `TOP_MOD.fail_flag
   reg      bad;
   reg      err_f;
   reg [1023:0] err;
   integer  number, num, f_time, max_cycle, cycle;

   // ---- verdict state (pc_cmp.v structure, SAS calls removed) -------------
   reg [47:0] good_trap [0:MAX_TRAPS-1];
   reg [47:0] bad_trap  [0:MAX_TRAPS-1];
   integer    good_trap_count, bad_trap_count;
   reg [31:0] finish_mask;
   reg [31:0] good;               // per-thread good-trap-done flag
   reg        hit_bad;
   integer    timeout_cnt [0:31];
   integer    timeout_max, time_tmp;

   initial begin
      sas_def        = 1'b0;     // de-SAS: hard-coded
      diag_done      = 1'b0;
      fail_flag      = 1'b0;
      bad            = 1'b0;
      err_f          = 1'b1;
      number         = 2;
      num            = 0;
      max_cycle      = 30000;   // legacy monitor.v default
      cycle          = 0;
      hit_bad        = 1'b0;
      good           = 32'b0;
      good_trap_count= 0;
      bad_trap_count = 0;
      finish_mask    = 32'b0;
      timeout_max    = 100000;
      if ($value$plusargs("TIMEOUT=%d", time_tmp)) timeout_max = time_tmp;
      if ($value$plusargs("max_cycle=%d", max_cycle))
         $display("MON: max cycles = %0d", max_cycle);
   end

   // ---- global watchdog (legacy monitor.v:80-88) --------------------------
   always @(posedge clk) begin
      if (diag_done == 1'b0) cycle = cycle + 1;
      if (cycle == max_cycle) begin
         $display("%0d : Simulation -> (terminated by reaching max cycles = %0d)",
                  $time, max_cycle);
         $finish;              // de-SAS: no $bw_sas_send
      end
   end

   // ---- central fail task (legacy monitor.v:91-107, SAS calls removed) ----
   task fail;
      input [1023:0] comment;
      begin
         if (bad) begin
            $display("%0d : Simulation -> FAIL(%0s)", $time, comment);
            $finish;
         end
         if (err_f) begin
            err   = comment;
            f_time = $time;
         end
         err_f  = 1'b0;
         fail_flag = 1'b1;
      end
   endtask

   // deferred fail (legacy monitor.v:108-118, `TOP_MOD.fail_flag -> local)
   always @(posedge clk) begin
      if (fail_flag && !diag_done) begin
         num = num + 1;
         if (num == number) begin
            diag_done = 1'b1;
            $display("%0d : Simulation -> FAIL(%0s)", f_time, err);
            $display("DIAG FAIL: %0s", err);
            $finish;
         end
      end
   end

   // =====================================================================
   // LOCAL trap / thread-activity watchers (replaces pc_cmp + $bw_good_trap)
   // =====================================================================

   // ---- per-core TLU trap XMRs ------------------------------------------
   // Cores exist only when RTL_SPARC<N> is defined; this build compiles
   // sparc0 only (core1_rtl.f: define+RTL_SPARC0).  Guard dead cores so the
   // downward XMRs resolve, mirroring iop.v's `ifdef RTL_SPARC<N>.
   wire        t0_trap_vld = cmp_top.iop.sparc0.tlu.tlu_ifu_trappc_vld_w1;
   wire [47:0] t0_trap_pc  = cmp_top.iop.sparc0.tlu.tlu_ifu_trappc_w2;
   wire [1:0]  t0_trap_tid = cmp_top.iop.sparc0.tlu.tlu_ifu_trap_tid_w1;
`ifdef RTL_SPARC1
   wire        t1_trap_vld = cmp_top.iop.sparc1.tlu.tlu_ifu_trappc_vld_w1;
   wire [47:0] t1_trap_pc  = cmp_top.iop.sparc1.tlu.tlu_ifu_trappc_w2;
   wire [1:0]  t1_trap_tid = cmp_top.iop.sparc1.tlu.tlu_ifu_trap_tid_w1;
`endif
`ifdef RTL_SPARC2
   wire        t2_trap_vld = cmp_top.iop.sparc2.tlu.tlu_ifu_trappc_vld_w1;
   wire [47:0] t2_trap_pc  = cmp_top.iop.sparc2.tlu.tlu_ifu_trappc_w2;
   wire [1:0]  t2_trap_tid = cmp_top.iop.sparc2.tlu.tlu_ifu_trap_tid_w1;
`endif
`ifdef RTL_SPARC3
   wire        t3_trap_vld = cmp_top.iop.sparc3.tlu.tlu_ifu_trappc_vld_w1;
   wire [47:0] t3_trap_pc  = cmp_top.iop.sparc3.tlu.tlu_ifu_trappc_w2;
   wire [1:0]  t3_trap_tid = cmp_top.iop.sparc3.tlu.tlu_ifu_trap_tid_w1;
`endif
`ifdef RTL_SPARC4
   wire        t4_trap_vld = cmp_top.iop.sparc4.tlu.tlu_ifu_trappc_vld_w1;
   wire [47:0] t4_trap_pc  = cmp_top.iop.sparc4.tlu.tlu_ifu_trappc_w2;
   wire [1:0]  t4_trap_tid = cmp_top.iop.sparc4.tlu.tlu_ifu_trap_tid_w1;
`endif
`ifdef RTL_SPARC5
   wire        t5_trap_vld = cmp_top.iop.sparc5.tlu.tlu_ifu_trappc_vld_w1;
   wire [47:0] t5_trap_pc  = cmp_top.iop.sparc5.tlu.tlu_ifu_trappc_w2;
   wire [1:0]  t5_trap_tid = cmp_top.iop.sparc5.tlu.tlu_ifu_trap_tid_w1;
`endif
`ifdef RTL_SPARC6
   wire        t6_trap_vld = cmp_top.iop.sparc6.tlu.tlu_ifu_trappc_vld_w1;
   wire [47:0] t6_trap_pc  = cmp_top.iop.sparc6.tlu.tlu_ifu_trappc_w2;
   wire [1:0]  t6_trap_tid = cmp_top.iop.sparc6.tlu.tlu_ifu_trap_tid_w1;
`endif
`ifdef RTL_SPARC7
   wire        t7_trap_vld = cmp_top.iop.sparc7.tlu.tlu_ifu_trappc_vld_w1;
   wire [47:0] t7_trap_pc  = cmp_top.iop.sparc7.tlu.tlu_ifu_trappc_w2;
   wire [1:0]  t7_trap_tid = cmp_top.iop.sparc7.tlu.tlu_ifu_trap_tid_w1;
`endif

   // ---- per-thread IFU thread-FSM state (activity + halt) ----------------
   // thread index j = core*4 + tid
   wire [4:0] thr_state_00 = cmp_top.iop.sparc0.ifu.swl.thrfsm0.thr_state;
   wire [4:0] thr_state_01 = cmp_top.iop.sparc0.ifu.swl.thrfsm1.thr_state;
   wire [4:0] thr_state_02 = cmp_top.iop.sparc0.ifu.swl.thrfsm2.thr_state;
   wire [4:0] thr_state_03 = cmp_top.iop.sparc0.ifu.swl.thrfsm3.thr_state;
`ifdef RTL_SPARC1
   wire [4:0] thr_state_10 = cmp_top.iop.sparc1.ifu.swl.thrfsm0.thr_state;
   wire [4:0] thr_state_11 = cmp_top.iop.sparc1.ifu.swl.thrfsm1.thr_state;
   wire [4:0] thr_state_12 = cmp_top.iop.sparc1.ifu.swl.thrfsm2.thr_state;
   wire [4:0] thr_state_13 = cmp_top.iop.sparc1.ifu.swl.thrfsm3.thr_state;
`endif
`ifdef RTL_SPARC2
   wire [4:0] thr_state_20 = cmp_top.iop.sparc2.ifu.swl.thrfsm0.thr_state;
   wire [4:0] thr_state_21 = cmp_top.iop.sparc2.ifu.swl.thrfsm1.thr_state;
   wire [4:0] thr_state_22 = cmp_top.iop.sparc2.ifu.swl.thrfsm2.thr_state;
   wire [4:0] thr_state_23 = cmp_top.iop.sparc2.ifu.swl.thrfsm3.thr_state;
`endif
`ifdef RTL_SPARC3
   wire [4:0] thr_state_30 = cmp_top.iop.sparc3.ifu.swl.thrfsm0.thr_state;
   wire [4:0] thr_state_31 = cmp_top.iop.sparc3.ifu.swl.thrfsm1.thr_state;
   wire [4:0] thr_state_32 = cmp_top.iop.sparc3.ifu.swl.thrfsm2.thr_state;
   wire [4:0] thr_state_33 = cmp_top.iop.sparc3.ifu.swl.thrfsm3.thr_state;
`endif
`ifdef RTL_SPARC4
   wire [4:0] thr_state_40 = cmp_top.iop.sparc4.ifu.swl.thrfsm0.thr_state;
   wire [4:0] thr_state_41 = cmp_top.iop.sparc4.ifu.swl.thrfsm1.thr_state;
   wire [4:0] thr_state_42 = cmp_top.iop.sparc4.ifu.swl.thrfsm2.thr_state;
   wire [4:0] thr_state_43 = cmp_top.iop.sparc4.ifu.swl.thrfsm3.thr_state;
`endif
`ifdef RTL_SPARC5
   wire [4:0] thr_state_50 = cmp_top.iop.sparc5.ifu.swl.thrfsm0.thr_state;
   wire [4:0] thr_state_51 = cmp_top.iop.sparc5.ifu.swl.thrfsm1.thr_state;
   wire [4:0] thr_state_52 = cmp_top.iop.sparc5.ifu.swl.thrfsm2.thr_state;
   wire [4:0] thr_state_53 = cmp_top.iop.sparc5.ifu.swl.thrfsm3.thr_state;
`endif
`ifdef RTL_SPARC6
   wire [4:0] thr_state_60 = cmp_top.iop.sparc6.ifu.swl.thrfsm0.thr_state;
   wire [4:0] thr_state_61 = cmp_top.iop.sparc6.ifu.swl.thrfsm1.thr_state;
   wire [4:0] thr_state_62 = cmp_top.iop.sparc6.ifu.swl.thrfsm2.thr_state;
   wire [4:0] thr_state_63 = cmp_top.iop.sparc6.ifu.swl.thrfsm3.thr_state;
`endif
`ifdef RTL_SPARC7
   wire [4:0] thr_state_70 = cmp_top.iop.sparc7.ifu.swl.thrfsm0.thr_state;
   wire [4:0] thr_state_71 = cmp_top.iop.sparc7.ifu.swl.thrfsm1.thr_state;
   wire [4:0] thr_state_72 = cmp_top.iop.sparc7.ifu.swl.thrfsm2.thr_state;
   wire [4:0] thr_state_73 = cmp_top.iop.sparc7.ifu.swl.thrfsm3.thr_state;
`endif

   // ---- trap list parsing (replaces $parse PLI) ---------------------------
   // Tokenizes "<hex>:<hex>:..." left-aligned in a 1024-bit string reg.
   task parse_list;
      input [1023:0] s;
      input          is_good;       // 1 = good_trap list, 0 = bad_trap list
      integer        k, n;
      reg [47:0]     v;
      reg [7:0]      c;
      reg            pending;
      begin
         n = 0; v = 48'b0; pending = 1'b0;
         // NOTE: iverilog stores $value$plusargs %s strings RIGHT-aligned
         // in the target reg, so scan from the LSB up to the NUL terminator.
         for (k = 0; k < 128; k = k + 1) begin
            c = s[8*k +: 8];
            if (c == 8'h00) begin
               if (pending) begin
                  if (is_good) begin good_trap[n] = v; n = n + 1; end
                  else         begin bad_trap[n]  = v; n = n + 1; end
               end
               k = 128;                      // end of string
            end
            else if (c == 8'h3a) begin       // ':' separator
               if (pending) begin
                  if (is_good) begin good_trap[n] = v; n = n + 1; end
                  else         begin bad_trap[n]  = v; n = n + 1; end
               end
               v = 48'b0; pending = 1'b0;
            end
            else if (c >= 8'h30 && c <= 8'h39) begin // '0'-'9'
               v = {v[43:0], c[3:0]}; pending = 1'b1;
            end
            else if (c >= 8'h61 && c <= 8'h66) begin // 'a'-'f'
               v = {v[43:0], c[3:0] + 4'd9}; pending = 1'b1;
            end
            else if (c >= 8'h41 && c <= 8'h46) begin // 'A'-'F'
               v = {v[43:0], c[3:0] + 4'd9}; pending = 1'b1;
            end
            // other chars (whitespace etc.) ignored
         end
         if (is_good) good_trap_count = n;
         else         bad_trap_count  = n;
         if (n > MAX_TRAPS) begin
            $display("%0t: trap list count %0d more than max %0d",
                     $time, n, MAX_TRAPS);
            fail("trap list too long");
         end
      end
   endtask

   // reads the plusargs once after reset is applied (pc_cmp.trap_extract,
   // de-SAS'd: no finish_mask/stub_mask SAS handshake)
   reg        lists_done;
   initial begin
      lists_done = 1'b0;
   end
   reg [1023:0] arg_str;
   always @(posedge rst_l) begin
      if (!lists_done) begin
         lists_done = 1'b1;
         arg_str = 1024'b0;
         if ($value$plusargs("good_trap=%s", arg_str)) parse_list(arg_str, 1'b1);
         arg_str = 1024'b0;
         if ($value$plusargs("bad_trap=%s", arg_str))  parse_list(arg_str, 1'b0);
         if (good_trap_count != 0) finish_mask = 32'h1; // legacy default (pc_cmp)
         if ($value$plusargs("finish_mask=%h", finish_mask))
            $display("%t: MON: finish_mask %h", $time, finish_mask);
         $display("MON: good_trap list (%0d entries), bad_trap list (%0d entries)",
                  good_trap_count, bad_trap_count);
      end
   end

   // ---- trap verdict (pc_cmp.check_done / check_bad_trap, de-SAS'd) -------
   task trap_verdict;
      input [2:0]  core;      // sparc core 0..7
      input [47:0] pc;
      input [1:0]  tid;
      integer      j, l;
      begin
         j = {core[2:0], tid};
         // bad trap list has absolute priority (pc_cmp.check_bad_trap)
         for (l = 0; l < bad_trap_count; l = l + 1) begin
            if (bad_trap[l] == pc) begin
               hit_bad   = 1'b1;
               diag_done = 1'b1;
               $display("Info: spc(%0d) thread(%0d) Hit BAD trap pc=%h",
                        core, tid, pc);
               $display("DIAG FAIL: bad trap, pc=%h thread=%0d", pc, j);
               $finish;
            end
         end
         // good trap list
         for (l = 0; l < good_trap_count; l = l + 1) begin
            if (good_trap[l] == pc) begin
               if (good[j] == 1'b0)
                  $display("Info: spc(%0d) thread(%0d) Hit Good trap pc=%h",
                           core, tid, pc);
               good[j] = 1'b1;
            end
         end
         // all finish_mask threads good and nothing bad -> PASS
         if ((good_trap_count != 0) && (good == finish_mask) &&
             (hit_bad == 1'b0) && (diag_done == 1'b0)) begin
            diag_done = 1'b1;
            $display("%0d: Simulation -> PASS (HIT GOOD TRAP)", $time);
            $display("DIAG PASS: good trap");
            $finish;
         end
      end
   endtask

   always @(posedge clk) begin
      if (rst_l && !diag_done) begin
         if (t0_trap_vld) trap_verdict(3'd0, t0_trap_pc, t0_trap_tid);
`ifdef RTL_SPARC1
         if (t1_trap_vld) trap_verdict(3'd1, t1_trap_pc, t1_trap_tid);
`endif
`ifdef RTL_SPARC2
         if (t2_trap_vld) trap_verdict(3'd2, t2_trap_pc, t2_trap_tid);
`endif
`ifdef RTL_SPARC3
         if (t3_trap_vld) trap_verdict(3'd3, t3_trap_pc, t3_trap_tid);
`endif
`ifdef RTL_SPARC4
         if (t4_trap_vld) trap_verdict(3'd4, t4_trap_pc, t4_trap_tid);
`endif
`ifdef RTL_SPARC5
         if (t5_trap_vld) trap_verdict(3'd5, t5_trap_pc, t5_trap_tid);
`endif
`ifdef RTL_SPARC6
         if (t6_trap_vld) trap_verdict(3'd6, t6_trap_pc, t6_trap_tid);
`endif
`ifdef RTL_SPARC7
         if (t7_trap_vld) trap_verdict(3'd7, t7_trap_pc, t7_trap_tid);
`endif
      end
   end

   // ---- thread-activity tracking + per-thread timeout ---------------------
   // (pc_cmp.check_time, de-SAS'd: thread_status read via local XMR)
   function is_active;      // input [4:0] state
      input [4:0] state;
      begin
         is_active = (state != THRFSM_HALT) && (state !== 5'bx);
      end
   endfunction

   // active_thread[core*4+tid]: a thread is active unless its thrfsm is in
   // THRFSM_HALT.  Absent cores (no RTL_SPARC<N>) contribute 0 (inactive).
   // Default X state -> is_active(5'bx)=0 keeps them inert in concat.
   wire [4:0] thr_state_10_d = `ifdef RTL_SPARC1 thr_state_10 `else 5'bxxxxx `endif;
   wire [4:0] thr_state_11_d = `ifdef RTL_SPARC1 thr_state_11 `else 5'bxxxxx `endif;
   wire [4:0] thr_state_12_d = `ifdef RTL_SPARC1 thr_state_12 `else 5'bxxxxx `endif;
   wire [4:0] thr_state_13_d = `ifdef RTL_SPARC1 thr_state_13 `else 5'bxxxxx `endif;
   wire [4:0] thr_state_20_d = `ifdef RTL_SPARC2 thr_state_20 `else 5'bxxxxx `endif;
   wire [4:0] thr_state_21_d = `ifdef RTL_SPARC2 thr_state_21 `else 5'bxxxxx `endif;
   wire [4:0] thr_state_22_d = `ifdef RTL_SPARC2 thr_state_22 `else 5'bxxxxx `endif;
   wire [4:0] thr_state_23_d = `ifdef RTL_SPARC2 thr_state_23 `else 5'bxxxxx `endif;
   wire [4:0] thr_state_30_d = `ifdef RTL_SPARC3 thr_state_30 `else 5'bxxxxx `endif;
   wire [4:0] thr_state_31_d = `ifdef RTL_SPARC3 thr_state_31 `else 5'bxxxxx `endif;
   wire [4:0] thr_state_32_d = `ifdef RTL_SPARC3 thr_state_32 `else 5'bxxxxx `endif;
   wire [4:0] thr_state_33_d = `ifdef RTL_SPARC3 thr_state_33 `else 5'bxxxxx `endif;
   wire [4:0] thr_state_40_d = `ifdef RTL_SPARC4 thr_state_40 `else 5'bxxxxx `endif;
   wire [4:0] thr_state_41_d = `ifdef RTL_SPARC4 thr_state_41 `else 5'bxxxxx `endif;
   wire [4:0] thr_state_42_d = `ifdef RTL_SPARC4 thr_state_42 `else 5'bxxxxx `endif;
   wire [4:0] thr_state_43_d = `ifdef RTL_SPARC4 thr_state_43 `else 5'bxxxxx `endif;
   wire [4:0] thr_state_50_d = `ifdef RTL_SPARC5 thr_state_50 `else 5'bxxxxx `endif;
   wire [4:0] thr_state_51_d = `ifdef RTL_SPARC5 thr_state_51 `else 5'bxxxxx `endif;
   wire [4:0] thr_state_52_d = `ifdef RTL_SPARC5 thr_state_52 `else 5'bxxxxx `endif;
   wire [4:0] thr_state_53_d = `ifdef RTL_SPARC5 thr_state_53 `else 5'bxxxxx `endif;
   wire [4:0] thr_state_60_d = `ifdef RTL_SPARC6 thr_state_60 `else 5'bxxxxx `endif;
   wire [4:0] thr_state_61_d = `ifdef RTL_SPARC6 thr_state_61 `else 5'bxxxxx `endif;
   wire [4:0] thr_state_62_d = `ifdef RTL_SPARC6 thr_state_62 `else 5'bxxxxx `endif;
   wire [4:0] thr_state_63_d = `ifdef RTL_SPARC6 thr_state_63 `else 5'bxxxxx `endif;
   wire [4:0] thr_state_70_d = `ifdef RTL_SPARC7 thr_state_70 `else 5'bxxxxx `endif;
   wire [4:0] thr_state_71_d = `ifdef RTL_SPARC7 thr_state_71 `else 5'bxxxxx `endif;
   wire [4:0] thr_state_72_d = `ifdef RTL_SPARC7 thr_state_72 `else 5'bxxxxx `endif;
   wire [4:0] thr_state_73_d = `ifdef RTL_SPARC7 thr_state_73 `else 5'bxxxxx `endif;

   wire [31:0] active_thread = {
      is_active(thr_state_73_d), is_active(thr_state_72_d),
      is_active(thr_state_71_d), is_active(thr_state_70_d),
      is_active(thr_state_63_d), is_active(thr_state_62_d),
      is_active(thr_state_61_d), is_active(thr_state_60_d),
      is_active(thr_state_53_d), is_active(thr_state_52_d),
      is_active(thr_state_51_d), is_active(thr_state_50_d),
      is_active(thr_state_43_d), is_active(thr_state_42_d),
      is_active(thr_state_41_d), is_active(thr_state_40_d),
      is_active(thr_state_33_d), is_active(thr_state_32_d),
      is_active(thr_state_31_d), is_active(thr_state_30_d),
      is_active(thr_state_23_d), is_active(thr_state_22_d),
      is_active(thr_state_21_d), is_active(thr_state_20_d),
      is_active(thr_state_13_d), is_active(thr_state_12_d),
      is_active(thr_state_11_d), is_active(thr_state_10_d),
      is_active(thr_state_03), is_active(thr_state_02),
      is_active(thr_state_01), is_active(thr_state_00)
   };

   always @(posedge clk) begin
      if (rst_l && !diag_done && !hit_bad) begin
         if (good_trap_count != 0) begin
            // a listed thread that runs forever without hitting the good
            // trap and never halts -> TIMEOUT fail (pc_cmp.check_time)
            if ((active_thread[3:0] & ~good[3:0]) != 32'b0) begin
               timeout_cnt[0] = timeout_cnt[0] + 1;
               if (timeout_cnt[0] > timeout_max) begin
                  $display("Info: spc(0) thread(0) -> timeout happen");
                  fail("TIMEOUT");
               end
            end else timeout_cnt[0] = 0;
            if ((active_thread[7:4] & ~good[7:4]) != 32'b0) begin
               timeout_cnt[1] = timeout_cnt[1] + 1;
               if (timeout_cnt[1] > timeout_max) begin
                  $display("Info: spc(1) thread(0) -> timeout happen");
                  fail("TIMEOUT");
               end
            end else timeout_cnt[1] = 0;
            if ((active_thread[11:8] & ~good[11:8]) != 32'b0) begin
               timeout_cnt[2] = timeout_cnt[2] + 1;
               if (timeout_cnt[2] > timeout_max) begin
                  $display("Info: spc(2) thread(0) -> timeout happen");
                  fail("TIMEOUT");
               end
            end else timeout_cnt[2] = 0;
            if ((active_thread[15:12] & ~good[15:12]) != 32'b0) begin
               timeout_cnt[3] = timeout_cnt[3] + 1;
               if (timeout_cnt[3] > timeout_max) begin
                  $display("Info: spc(3) thread(0) -> timeout happen");
                  fail("TIMEOUT");
               end
            end else timeout_cnt[3] = 0;
            if ((active_thread[19:16] & ~good[19:16]) != 32'b0) begin
               timeout_cnt[4] = timeout_cnt[4] + 1;
               if (timeout_cnt[4] > timeout_max) begin
                  $display("Info: spc(4) thread(0) -> timeout happen");
                  fail("TIMEOUT");
               end
            end else timeout_cnt[4] = 0;
            if ((active_thread[23:20] & ~good[23:20]) != 32'b0) begin
               timeout_cnt[5] = timeout_cnt[5] + 1;
               if (timeout_cnt[5] > timeout_max) begin
                  $display("Info: spc(5) thread(0) -> timeout happen");
                  fail("TIMEOUT");
               end
            end else timeout_cnt[5] = 0;
            if ((active_thread[27:24] & ~good[27:24]) != 32'b0) begin
               timeout_cnt[6] = timeout_cnt[6] + 1;
               if (timeout_cnt[6] > timeout_max) begin
                  $display("Info: spc(6) thread(0) -> timeout happen");
                  fail("TIMEOUT");
               end
            end else timeout_cnt[6] = 0;
            if ((active_thread[31:28] & ~good[31:28]) != 32'b0) begin
               timeout_cnt[7] = timeout_cnt[7] + 1;
               if (timeout_cnt[7] > timeout_max) begin
                  $display("Info: spc(7) thread(0) -> timeout happen");
                  fail("TIMEOUT");
               end
            end else timeout_cnt[7] = 0;
         end
         else begin
            // no good-trap list: neutral timeout (tb_diag verdict style)
            if (cycle == max_cycle - 1) begin
               $display("DIAG TIMEOUT: no PASS/FAIL within %0d cycles",
                        max_cycle);
               $display("DIAG INFO: traps seen (good=%0d bad=%0d)",
                        good_trap_count, bad_trap_count);
            end
         end
      end
   end

   // ---- periodic progress diagnostics (thread activity, legacy style) -----
   always @(posedge clk) begin
      if (rst_l && !diag_done && (cycle % 10000 == 0) && cycle != 0) begin
         $display("MON: cycle %0d active=%h good=%h hit_bad=%b",
                  cycle, active_thread, good, hit_bad);
      end
   end

   // ---- reset-time state clear (legacy monitor.v / pc_cmp.v rst block) ----
   always @(negedge rst_l) begin
      good        = 32'b0;
      hit_bad     = 1'b0;
      diag_done   = 1'b0;
      fail_flag   = 1'b0;
      cycle       = 0;
      num         = 0;
      err_f       = 1'b1;
   end

   // sas_def / dum / cmp_gclk kept for structural parity with legacy
   // monitor.v's port list and SAS plumbing; all unused in the port.
   wire _unused_cmp_gclk = cmp_gclk;

endmodule
