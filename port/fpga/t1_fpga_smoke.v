// Tiny nextpnr/Gowin toolchain smoke test.
//
// Runs a free counter through the T1 64-bit adder and shows the result on
// the board LEDs.  This design exists only to validate synthesis, place and
// route, and bitstream generation quickly; it is not the T1 core.

module t1_fpga_smoke (
    input  wire       clk,
    input  wire       reset_l,
    output wire [5:0] led
);

    reg [63:0] cnt;
    always @(posedge clk) begin
        if (!reset_l)
            cnt <= 64'd0;
        else
            cnt <= cnt + 64'd1;
    end

    wire [63:0] sum;
    wire        cout32;
    wire        cout64;

    sparc_exu_aluadder64 adder (
        .rs1_data (cnt),
        .rs2_data (cnt ^ 64'h9e37_79b9_7f4a_7c15),
        .cin      (cnt[0]),
        .adder_out(sum),
        .cout32   (cout32),
        .cout64   (cout64)
    );

    // Active-low LEDs on the Tang Mega 138K Pro Dock.
    assign led = ~{cout64, sum[25:21]};

endmodule