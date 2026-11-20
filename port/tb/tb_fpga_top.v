`timescale 1ns/1ps

module tb_fpga_top;
    reg clk = 1'b0;
    reg reset_l = 1'b0;
    wire [5:0] led;

    always #10 clk = ~clk;  // 50 MHz

    t1_fpga_top dut (
        .clk     (clk),
        .reset_l (reset_l),
        .led     (led)
    );

    initial begin
        repeat (20) @(posedge clk);
        reset_l = 1'b1;
        $display("FPGA TB: reset released");
    end

    initial begin
        repeat (20000) @(posedge clk);
        if (led[3] !== 1'b0) begin
            $display("FPGA WRAPPER FAIL: led=%b", led);
            $finish;
        end
    end

    always @(posedge clk) begin
        if (reset_l && led[3] === 1'b0) begin
            $display("FPGA WRAPPER PASS: boot image executed");
            $finish;
        end
    end
endmodule