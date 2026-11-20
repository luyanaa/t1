`timescale 1ps/1ps

// Generic OpenSPARC T1 diag testbench.
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
//   vvp tb_diag.vvp +memfile=port/build/diag/<name>.mem [+max_cycle=N]
//
// Boot mechanism is identical to tb_core_smoke.v: a CPX INT_RET reset
// interrupt is injected once; the served image's trap table at
// PA 0xfff0000000 (reset slot 0xfff0000040) provides the first instructions.
// The minimal boot harness (port/scripts/t1boot_min.s) lands there.
//
// PCX/CPX protocol (field defs: design/sys/iop/include/iop.h):
//   PCX IMISS_RQ (5'b10000) -> two CPX IFILL_RET (4'b0001) 16B halves
//   PCX LOAD_RQ  (5'b00000) -> CPX LOAD_RET (4'b0000), 64-bit word
//   PCX STORE_RQ (5'b00001) -> write mem, then CPX ST_ACK (4'b0100)
//   PCX STQ_RQ   (5'b00111) -> write mem, then CPX ST_ACK
//   other types  -> logged, no response
//
// PASS/FAIL: a STORE_RQ to PA thread_status_mem (0x10002000) carries a
// one-hot thread result word; upper 32 bits 0 => good_trap (pass),
// nonzero (0xF) => bad_trap (fail).

module tb_diag;
    localparam integer CLK_HALF       = 2500;   // 200 MHz
    localparam integer RESET_HOLD_PS  = 100000;
    localparam integer BOOT_CYCLE     = 300;
    localparam integer TIMEOUT_CYCLES = 200000;

    // thread_status_mem (t1boot.ld .tstatus @ PA 0x10020000)
    localparam [39:0] STATUS_MEM_PA = 40'h00_1002_0000;

    // PCX request types (iop.h)
    localparam [4:0] LOAD_RQ  = 5'b00000;
    localparam [4:0] STORE_RQ = 5'b00001;
    localparam [4:0] STQ_RQ   = 5'b00111;
    localparam [4:0] IMISS_RQ = 5'b10000;

    // CPX return types (iop.h)
    localparam [3:0] LOAD_RET  = 4'b0000;
    localparam [3:0] IFILL_RET = 4'b0001;
    localparam [3:0] ST_ACK    = 4'b0100;

    // PCX size encodings
    localparam [2:0] SZ_8B  = 3'b011;
    localparam [2:0] SZ_16B = 3'b111;

    reg gclk;
    reg reset_l;

    wire [4:0]   spc_pcx_req_pq;
    wire         spc_pcx_atom_pq;
    wire [123:0] spc_pcx_data_pa;
    wire [4:0]   pcx_spc_grant_px;
    wire         cpx_spc_data_rdy_cx2;
    wire [144:0] cpx_spc_data_cx2;

    reg [4:0] grant_px;

    // CPX INT_RET reset interrupt for CPU0/thread0 (same as tb_core_smoke)
    localparam [144:0] CPX_RST_PKT =
        (145'h1 << 144) | (145'h7 << 140) | (145'h1 << 16);

    reg boot_rdy;
    reg boot_sent;

    // ---------------------------------------------------------------
    // Backing memory: 64-bit words indexed by (pa>>3) & MASK.
    //
    // Physical addresses span 0xfff0000000 (RED boot page) down to
    // 0x10000000 (diag text/data).  A flat mem[] indexed by pa>>3 needs
    // 2^36 words — too large.  Instead we use a hash window: the boot
    // page and diag regions occupy disjoint low bits, so mask keeps the
    // interesting bits.  PA[27:3] distinguishes 0x10002000 (status) from
    // RED/data regions; RED PA[39:36]=0xf aliases onto high bits too, so
    // we use PA[31:3] (29 bits, 512M words is still too big).
    //
    // Practical compromise: two separate images.
    //   mem_low : PA[27:3]  for PA < 0x10000000 is impossible (RED is
    //             high), so split by PA[39] — see mem_lookup below.
    // ---------------------------------------------------------------
    localparam integer LOW_WORDS  = 1 << 25;   // PA[27:3]  -> up to 0x10000000
    localparam integer RED_WORDS  = 1 << 17;   // PA[19:3]  -> RED page 0xfff0..
    reg [63:0] mem_low [0:LOW_WORDS-1];
    reg [63:0] mem_red [0:RED_WORDS-1];

    reg [256*8-1:0] memfile;
    integer max_cycle;

    // mem[pa>>3] equivalent: RED page (PA[39:28]==0xff0) -> mem_red[PA[19:3]];
    // everything else -> mem_low[PA[27:3]].  Diag images only use these.
    function [63:0] mem_read;
        input [39:0] pa;
        begin
            if (pa[39:28] == 12'hfff)
                mem_read = mem_red[pa[19:3]];
            else
                mem_read = mem_low[pa[27:3]];
        end
    endfunction

    task mem_write;
        input [39:0] pa;
        input [63:0] val;
        begin
            if (pa[39:28] == 12'hfff)
                mem_red[pa[19:3]] = val;
            else
                mem_low[pa[27:3]] = val;
        end
    endtask

    // Image loader: parse the sparse $readmemh-style file ourselves.
    // Each non-comment token is either "@<hexidx>" (word index = pa/8) or a
    // 16-hex-digit 64-bit word.  iverilog's $fscanf("%s") right-aligns the
    // string in `line`, so we distinguish records by $sscanf success, not
    // by peeking at a fixed byte.  Each word is banked via mem_write.
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
                        waddr = idx;                    // "@<idx>" address record
                    end else if (line[7:0] == 8'h2f) begin
                        // token starting with '/' — comment text; skip.
                        // ($fscanf %s splits on whitespace, so a "// ..."
                        // comment arrives as several tokens, all ignored.)
                    end else if ($sscanf(line, "%h", wval) == 1) begin
                        // waddr is a word index; reconstruct byte PA
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

    // One-deep pending request latch: a PCX request that arrives while the
    // responder is busy is captured here and serviced when the FSM returns
    // to R_IDLE, so stores/loads are never silently dropped.
    reg        pend_vld;
    reg [4:0]  pend_rq;
    reg [1:0]  pend_tid;
    reg [1:0]  pend_pid;
    reg [2:0]  pend_sz;
    reg [39:0] pend_addr;
    reg [63:0] pend_data;

    reg          cpx_rdy;
    reg [144:0]  cpx_data;

    assign pcx_spc_grant_px     = grant_px;
    assign cpx_spc_data_rdy_cx2 = cpx_rdy;
    assign cpx_spc_data_cx2     = cpx_data;

    // ---------------------------------------------------------------
    // Memory helpers
    // ---------------------------------------------------------------
    // 128-bit IFILL half: two consecutive 64-bit BE words from the line.
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

    // Aligned 64-bit word containing pa (loads).
    function [63:0] ld_word;
        input [39:0] pa;
        begin
            ld_word = mem_read(pa);
        end
    endfunction

    // Store nbytes (from pcx_sz) of stdata into mem at pa, BE lanes.
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
            for (i = 0; i < nbytes && i < 8; i = i + 1)
                cur[63 - 8*(byteoff+i) -: 8] = stdata[8*i +: 8];
            mem_write(pa, cur);
            if (nbytes > 8) begin
                cur = mem_read(pa + 8);
                for (i = 0; i < nbytes-8; i = i + 1)
                    cur[63 - 8*i -: 8] = stdata[8*(8+i) +: 8];
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
            ifill_pkt          = 145'b0;
            ifill_pkt[144]     = 1'b1;
            ifill_pkt[143:140] = IFILL_RET;
            ifill_pkt[135:134] = tid;
            ifill_pkt[127:0]   = data;
        end
    endfunction

    function [144:0] load_pkt;
        input [1:0]  tid;
        input [63:0] data;
        begin
            load_pkt          = 145'b0;
            load_pkt[144]     = 1'b1;
            load_pkt[143:140] = LOAD_RET;
            load_pkt[135:134] = tid;
            load_pkt[63:0]    = data;
        end
    endfunction

    function [144:0] stack_pkt;
        input [1:0] tid;
        input [1:0] pktid;
        begin
            stack_pkt          = 145'b0;
            stack_pkt[144]     = 1'b1;
            stack_pkt[143:140] = ST_ACK;
            stack_pkt[135:134] = tid;
            stack_pkt[131:130] = pktid;   // STQ packet id
            stack_pkt[125]     = 1'b0;    // not squashed
            stack_pkt[124]     = 1'b0;    // no iinv
            stack_pkt[123]     = 1'b0;    // no dinv
            stack_pkt[120:118] = 3'b000;  // cpuid 0
        end
    endfunction

    // ---------------------------------------------------------------
    // Combined CPX driver
    // ---------------------------------------------------------------
    always @* begin
        cpx_rdy  = 1'b0;
        cpx_data = 145'b0;

        if (boot_rdy) begin
            cpx_rdy  = 1'b1;
            cpx_data = CPX_RST_PKT;
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
        end
        else if (rsp_state == R_SACK) begin
            cpx_rdy  = 1'b1;
            cpx_data = stack_pkt(rsp_tid, rsp_pktid);
        end
    end

    // ---------------------------------------------------------------
    // PCX monitor + scoreboard
    // ---------------------------------------------------------------
    integer imiss_count, load_count, store_count, other_count;
    integer cycle_count;
    reg     pcx_valid_d;
    reg     finished;

    wire pcx_new  = reset_l & spc_pcx_data_pa[123] & ~pcx_valid_d;
    wire [4:0]  pcx_rq   = spc_pcx_data_pa[122:118];
    wire [1:0]  pcx_tid  = spc_pcx_data_pa[113:112];
    wire [1:0]  pcx_pid  = spc_pcx_data_pa[108:107];
    wire [2:0]  pcx_sz   = spc_pcx_data_pa[106:104];
    wire [39:0] pcx_addr = spc_pcx_data_pa[103:64];
    wire [39:0] pcx_line = {pcx_addr[39:5], 5'b0};
    wire [63:0] pcx_data = spc_pcx_data_pa[63:0];

    // A store whose aligned-8 address equals STATUS_MEM_PA is the result write.
    wire status_hit = pcx_new && (pcx_rq == STORE_RQ || pcx_rq == STQ_RQ) &&
                      ((pcx_addr >> 3) == (STATUS_MEM_PA >> 3));

    always @(posedge gclk)
        pcx_valid_d <= reset_l & spc_pcx_data_pa[123];

    // The status scoreboard is checked independently of the responder FSM:
    // a status store may arrive while the FSM is mid-IFILL/LOAD, so it must
    // not be gated behind the R_IDLE branch.
    always @(posedge gclk) begin
        if (reset_l && !finished && status_hit) begin
            check_status(pcx_data);
            finished <= 1'b1;
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
        cycle_count = 0; pcx_valid_d = 1'b0; finished = 1'b0;
        reset_l = 1'b0; grant_px = 5'b0;
        boot_rdy = 1'b0; boot_sent = 1'b0;
        rsp_state = R_IDLE; rsp_delay = 8'd0;
        rsp_addr = 40'b0; rsp_tid = 2'b0; rsp_pktid = 2'b0;
        pend_vld = 1'b0; pend_rq = 5'b0; pend_tid = 2'b0; pend_pid = 2'b0;
        pend_sz = 3'b0; pend_addr = 40'b0; pend_data = 64'b0;
        $display("TB: start");
        #(RESET_HOLD_PS) reset_l = 1'b1;
        $display("TB: reset released at %0t", $time);
    end

    always @(posedge gclk) begin
        if (!reset_l) begin
            boot_rdy  <= 1'b0;
            boot_sent <= 1'b0;
            rsp_state <= R_IDLE;
            rsp_delay <= 8'd0;
            pend_vld  <= 1'b0;
        end else if (!finished) begin
            cycle_count <= cycle_count + 1;

            boot_rdy <= 1'b0;
            if (!boot_sent && cycle_count == BOOT_CYCLE) begin
                boot_rdy  <= 1'b1;
                boot_sent <= 1'b1;
                $display("TB: inject CPX INT_RET reset packet at cyc=%0d",
                         cycle_count);
            end

            // Latch any request that arrives while the FSM is busy.
            if (pcx_new && rsp_state != R_IDLE) begin
                pend_vld  <= 1'b1;
                pend_rq   <= pcx_rq;
                pend_tid  <= pcx_tid;
                pend_pid  <= pcx_pid;
                pend_sz   <= pcx_sz;
                pend_addr <= pcx_addr;
                pend_data <= pcx_data;
            end

            // responder FSM
            case (rsp_state)
                R_IDLE: begin
                    if (pend_vld) begin
                        // service the latched request first
                        pend_vld <= 1'b0;
                        if (pend_rq == IMISS_RQ) begin
                            rsp_addr  <= {pend_addr[39:5], 5'b0};
                            rsp_tid   <= pend_tid;
                            rsp_delay <= 8'd8;
                            rsp_state <= R_IDLY;
                        end else if (pend_rq == LOAD_RQ) begin
                            rsp_addr  <= pend_addr;
                            rsp_tid   <= pend_tid;
                            rsp_delay <= 8'd6;
                            rsp_state <= R_LDLY;
                        end else if (pend_rq == STORE_RQ || pend_rq == STQ_RQ) begin
                            st_write(pend_addr, pend_sz, pend_data);
                            rsp_addr  <= pend_addr;
                            rsp_tid   <= pend_tid;
                            rsp_pktid <= pend_pid;
                            rsp_delay <= 8'd6;
                            rsp_state <= R_SDLY;
                        end
                    end else if (pcx_new && pcx_rq == IMISS_RQ) begin
                        rsp_addr  <= pcx_line;
                        rsp_tid   <= pcx_tid;
                        rsp_delay <= 8'd8;
                        rsp_state <= R_IDLY;
                    end else if (pcx_new && pcx_rq == LOAD_RQ) begin
                        rsp_addr  <= pcx_addr;
                        rsp_tid   <= pcx_tid;
                        rsp_delay <= 8'd6;
                        rsp_state <= R_LDLY;
                    end else if (pcx_new &&
                                 (pcx_rq == STORE_RQ || pcx_rq == STQ_RQ)) begin
                        st_write(pcx_addr, pcx_sz, pcx_data);
                        rsp_addr  <= pcx_addr;
                        rsp_tid   <= pcx_tid;
                        rsp_pktid <= pcx_pid;
                        rsp_delay <= 8'd6;
                        rsp_state <= R_SDLY;
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
            endcase

            // request logging
            if (pcx_new) begin
                case (pcx_rq)
                    IMISS_RQ: begin
                        imiss_count <= imiss_count + 1;
                        $display("PCX IMISS #%0d t=%0t tid=%0d line=%h",
                                 imiss_count, $time, pcx_tid, pcx_line);
                    end
                    LOAD_RQ: begin
                        load_count <= load_count + 1;
                        $display("PCX LOAD  #%0d t=%0t tid=%0d sz=%0d addr=%h",
                                 load_count, $time, pcx_tid, pcx_sz, pcx_addr);
                    end
                    STORE_RQ, STQ_RQ: begin
                        store_count <= store_count + 1;
                        $display("PCX STORE #%0d t=%0t tid=%0d sz=%0d addr=%h data=%h",
                                 store_count, $time, pcx_tid, pcx_sz,
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
                $display("TB: cycle %0d, imiss=%0d load=%0d store=%0d other=%0d",
                         cycle_count, imiss_count, load_count,
                         store_count, other_count);

            if (cycle_count == max_cycle) begin
                $display("DIAG TIMEOUT: no PASS/FAIL within %0d cycles",
                         max_cycle);
                $display("DIAG INFO: imiss=%0d load=%0d store=%0d other=%0d",
                         imiss_count, load_count, store_count, other_count);
                $display("DIAG INFO: pc0=%h pc1=%h",
                         dut.sparc0.ifu.fdp.t0pc_f[47:0],
                         dut.sparc0.ifu.fdp.t1pc_f[47:0]);
                $finish;
            end
        end
    end

endmodule
