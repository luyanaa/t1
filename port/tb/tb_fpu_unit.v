// =====================================================================
// Unit test for the shared FPU block (design/sys/iop/fpu/rtl/fpu.v).
//
// This drives the real block over its PCX/CPX ports with the packets the
// core's FFU/LSU would produce, so it checks the FPU arithmetic itself,
// independent of the core pipeline:
//
//   sparc_ffu_ctl.v, "Create packet for LSU: ffu_lsu_data[80:0]"
//     [80]    vld
//     [79:78] type: 00 = fpop operand 1 (PCX 5'h0a), 01 = operand 2 (5'h0b)
//     [77:76] tid
//     [75:68] opf[7:0]
//     [67:66] fcc, [65:64] rounding mode, [63:0] data
//   lsu_qdp1.v, "Format fpop_full_pcxpkt"
//     PCX_RQ = {4'b0101, ffu_lsu_data[78]}, PCX_TH = tid,
//     [79:72] = opf, [67:64] = fcc/rnd, [63:0] = data
//   fpu_out_dp.v
//     CPX [144] vld, [143:140] = 4'b1000 (FP_RET), [135:134] tid,
//     [76:72] exc, [63:0] data
//
// Packets go out one per cycle: operand 1 first, then operand 2 (fpu_in
// expects that order; the not0in property in fpu_in.v checks it).
// =====================================================================

`timescale 1ps/1ps

module tb_fpu_unit;

    localparam [123:0] ZERO_PKT = 124'b0;

    reg gclk = 1'b0;
    reg reset_l = 1'b0;

    reg  [123:0] pcx_data = ZERO_PKT;
    reg          pcx_rdy  = 1'b0;

    wire [7:0]   fp_cpx_req_cq;
    wire [144:0] fp_cpx_data_ca;

    integer errors = 0;
    integer nets   = 0;

    fpu fpu0 (
        .pcx_fpio_data_rdy_px2 (pcx_rdy),
        .pcx_fpio_data_px2     (pcx_data),
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

    always #1000 gclk = ~gclk;

    // short trace window for bring-up (kept behind a plusarg)
    reg trace = 1'b0;
    initial begin
        if ($test$plusargs("trace")) trace = 1'b1;
    end
    always @(posedge gclk) if (trace) begin
        $display("TRACE cyc=%0t in=%b type=%b inq_we=%b dest=%b add_dest=%b req=%h ca144=%b add_in=%b",
                 $time, pcx_data[123], pcx_data[122:118],
                 fpu0.fpu_in.fpu_in_ctl.inq_we,
                 fpu0.fpu_out.dest_rdy, fpu0.fpu_out.add_dest_rdy,
                 fpu0.fpu_out.fp_cpx_req_cq, fpu0.fpu_out.fp_cpx_data_ca[144],
                 fpu0.fpu_in.fpu_in_ctl.fp_add_in);
    end

    // -----------------------------------------------------------------
    // Packet helpers
    // -----------------------------------------------------------------
    function [123:0] fpop_pkt;
        input       b_packet;   // 0 = operand 1 (5'h0a), 1 = operand 2 (5'h0b)
        input [1:0] tid;
        input [7:0] op;
        input [63:0] data;
        begin
            fpop_pkt          = ZERO_PKT;
            fpop_pkt[123]     = 1'b1;
            fpop_pkt[122:118] = b_packet ? 5'h0b : 5'h0a;
            fpop_pkt[113:112] = tid;
            fpop_pkt[79:72]   = op;
            fpop_pkt[63:0]    = data;
        end
    endfunction

    // -----------------------------------------------------------------
    // Drive one fpop: operand 1 on one cycle, operand 2 on the next.
    // -----------------------------------------------------------------
    task send_fpop;
        input [7:0]  op;
        input [1:0]  tid;
        input [63:0] rs1;
        input [63:0] rs2;
        begin
            @(posedge gclk);
            // Hardware order (sparc_ffu_ctl.v): rs2 goes first (fpop1,
            // PCX 5'h0a), rs1 second (fpop2, PCX 5'h0b) -- the FPU takes
            // the second packet as src1, which is why fsub/fdiv need it.
            pcx_data <= fpop_pkt(1'b0, tid, op, rs2);
            pcx_rdy  <= 1'b1;
            @(posedge gclk);
            pcx_data <= fpop_pkt(1'b1, tid, op, rs1);
            pcx_rdy  <= 1'b1;
            @(posedge gclk);
            pcx_data <= ZERO_PKT;
            pcx_rdy  <= 1'b0;
        end
    endtask

    // -----------------------------------------------------------------
    // Wait for a CPX return and check the payload.
    // -----------------------------------------------------------------
    task expect_ret;
        input [7:0]  what;
        input [63:0] exp;
        input [1:0]  exp_tid;
        integer      waited;
        reg   [144:0] pkt;
        begin
            waited = 0;
            pkt    = 145'b0;
            // fp_cpx_req_cq is a registered pulse, so sample it every
            // cycle until it fires.
            // fp_cpx_req_cq is the (one cycle wide) request into the CPX
            // buffer stage; the CPX packet itself is driven on the
            // following cycle (fpu_out_dp flops it one stage later).
            while ((fp_cpx_req_cq == 8'b0) && (waited < 400)) begin
                @(posedge gclk);
                waited = waited + 1;
            end
            if (fp_cpx_req_cq == 8'b0) begin
                $display("FPU-UNIT FAIL: op %h timed out after %0d cycles",
                         what, waited);
                errors = errors + 1;
            end
            else begin
                @(posedge gclk);        // CA stage: packet is valid now
                pkt = fp_cpx_data_ca;
                if (!pkt[144]) begin
                    $display("FPU-UNIT FAIL: op %h return without CPX vld: %h",
                             what, pkt);
                    errors = errors + 1;
                end
                else if (pkt[143:140] != 4'b1000) begin
                    $display("FPU-UNIT FAIL: op %h return type %b (want FP_RET)",
                             what, pkt[143:140]);
                    errors = errors + 1;
                end
                else if (pkt[135:134] != exp_tid) begin
                    $display("FPU-UNIT FAIL: op %h return tid %0d (want %0d)",
                             what, pkt[135:134], exp_tid);
                    errors = errors + 1;
                end
                else if (pkt[63:0] !== exp) begin
                    $display("FPU-UNIT FAIL: op %h got %h want %h",
                             what, pkt[63:0], exp);
                    errors = errors + 1;
                end
                else begin
                    $display("FPU-UNIT op %h -> %h  (cyc +%0d)", what, pkt[63:0], waited);
                    nets = nets + 1;
                end
            end
            // drain the pulse
            @(posedge gclk);
            @(posedge gclk);
        end
    endtask

    // -----------------------------------------------------------------
    // Test sequence
    // -----------------------------------------------------------------
    initial begin
        repeat (10) @(posedge gclk);
        reset_l <= 1'b1;
        repeat (5) @(posedge gclk);

        // 3.0 + 2.0 = 5.0
        send_fpop(8'h42, 2'd0, 64'h4008000000000000, 64'h4000000000000000);
        expect_ret(8'h42, 64'h4014000000000000, 2'd0);

        // 3.0 - 2.0 = 1.0
        send_fpop(8'h46, 2'd1, 64'h4008000000000000, 64'h4000000000000000);
        expect_ret(8'h46, 64'h3FF0000000000000, 2'd1);

        // 1.5 * 2.5 = 3.75
        send_fpop(8'h4a, 2'd2, 64'h3FF8000000000000, 64'h4004000000000000);
        expect_ret(8'h4a, 64'h400E000000000000, 2'd2);

        // 3.0 / 2.0 = 1.5
        send_fpop(8'h4e, 2'd3, 64'h4008000000000000, 64'h4000000000000000);
        expect_ret(8'h4e, 64'h3FF8000000000000, 2'd3);

        // 1.0 + 2^-52 (ulp-exact, catches a lost low mantissa bit)
        send_fpop(8'h42, 2'd0, 64'h3FF0000000000000, 64'h3CB0000000000000);
        expect_ret(8'h42, 64'h3FF0000000000001, 2'd0);

        if (errors == 0)
            $display("FPU-UNIT PASS: %0d operations", nets);
        else
            $display("FPU-UNIT FAIL: %0d errors", errors);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("FPU-UNIT FAIL: global timeout, %0d errors", errors);
        $finish;
    end

endmodule
