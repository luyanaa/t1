// OpenSPARC T1 single-core FPGA wrapper.
//
// Brings up one SPARC core on a board with only a clock, a reset button
// and LEDs.  The core is attached to a tiny CPX/PCX responder that starts
// the reset trap and serves instruction lines from a hard-coded image.
//
// Boot sequence:
//   - an INT_RET CPX packet selects the reset trap (VA 0xffff_f000_0040)
//   - IFILL_RET packets return a 32-byte line; the first instruction is
//     "ba 0xffff_f000_0080"
//   - the second I-miss at line 0xffff_f000_0080 proves that the trap,
//     the I-cache fill and instruction execution all work
//
// PCX request fields: valid[123], type[122:118], tid[113:112],
// address[103:64].  CPX packet fields: valid[144], type[143:140],
// tid[135:134], data[127:0].

module t1_fpga_top (
    input  wire        clk,
    input  wire        reset_l,
    output wire [5:0]  led
);

    localparam [39:0] LINE0_BASE = 40'hfff0000040;
    localparam [39:0] LINE1_BASE = 40'hfff0000080;

    localparam [31:0] INST_BA_80 = 32'h1080_0010;
    localparam [31:0] INST_NOP   = 32'h0100_0000;

    localparam [4:0] IMISS_RQ  = 5'b10000;
    localparam [3:0] IFILL_RET = 4'b0001;

    localparam [144:0] CPX_RST_PKT =
        (145'h1 << 144) |
        (145'h7 << 140) |
        (145'h1 << 16);

    localparam integer BOOT_CYCLE    = 300;
    localparam integer TIMEOUT_CYCLES = 5000;

    // ---------------------------------------------------------------
    // Power-on reset: hold the core in reset for 256 clocks.
    // ---------------------------------------------------------------
    reg [7:0] por_cnt;
    always @(posedge clk) begin
        if (!reset_l)
            por_cnt <= 8'd0;
        else if (por_cnt != 8'hff)
            por_cnt <= por_cnt + 8'd1;
    end

    wire core_reset_l = reset_l & (por_cnt == 8'hff);

    // ---------------------------------------------------------------
    // Core PCX/CPX nets
    // ---------------------------------------------------------------
    wire [4:0]   spc_pcx_req_pq;
    wire         spc_pcx_atom_pq;
    wire [123:0] spc_pcx_data_pa;
    wire [4:0]   pcx_spc_grant_px;
    wire         cpx_spc_data_rdy_cx2;
    wire [144:0] cpx_spc_data_cx2;

    reg [4:0] grant_px;
    always @(posedge clk) begin
        if (!core_reset_l)
            grant_px <= 5'b0;
        else
            grant_px <= spc_pcx_req_pq;
    end

    iop_fpga core (
        .reset_l              (core_reset_l),
        .gclk                 (clk),
        .spc_pcx_req_pq       (spc_pcx_req_pq),
        .spc_pcx_atom_pq      (spc_pcx_atom_pq),
        .spc_pcx_data_pa      (spc_pcx_data_pa),
        .pcx_spc_grant_px     (pcx_spc_grant_px),
        .cpx_spc_data_rdy_cx2 (cpx_spc_data_rdy_cx2),
        .cpx_spc_data_cx2     (cpx_spc_data_cx2)
    );

    assign pcx_spc_grant_px = grant_px;

    // ---------------------------------------------------------------
    // Instruction image: four big-endian instructions per 16-byte half
    // ---------------------------------------------------------------
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
            ifill_pkt[144]     = 1'b1;
            ifill_pkt[143:140] = IFILL_RET;
            ifill_pkt[135:134] = tid;
            ifill_pkt[127:0]   = data;
        end
    endfunction

    // ---------------------------------------------------------------
    // Boot packet and IFILL responder
    // ---------------------------------------------------------------
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

    reg [15:0] cycle_count;
    reg        boot_rdy;
    reg        boot_sent;

    reg        pcx_valid_d;
    wire       pcx_new = core_reset_l & spc_pcx_data_pa[123] & ~pcx_valid_d;
    wire [39:0] pcx_addr = spc_pcx_data_pa[103:64];
    wire [39:0] pcx_line = {pcx_addr[39:5], 5'b0};

    reg          cpx_rdy;
    reg [144:0]  cpx_data;

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

    assign cpx_spc_data_rdy_cx2 = cpx_rdy;
    assign cpx_spc_data_cx2     = cpx_data;

    // ---------------------------------------------------------------
    // Status
    // ---------------------------------------------------------------
    reg imiss_seen;
    reg pass;
    reg timeout;

    always @(posedge clk) begin
        if (!core_reset_l) begin
            cycle_count  <= 16'd0;
            boot_rdy     <= 1'b0;
            boot_sent    <= 1'b0;
            rsp_state    <= R_IDLE;
            rsp_delay    <= 4'd0;
            rsp_line     <= 40'b0;
            rsp_tid      <= 2'b0;
            pcx_valid_d  <= 1'b0;
            imiss_seen   <= 1'b0;
            pass         <= 1'b0;
            timeout      <= 1'b0;
        end
        else begin
            cycle_count <= cycle_count + 16'd1;
            pcx_valid_d <= spc_pcx_data_pa[123];

            boot_rdy <= 1'b0;
            if (!boot_sent && cycle_count == BOOT_CYCLE) begin
                boot_rdy  <= 1'b1;
                boot_sent <= 1'b1;
            end

            case (rsp_state)
                R_IDLE: begin
                    if (pcx_new && spc_pcx_data_pa[122:118] == IMISS_RQ) begin
                        rsp_line  <= pcx_line;
                        rsp_tid   <= spc_pcx_data_pa[113:112];
                        rsp_delay <= 4'd8;
                        rsp_state <= R_DLY;
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
                default: rsp_state <= R_IDLE;
            endcase

            if (pcx_new) begin
                if (spc_pcx_data_pa[122:118] == IMISS_RQ) begin
                    imiss_seen <= 1'b1;
                    if (pcx_line == LINE1_BASE)
                        pass <= 1'b1;
                end
            end

            if (boot_sent && !pass && !timeout &&
                cycle_count == BOOT_CYCLE + TIMEOUT_CYCLES)
                timeout <= 1'b1;
        end
    end

    // ---------------------------------------------------------------
    // LEDs are active-low on the Tang Mega 138K Pro Dock.
    // ---------------------------------------------------------------
    reg [25:0] heartbeat;
    always @(posedge clk) begin
        if (!reset_l)
            heartbeat <= 26'd0;
        else
            heartbeat <= heartbeat + 26'd1;
    end

    assign led[0] = ~heartbeat[25];  // ~0.7 s heartbeat
    assign led[1] = ~boot_sent;
    assign led[2] = ~imiss_seen;
    assign led[3] = ~pass;
    assign led[4] = ~timeout;
    assign led[5] = ~heartbeat[22];  // ~12 Hz clock activity

endmodule