`timescale 1ps/1ps

// PCX/CPX field positions and encodings come from the chip header.
`include "iop.h"

// Generic OpenSPARC T1 diag testbench (per-thread version).
//
// Unlike tb_core_smoke.v (hard-coded image, pass = observe a second IMISS),
// this TB is a minimal L2/DRAM responder driven by a $readmemh memory image,
// plus a PASS/FAIL scoreboard watching the legacy diag's thread_status_mem
// store and thread halt.
//
// Image format (port/scripts/diag2hex.py, memimage2hex.py):
//   sparse $readmemh, 64-bit big-endian words, @idx = phys_addr / 8.
//   Lookup: mem[pa >> 3].
//
// Usage:
//   vvp tb_diag.vvp +memfile=port/build/diag/<name>.mem [+threads=N]
//                                                     [+max_cycle=N]
//
// Boot mechanism is identical to tb_core_smoke.v: one CPX INT_RET reset
// interrupt per thread is injected (thread id in cputhread [12:8]); the
// served image's trap table at PA 0xfff0000000 (reset slot 0xfff0000040)
// provides the first instructions.  The minimal boot harness
// (port/scripts/t1boot_min.s) lands there.  +threads=N sets how many
// threads are started (default: the compiled-in SMT width); a diag that
// only runs thread 0 is started with +threads=1.
//
// PCX/CPX protocol (field defs: design/sys/iop/include/iop.h):
//   PCX RQ_IMISS (5'b10000) -> two CPX RET_IFILL (4'b0001) 16B halves
//   PCX RQ_LOAD  (5'b00000) -> CPX RET_LOAD (4'b0000), 64-bit word
//   PCX RQ_STORE (5'b00001) -> write mem, then CPX RET_STACK (4'b0100)
//   PCX RQ_STQ   (5'b00111) -> write mem, then CPX RET_STACK
//   other types  -> logged, no response
//
// PASS/FAIL: a RQ_STORE to PA thread_status_mem (0xfff0020000) carries a
// one-hot thread result word; upper 32 bits 0 => good_trap (pass),
// nonzero (0xF) => bad_trap (fail).  Every active thread writes that
// same word, so the scoreboard keeps one entry per TID and only decides
// once all started threads have reported.

module tb_diag;
    localparam integer CLK_HALF       = 2500;   // 200 MHz
    localparam integer RESET_HOLD_PS  = 100000;
    localparam integer BOOT_CYCLE     = 300;
    localparam integer TIMEOUT_CYCLES = 200000;
    localparam integer THREAD_GAP     = 16;
    localparam integer MAXQ           = 16;     // request queue depth

    // thread_status_mem (t1boot.ld .tstatus @ PA 0xfffff0020000, i.e.
    // 40-bit PA 0xfff0020000 in the RED IO window)
    localparam [39:0] STATUS_MEM_PA = 40'hff_f002_0000;

    // PCX request / CPX return encodings.  Field positions come from iop.h
    // (CPX_*, PCX_*); the encodings stay local so the bench does not depend
    // on the chip header's value macros in this compile context.
    localparam [4:0] RQ_LOAD  = 5'b00000;
    localparam [4:0] RQ_STORE = 5'b00001;
    localparam [4:0] RQ_STQ   = 5'b00111;
    localparam [4:0] RQ_IMISS = 5'b10000;
    localparam [3:0] RET_LOAD  = 4'b0000;
    localparam [3:0] RET_IFILL = 4'b0001;
    localparam [3:0] RET_STACK = 4'b0100;
    localparam [3:0] RET_INT   = 4'b0111;

    // PCX size encodings
    localparam [2:0] SZ_8B  = 3'b011;
    localparam [2:0] SZ_16B = 3'b111;

`ifdef SPARC_1THREAD
    localparam integer SMT_WIDTH = 1;
`elsif SPARC_2THREAD
    localparam integer SMT_WIDTH = 2;
`else
    localparam integer SMT_WIDTH = 4;
`endif

    integer nthreads;          // threads started by this run
    reg [3:0] active_mask;     // one-hot of the started threads

    reg gclk;
    reg reset_l;

    wire [4:0]   spc_pcx_req_pq;
    wire         spc_pcx_atom_pq;
    wire [123:0] spc_pcx_data_pa;
    wire [4:0]   pcx_spc_grant_px;
    wire         cpx_spc_data_rdy_cx2;
    wire [144:0] cpx_spc_data_cx2;

    reg [4:0] grant_px;

    reg         boot_pend;
    reg [1:0]   boot_tid;
    integer     boot_next;

    // ---------------------------------------------------------------
    // Backing memory: 64-bit words indexed by (pa>>3) & MASK.
    // ---------------------------------------------------------------
    localparam integer LOW_WORDS  = 1 << 25;   // PA[27:3]  -> up to 0x10000000
    localparam integer RED_WORDS  = 1 << 17;   // PA[19:3]  -> RED page 0xfff0..
    reg [63:0] mem_low [0:LOW_WORDS-1];
    reg [63:0] mem_red [0:RED_WORDS-1];

    reg [256*8-1:0] memfile;
    integer max_cycle;

    // The arrays come up as x in simulation, and st_write is a byte-merged
    // read-modify-write: without scrubbing x the first partial store leaves
    // the untouched lanes as x and every later load reads x back.
    function [63:0] mem_read;
        input [39:0] pa;
        reg [63:0] v;
        begin
            if ((pa[39:28] == 12'hfff) || (pa[35:28] == 8'h0f))
                v = mem_red[pa[19:3]];
            else
                v = mem_low[pa[27:3]];
            mem_read = (^v === 1'bx) ? 64'b0 : v;
        end
    endfunction

    task mem_write;
        input [39:0] pa;
        input [63:0] val;
        begin
            if ((pa[39:28] == 12'hfff) || (pa[35:28] == 8'h0f))
                mem_red[pa[19:3]] = val;
            else
                mem_low[pa[27:3]] = val;
        end
    endtask

    task load_image;
        input [256*8-1:0] path;
        integer fid, code;
        reg [255:0] line;
        reg [63:0]  idx;
        reg [63:0]  waddr;
        reg [63:0]  wval;
        integer     nwords;
        begin
            fid = $fopen(path, "r");
            if (fid == 0) begin
                $display("TB: cannot open memfile %0s", path);
                $finish;
            end
            waddr  = 64'b0;
            nwords = 0;
            while (!$feof(fid)) begin
                code = $fscanf(fid, "%s", line);
                if (code == 1) begin
                    if ($sscanf(line, "@%h", idx) == 1) begin
                        waddr = idx;
                    end else if (line[7:0] == 8'h2f) begin
                        // comment token
                    end else if ($sscanf(line, "%h", wval) == 1) begin
                        mem_write({waddr[36:0], 3'b000}, wval);
                        waddr  = waddr + 1;
                        nwords = nwords + 1;
                    end
                end
            end
            $fclose(fid);
            $display("TB: %0d words loaded", nwords);
        end
    endtask

    initial begin
        memfile = "none";
        if ($value$plusargs("memfile=%s", memfile)) begin
            load_image(memfile);
            $display("TB: loaded memfile %0s", memfile);
        end else begin
            $display("TB: no +memfile given, memory starts empty");
        end
        if (!$value$plusargs("max_cycle=%d", max_cycle))
            max_cycle = TIMEOUT_CYCLES;

        nthreads = 1;
        if ($value$plusargs("threads=%d", nthreads)) begin
            if (nthreads < 1) nthreads = 1;
            if (nthreads > SMT_WIDTH) nthreads = SMT_WIDTH;
        end
        case (nthreads)
            1: active_mask = 4'b0001;
            2: active_mask = 4'b0011;
            default: active_mask = 4'b1111;
        endcase
        $display("TB: %0d active thread(s), mask=%b", nthreads, active_mask);
    end

    // ---------------------------------------------------------------
    // DUT
    // ---------------------------------------------------------------
    iop_fpga dut (
        .reset_l              (reset_l),
        .gclk                 (gclk),
        .spc_pcx_req_pq       (spc_pcx_req_pq),
        .spc_pcx_atom_pq      (spc_pcx_atom_pq),
        .spc_pcx_data_pa      (spc_pcx_data_pa),
        .pcx_spc_grant_px     (pcx_spc_grant_px),
        .cpx_spc_data_rdy_cx2 (cpx_spc_data_rdy_cx2),
        .cpx_spc_data_cx2     (cpx_spc_data_cx2)
    );

`ifdef FPU_SMOKE
    // ---------------------------------------------------------------
    // Shared FPU (the block that sits behind the CCX in a real chip,
    // design/sys/iop/fpu/rtl/fpu.v).  The PCX/CPX fabric is replaced by
    // the two queues below: requests whose PCX type is 5'h0a / 5'h0b
    // (the FPU A/B packets) are routed here instead of to the memory
    // responder, and the FPU's CPX returns are multiplexed onto the
    // core's CPX port ahead of nothing (memory keeps priority).
    // ---------------------------------------------------------------
    wire [7:0]   fp_cpx_req_cq;
    wire [144:0] fp_cpx_data_ca;


    localparam FPQ    = 4;      // PCX -> FPU request queue depth
    localparam FPCPXQ = 4;      // FPU -> CPX return FIFO depth
    reg [123:0] fp_q    [0:FPQ-1];
    integer     fp_q_head, fp_q_count;
    reg [144:0] fp_cq   [0:FPCPXQ-1];
    integer     fp_cq_head, fp_cq_count;
    integer     fp_rq_count, fp_ret_count, fp_drop;
    reg         fp_req_d;       // fp_cpx_req_cq delayed one cycle
    integer     fp_i;

    wire [123:0] fp_pcx_data = (fp_q_count != 0) ? fp_q[fp_q_head] : 124'b0;
    // The FPU pairs the two halves of an op (rs2 then rs1) when they arrive
    // on adjacent cycles; wait for a pair, then keep the port busy until the
    // queue drains so the two halves stay back to back.
    reg          fp_sending;
    wire         fp_pcx_rdy  = reset_l && ((fp_q_count >= 2) || fp_sending);

    // Never let the un-written FIFO array (all X) reach the core's CPX
    // input: an empty FIFO reads out as zero.
    wire [144:0] fp_data_out = (fp_cq_count != 0) ? fp_cq[fp_cq_head] : 145'b0;
    wire         fp_vld_out  = reset_l && (fp_cq_count != 0);

    fpu fpu0 (
        .pcx_fpio_data_rdy_px2 (fp_pcx_rdy),
        .pcx_fpio_data_px2     (fp_pcx_data),
        .arst_l                (reset_l),
        .grst_l                (reset_l),
        .gclk                  (gclk),
        .cluster_cken          (1'b1),
        .fp_cpx_req_cq         (fp_cpx_req_cq),
        .fp_cpx_data_ca        (fp_cpx_data_ca),
        .ctu_tst_pre_grst_l    (1'b1),
        .global_shift_enable   (1'b0),
        .ctu_tst_scan_disable  (1'b1),
        .ctu_tst_scanmode      (1'b0),
        .ctu_tst_macrotest     (1'b0),
        .ctu_tst_short_chain   (1'b0),
        .si                    (1'b0),
        .so                    ()
    );
`endif

`ifdef FPU_SMOKE
    // FFU/LSU bring-up probe: is the core even asking for an fpop?
    // qctl1 lives in a generate block, so the path differs by thread count.
`ifdef SPARC_1THREAD
    `define LSU_QCTL dut.sparc0.lsu.g_qctl_smt1.qctl1
`else
    `define LSU_QCTL dut.sparc0.lsu.g_qctl_smtn.qctl1
`endif

    reg ffu_trace = 1'b0;
    initial if ($test$plusargs("ffutrace")) ffu_trace = 1'b1;
    always @(posedge gclk) if (ffu_trace) begin
        $display("FFU cyc=%0d fpop_rq_vld=%b fpop1_d=%b fpop2_d=%b fld_d=%b opcode=%h op1_rdy=%b op2_rdy=%b op_w3=%b ack=%b opf=%h",
                 cycle_count,
                 dut.sparc0.ffu_lsu_fpop_rq_vld,
                 dut.sparc0.ifu_ffu_fpop1_d,
                 dut.sparc0.ifu_ffu_fpop2_d,
                 dut.sparc0.ifu_ffu_fld_d,
                 dut.sparc0.ifu_ffu_fpopcode_d,
                 dut.sparc0.ffu.ctl.fpop1_ready_w2,
                 dut.sparc0.ffu.ctl.fpop2_ready_w3,
                 dut.sparc0.ffu.ctl.fpu_op_w3_vld,
                 dut.sparc0.ffu.ctl.lsu_ffu_ack,
                 dut.sparc0.ffu.ctl.opf);
        $display("FRF3 cyc=%0d wen=%b addr=%h wr=%h rd=%h",
                 cycle_count, dut.sparc0.ffu.frf.ctl_frf_wen,
                 dut.sparc0.ffu.frf.ctl_frf_addr,
                 dut.sparc0.ffu.frf.dp_frf_data,
                 dut.sparc0.ffu.frf.frf_dp_data);
        $display("FFU2 cyc=%0d op2=%b op3=%b op3v=%b nceen=%b rs2ue=%b rb2=%b kill2=%b rs1ce=%b ue3=%b uetrap=%b rb13=%b ce=%b pce=%b pue=%b rbk=%b r2=%b r2w=%b fl2=%b",
                 cycle_count,
                 dut.sparc0.ffu.ctl.fpu_op_w2,
                 dut.sparc0.ffu.ctl.fpu_op_w3,
                 dut.sparc0.ffu.ctl.fpu_op_w3_vld,
                 dut.sparc0.ffu.ctl.nceen,
                 dut.sparc0.ffu.ctl.rs2_ue_w2,
                 dut.sparc0.ffu.ctl.rollback_rs2_w2,
                 dut.sparc0.ffu.ctl.ecc_kill_rs2_w2,
                 dut.sparc0.ffu.ctl.rs1_ce_w3,
                 dut.sparc0.ffu.ctl.ue_w3,
                 dut.sparc0.ffu.ctl.ue_trap_w3,
                 dut.sparc0.ffu.ctl.rollback_rs1_w3,
                 dut.sparc0.ffu.ctl.ce,
                 dut.sparc0.ffu.ctl.previous_ce,
                 dut.sparc0.ffu.ctl.previous_ue,
                 dut.sparc0.ffu.ctl.rolled_back,
                 dut.sparc0.ffu.ctl.ren_rs2_w2,
                 dut.sparc0.ffu.ctl.ren_rs2_w,
                 dut.sparc0.ffu.ctl.flush_w2);
        $display("OPF cyc=%0d opf=%h d=%h pk=%h p1=%b p2=%b ack=%b ldd=%h",
                 cycle_count, dut.sparc0.ffu.ctl.opf,
                 dut.sparc0.ffu_lsu_data,
                 {dut.sparc0.ffu_lsu_data[79:72], dut.sparc0.ffu_lsu_data[63:0]},
                 dut.sparc0.ffu.ctl.fpop1_ready_w2,
                 dut.sparc0.ffu.ctl.fpop2_ready_w3,
                 dut.sparc0.ffu.ctl.lsu_ffu_ack,
                 dut.sparc0.lsu_ffu_ld_data);
        if (cycle_count > 1300 && cycle_count < 1500)
            $display("FPRQ cyc=%0d reqcq=%b vld=%b data=%h",
                     cycle_count, fpu0.fp_cpx_req_cq,
                     fpu0.fp_cpx_data_ca[144],
                     fpu0.fp_cpx_data_ca[63:0]);
        $display("LDW cyc=%0d ldvld=%b ldret=%b nfl=%b fl=%b nff=%b ff=%b",
                 cycle_count, dut.sparc0.ffu.ctl.lsu_ffu_ld_vld,
                 dut.sparc0.ffu.ctl.ld_ret,
                 dut.sparc0.ffu.ctl.ctl_dp_noflip_lsu,
                 dut.sparc0.ffu.ctl.ctl_dp_flip_lsu,
                 dut.sparc0.ffu.ctl.ctl_dp_noflip_fpu,
                 dut.sparc0.ffu.ctl.ctl_dp_flip_fpu);
        $display("QMON cyc=%0d e0=%b e1=%b upd4=%b gr4=%b sel4=%b",
                 cycle_count, `LSU_QCTL.fpiobridge_qmon.entry0_full,
                 `LSU_QCTL.fpiobridge_qmon.entry1_full,
                 `LSU_QCTL.spc_pcx_req_update_w2[4],
                 dut.sparc0.pcx_spc_grant_px[4],
                 `LSU_QCTL.sel_qentry0[4]);
        $display("LSU2 cyc=%0d ld0=%b ld1=%b st0=%b st1=%b im=%b strm=%b rq=%h",
                 cycle_count, `LSU_QCTL.ld0_pcx_rq_vld,
                 `LSU_QCTL.ld1_pcx_rq_vld,
                 `LSU_QCTL.st0_pcx_rq_vld,
                 `LSU_QCTL.st1_pcx_rq_vld,
                 `LSU_QCTL.imiss_pcx_rq_vld,
                 `LSU_QCTL.strm_pcx_rq_vld,
                 dut.sparc0.lsu.spc_pcx_req_pq);
        $display("LSU cyc=%0d fvld=%b pktv=%b pktu=%b qwr=%b sel=%b rqv=%b sel2=%b",
                 cycle_count, dut.sparc0.ffu_lsu_fpop_rq_vld,
                 `LSU_QCTL.fpop_pkt_vld,
                 `LSU_QCTL.fpop_pkt_vld_unmasked,
                 `LSU_QCTL.fpop_q_wr,
                 `LSU_QCTL.fpop_pcx_rq_sel,
                 `LSU_QCTL.fpop_pcx_rq_vld,
                 `LSU_QCTL.fpop_pcx_rq_sel_d1);
    end
`endif

    initial gclk = 1'b0;
    always #(CLK_HALF) gclk = ~gclk;

    always @(posedge gclk)
        grant_px <= spc_pcx_req_pq;

    // ---------------------------------------------------------------
    // Responder FSM
    // ---------------------------------------------------------------
    localparam [3:0] R_IDLE   = 4'd0,
                     R_IDLY   = 4'd1,   // imiss latency
                     R_ILOW   = 4'd2,
                     R_IGAP0  = 4'd3,
                     R_IHIGH  = 4'd4,
                     R_IGAP1  = 4'd5,
                     R_LDLY   = 4'd6,   // load latency
                     R_LDRDY  = 4'd7,
                     R_SDLY   = 4'd8,   // store->ack latency
                     R_SACK   = 4'd9;

    reg [3:0]  rsp_state;
    reg [7:0]  rsp_delay;
    reg [39:0] rsp_addr;
    reg [1:0]  rsp_tid;
    reg [1:0]  rsp_pktid;

    // Request queue: with several threads fetching, loading and storing
    // at once, a single pending latch would drop requests.  The queue
    // holds one entry per accepted PCX packet and the FSM drains it one
    // request at a time.
    reg [4:0]  q_rq   [0:MAXQ-1];
    reg [1:0]  q_tid  [0:MAXQ-1];
    reg [1:0]  q_pid  [0:MAXQ-1];
    reg [2:0]  q_sz   [0:MAXQ-1];
    reg [39:0] q_addr [0:MAXQ-1];
    reg [63:0] q_data [0:MAXQ-1];
    integer    q_head, q_count;

    reg          cpx_rdy;
    reg [144:0]  cpx_data;

    assign pcx_spc_grant_px     = grant_px;
`ifdef FPU_SMOKE
    // Memory (and the reset/IFILL burst) win; an FPU return that loses
    // the cycle stays in the FIFO and is offered again next cycle.
    assign cpx_spc_data_rdy_cx2 = cpx_rdy | fp_vld_out;
    assign cpx_spc_data_cx2     = fp_vld_out ? fp_data_out : cpx_data;
`else
    assign cpx_spc_data_rdy_cx2 = cpx_rdy;
    assign cpx_spc_data_cx2     = cpx_data;
`endif

    // ---------------------------------------------------------------
    // Memory helpers
    // ---------------------------------------------------------------
    function [127:0] ifill_data;
        input [39:0] line;
        input        upper;
        reg   [63:0] w0, w1;
        begin
            if (!upper) begin
                w0 = mem_read(line & 40'hffff_ffff_f8);
                w1 = mem_read((line & 40'hffff_ffff_f8) + 8);
            end else begin
                w0 = mem_read((line & 40'hffff_ffff_f8) + 16);
                w1 = mem_read((line & 40'hffff_ffff_f8) + 24);
            end
            ifill_data = {w0, w1};
        end
    endfunction

    function [63:0] ld_word;
        input [39:0] pa;
        begin
            ld_word = mem_read(pa);
        end
    endfunction

    task st_write;
        input [39:0] pa;
        input [2:0]  sz;
        input [63:0] stdata;
        integer nbytes, i, byteoff;
        reg [63:0] cur;
        begin
            case (sz)
                3'b000: nbytes = 1;
                3'b001: nbytes = 2;
                3'b010: nbytes = 4;
                3'b011: nbytes = 8;
                3'b111: nbytes = 16;
                default: nbytes = 8;
            endcase
            byteoff = pa[2:0];
            cur = mem_read(pa);
            // The PCX store data is big-endian inside its 64-bit field: byte
            // 0 of the word sits in stdata[63:56].  (It used to be taken from
            // the low end, which byte-reversed every diag store.)
            for (i = 0; i < nbytes && i < 8; i = i + 1)
                cur[63 - 8*(byteoff+i) -: 8] = stdata[63 - 8*i -: 8];
            mem_write(pa, cur);
            if (nbytes > 8) begin
                cur = mem_read(pa + 8);
                for (i = 0; i < nbytes-8; i = i + 1)
                    cur[63 - 8*i -: 8] = stdata[63 - 8*(8+i) -: 8];
                mem_write(pa + 8, cur);
            end
        end
    endtask

    // ---------------------------------------------------------------
    // CPX packet builders
    // ---------------------------------------------------------------
    function [144:0] ifill_pkt;
        input [1:0]   tid;
        input [127:0] data;
        begin
            ifill_pkt                        = 145'b0;
            ifill_pkt[`CPX_VLD]              = 1'b1;
            ifill_pkt[`CPX_RQ_HI:`CPX_RQ_LO] = RET_IFILL;
            ifill_pkt[`CPX_TH_HI:`CPX_TH_LO] = tid;
            ifill_pkt[127:0]                 = data;
        end
    endfunction

    function [144:0] load_pkt;
        input [1:0]  tid;
        input [63:0] data;
        begin
            load_pkt                        = 145'b0;
            load_pkt[`CPX_VLD]              = 1'b1;
            load_pkt[`CPX_RQ_HI:`CPX_RQ_LO] = RET_LOAD;
            load_pkt[`CPX_TH_HI:`CPX_TH_LO] = tid;
            load_pkt[63:0]                  = data;
        end
    endfunction

    function [144:0] stack_pkt;
        input [1:0] tid;
        input [1:0] pktid;
        begin
            stack_pkt                                    = 145'b0;
            stack_pkt[`CPX_VLD]                          = 1'b1;
            stack_pkt[`CPX_RQ_HI:`CPX_RQ_LO]             = RET_STACK;
            stack_pkt[`CPX_TH_HI:`CPX_TH_LO]             = tid;
            stack_pkt[`CPX_P_HI:`CPX_P_LO]               = pktid;
            stack_pkt[125]                               = 1'b0;  // not squashed
            stack_pkt[`CPX_IINV]                         = 1'b0;
            stack_pkt[`CPX_DINV]                         = 1'b0;
            stack_pkt[`CPX_CPUID_HI:`CPX_CPUID_LO]       = 3'b000;
        end
    endfunction

    // CPX INT_RET reset packet for one thread: type [17:16] = 01 (reset),
    // cputhread [12:8] = the thread to reset.
    function [144:0] cpx_rst_pkt;
        input [1:0] tid;
        reg   [144:0] pkt;
        begin
            pkt                         = 145'b0;
            pkt[`CPX_VLD]               = 1'b1;
            pkt[`CPX_RQ_HI:`CPX_RQ_LO]  = RET_INT;   // reset interrupt
            pkt[17:16]     = 2'b01;     // reset
            pkt[9:8]       = tid;
            cpx_rst_pkt    = pkt;
        end
    endfunction

    // ---------------------------------------------------------------
    // Combined CPX driver
    //
    // The CPX port is a single channel, so reset packets and responder
    // returns are serialized: a reset packet is only offered while the
    // responder is idle, and the responder only starts a burst while no
    // reset packet is waiting.
    // ---------------------------------------------------------------
    always @* begin
        cpx_rdy  = 1'b0;
        cpx_data = 145'b0;

        if (boot_pend && rsp_state == R_IDLE) begin
            cpx_rdy  = 1'b1;
            cpx_data = cpx_rst_pkt(boot_tid);
        end
        else if (rsp_state == R_ILOW) begin
            cpx_rdy  = 1'b1;
            cpx_data = ifill_pkt(rsp_tid, ifill_data(rsp_addr, 1'b0));
        end
        else if (rsp_state == R_IHIGH) begin
            cpx_rdy  = 1'b1;
            cpx_data = ifill_pkt(rsp_tid, ifill_data(rsp_addr, 1'b1));
        end
        else if (rsp_state == R_LDRDY) begin
            cpx_rdy  = 1'b1;
            cpx_data = load_pkt(rsp_tid, ld_word(rsp_addr));
`ifdef FPU_SMOKE
            $display("TB: LDRET cyc=%0d addr=%h word=%h", cycle_count,
                     rsp_addr, ld_word(rsp_addr));
`endif
        end
        else if (rsp_state == R_SACK) begin
            cpx_rdy  = 1'b1;
            cpx_data = stack_pkt(rsp_tid, rsp_pktid);
        end
    end

    // ---------------------------------------------------------------
    // PCX monitor + scoreboard
    // ---------------------------------------------------------------
    integer imiss_count, load_count, store_count, other_count, drop_count;
    integer cycle_count;
    reg [123:0] pcx_sig_d;
    reg     finished;

    wire [4:0]  pcx_rq   = spc_pcx_data_pa[`PCX_RQ_HI:`PCX_RQ_LO];
`ifdef FPU_SMOKE
    // The FPU's two request packets (design/sys/iop/fpu/rtl/fpu_in.v:
    // fpu_in_ctl decodes 5'h0a as packet A and 5'h0b as packet B).
    wire is_fpop = (pcx_rq == 5'h0a) || (pcx_rq == 5'h0b);
`else
    wire is_fpop = 1'b0;
`endif
    wire [1:0]  pcx_tid  = spc_pcx_data_pa[`PCX_TH_HI:`PCX_TH_LO];
    wire [1:0]  pcx_pid  = spc_pcx_data_pa[`PCX_P_HI:`PCX_P_LO];
    wire [2:0]  pcx_sz   = spc_pcx_data_pa[`PCX_SZ_HI:`PCX_SZ_LO];
    wire [39:0] pcx_addr = spc_pcx_data_pa[`PCX_AD_HI:`PCX_AD_LO];
    wire [39:0] pcx_line = {pcx_addr[39:5], 5'b0};
    wire [63:0] pcx_data = spc_pcx_data_pa[`PCX_DA_HI:`PCX_DA_LO];

    // A packet is accepted on the cycle it is granted.  The grant is
    // registered from the request vector, so a back-to-back packet can
    // appear with vld still high; comparing the packet with the previous
    // cycle keeps the capture one-per-packet.
    wire pcx_new_sig = (spc_pcx_data_pa[123:0] != pcx_sig_d);
    // fpop requests are presented for a single cycle (the LSU retires the
    // entry as soon as it is selected), so they must be taken on that cycle
    // even though the grant lands one cycle later.
    wire pcx_fire = reset_l & spc_pcx_data_pa[`PCX_VLD] & pcx_new_sig &
                    ((|grant_px) | is_fpop);

`ifdef FPU_SMOKE
    // FFU load-port data at the moment the load return is accepted, plus a
    // dump of the FRF array afterwards (the flop-level probe can lag a cycle).
    always @(posedge gclk) begin
        if (cycle_count == 1800)
            $display("TB: FRFDUMP f0=%h f2=%h f4=%h f6=%h",
                     dut.sparc0.ffu.frf.regfile[0], dut.sparc0.ffu.frf.regfile[2],
                     dut.sparc0.ffu.frf.regfile[4], dut.sparc0.ffu.frf.regfile[6]);
    end
`endif

`ifdef FPU_SMOKE
    always @(posedge gclk)
        if (pcx_fire)
            $display("TB: FIRE cyc=%0d rq=%b tid=%0d sz=%b addr=%h data=%h",
                     cycle_count, pcx_rq, pcx_tid, pcx_sz, pcx_addr, pcx_data);
`endif

    // A store whose aligned-8 address equals STATUS_MEM_PA is the result write.
    wire status_hit = pcx_fire && (pcx_rq == RQ_STORE || pcx_rq == RQ_STQ) &&
                      ((pcx_addr >> 3) == (STATUS_MEM_PA >> 3));

    reg [63:0] status_word [0:3];
    reg [63:0] status_or;
    reg [3:0]  reported;

    // The status scoreboard runs independently of the responder FSM: a
    // status store may arrive while the FSM is mid-IFILL/LOAD, so it must
    // not be gated behind the R_IDLE branch.  Every started thread writes
    // the same word, so the verdict waits for all of them.
    always @(posedge gclk) begin
        if (reset_l && !finished && status_hit) begin
            status_word[pcx_tid] = pcx_data;
            status_or             = status_or | pcx_data;
            reported[pcx_tid]     = 1'b1;
            $display("TB: thread %0d reported status %h", pcx_tid, pcx_data);
            if ((reported | (4'b1 << pcx_tid)) == active_mask) begin
                finished = 1'b1;
                check_status(status_or | pcx_data);
            end
        end
    end

    task check_status;
        input [63:0] stdata;
        begin
            if (stdata[63:32] == 32'h0000_0000)
                $display("DIAG PASS: good trap, thread_status=%h", stdata);
            else
                $display("DIAG FAIL: bad trap, thread_status=%h", stdata);
            $finish;
        end
    endtask

    initial begin
        imiss_count = 0; load_count = 0; store_count = 0; other_count = 0;
        drop_count = 0;
        cycle_count = 0; pcx_sig_d = 124'b0; finished = 1'b0;
        status_or = 64'b0; reported = 4'b0;
        status_word[0] = 64'b0; status_word[1] = 64'b0;
        status_word[2] = 64'b0; status_word[3] = 64'b0;
        reset_l = 1'b0; grant_px = 5'b0;
        boot_pend = 1'b0; boot_tid = 2'b0; boot_next = 0;
        rsp_state = R_IDLE; rsp_delay = 8'd0;
        rsp_addr = 40'b0; rsp_tid = 2'b0; rsp_pktid = 2'b0;
        q_head = 0; q_count = 0;
`ifdef FPU_SMOKE
        fp_q_head = 0; fp_q_count = 0;
        fp_cq_head = 0; fp_cq_count = 0;
        fp_rq_count = 0; fp_ret_count = 0; fp_drop = 0;
        fp_req_d = 1'b0; fp_sending = 1'b0;
        // Power-up model for the FFU's floating-point register file: it is
        // BRAM inside the core, and an unwritten entry reads out as x, which
        // the ECC check turns into an x on rs2_ue_w2 -> the fpop request
        // never becomes valid.  Zero it the way configuration would.
        for (fp_i = 0; fp_i < 256; fp_i = fp_i + 1)
            dut.sparc0.ffu.frf.regfile[fp_i] = 39'b0;
`endif
        $display("TB: start");
        #(RESET_HOLD_PS) reset_l = 1'b1;
        $display("TB: reset released at %0t", $time);
    end

    always @(posedge gclk) begin
        pcx_sig_d <= spc_pcx_data_pa[123:0];
`ifdef FPU_SMOKE
        if (reset_l && (spc_pcx_req_pq !== 5'b0))
            $display("TB: REQ cyc=%0d pq=%b atom=%b vld=%b type=%b tid=%0d addr=%h data=%h grant=%b",
                     cycle_count, spc_pcx_req_pq, spc_pcx_atom_pq,
                     spc_pcx_data_pa[`PCX_VLD],
                     spc_pcx_data_pa[`PCX_RQ_HI:`PCX_RQ_LO],
                     spc_pcx_data_pa[`PCX_TH_HI:`PCX_TH_LO],
                     spc_pcx_data_pa[`PCX_AD_HI:`PCX_AD_LO],
                     spc_pcx_data_pa[`PCX_DA_HI:`PCX_DA_LO],
                     grant_px);
`endif

        if (!reset_l) begin
            boot_pend  <= 1'b0;
            boot_next  <= 0;
            boot_tid   <= 2'b0;
            rsp_state  <= R_IDLE;
            rsp_delay  <= 8'd0;
            q_head     <= 0;
            q_count    <= 0;
        end
        else if (!finished) begin
            cycle_count <= cycle_count + 1;

            // ---- one reset packet per thread ------------------------
            // Offered as soon as the responder is idle; the pending flag
            // is only cleared once the packet has actually been driven.
            if (boot_pend) begin
                if (rsp_state == R_IDLE)
                    boot_pend <= 1'b0;
            end
            else if (boot_next < nthreads && cycle_count >= BOOT_CYCLE &&
                     ((cycle_count - BOOT_CYCLE) % THREAD_GAP) == 0) begin
                boot_pend <= 1'b1;
                boot_tid  <= boot_next[1:0];
                boot_next <= boot_next + 1;
                $display("TB: queue CPX reset packet thread %0d at cyc=%0d",
                         boot_next, cycle_count);
            end

            // ---- request capture ------------------------------------
            if (pcx_fire) begin
`ifdef FPU_SMOKE
                if (is_fpop) begin
                    fp_rq_count <= fp_rq_count + 1;
                    $display("TB: FPOP rq #%0d type=%b tid=%0d op=%h id=%0d",
                             fp_rq_count, pcx_rq, pcx_tid, pcx_data[79:72],
                             spc_pcx_data_pa[116:112]);
                    if (fp_q_count == FPQ) begin
                        fp_drop <= fp_drop + 1;
                        $display("TB: FPU request queue full, dropping type=%b tid=%0d",
                                 pcx_rq, pcx_tid);
                    end else begin
                        fp_q[(fp_q_head + fp_q_count) % FPQ] <= spc_pcx_data_pa;
                        fp_q_count <= fp_q_count + 1;
                    end
                end
                else
`endif
                if (q_count == MAXQ) begin
                    drop_count <= drop_count + 1;
                    $display("TB: request queue full, dropping type=%b tid=%0d",
                             pcx_rq, pcx_tid);
                end else begin
                    q_rq [(q_head + q_count) % MAXQ] <= pcx_rq;
                    q_tid[(q_head + q_count) % MAXQ] <= pcx_tid;
                    q_pid[(q_head + q_count) % MAXQ] <= pcx_pid;
                    q_sz [(q_head + q_count) % MAXQ] <= pcx_sz;
                    q_addr[(q_head + q_count) % MAXQ] <= pcx_addr;
                    q_data[(q_head + q_count) % MAXQ] <= pcx_data;
                    q_count <= q_count + 1;
                end
            end

`ifdef FPU_SMOKE
            // ---- FPU request queue: hand out one packet per cycle ----
            // Holding a packet would feed the FPU the same one forever; a
            // queued packet is presented for exactly one cycle and retired.
            if (fp_pcx_rdy && fp_pcx_data[123])
                $display("FPSEND cyc=%0d pkt=%h rq=%b op=%h id=%h inq_op=%h inq_id=%h",
                         cycle_count, fp_pcx_data, fp_pcx_data[122:118],
                         fp_pcx_data[79:72], fp_pcx_data[116:112],
                         fpu0.fpu_in.fpu_in_dp.fp_op_in, fpu0.fpu_in.fpu_in_dp.fp_id_in);
            if (fp_pcx_rdy && fp_pcx_data[123]) begin
                fp_q_head  <= (fp_q_head + 1) % FPQ;
                fp_q_count <= fp_q_count - 1;
                fp_sending <= 1'b1;
            end
            if (fp_q_count == 0) fp_sending <= 1'b0;

            // ---- FPU return FIFO -------------------------------------
            // fp_cpx_req_cq is the FPU's (pulsed) request into the CPX
            // buffer stage; fp_cpx_data_ca carries the whole CPX packet
            // (bit 144 = CPX valid, [143:140] = FP_RET, [135:134] = tid).
            // fp_cpx_req_cq is the request into the CPX buffer stage; the
            // CA packet itself lands one cycle later (fpu_out_dp flops it
            // one more stage), so the data is sampled on the next cycle.
            fp_req_d <= (fp_cpx_req_cq != 8'b0);
            if (fp_req_d) begin
                fp_ret_count <= fp_ret_count + 1;
                if (fp_cq_count == FPCPXQ) begin
                    fp_drop <= fp_drop + 1;
                    $display("TB: FPU return FIFO full, dropping packet %h",
                             fp_cpx_data_ca);
                end else begin
                    fp_cq[(fp_cq_head + fp_cq_count) % FPCPXQ] <= fp_cpx_data_ca;
                    $display("TB: FPU ret #%0d %h", fp_ret_count, fp_cpx_data_ca);
                    fp_cq_count <= fp_cq_count + 1;
                end
            end
            else if (fp_vld_out && !cpx_rdy) begin
                // presented on the CPX port this cycle -> consume it
                fp_cq_head  <= (fp_cq_head + 1) % FPCPXQ;
                fp_cq_count <= fp_cq_count - 1;
            end
`endif

            // ---- responder FSM --------------------------------------
            case (rsp_state)
                R_IDLE: begin
                    if (q_count != 0 && !boot_pend) begin
                        q_head  <= (q_head + 1) % MAXQ;
                        q_count <= q_count - 1;
                        if (q_rq[q_head] == RQ_IMISS) begin
                            rsp_addr  <= {q_addr[q_head][39:5], 5'b0};
                            rsp_tid   <= q_tid[q_head];
                            rsp_delay <= 8'd8;
                            rsp_state <= R_IDLY;
                        end
                        else if (q_rq[q_head] == RQ_LOAD) begin
                            rsp_addr  <= q_addr[q_head];
                            rsp_tid   <= q_tid[q_head];
                            rsp_delay <= 8'd6;
                            rsp_state <= R_LDLY;
                        end
                        else if (q_rq[q_head] == RQ_STORE ||
                                 q_rq[q_head] == RQ_STQ) begin
                            st_write(q_addr[q_head], q_sz[q_head],
                                     q_data[q_head]);
                            rsp_addr  <= q_addr[q_head];
                            rsp_tid   <= q_tid[q_head];
                            rsp_pktid <= q_pid[q_head];
                            rsp_delay <= 8'd6;
                            rsp_state <= R_SDLY;
                        end
                        else begin
                            // unsupported request: already dequeued
                            other_count <= other_count + 1;
                            $display("TB: ignore request type=%b tid=%0d",
                                     q_rq[q_head], q_tid[q_head]);
                        end
                    end
                end
                R_IDLY: begin
                    if (rsp_delay == 8'd0) rsp_state <= R_ILOW;
                    else                   rsp_delay <= rsp_delay - 8'd1;
                end
                R_ILOW:  rsp_state <= R_IGAP0;
                R_IGAP0: rsp_state <= R_IHIGH;
                R_IHIGH: rsp_state <= R_IGAP1;
                R_IGAP1: rsp_state <= R_IDLE;
                R_LDLY: begin
                    if (rsp_delay == 8'd0) rsp_state <= R_LDRDY;
                    else                   rsp_delay <= rsp_delay - 8'd1;
                end
                R_LDRDY: rsp_state <= R_IDLE;
                R_SDLY: begin
                    if (rsp_delay == 8'd0) rsp_state <= R_SACK;
                    else                   rsp_delay <= rsp_delay - 8'd1;
                end
                R_SACK: rsp_state <= R_IDLE;
                default: rsp_state <= R_IDLE;
            endcase

            // ---- request logging ------------------------------------
            if (pcx_fire) begin
                case (pcx_rq)
                    RQ_IMISS: begin
                        imiss_count <= imiss_count + 1;
                        $display("PCX IMISS #%0d t=%0t tid=%0d line=%h",
                                 imiss_count + 1, $time, pcx_tid, pcx_line);
                    end
                    RQ_LOAD: begin
                        load_count <= load_count + 1;
                        $display("PCX LOAD  #%0d t=%0t tid=%0d sz=%0d addr=%h",
                                 load_count + 1, $time, pcx_tid, pcx_sz,
                                 pcx_addr);
                    end
                    RQ_STORE, RQ_STQ: begin
                        store_count <= store_count + 1;
                        $display("PCX STORE #%0d t=%0t tid=%0d sz=%0d addr=%h data=%h",
                                 store_count + 1, $time, pcx_tid, pcx_sz,
                                 pcx_addr, pcx_data);
                    end
                    default: begin
                        other_count <= other_count + 1;
                        $display("PCX PKT   t=%0t type=%b tid=%0d addr=%h",
                                 $time, pcx_rq, pcx_tid, pcx_addr);
                    end
                endcase
            end

            if ((cycle_count % 20000) == 0 && cycle_count != 0)
                $display("TB: cycle %0d, imiss=%0d load=%0d store=%0d other=%0d drop=%0d q=%0d",
                         cycle_count, imiss_count, load_count,
                         store_count, other_count, drop_count, q_count);
`ifdef FPU_SMOKE
                $display("TB:   state rsp=%0d req_pq=%b cpx_rdy=%b fp_q=%0d fp_cq=%0d fp_rq=%0d fp_ret=%0d pcx_vld=%b pcx_type=%b grant=%b",
                         rsp_state, spc_pcx_req_pq, cpx_rdy,
                         fp_q_count, fp_cq_count, fp_rq_count, fp_ret_count,
                         spc_pcx_data_pa[123], spc_pcx_data_pa[122:118], grant_px);
`endif

            if (cycle_count == max_cycle) begin
                $display("DIAG TIMEOUT: no PASS/FAIL within %0d cycles",
                         max_cycle);
                $display("DIAG INFO: reported=%b imiss=%0d load=%0d store=%0d other=%0d drop=%0d",
                         reported, imiss_count, load_count, store_count,
                         other_count, drop_count);
                $display("DIAG INFO: pc0=%h pc1=%h pc2=%h pc3=%h",
                         dut.sparc0.ifu.fdp.t0pc_f[47:0],
                         dut.sparc0.ifu.fdp.t1pc_f[47:0],
                         dut.sparc0.ifu.fdp.t2pc_f[47:0],
                         dut.sparc0.ifu.fdp.t3pc_f[47:0]);
                $finish;
            end
        end
    end

endmodule
