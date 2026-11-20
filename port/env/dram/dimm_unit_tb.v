// dimm_unit_tb.v - unit check for the functional DIMM model (dimm_mem.v).
//
// Drives a real DDR command sequence at the dimm port level:
//   SETUP (mode regs) -> RAS (open row) -> WRITE burst -> READ burst
// and verifies
//   1. the local array holds the written word (hierarchical read of
//      u_dimm.mem[faddr], allowed for the unit check), and
//   2. the data comes back through the DDR read path on dataq.
//
//   iverilog -g2005 -s dimm_unit_tb port/env/dram/dimm_mem.v \
//            port/env/dram/dimm_unit_tb.v -o /tmp/dimm_unit.vvp
//   vvp /tmp/dimm_unit.vvp   -> "DIMM UNIT PASS"
//
// faddr layout (dimm_mem.v header): faddr = {row[16:0], col[10:2], ba,
// col[1:0]}; with row=1, col=0, ba=0 the 4 burst beats land at
// faddr = 16'h4000 + n (n = 0..3).  MEM_AW=20, so index = faddr.

`timescale 1ps/1ps

module dimm_unit_tb;

  reg [2:0]  clk;
  reg [1:0]  cs;
  reg        ras, cas, we;
  reg [2:0]  ba;
  reg [16:0] addr;
  reg [7:0]  cs_sel = 8'h00;

  wire [63:0] dataq;
  wire [7:0]  ecc;
  wire [8:0]  dqs, dm_rdqs;

  reg [63:0]  wdata;
  reg [7:0]   wecc;
  reg         dqs_drv;
  reg         dqs_t;

  assign dataq = dqs_drv ? wdata : 64'bz;
  assign ecc   = dqs_drv ? wecc  : 8'bz;
  assign dqs   = dqs_drv ? {9{dqs_t}} : 9'bz;  // DDR: toggle during the burst

  always #500 dqs_t = ~dqs_t;

  dimm u_dimm(
    .clk     (clk),
    .cs      (cs),
    .ras     (ras),
    .cas     (cas),
    .we      (we),
    .ba      (ba),
    .addr    (addr),
    .cs_sel  (cs_sel),
    .dataq   (dataq),
    .ecc     (ecc),
    .dqs     (dqs),
    .dm_rdqs (dm_rdqs)
  );

  // 1 GHz clock
  initial clk = 3'b000;
  always #500 clk[0] = ~clk[0];

  integer n;
  reg [71:0] got;
  reg [63:0] rdata;
  reg        read_ok;
  integer    errors = 0;

  task do_setup;
    begin
      // mode reg bank0: BurstLen=4 (1<<addr[2:0], addr[2:0]=2),
      // CasLat=3 (addr[6:4]=3)
      cs = 2'b00; ras = 1'b0; cas = 1'b0; we = 1'b0;
      ba = 3'd0;  addr = 17'h32;      // 000_11_010
      @(posedge clk[0]);
      @(posedge clk[0]);
      // mode reg bank1: AlignLat=2 (addr[5:3]=2)
      ba = 3'd1;  addr = 17'h10;
      @(posedge clk[0]);
      @(posedge clk[0]);
    end
  endtask

  task do_ras(input [16:0] row);
    begin
      cs = 2'b00; ras = 1'b0; cas = 1'b1; we = 1'b1;
      ba = 3'd0;  addr = row;
      @(posedge clk[0]);
      @(posedge clk[0]);
    end
  endtask

  task idle_cmd;
    begin
      cs = 2'b11; ras = 1'b1; cas = 1'b1; we = 1'b1;
    end
  endtask

  initial begin
    dqs_t = 1'b1;
    idle_cmd;
    #100;
    do_setup;
    do_ras(17'h1);            // open row 1, bank 0

    //--------------------------------------------------------------
    // WRITE burst: col=0, data V.  Beats land at faddr = 0x4000+n.
    // Command is asserted for ONE clk cycle (as the DDR controller
    // does); the model then plays the burst from its queues.
    //--------------------------------------------------------------
    wdata = 64'hA5A5_5A5A_DEAD_BEEF;
    wecc  = 8'hC3;
    dqs_drv = 1'b1;           // drive data + dqs during the write burst
    cs = 2'b00; ras = 1'b1; cas = 1'b0; we = 1'b0;   // WRITE
    ba = 3'd0;  addr = 17'h0;  // col 0
    @(posedge clk[0]);
    idle_cmd;                  // one-cycle command
    // keep driving data+dqs until every queue beat has been consumed
    // (WriteLat=4 -> beats pop within ~6 clk of the command)
    repeat (12) @(posedge clk[0]);
    dqs_drv = 1'b0;
    #1000;

    // 1. array content check (faddr = {17'h1,9'h0,3'h0,2'n} = 0x4000+n)
    for (n = 0; n < 4; n = n + 1) begin
      got = u_dimm.mem[16'h4000 + n];
      if (got !== {wecc, wdata}) begin
        $display("DIMM UNIT FAIL: mem[0x4000+%0d]=%h expected %h", n, got, {wecc, wdata});
        errors = errors + 1;
      end
    end

    //--------------------------------------------------------------
    // READ burst from the same address; data must come back on dataq.
    //--------------------------------------------------------------
    cs = 2'b00; ras = 1'b1; cas = 1'b0; we = 1'b1;   // READ
    ba = 3'd0;  addr = 17'h0;
    @(posedge clk[0]);
    idle_cmd;                  // one-cycle command

    read_ok = 0;
    rdata = 64'bx;
    // wait for the model to drive dataq (dataq_oe == 1)
    begin : poll_loop
      repeat (200) begin
        #500;
        if (u_dimm.dataq_oe === 1'b1) begin
          rdata  = dataq;
          read_ok = (dataq === wdata);
          $display("DIMM UNIT: read dataq=%h ecc=%h", dataq, ecc);
          disable poll_loop;
        end
      end
    end

    if (!read_ok) begin
      $display("DIMM UNIT FAIL: no data returned on dataq (dataq=%h, dataq_oe=%b)",
               dataq, u_dimm.dataq_oe);
      errors = errors + 1;
    end else if (rdata !== wdata) begin
      $display("DIMM UNIT FAIL: read data mismatch %h != %h", rdata, wdata);
      errors = errors + 1;
    end

    if (errors == 0)
      $display("DIMM UNIT PASS: array write + DDR-path read-back verified");
    else
      $display("DIMM UNIT FAIL: %0d errors", errors);
    $finish;
  end

  // watchdog
  initial begin
    #200000;
    $display("DIMM UNIT FAIL: watchdog timeout");
    $finish;
  end

endmodule
