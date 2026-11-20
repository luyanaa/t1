// Small T1 leaf block wrapped in a register-to-register stage so that the
// LibreLane ASIC flow has a clocked design to place and route.

module t1_asic_smoke (
    input  wire        clk,
    input  wire        reset_l,
    input  wire [63:0] a,
    input  wire [63:0] b,
    input  wire        cin,
    output wire [63:0] sum,
    output wire        cout
);

    reg [63:0] a_r;
    reg [63:0] b_r;
    reg        cin_r;

    always @(posedge clk) begin
        if (!reset_l) begin
            a_r   <= 64'b0;
            b_r   <= 64'b0;
            cin_r <= 1'b0;
        end
        else begin
            a_r   <= a;
            b_r   <= b;
            cin_r <= cin;
        end
    end

    wire [63:0] adder_out;
    wire        cout32;
    wire        cout64;

    sparc_exu_aluadder64 adder (
        .rs1_data (a_r),
        .rs2_data (b_r),
        .cin      (cin_r),
        .adder_out(adder_out),
        .cout32   (cout32),
        .cout64   (cout64)
    );

    reg [63:0] sum_r;
    reg        cout_r;

    always @(posedge clk) begin
        sum_r  <= adder_out;
        cout_r <= cout64;
    end

    assign sum  = sum_r;
    assign cout = cout_r;

endmodule