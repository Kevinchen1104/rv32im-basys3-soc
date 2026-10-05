`timescale 1ns / 1ps

// Testbench: tb_load_use_decode
// Purpose: Checks a focused CPU core unit or core-level smoke path.
// Checks: Load-use decode distinguishes real source dependencies from I-type immediate bit aliases.
// Pass condition: All self-checks complete on the PASS path without a mismatch, timeout, or $fatal.

module tb_load_use_decode;

`include "tb_common.vh"

    reg saw_false_stall_window;
    reg saw_true_stall_window;

    always @(posedge clock) begin
        if (!reset &&
            dut.IDEXMemRead &&
            (dut.IDEXrd == 5'd5) &&
            (dut.IFIDop == 7'b0010011) &&
            (dut.IFIDrs1 == 5'd0) &&
            (dut.IFIDrs2 == 5'd5)) begin

            saw_false_stall_window = 1'b1;

            if (dut.load_use_hazard !== 1'b0) begin
                $display("FAIL: I-type immediate bits caused a false load-use stall");
                $fatal;
            end
        end

        if (!reset &&
            dut.IDEXMemRead &&
            (dut.IDEXrd == 5'd7) &&
            (dut.IFIDop == 7'b0110011) &&
            (dut.IFIDrs1 == 5'd7)) begin

            saw_true_stall_window = 1'b1;

            if (dut.load_use_hazard !== 1'b1) begin
                $display("FAIL: true load-use dependency did not stall");
                $fatal;
            end
        end
    end

    initial begin
        $dumpfile("results/waveforms/tb_load_use_decode.vcd");
        $dumpvars(0, tb_load_use_decode);
        saw_false_stall_window = 1'b0;
        saw_true_stall_window = 1'b0;
        reset_cpu();

        dut.DMemory[0] = 32'd123;
        dut.DMemory[1] = 32'd9;

        dut.IMemory[0] = i_type(12'd0, 5'd0, 3'b010, 5'd5, 7'b0000011);   // lw x5, 0(x0)
        dut.IMemory[1] = i_type(12'd5, 5'd0, 3'b000, 5'd6, 7'b0010011);   // addi x6, x0, 5; imm[4:0] aliases x5
        dut.IMemory[2] = i_type(12'd4, 5'd0, 3'b010, 5'd7, 7'b0000011);   // lw x7, 4(x0)
        dut.IMemory[3] = r_type(7'b0000000, 5'd0, 5'd7, 3'b000, 5'd8, 7'b0110011); // add x8, x7, x0
        dut.IMemory[4] = b_type(0, 5'd0, 5'd0, 3'b000, 7'b1100011);       // halt

        run_cycles(180);

        check_reg(5, 32'd123);
        check_reg(6, 32'd5);
        check_reg(7, 32'd9);
        check_reg(8, 32'd9);

        if (!saw_false_stall_window) begin
            $display("FAIL: did not observe false-stall decode window");
            $fatal;
        end

        if (!saw_true_stall_window) begin
            $display("FAIL: did not observe true load-use decode window");
            $fatal;
        end

        $display("PASS: load-use decode distinguishes real rs2 from I-type immediates");
        $display("PASS: tb_load_use_decode passed");
        $finish;
    end

endmodule
