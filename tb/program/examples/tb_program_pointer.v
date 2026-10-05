`timescale 1ns / 1ps

// Testbench: tb_program_pointer
// Purpose: Runs a small firmware example as a directed CPU instruction/program check.
// Checks: La-derived pointer loads and stores through data memory.
// Pass condition: Firmware-visible register, memory, debug_status, I/O, or transcript signatures match expected
//   values before timeout.
// Firmware: firmware/hex/examples/pointer_store.hex

module tb_program_pointer;

`include "tb_common.vh"

    initial begin
        $dumpfile("results/waveforms/tb_program_pointer.vcd");
        $dumpvars(0, tb_program_pointer);
        reset_cpu();

        $readmemh("firmware/hex/examples/pointer_store.hex", dut.IMemory, 0, 7);
        dut.DMemory[8] = 32'hdead_beef;   // data_slot at byte address 32
        dut.DMemory[24] = 32'hcafe_babe;  // byte address 96 evicts data_slot

        run_cycles(300);

        check_reg(5, 32'd32);          // t0 = &data_slot
        check_reg(6, 32'h1234_5678);   // t1
        check_reg(10, 32'h1234_5678);  // a0 = *data_slot
        check_reg(8, 32'hcafe_babe);   // s0

        if (dut.DMemory[8] !== 32'h1234_5678) begin
            $display("FAIL: pointer store expected DMemory[8] = %h, got %h",
                     32'h1234_5678, dut.DMemory[8]);
            $fatal;
        end

        $display("PASS: la-derived pointer loaded and stored through DMemory");
        $display("PASS: tb_program_pointer passed");
        $finish;
    end

endmodule
