// Minimal smoke test for the SJM VPI port.
//   iverilog -o tb.vvp -v tb.v ; vvp -M. -msjm tb.vvp
module tb;

  reg [1:0]  dummy_status;
  reg        dummy_in;
  wire [7:0] dummy_out;

  initial begin
    $display("tb: calling $sjm_init ...");
    $sjm_init(0);
    $display("tb: calling $sjm_get_status(0, dummy_status) ...");
    $sjm_get_status(0, dummy_status);
    $display("tb: dummy_status = %b", dummy_status);
    $display("tb: done.");
    $finish;
  end

endmodule
