`timescale 1ns / 1ps

// Testbench: tb_program_board_smoke
// Purpose: Runs showcase firmware and observes public status, I/O, or transcript outputs.
// Checks: Board-smoke program writes the pass value to the status address.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/showcase/board_smoke.hex

module tb_program_board_smoke;

`include "tb_common.vh"

    initial begin
        $dumpfile("wave/tb_program_board_smoke.vcd");
        $dumpvars(0, tb_program_board_smoke);
        reset_cpu();

        $readmemh("firmware/hex/showcase/board_smoke.hex", dut.IMemory, 0, 6);

        run_cycles(260);

        check_reg(5, 32'd256);         // t0 = status address
        check_reg(6, 32'h600d_cafe);   // t1 = pass value
        check_reg(8, 32'h0);           // s0 = conflicting block load from cleared memory

        if (dut.DMemory[64] !== 32'h600d_cafe) begin
            $display("FAIL: board smoke expected DMemory[64] = %h, got %h",
                     32'h600d_cafe, dut.DMemory[64]);
            $fatal;
        end

        if (debug_status !== 32'h600d_cafe) begin
            $display("FAIL: board smoke expected debug_status = %h, got %h",
                     32'h600d_cafe, debug_status);
            $fatal;
        end

        if (debug_pc !== 32'd24) begin
            $display("FAIL: board smoke expected debug_pc = %h, got %h", 32'd24, debug_pc);
            $fatal;
        end

        $display("PASS: board smoke wrote pass value to status address 0x100");
        $display("PASS: tb_program_board_smoke passed");
        $finish;
    end

endmodule
