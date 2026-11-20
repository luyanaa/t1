// Deeper smoke test: instantiates a real SJM master from a command file and
// exercises get_status + set_inputs/get_outputs.
module tb2;

  reg [1:0]  status;
  reg        j_req_in, j_rst, j_por, j_change;
  reg [41:0] j_ad;
  reg [1:0]  j_adp;
  reg [2:0]  j_adtype;
  reg [7:0]  j_pack [0:6];
  wire [59:0] j_req_out;
  wire [41:0] j_ad_o;
  wire [1:0]  j_adp_o;
  wire [2:0]  j_adtype_o;
  wire [7:0]  j_pack_o [0:6];
  wire        j_change_o, j_rst_o, j_por_o;

  // Instance-driven tasks with the shape used by the real env (1-based ports).
  initial begin
    $display("tb2: init ...");
    $sjm_init(0);
    $display("tb2: por/rst/pwr ...");
    $sjm_assert_pwr(4);
    $sjm_assert_por(4);
    $sjm_deassert_por(4);
    $sjm_get_status(4, status);
    $display("tb2: status after por = %b (00=inactive, 01=reset)", status);
    // Feed idle bus inputs.
    $sjm_set_inputs(4, j_req_in, j_ad, j_adp, j_adtype,
                    j_pack[0], j_pack[1], j_pack[2], j_pack[3],
                    j_pack[4], j_pack[5], j_pack[6],
                    j_change, j_rst, j_por);
    $sjm_get_outputs(4, j_req_out, j_ad_o, j_adp_o, j_adtype_o,
                     j_pack_o[0], j_pack_o[1], j_pack_o[2], j_pack_o[3],
                     j_pack_o[4], j_pack_o[5], j_pack_o[6],
                     j_change_o, j_rst_o, j_por_o);
    $display("tb2: req_out=%b rst_out=%b", j_req_out[7:0], j_rst_o);
    $display("tb2: done.");
    $finish;
  end

endmodule
