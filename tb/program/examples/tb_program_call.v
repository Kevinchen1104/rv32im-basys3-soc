`timescale 1ns / 1ps

// Testbench: tb_program_call
// Purpose: Runs a small firmware example as a directed CPU instruction/program check.
// Checks: An assembled call program returns a value through jal/jalr flow.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/examples/call_add.hex

module tb_program_call;

`include "tb_common.vh"

    initial begin
        $dumpfile("wave/tb_program_call.vcd");
        $dumpvars(0, tb_program_call);
        reset_cpu();

        $readmemh("firmware/hex/examples/call_add.hex", dut.IMemory, 0, 7);
        dut.DMemory[16] = 32'h1234_abcd;  // address 64, evicts result at address 0

        run_cycles(220);

        check_reg(1, 32'd8);
        check_reg(10, 32'd12);
        check_reg(4, 32'h1234_abcd);

        if (dut.DMemory[0] !== 32'd12) begin
            $display("FAIL: returned value expected DMemory[0] = %h, got %h", 32'd12, dut.DMemory[0]);
            $fatal;
        end

        if (dut.RASCount !== 4'd0) begin
            $display("FAIL: RASCount expected 0, got %0d", dut.RASCount);
            $fatal;
        end

        $display("PASS: loaded call program returned value = %0d", dut.DMemory[0]);
        $display("PASS: tb_program_call passed");
        $finish;
    end

endmodule
