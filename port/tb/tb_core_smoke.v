`timescale 1ps/1ps

// Core-level smoke test for the OpenSPARC T1 port.
//
// The core does not self-start after reset.  A CPX INT_RET carrying a
// reset interrupt is injected to make the TLU trap to the reset vector.
// A tiny instruction image is then served over CPX:
//
//   0xfffff0000040: ba 0xfffff0000080   (0x10800010)
//   0xfffff0000044: nop                 (0x01000000)
//   0xfffff0000080: nop ...
//
// Seeing the second I-miss at physical 0xfff0000080 proves that the
// reset trap, the I-cache line fill, instruction execution and branch
// redirection all work in simulation.

module tb_core_smoke;
    localparam integer CLK_HALF = 2500;
    localparam integer RESET_HOLD_PS = 100000;
    localparam integer TIMEOUT_CYCLES = 5000;
    localparam integer BOOT_CYCLE = 300;

    localparam [39:0] LINE0_BASE = 40'hfff0000040;
    localparam [39:0] LINE1_BASE = 40'hfff0000080;

    localparam [31:0] INST_BA_80 = 32'h1080_0010;  // ba 0xfffff0000080
    localparam [31:0] INST_NOP   = 32'h0100_0000;  // sethi %hi(0), %g0

    localparam [4:0]  IMISS_RQ   = 5'b10000;
    localparam [3:0]  IFILL_RET  = 4'b0001;

    reg gclk;
    reg reset_l;

    wire [4:0]   spc_pcx_req_pq;
    wire         spc_pcx_atom_pq;
    wire [123:0] spc_pcx_data_pa;
    wire [4:0]   pcx_spc_grant_px;
    wire         cpx_spc_data_rdy_cx2;
    wire [144:0] cpx_spc_data_cx2;

    reg [4:0] grant_px;

    // CPX INT_RET carrying a reset interrupt for CPU 0 / thread 0.
    localparam [144:0] CPX_RST_PKT =
        (145'h1 << 144) |   // valid
        (145'h7 << 140) |   // INT_RET
        (145'h1 << 16);     // interrupt type 01 = reset

    reg         boot_rdy;
    reg         boot_sent;

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

    reg          cpx_rdy;
    reg [144:0]  cpx_data;

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
    // in big-endian order: bits [127:96] are the lowest address.
    function [127:0] ifill_data;
        input [39:0] line;
        input        upper;
        begin
            if (!upper && line == LINE0_BASE)
                ifill_data = {INST_BA_80, INST_NOP, INST_NOP, INST_NOP};
            else
                ifill_data = {INST_NOP, INST_NOP, INST_NOP, INST_NOP};
        end
    endfunction

    function [144:0] ifill_pkt;
        input [1:0]   tid;
        input [127:0] data;
        begin
            ifill_pkt          = 145'b0;
            ifill_pkt[144]     = 1'b1;          // valid
            ifill_pkt[143:140] = IFILL_RET;
            ifill_pkt[135:134] = tid;
            ifill_pkt[127:0]   = data;
        end
    endfunction

    // ---------------------------------------------------------------
    // Combined CPX driver: boot interrupt and IFILL returns
    // ---------------------------------------------------------------
    always @* begin
        cpx_rdy  = 1'b0;
        cpx_data = 145'b0;

        if (boot_rdy) begin
            cpx_rdy  = 1'b1;
            cpx_data = CPX_RST_PKT;
        end
        else if (rsp_state == R_LOW) begin
            cpx_rdy  = 1'b1;
            cpx_data = ifill_pkt(rsp_tid, ifill_data(rsp_line, 1'b0));
        end
        else if (rsp_state == R_HIGH) begin
            cpx_rdy  = 1'b1;
            cpx_data = ifill_pkt(rsp_tid, ifill_data(rsp_line, 1'b1));
        end
    end

    // ---------------------------------------------------------------
    // Request monitor
    // ---------------------------------------------------------------
    integer imiss_count;
    integer other_count;
    integer cycle_count;
    reg     pcx_valid_d;

    wire pcx_new = reset_l & spc_pcx_data_pa[123] & ~pcx_valid_d;
    wire [39:0] pcx_addr = spc_pcx_data_pa[103:64];
    wire [39:0] pcx_line = {pcx_addr[39:5], 5'b0};

    always @(posedge gclk) begin
        pcx_valid_d <= reset_l & spc_pcx_data_pa[123];
    end

    initial begin
        imiss_count = 0;
        other_count = 0;
        cycle_count = 0;
        pcx_valid_d = 1'b0;
        reset_l     = 1'b0;
        grant_px    = 5'b0;
        boot_rdy    = 1'b0;
        boot_sent   = 1'b0;
        rsp_state   = R_IDLE;
        rsp_delay   = 4'd0;
        rsp_line    = 40'b0;
        rsp_tid     = 2'b0;
        $display("TB: start");
        #(RESET_HOLD_PS) reset_l = 1'b1;
        $display("TB: reset released at %0t", $time);
    end

    always @(posedge gclk) begin
        if (!reset_l) begin
            boot_rdy  <= 1'b0;
            boot_sent <= 1'b0;
            rsp_state <= R_IDLE;
            rsp_delay <= 4'd0;
        end
        else begin
            cycle_count <= cycle_count + 1;

            boot_rdy <= 1'b0;
            if (!boot_sent && cycle_count == BOOT_CYCLE) begin
                boot_rdy  <= 1'b1;
                boot_sent <= 1'b1;
                $display("TB: inject CPX INT_RET reset packet at cyc=%0d",
                         cycle_count);
            end

            case (rsp_state)
                R_IDLE: begin
                    if (pcx_new && spc_pcx_data_pa[122:118] == IMISS_RQ) begin
                        rsp_line  <= pcx_line;
                        rsp_tid   <= spc_pcx_data_pa[113:112];
                        rsp_delay <= 4'd8;
                        rsp_state <= R_DLY;
                        $display("TB: serve line %h tid=%0d",
                                 pcx_line, spc_pcx_data_pa[113:112]);
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

            if (pcx_new) begin
                case (spc_pcx_data_pa[122:118])
                    IMISS_RQ: begin
                        imiss_count <= imiss_count + 1;
                        $display("PCX IMISS #%0d t=%0t tid=%0d line=%h",
                                 imiss_count, $time,
                                 spc_pcx_data_pa[113:112], pcx_line);
                        if (pcx_line == LINE1_BASE) begin
                            $display("SMOKE PASS: branch to %h executed, second fetch issued",
                                     LINE1_BASE);
                            $finish;
                        end
                    end
                    default: begin
                        other_count <= other_count + 1;
                        $display("PCX PKT   t=%0t type=%b tid=%0d addr=%h",
                                 $time, spc_pcx_data_pa[122:118],
                                 spc_pcx_data_pa[113:112],
                                 spc_pcx_data_pa[103:64]);
                    end
                endcase
            end

            if ((cycle_count % 1000) == 0 && cycle_count != 0) begin
                $display("TB: cycle %0d, imiss=%0d other=%0d rclk=%0d",
                         cycle_count, imiss_count, other_count,
                         dut.sparc0.rclk);
            end

            if (cycle_count == TIMEOUT_CYCLES) begin
                $display("SMOKE FAIL: no branch fetch within %0d cycles",
                         TIMEOUT_CYCLES);
                $display("SMOKE INFO: imiss=%0d other=%0d pc0=%h pc1=%h pc2=%h pc3=%h",
                         imiss_count, other_count,
                         dut.sparc0.ifu.fdp.t0pc_f[47:0],
                         dut.sparc0.ifu.fdp.t1pc_f[47:0],
                         dut.sparc0.ifu.fdp.t2pc_f[47:0],
                         dut.sparc0.ifu.fdp.t3pc_f[47:0]);
                $display("SMOKE INFO: thr=%0d,%0d,%0d,%0d rsp_state=%0d",
                         dut.sparc0.ifu.swl.thr0_state,
                         dut.sparc0.ifu.swl.thr1_state,
                         dut.sparc0.ifu.swl.thr2_state,
                         dut.sparc0.ifu.swl.thr3_state,
                         rsp_state);
                $finish;
            end
        end
    end
endmodule