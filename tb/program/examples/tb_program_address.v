`timescale 1ns / 1ps

// Testbench: tb_program_address
// Purpose: Runs a small firmware example as a directed CPU instruction/program check.
// Checks: La-style address expansion for forward and backward labels.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/examples/address_labels.hex

module tb_program_address;

`include "tb_common.vh"

    initial begin
        $dumpfile("wave/tb_program_address.vcd");
        $dumpvars(0, tb_program_address);
        reset_cpu();

        $readmemh("firmware/hex/examples/address_labels.hex", dut.IMemory, 0, 12);
        dut.DMemory[16] = 32'hface_cafe;

        run_cycles(300);

        check_reg(5, 32'd36);          // t0 = address of selected
        check_reg(6, 32'd0);           // t1 = address of start
        check_reg(7, 32'h1357_9bdf);   // t2, wrong path was flushed
        check_reg(28, 32'd36);         // t3 = selected - start
        check_reg(8, 32'hface_cafe);   // s0

        if (dut.DMemory[0] !== 32'd36) begin
            $display("FAIL: la result expected DMemory[0] = %h, got %h",
                     32'd36, dut.DMemory[0]);
            $fatal;
        end

        $display("PASS: la pseudos loaded forward/backward label addresses");
        $display("PASS: tb_program_address passed");
        $finish;
    end

endmodule
