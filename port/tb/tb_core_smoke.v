`timescale 1ps/1ps

// PCX/CPX field positions come from the chip header.
`include "iop.h"

// Core-level smoke test for the OpenSPARC T1 port (per-thread version).
//
// The core does not self-start after reset.  One CPX INT_RET reset packet
// per thread is injected; the packet carries the target thread in its
// cputhread field (bits [12:8]) and reset type 01 in [17:16].  Each thread
// then traps to the reset vector and starts fetching.
//
// The IFILL responder keeps one pending entry per thread and answers the
// requests one at a time, tagging each RET_IFILL with the requesting
// thread's TID.  For the first line (0xfff0000040) the returned
// instruction word is made thread-specific:
//
//   thread N at 0x40:  ba 0x80 + N*0x40    (0x1080_0000 | 0x10 + N*0x10)
//
// so every thread branches to a line of its own.  Seeing an IMISS from
// thread N for line 0x80+N*0x40 proves that the reset interrupt, the
// I-miss request, the per-thread IFILL return steering, instruction
// execution and branch redirection all work for that thread.
//
// The data served for a given line differs per thread on purpose: a real
// memory would return the same bytes to everyone, but this is a directed
// test of the TID steering, and per-thread data makes each thread's
// progress observable from the PCX address alone.

module tb_core_smoke;
    localparam integer CLK_HALF = 2500;
    localparam integer RESET_HOLD_PS = 100000;
    localparam integer TIMEOUT_CYCLES = 20000;
    localparam integer BOOT_CYCLE = 300;
    localparam integer THREAD_GAP = 16;   // cycles between reset packets

`ifdef SPARC_1THREAD
    localparam integer NTHREADS = 1;
`elsif SPARC_2THREAD
    localparam integer NTHREADS = 2;
`else
    localparam integer NTHREADS = 4;
`endif
    localparam [3:0] THREAD_MASK = (NTHREADS == 1) ? 4'b0001 :
                                   (NTHREADS == 2) ? 4'b0011 :
                                                     4'b1111;

    localparam [39:0] LINE0_BASE = 40'hfff0000040;
    localparam [39:0] LINE1_BASE = 40'hfff0000080;
    localparam [39:0] LINE_STEP  = 40'h40;

    localparam [31:0] INST_NOP   = 32'h0100_0000;  // sethi %hi(0), %g0
    localparam [31:0] BA_BASE    = 32'h1080_0000;  // ba <imm22>

    localparam [4:0]  RQ_IMISS   = 5'b10000;
    localparam [3:0]  RET_IFILL  = 4'b0001;

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

    // IFILL responder states
    localparam [2:0] R_IDLE = 3'd0,
                     R_DLY  = 3'd1,
                     R_LOW  = 3'd2,
                     R_GAP0 = 3'd3,
                     R_HIGH = 3'd4,
                     R_GAP1 = 3'd5;

    reg [2:0]  rsp_state;
    reg [3:0]  rsp_delay;
    reg [39:0] rsp_line;
    reg [1:0]  rsp_tid;

    // One pending I-miss per thread: a thread has at most one outstanding
    // IFILL at a time, so a single entry per TID is enough.
    reg [3:0]  pend_vld;
    reg [39:0] pend_line [0:3];

    reg         cpx_rdy;
    reg [144:0] cpx_data;

    assign pcx_spc_grant_px     = grant_px;
    assign cpx_spc_data_rdy_cx2 = cpx_rdy;
    assign cpx_spc_data_cx2     = cpx_data;

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

    initial gclk = 1'b0;
    always #(CLK_HALF) gclk = ~gclk;

    always @(posedge gclk) begin
        grant_px <= spc_pcx_req_pq;
    end

    // ---------------------------------------------------------------
    // Instruction image
    // ---------------------------------------------------------------
    // The 128-bit IFILL data field holds four consecutive instructions
    // in big-endian order: bits [127:96] are the lowest address.  The
    // first line branches to a per-thread target.
    function [31:0] inst_ba_to;
        input [39:0] target;
        reg   [39:0] delta;
        begin
            delta = target - LINE0_BASE;
            inst_ba_to = BA_BASE | {10'b0, delta[21:2]};
        end
    endfunction

    function [127:0] ifill_data;
        input [39:0] line;
        input [1:0]   tid;
        input         upper;
        begin
            if (!upper && line == LINE0_BASE)
                ifill_data = {inst_ba_to(LINE1_BASE + tid * LINE_STEP),
                              INST_NOP, INST_NOP, INST_NOP};
            else
                ifill_data = {INST_NOP, INST_NOP, INST_NOP, INST_NOP};
        end
    endfunction

    function [144:0] ifill_pkt;
        input [1:0]   tid;
        input [127:0] data;
        begin
            ifill_pkt          = 145'b0;
            ifill_pkt[`CPX_VLD]              = 1'b1;
            ifill_pkt[`CPX_RQ_HI:`CPX_RQ_LO] = RET_IFILL;
            ifill_pkt[`CPX_TH_HI:`CPX_TH_LO] = tid;
            ifill_pkt[127:0]   = data;
        end
    endfunction

    // CPX INT_RET reset packet for one thread.  Type [17:16] = 01 is the
    // reset interrupt, [12:8] is the cputhread the TLU resets.
    function [144:0] cpx_rst_pkt;
        input [1:0] tid;
        reg   [144:0] pkt;
        begin
            pkt            = 145'b0;
            pkt[`CPX_VLD]               = 1'b1;
            pkt[`CPX_RQ_HI:`CPX_RQ_LO]  = 4'b0111;   // INT_RET
            pkt[17:16]     = 2'b01;     // reset
            pkt[9:8]       = tid;
            cpx_rst_pkt    = pkt;
        end
    endfunction

    // ---------------------------------------------------------------
    // Combined CPX driver: boot interrupts and IFILL returns
    //
    // The CPX port is a single channel, so the two sources are
    // serialized: a reset packet is only offered while the IFILL
    // responder is idle, and the responder only starts a burst while no
    // reset packet is waiting.  Otherwise a reset packet would replace
    // one beat of a two-beat IFILL burst and the thread would be left
    // with a half line.
    // ---------------------------------------------------------------
    always @* begin
        cpx_rdy  = 1'b0;
        cpx_data = 145'b0;

        if (boot_pend && rsp_state == R_IDLE) begin
            cpx_rdy  = 1'b1;
            cpx_data = cpx_rst_pkt(boot_tid);
        end
        else if (rsp_state == R_LOW) begin
            cpx_rdy  = 1'b1;
            cpx_data = ifill_pkt(rsp_tid, ifill_data(rsp_line, rsp_tid, 1'b0));
        end
        else if (rsp_state == R_HIGH) begin
            cpx_rdy  = 1'b1;
            cpx_data = ifill_pkt(rsp_tid, ifill_data(rsp_line, rsp_tid, 1'b1));
        end
    end

    // ---------------------------------------------------------------
    // Request monitor
    // ---------------------------------------------------------------
    integer imiss_count;
    integer other_count;
    integer cycle_count;
    integer imiss_cnt [0:3];
    reg [3:0] thr_hit;
    reg [123:0] pcx_sig_d;

    wire [1:0]  pcx_tid  = spc_pcx_data_pa[`PCX_TH_HI:`PCX_TH_LO];
    wire [39:0] pcx_addr = spc_pcx_data_pa[103:64];
    wire [39:0] pcx_line = {pcx_addr[39:5], 5'b0};

    // A request is accepted on the cycle the TB grants it.  The grant is
    // registered from the request vector, so a back-to-back packet can
    // appear with vld still high; comparing the packet with the previous
    // cycle keeps the capture one-per-packet.
    wire pcx_vld  = reset_l & spc_pcx_data_pa[`PCX_VLD];
    wire pcx_fire = pcx_vld & (|grant_px) &
                    (spc_pcx_data_pa[123:0] != pcx_sig_d);

    // Lowest-numbered thread with a pending I-miss, starting the scan
    // after the thread served last (round robin).  A fixed priority
    // would starve the higher-numbered threads: threads that run ahead
    // always have a new miss pending.
    reg [1:0] rr_ptr;

    wire [3:0] pend_rot = (pend_vld >> rr_ptr) |
                          (pend_vld << (4'd4 - {2'd0, rr_ptr}));

    function [2:0] first_pending;
        input [3:0] v;
        begin
            if (v[0])      first_pending = 3'd0;
            else if (v[1]) first_pending = 3'd1;
            else if (v[2]) first_pending = 3'd2;
            else if (v[3]) first_pending = 3'd3;
            else           first_pending = 3'd7;
        end
    endfunction

    wire        pend_any   = |pend_vld;
    wire [2:0]  pend_off    = first_pending(pend_rot);
    wire [1:0]  pend_first = pend_off[1:0] + rr_ptr;

    // Per-thread target line: 0x80 + tid*0x40.
    wire [39:0] hit_line = LINE1_BASE + pcx_tid * LINE_STEP;

    reg [3:0] hit_now;
    always @* begin
        hit_now = 4'b0;
        if (pcx_fire && spc_pcx_data_pa[122:118] == RQ_IMISS &&
            pcx_line == hit_line)
            hit_now[pcx_tid] = 1'b1;
    end

    // ---- debug (compile with +define+TB_DEBUG) ----
`ifdef TB_DEBUG
    always @(posedge gclk) begin
        if (reset_l) begin
            if (rsp_state == R_LOW || rsp_state == R_HIGH)
                $display("DBG deliver %s tid=%0d line=%h cyc=%0d data=%h",
                         rsp_state == R_LOW ? "LOW " : "HIGH", rsp_tid,
                         rsp_line, cycle_count,
                         ifill_data(rsp_line, rsp_tid, rsp_state == R_HIGH));
            if (cycle_count >= 300 && cycle_count < 900 &&
                (cycle_count % 25) == 0)
                $display("DBG cyc=%0d pc=%h %h %h %h thr=%0d%0d%0d%0d mil=%b%b%b%b wrt=%b%b%b%b",
                         cycle_count,
                         dut.sparc0.ifu.fdp.t0pc_f[47:0],
                         dut.sparc0.ifu.fdp.t1pc_f[47:0],
                         dut.sparc0.ifu.fdp.t2pc_f[47:0],
                         dut.sparc0.ifu.fdp.t3pc_f[47:0],
                         dut.sparc0.ifu.swl.thr0_state,
                         dut.sparc0.ifu.swl.thr1_state,
                         dut.sparc0.ifu.swl.thr2_state,
                         dut.sparc0.ifu.swl.thr3_state,
                         dut.sparc0.ifu.ifqctl.mil0_state,
                         dut.sparc0.ifu.ifqctl.mil1_state,
                         dut.sparc0.ifu.ifqctl.mil2_state,
                         dut.sparc0.ifu.ifqctl.mil3_state,
                         dut.sparc0.ifu.ifqctl.wrt_tir[0],
                         dut.sparc0.ifu.ifqctl.wrt_tir[1],
                         dut.sparc0.ifu.ifqctl.wrt_tir[2],
                         dut.sparc0.ifu.ifqctl.wrt_tir[3]);
        end
    end
`endif

    initial begin
        imiss_count = 0;
        other_count = 0;
        cycle_count = 0;
        pcx_sig_d   = 124'b0;
        thr_hit     = 4'b0;
        pend_vld    = 4'b0;
        reset_l     = 1'b0;
        grant_px    = 5'b0;
        boot_pend  = 1'b0;
        boot_tid    = 2'b0;
        boot_next   = 0;
        rr_ptr      = 2'b0;
        rsp_state   = R_IDLE;
        rsp_delay   = 4'd0;
        rsp_line    = 40'b0;
        rsp_tid     = 2'b0;
        imiss_cnt[0] = 0; imiss_cnt[1] = 0;
        imiss_cnt[2] = 0; imiss_cnt[3] = 0;
        pend_line[0] = 40'b0; pend_line[1] = 40'b0;
        pend_line[2] = 40'b0; pend_line[3] = 40'b0;
        $display("TB: start (%0d threads)", NTHREADS);
        #(RESET_HOLD_PS) reset_l = 1'b1;
        $display("TB: reset released at %0t", $time);
    end

    always @(posedge gclk) begin
        pcx_sig_d <= spc_pcx_data_pa[123:0];

        if (!reset_l) begin
            boot_pend  <= 1'b0;
            boot_next  <= 0;
            boot_tid   <= 2'b0;
            rsp_state  <= R_IDLE;
            rsp_delay  <= 4'd0;
            rr_ptr     <= 2'b0;
            pend_vld   <= 4'b0;
            thr_hit    <= 4'b0;
            cycle_count <= 0;
            imiss_count <= 0;
            other_count <= 0;
        end
        else begin
            cycle_count <= cycle_count + 1;

            // ---- one reset packet per thread ------------------------
            // The packet is offered on the CPX port as soon as the
            // responder is idle; only then is the pending flag cleared,
            // so a packet can never be lost to a busy IFILL burst.
            if (boot_pend) begin
                if (rsp_state == R_IDLE)
                    boot_pend <= 1'b0;
            end
            else if (boot_next < NTHREADS && cycle_count >= BOOT_CYCLE &&
                     ((cycle_count - BOOT_CYCLE) % THREAD_GAP) == 0) begin
                boot_pend <= 1'b1;
                boot_tid  <= boot_next[1:0];
                boot_next <= boot_next + 1;
                $display("TB: queue CPX reset packet thread %0d at cyc=%0d",
                         boot_next, cycle_count);
            end

            // ---- request capture ------------------------------------
            if (pcx_fire) begin
                if (spc_pcx_data_pa[122:118] == RQ_IMISS) begin
                    imiss_count    <= imiss_count + 1;
                    imiss_cnt[pcx_tid] = imiss_cnt[pcx_tid] + 1;
                    if (!pend_vld[pcx_tid]) begin
                        pend_vld[pcx_tid]  <= 1'b1;
                        pend_line[pcx_tid] <= pcx_line;
                    end
                    $display("PCX IMISS #%0d t=%0t tid=%0d line=%h",
                             imiss_count + 1, $time, pcx_tid, pcx_line);
                end
                else begin
                    other_count <= other_count + 1;
                    $display("PCX PKT   t=%0t type=%b tid=%0d addr=%h",
                             $time, spc_pcx_data_pa[122:118], pcx_tid, pcx_addr);
                end
            end

            // ---- IFILL responder ------------------------------------
            case (rsp_state)
                R_IDLE: begin
                    if (pend_any && !boot_pend) begin
                        rsp_tid                   <= pend_first[1:0];
                        rsp_line                  <= pend_line[pend_first[1:0]];
                        pend_vld[pend_first[1:0]] <= 1'b0;
                        rsp_delay                 <= 4'd16;
                        rsp_state                 <= R_DLY;
                        rr_ptr                    <= pend_first + 2'd1;
                        $display("TB: serve line %h tid=%0d",
                                 pend_line[pend_first[1:0]], pend_first[1:0]);
                    end
                end
                R_DLY: begin
                    if (rsp_delay == 4'd0)
                        rsp_state <= R_LOW;
                    else
                        rsp_delay <= rsp_delay - 4'd1;
                end
                R_LOW:  rsp_state <= R_GAP0;
                R_GAP0: rsp_state <= R_HIGH;
                R_HIGH: rsp_state <= R_GAP1;
                R_GAP1: rsp_state <= R_IDLE;
            endcase

            // ---- verdict --------------------------------------------
            thr_hit <= thr_hit | hit_now;
            if ((thr_hit | hit_now) == THREAD_MASK) begin
                $display("SMOKE PASS: all %0d threads branched to their own line",
                         NTHREADS);
                $display("SMOKE INFO: imiss=%0d other=%0d (per thread %0d %0d %0d %0d)",
                         imiss_count + 1, other_count,
                         imiss_cnt[0], imiss_cnt[1], imiss_cnt[2], imiss_cnt[3]);
                $finish;
            end

            if ((cycle_count % 2000) == 0 && cycle_count != 0) begin
                $display("TB: cycle %0d, imiss=%0d other=%0d rclk=%0d hit=%b",
                         cycle_count, imiss_count, other_count,
                         dut.sparc0.rclk, thr_hit | hit_now);
            end

            if (cycle_count == TIMEOUT_CYCLES) begin
                $display("SMOKE FAIL: threads %b did not branch within %0d cycles",
                         THREAD_MASK & ~(thr_hit | hit_now), TIMEOUT_CYCLES);
                $display("SMOKE INFO: imiss=%0d other=%0d pc0=%h pc1=%h pc2=%h pc3=%h",
                         imiss_count, other_count,
                         dut.sparc0.ifu.fdp.t0pc_f[47:0],
                         dut.sparc0.ifu.fdp.t1pc_f[47:0],
                         dut.sparc0.ifu.fdp.t2pc_f[47:0],
                         dut.sparc0.ifu.fdp.t3pc_f[47:0]);
                $display("SMOKE INFO: thr=%0d,%0d,%0d,%0d rsp_state=%0d pend=%b",
                         dut.sparc0.ifu.swl.thr0_state,
                         dut.sparc0.ifu.swl.thr1_state,
                         dut.sparc0.ifu.swl.thr2_state,
                         dut.sparc0.ifu.swl.thr3_state,
                         rsp_state, pend_vld);
                $finish;
            end
        end
    end
endmodule
